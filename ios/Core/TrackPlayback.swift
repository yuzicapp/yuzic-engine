import Foundation
import AVFoundation

/**
 Keeps one player node fed.

 The reader blocks — it has to, since `AudioFile_ReadProc` has no async form —
 so decoding happens on its own queue and never on the render thread. What this
 class does is keep a couple of seconds of PCM scheduled ahead, so a slow
 network read costs buffer-ahead rather than a dropout.

 Scheduling is driven by completion rather than a timer: every buffer handed to
 the node carries a callback asking for the next one. The depth is then
 self-correcting — slow decoding drains the queue and refills as fast as it can,
 fast decoding leaves it at target with the thread asleep.
 */
public final class TrackPlayback {

  /// Half a second each, four deep: two seconds of slack. Enough to ride out a
  /// window fetch on a slow connection, short enough that a stop takes effect
  /// promptly.
  public static let bufferFrames: AVAudioFrameCount = 22_050
  public static let targetBuffersAhead = 4

  /**
   How many times a failing read is retried before the track is given up on.

   A cap on requests, not on time — see `readRetryBudgetSec` for the wait a
   listener actually experiences. The first version allowed five over 3.75
   seconds, which is not a stall on a patchy cellular link but a blink, and
   giving up inside it turned a momentary drop into a paused player a minute
   into a song. A listener will forgive a gap far longer than they will forgive
   having to press play again.
   */
  public static let readRetries = 20

  /**
   How long the ladder may keep trying, in wall clock.

   The attempt count alone was not a budget. Every attempt calls through to a
   range request that can block for its own timeout, so "twenty attempts" was
   twenty *plus* however long each read sat there — minutes of silence, not the
   half-minute the comment above claims. The count still caps the number of
   requests; this caps the wait a listener actually experiences.
   */
  public static let readRetryBudgetSec: TimeInterval = 40
  /// Base delay, multiplied by the attempt and capped, so the ladder backs off
  /// without the last rungs becoming minutes apart.
  public static let readRetryDelaySec: TimeInterval = 0.25
  public static let readRetryMaxDelaySec: TimeInterval = 2.0

  /// Fires the first time a read fails, so the engine can say it is waiting
  /// rather than go quiet while pretending to play.
  public var onReadStalled: (() -> Void)?
  /// Fires when reads recover, so it can say so again.
  public var onReadResumed: (() -> Void)?

  /**
   Fires when the node has run out of scheduled audio.

   The stall pair above only speaks for a read that **threw**. A read that is
   merely slow — anything up to `HTTPByteFetcher.defaultTimeout`, which is
   eight seconds — returns successfully and says nothing, so the depth drains
   to zero, the node renders silence, the rendered position stops advancing
   and the engine goes on reporting `.playing`. That is the dropout listeners
   describe as the music cutting out and coming back, and it is the one
   remaining way this engine fails with no instrument on it: nothing throws,
   nothing is counted, nothing is logged, and §12 of `docs/architecture.md`
   is a list of exactly this shape of fault.

   Raised from the buffer completion that takes the depth to zero, which is
   the moment the node has nothing left to render — not a prediction that it
   is about to, and not an inference from a clock.
   */
  public var onUnderrun: (() -> Void)?
  /// Fires when a buffer is scheduled again after an underrun.
  public var onUnderrunEnded: (() -> Void)?

  private let reader: TrackReader
  private let voice: AudioGraph.Voice
  private let queue: DispatchQueue
  private let lock = NSLock()

  private var scheduledAhead = 0
  private var stopped = false
  private var reachedEnd = false
  private var startFrameValue: Int64 = 0

  /// Fires once the last scheduled buffer has played out.
  public var onEndOfTrack: (() -> Void)?

  /**
   Fires when the first buffer of this track is handed to the node.

   The gap between `start()` and this is real and can be long: `start` only
   dispatches, and the decode it dispatches blocks on the network. On a slow
   connection a large file can sit there for a long time with nothing
   scheduled and nothing playing, so an engine that announces "playing" at
   `start()` is announcing something that has not happened.

   Fires at most once, from the decode queue.
   */
  public var onFirstBufferScheduled: (() -> Void)?

  private var scheduledAny = false
  /// Whether the node is currently out of audio — see `onUnderrun`.
  private var underrunning = false
  /// Consecutive failed reads, reset by any successful one.
  private var consecutiveFailures = 0
  /// When the current run of failures began, for the wall-clock budget.
  private var stalledSince: Date?

  /**
   Fires when reads have failed enough times to give up on the track.

   Distinct from `onEndOfTrack`, and the distinction is the point: a read that
   *throws* is a failure, and a read that returns nothing is the end of the
   file. `AudioFileReader.read` already says which is which — it returns nil at
   the end and throws on error — and collapsing the two made a dropped
   connection indistinguishable from a track finishing normally.
   */
  public var onReadFailed: ((Error) -> Void)?

  /// This playback's retry ladder. Instance rather than static so a test can
  /// drive the give-up path in milliseconds instead of waiting out the real
  /// half-minute — the budget is deliberately long, and a suite that waits for
  /// it is a suite people stop running.
  private let retries: Int
  private let retryDelaySec: TimeInterval

