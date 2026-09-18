import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 The dropout with no instrument on it.

 Every fault handled before this one *threw*: a read that failed, a stream
 that ended short, an interruption, a media server that died. A read that is
 merely slow throws nothing. It returns, late, having succeeded — and in the
 meantime the scheduled depth drains, the node renders silence, the rendered
 position stops advancing, and the engine goes on reporting `.playing`. There
 was no signal, no count and no log line for any of it.

 That is the residual cut-out reported over the network after every other fix:
 the music stops for a few seconds and comes back, at no particular point in
 the track, with nothing wrong anywhere anyone could look. §12 of
 `docs/architecture.md` is a list of faults of exactly this shape — correct
 code succeeding at nothing — and this was the last one still unlit.

 These cover the detection (`TrackPlayback`) and the policy (`PlaybackEngine`)
 separately, because they answer different questions. The first is "did the
 node actually run out", which must be true of the depth and nothing else. The
 second is "does the listener get told", which deliberately is *not* true of
 every underrun — see `underrunGraceSec`.
 */
final class UnderrunTests: XCTestCase {

  // MARK: - Detection

  /**
   A reader that serves buffers until told to stop, then blocks in `read`
   without throwing — which is what a slow range request looks like from here.

   Blocking rather than throwing is the whole point. A throwing reader takes
   the retry ladder, which has been instrumented since `onReadStalled` was
   wired up; this one takes no path at all, which is why nothing saw it.
   */
  private final class SlowReader: TrackReader {
    let totalFrames: Int64 = 44_100 * 60
    let sampleRate: Double = 44_100
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Held by the reader while it is "waiting on the network".
    private let gate = DispatchSemaphore(value: 0)
    /// Fulfilled as the reader enters the blocking read, so a test knows the
    /// buffers before it are scheduled and it is safe to drain them.
    let blocked = XCTestExpectation(description: "reader is waiting on the network")

    private var servedBeforeBlocking: Int
    private var blockedOnce = false
    /// Serve this many more once released, so recovery has something to
    /// schedule.
    private var afterRelease = 4

    init(servesBeforeBlocking: Int) {
      self.servedBeforeBlocking = servesBeforeBlocking
    }

    func open() throws {}
    func seek(toFrame frame: Int64) throws {}
    func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 { 0 }
    func cancelPendingReads() { gate.signal() }
    func resumePendingReads() {}

    /// Let the stalled read complete.
    func release() { gate.signal() }

    private func tone(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      return buffer
    }