  public init(
    reader: TrackReader,
    voice: AudioGraph.Voice,
    label: String = "decode",
    retries: Int = TrackPlayback.readRetries,
    retryDelaySec: TimeInterval = TrackPlayback.readRetryDelaySec
  ) {
    self.reader = reader
    self.voice = voice
    self.retries = retries
    self.retryDelaySec = retryDelaySec
    self.queue = DispatchQueue(label: "dev.yuzic.engine.\(label)", qos: .userInitiated)
  }

  public var startFrame: Int64 {
    lock.lock(); defer { lock.unlock() }
    return startFrameValue
  }

  /**
   Where playback has actually reached, in frames from the start of the track.

   Derived from the node's own render time rather than counted on the way in:
   what has been *scheduled* runs ahead of what has been *heard* by exactly the
   buffer depth, and reporting the former would put the progress bar two seconds
   into the future.
   */
  /**
   Whether this playback can still produce audio.

   `resume()` on a finished one is silence: it calls `play()` on the node and
   then `fill()`, which returns immediately because `stopped` is set. Nothing
   throws and nothing recovers, so a caller that resumes rather than restarts
   has no way back. The engine asks this before choosing which to do.
   */
  public var isFinished: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped || reachedEnd
  }

  /**
   The last position the node reported, for when it can no longer be asked.

   `lastRenderTime` stops carrying a valid time once the node is stopped, and
   the fallback below is `startFrame` — where this playback *began*. For a
   track that has been playing for three minutes that is three minutes wrong,
   and it is exactly the number a restart needs to be right.
   */
  private var lastKnownFrame: Int64 = 0

  public var currentFrame: Int64 {
    // `playerTime(forNodeTime:)` is not merely optional-returning: it asserts
    // that the time it is handed carries a valid sample or host time, and
    // `lastRenderTime` returns one with neither in the window between starting
    // a node and its first render. Passing that straight through traps —
    // a hard crash, not a nil — and the window is exactly when the lock screen
    // asks for a position.
    guard let nodeTime = voice.player.lastRenderTime,
          nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
          let playerTime = voice.player.playerTime(forNodeTime: nodeTime) else {
      return max(startFrame, lastKnownFrame)
    }
    let frame = startFrame + playerTime.sampleTime
    lastKnownFrame = frame
    return frame
  }

  /**
   Begin decoding, reporting positions from `frame`.

   `readerOrigin` is which frame of the *track* the reader's own frame zero
   is. Zero for every reader that holds the whole file, which is why it
   defaults there and why most callers never mention it. A stream restarted
   partway in is the exception: the server was asked for the track from
   `timeOffset` onwards, so the bytes begin at that point and the reader
   counts from zero regardless — while the position the listener sees, the
   lock screen's fix point and the scrobble all have to keep counting from
   where the track really is. Separating the two is what stops a reconnection
   from throwing the progress bar back to 0:00.
   */
  public func start(atFrame frame: Int64 = 0, readerOrigin: Int64 = 0) throws {
    // Asked before anything moves. `AVAudioPlayerNode.play()` on a stopped
    // engine raises an Objective-C exception rather than returning an error,
    // and the system stops the engine whenever it takes audio away — so this
    // was a crash waiting behind every interruption.
    guard voice.player.engine?.isRunning == true else { throw PlaybackError.graphNotRunning }

    lock.lock()
    stopped = false
    reachedEnd = false
    scheduledAhead = 0
    scheduledAny = false
    underrunning = false
    startFrameValue = frame
    readerOriginValue = readerOrigin
    consecutiveFailures = 0
    stalledSince = nil
    lock.unlock()

    try reader.seek(toFrame: max(0, frame - readerOrigin))
    fill()
    voice.player.play()
  }

  public enum PlaybackError: Error, Equatable {
    /// The engine this voice belongs to is not running, so nothing can play.
    case graphNotRunning
  }

  /// Which frame of the track the reader's own frame zero is — see `start`.
  /// Kept so the playback can be rebuilt at the same place after the system
  /// tears the graph down, without losing a reconnected stream's offset.
  public var readerOrigin: Int64 {
    lock.lock(); defer { lock.unlock() }
    return readerOriginValue
  }
  private var readerOriginValue: Int64 = 0

  public func pause() { voice.player.pause() }

  /// Resume a paused node. Does nothing on a stopped engine — see `start` —
  /// which the engine avoids by rebuilding instead of resuming after the
  /// system has taken audio away.
  public func resume() {
    guard voice.player.engine?.isRunning == true else { return }
    voice.player.play()
    // A long pause can drain the queue; top it up rather than waiting for a
    // completion callback that is never going to arrive.
    fill()
  }

  /**
   Stop feeding the node, and unblock the decode thread if it is waiting.

   `stopped` is set before the node is stopped so the completion handlers that
   `stop()` fires for the flushed buffers see it and do not schedule more.

   The cancel is what makes this prompt. Without it a producer parked in a
   network read stays parked — holding a thread and a request open until the
   HTTP timeout, long after nothing wants the audio. It does not wait for that
   to happen: the thread unwinds on its own, and this playback is being
   discarded either way.
   */
  public func stop() {
    lock.lock(); stopped = true; lock.unlock()
    voice.player.stop()
    reader.cancelPendingReads()
  }

  /**
   Stop, and do not return until the decode thread has actually unwound.

   For the one case where the difference matters: a seek builds a new
   `TrackPlayback` over the *same* reader, and `AudioFileReader` is explicitly
   not thread-safe. Returning while the old producer is still inside
   `ExtAudioFileRead` would leave two threads in one reader, with the new one
   seeking it — which is undefined behaviour rather than a race that merely
   sounds bad.

   The queue is serial, so an empty block is a barrier: it runs only once the
   read in flight has returned. The reads are put back to work afterwards
   because the reader is about to be reused, and a cancelled source refuses
   everything.
   */
  public func stopAndWait() {
    stop()
    queue.sync {}
    reader.resumePendingReads()
  }

  /// Decode and schedule until the target depth is reached. Safe to call
  /// spuriously — it returns immediately when there is nothing to do.
  public func fill() {
    queue.async { [weak self] in
      guard let self else { return }

      while true {
        self.lock.lock()
        let idle = self.stopped || self.reachedEnd || self.scheduledAhead >= Self.targetBuffersAhead
        self.lock.unlock()
        if idle { return }

        let buffer: AVAudioPCMBuffer?
        do {
          buffer = try self.reader.read(frames: Self.bufferFrames)
          self.lock.lock()
          let wasStalled = self.consecutiveFailures > 0
          self.consecutiveFailures = 0
          self.stalledSince = nil
          self.lock.unlock()
          if wasStalled { self.onReadResumed?() }
        } catch {
          // A read that throws is a *failure*, not an end. This used to set
          // `reachedEnd` and the track reported a normal completion, so a
          // network hiccup was indistinguishable from the file running out —
          // and the engine advanced to the next track. Reported as songs
          // "skipping" part-way through, at a different point every time,
          // over the network only and never on downloaded files. Nothing threw
          // where anyone could see it: the failure was reported as success.
          self.lock.lock()
          self.consecutiveFailures += 1
          let attempt = self.consecutiveFailures
          if self.stalledSince == nil { self.stalledSince = Date() }
          let stalledFor = Date().timeIntervalSince(self.stalledSince ?? Date())
          let givenUp = self.stopped
          self.lock.unlock()
          if givenUp { return }

          if attempt == 1 { self.onReadStalled?() }

          if attempt <= self.retries && stalledFor < Self.readRetryBudgetSec {
            // Re-dispatched rather than slept. Sleeping holds the decode
            // queue, and `stopAndWait` does `queue.sync {}` from the main
            // thread — so a backoff would block the interface for its whole
            // length, which is the fault this engine has just finished
            // removing from two other paths.
            let delay = min(
              self.retryDelaySec * Double(attempt), Self.readRetryMaxDelaySec
            )
            self.queue.asyncAfter(deadline: .now() + delay) { [weak self] in
              self?.fill()
            }
            return
          }

          self.lock.lock(); self.stopped = true; self.lock.unlock()
          self.onReadFailed?(error)
          return
        }

        // Nothing to read *without* an error is the genuine end of the file.
        guard let buffer, buffer.frameLength > 0 else {
          self.lock.lock(); self.reachedEnd = true; self.lock.unlock()
          self.notifyEndIfDrained()
          return
        }

        self.lock.lock()
        self.scheduledAhead += 1
        let isFirst = !self.scheduledAny
        self.scheduledAny = true
        // Claimed here rather than in the completion handler: the drought
        // ends when there is audio to render again, which is now, not when
        // the buffer that ends it finishes playing half a second later.
        let recovered = self.underrunning
        self.underrunning = false
        self.lock.unlock()
        if isFirst { self.onFirstBufferScheduled?() }
        if recovered { self.onUnderrunEnded?() }

        self.voice.player.scheduleBuffer(buffer) { [weak self] in
          guard let self else { return }
          self.lock.lock()
          self.scheduledAhead -= 1
          // Zero depth with the track neither finished nor stopped is the
          // node about to render silence. `reachedEnd` excludes the ordinary
          // drain at the end of a track, and `stopped` the flush that
          // `stop()` fires a completion for on every buffer it discards —
          // both of which reach zero legitimately.
          let starved =
            self.scheduledAhead <= 0 && !self.reachedEnd && !self.stopped && !self.underrunning
          if starved { self.underrunning = true }
          self.lock.unlock()
          if starved { self.onUnderrun?() }
          self.notifyEndIfDrained()
          self.fill()
        }
      }
    }
  }

  private func notifyEndIfDrained() {
    lock.lock()
    let done = reachedEnd && scheduledAhead <= 0 && !stopped
    if done { stopped = true }
    lock.unlock()
    if done { onEndOfTrack?() }
  }
}