    func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
      if servedBeforeBlocking > 0 {
        servedBeforeBlocking -= 1
        return tone(frames)
      }
      if !blockedOnce {
        blockedOnce = true
        blocked.fulfill()
        gate.wait()
      }
      guard afterRelease > 0 else {
        // Park rather than end: a reader that returned nil here would report
        // the end of the track and take the assertions with it.
        gate.wait()
        return nil
      }
      afterRelease -= 1
      return tone(frames)
    }
  }

  /// Serves a fixed number of buffers and then genuinely ends.
  private final class ShortReader: TrackReader {
    let totalFrames: Int64
    let sampleRate: Double = 44_100
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var remaining: Int

    init(buffers: Int) {
      self.remaining = buffers
      self.totalFrames = Int64(buffers) * Int64(TrackPlayback.bufferFrames)
    }

    func open() throws {}
    func seek(toFrame frame: Int64) throws {}
    func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 { 0 }
    func cancelPendingReads() {}
    func resumePendingReads() {}

    func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
      guard remaining > 0 else { return nil }
      remaining -= 1
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
      buffer.frameLength = frames
      return buffer
    }
  }

  /// The graph has to outlive the playback — see `TrackPlaybackFailureTests`.
  private var graph: AudioGraph?

  private func offlineGraph() throws -> AudioGraph {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    self.graph = graph
    return graph
  }

  override func tearDown() {
    graph = nil
    super.tearDown()
  }

  func testDrainingTheNodeRaisesAnUnderrun() throws {
    let graph = try offlineGraph()
    let reader = SlowReader(servesBeforeBlocking: 2)
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)

    let underran = expectation(description: "underrun raised")
    playback.onUnderrun = { underran.fulfill() }

    try playback.start(atFrame: 0)
    // Wait until the reader is parked, so what follows drains a queue nothing
    // is refilling — the condition being tested, rather than a race against
    // the decode thread.
    wait(for: [reader.blocked], timeout: 5)

    // Two buffers were scheduled before the block. Render past both.
    _ = try graph.renderOffline(frames: TrackPlayback.bufferFrames * 3)

    wait(for: [underran], timeout: 5)
    // Unwound through the playback, not just the reader: `tearDown` drops the
    // graph, and a producer still running would schedule into a voice whose
    // engine has gone. `stop()` cancels the pending read on its way.
    playback.stopAndWait()
  }

  func testServingAgainEndsTheUnderrun() throws {
    let graph = try offlineGraph()
    let reader = SlowReader(servesBeforeBlocking: 2)
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)

    let underran = expectation(description: "underrun raised")
    let ended = expectation(description: "underrun ended")
    playback.onUnderrun = { underran.fulfill() }
    playback.onUnderrunEnded = { ended.fulfill() }

    try playback.start(atFrame: 0)
    wait(for: [reader.blocked], timeout: 5)
    _ = try graph.renderOffline(frames: TrackPlayback.bufferFrames * 3)
    wait(for: [underran], timeout: 5)

    reader.release()
    wait(for: [ended], timeout: 5)
    playback.stopAndWait()
  }

  /**
   The ordinary drain at the end of a track is not an underrun.

   It reaches zero depth like every other drain, and a check written against
   the depth alone would report one on every track a listener ever finishes —
   which would make the count worthless and the spinner a liar.
   */
  func testTheEndOfATrackIsNotAnUnderrun() throws {
    let graph = try offlineGraph()
    let reader = ShortReader(buffers: 3)
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)

    var underruns = 0
    let finished = expectation(description: "track finished")
    playback.onUnderrun = { underruns += 1 }
    playback.onEndOfTrack = { finished.fulfill() }

    try playback.start(atFrame: 0)
    _ = try graph.renderOffline(frames: TrackPlayback.bufferFrames * 5)

    wait(for: [finished], timeout: 5)
    XCTAssertEqual(underruns, 0,
                   "a track that finished is not a track that ran out of audio")
  }

  /**
   Nor is a stop.

   `stop()` flushes the node, and the node fires a completion for every buffer
   it discards. Those completions run the same handler and reach zero depth,
   so without the guard each would report the listener's own skip as a
   dropout.
   */
  func testStoppingIsNotAnUnderrun() throws {
    let graph = try offlineGraph()
    let reader = SlowReader(servesBeforeBlocking: 4)
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)

    var underruns = 0
    playback.onUnderrun = { underruns += 1 }

    try playback.start(atFrame: 0)
    wait(for: [reader.blocked], timeout: 5)
    playback.stop()
    _ = try graph.renderOffline(frames: TrackPlayback.bufferFrames * 6)

    XCTAssertEqual(underruns, 0, "a stop discards buffers; it does not run out of them")
    playback.stopAndWait()
  }

  // MARK: - Policy

  private final class BlobSource: ByteSource {
    let blob: Data
    init(_ blob: Data) { self.blob = blob }
    var isSequential: Bool { false }
    func totalBytes() throws -> Int64 { Int64(blob.count) }
    func read(offset: Int64, count: Int) throws -> Data {
      let end = min(Int(offset) + count, blob.count)
      guard Int(offset) < end else { return Data() }
      return blob.subdata(in: Int(offset)..<end)
    }
    func availableBytes(from offset: Int64) -> Int64 { max(0, Int64(blob.count) - offset) }
    func cancel() {}
    func resume() {}
  }

  private final class BlobFactory: TrackReaderFactory {
    let data: Data
    init(data: Data) { self.data = data }
    func makeReader(for track: Track) throws -> TrackReader {
      try makeReader(for: track, timeOffsetSeconds: 0)
    }
    func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
      AudioFileReader(source: BlobSource(data))
    }
  }

  private func makeEngine() throws -> PlaybackEngine {
    let fixture = try EncodedFixture.wav(seconds: 30)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    self.graph = graph
    return PlaybackEngine(graph: graph, factory: BlobFactory(data: fixture.data))
  }

  private func settle(timeout: TimeInterval = 3, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  private func playing(_ engine: PlaybackEngine) throws {
    let track = Track(id: "t", uri: "https://example.test/t", title: "t", durationSec: 30)
    engine.setQueue([track], startIndex: 0)
    try engine.play()
    // The track opens off the main thread, and the engine stays `.buffering`
    // until the first buffer is scheduled — so both have to have happened
    // before any of this means anything.
    settle { engine.activePlaybackIsWiredForTesting && engine.state == .playing }
    XCTAssertEqual(engine.state, .playing, "the fixture has to be playing before it can stop")
  }

  /**
   A drought long enough to hear is drawn.

   Thirty seconds of unexplained silence is the bug. Thirty seconds of visible
   buffering is a player doing its job on a bad link — the same argument that
   made the read-stall signal worth wiring, applied to the case that never
   throws.
   */
  func testAnUnderrunThatLastsIsShownAsBuffering() throws {
    let engine = try makeEngine()
    try playing(engine)

    engine.underrunActiveTrackForTesting()
    settle { engine.state == .buffering }
    XCTAssertEqual(engine.state, .buffering)

    engine.endUnderrunActiveTrackForTesting()
    settle { engine.state == .playing }
    XCTAssertEqual(engine.state, .playing)
  }

  /**
   A drought that ends inside the grace is not.

   The decode thread refills from its own completion handler, so the depth
   touching zero and being served again a few milliseconds later is routine
   and inaudible. Drawing it would flash a spinner over music that never
   stopped, which is a worse instrument than none.
   */
  func testAMomentaryUnderrunIsNeverDrawn() throws {
    let engine = try makeEngine()
    try playing(engine)

    engine.underrunActiveTrackForTesting()
    engine.endUnderrunActiveTrackForTesting()

    // Past the grace, so a pending announcement would have landed by now.
    let deadline = Date().addingTimeInterval(PlaybackEngine.underrunGraceSec * 3)
    var seenBuffering = false
    while Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
      if engine.state == .buffering { seenBuffering = true }
    }
    XCTAssertFalse(seenBuffering, "a gap nobody heard is a gap nobody should be shown")
    XCTAssertEqual(engine.state, .playing)
  }

  /**
   Counted even when it is not drawn.

   The count is the instrument; the grace is a drawing decision. A track that
   underran forty times inside the grace played — but not in any way its
   listener would call playing, and that has to be legible from a device log
   even though nothing was ever put on screen.
   */
  func testEveryUnderrunIsCountedWhetherOrNotItIsDrawn() throws {
    let engine = try makeEngine()
    try playing(engine)

    for _ in 0..<3 {
      engine.underrunActiveTrackForTesting()
      engine.endUnderrunActiveTrackForTesting()
    }
    settle(timeout: 1) { engine.underrunCountForTesting == 3 }
    XCTAssertEqual(engine.underrunCountForTesting, 3)
  }

  /**
   An underrun ending does not clear a read stall.

   Both draw `.buffering`, and a buffer arriving is not proof the connection
   came back: the decoder may simply be handing over the last thing it read
   before the stream broke. Clearing here would put the player back to
   `playing` in the middle of the retry ladder — the unexplained silence this
   whole line of work exists to remove, restored.
   */
  func testEndingAnUnderrunLeavesAReadStallShowing() throws {
    let engine = try makeEngine()
    try playing(engine)

    // A real drought first, so the end of it is not turned away for having
    // nothing to end — otherwise this passes on the wrong guard and says
    // nothing about the one it is here to check.
    engine.underrunActiveTrackForTesting()
    settle { engine.state == .buffering }
    XCTAssertEqual(engine.state, .buffering, "the drought has to be showing before it can be wrongly cleared")

    engine.stallActiveTrackForTesting()
    engine.endUnderrunActiveTrackForTesting()
    settle(timeout: 0.5) { engine.state == .playing }
    XCTAssertEqual(engine.state, .buffering,
                   "reads are still in the ladder; only onReadResumed may say otherwise")

    // And the ladder's own recovery does clear it, so the guard above is a
    // guard and not a wall.
    engine.resumeActiveTrackForTesting()
    settle { engine.state == .playing }
    XCTAssertEqual(engine.state, .playing)
  }
}
