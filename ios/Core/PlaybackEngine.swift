import Foundation
import AVFoundation

/// Opens a decodable stream for a track. Injected so the engine can be driven
/// from fixtures in a test without a network, and so the choice between the two
/// transports lives in one place rather than inside the engine.
public protocol TrackReaderFactory {
  func makeReader(for track: Track) throws -> TrackReader

  /**
   A reader for `track` whose first frame is `timeOffsetSeconds` into it.

   Only meaningful for the sequential transport, and only the sequential
   transport implements it: a ranged source is seekable, so the engine reaches
   an offset with `seek` and never asks for this. On a transcoded stream there
   is nothing to seek — the offset has to be part of the *request*, which
   makes the result a different byte stream and so a different reader.

   The default ignores the offset, which is the right answer for any factory
   that only ever hands back seekable readers, test doubles included.
   */
  func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader
}

public extension TrackReaderFactory {
  func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
    try makeReader(for: track)
  }
}

/**
 The player: queue, graph, and the rules about moving between tracks.

 Two `TrackPlayback`s, one per voice, alternating. While one is playing the
 other is either idle or being prepared, and a crossfade is the window where
 both are running and their gains are moving in opposite directions.

 Everything about *when* to move is decided here rather than in JavaScript,
 because a backgrounded app's JS is suspended and the transition still has to
 happen. `PlaybackQueue.transitionDuration` supplies the how-long; this supplies
 the when.
 */
public final class PlaybackEngine {

  public enum Event {
    case stateChanged(PlaybackState)
    /// Fired at the crossover point, so it lines up with what is being heard
    /// rather than with when the machinery started moving. `listenedSec` is the
    /// outgoing track's played time *including* its fade-out — a host
    /// scrobbling on "half the track" needs that, or a long crossfade silently
    /// stops it ever reaching the threshold.
    case trackChanged(index: Int, id: MediaId?, previousListenedSec: Double?)
    case progress(positionSec: Double, durationSec: Double, bufferedSec: Double)
    case ended
    case failed(String)
  }

  public enum PlaybackState: String {
    case idle, buffering, playing, paused, ended
  }

  private let graph: AudioGraph
  private let factory: TrackReaderFactory
  private let nowPlaying: NowPlayingCenter
  public let queue = PlaybackQueue()

  private var activePlayback: TrackPlayback?
  private var incomingPlayback: TrackPlayback?
  /// What the idle voice is carrying during a crossfade, so volume can reach it.
  private var incomingTrack: Track?

  /**
   Whether a fade is actually ramping, as opposed to being prepared.

   `transitioning` covers both, because it exists to stop the ticker starting
   a second transition. Once the crossfade's reader began being fetched
   asynchronously, that flag started covering a state it was never written for
   — "still fetching, nothing started" — and `handleTrackFinished` was reading
   it as "a fade is running, it will handle the handover". On a link where the
   fetch takes longer than the fade is long, the track ended, nothing
   advanced, and the listener got silence until the fetch landed and started a
   fade against a track that was already over.
   */
  private var fading = false

  /**
   Where readers are opened.

   `open()` is a network round trip for a remote track, and everything that
   drives this engine is on the main thread: the ticker is scheduled on
   `RunLoop.main` and the lock-screen and car handlers arrive there too. Opening
   inline froze the interface for the length of a fetch — on every skip, and at
   the start of every crossfade.
   */
  private let openQueue = DispatchQueue(label: "dev.yuzic.engine.open", qos: .userInitiated)

  /**
   Invalidates an open that has been overtaken.

   A second skip, or a skip during a crossfade's open, must not be followed by
   the first one's reader arriving late and taking over the graph. Every open
   carries the token it started with and is dropped if it no longer matches.
   */
  private var openToken: Int = 0

  /**
   How many times the current track has been reconnected — see
   `reconnectStream`.

   Bounded because the failure this recovers from is indistinguishable, from
   here, from a server that has stopped answering: both arrive as a read that
   would not complete. Unbounded, a dead server would be asked for the same
   track for as long as the app ran, at a rate set by how fast it refuses.
   Reset when a track begins and when reads resume, so the budget is per
   outage rather than per listening session.
   */
  private var reconnectAttempts = 0

  /// A stream may be picked up this many times before the track is given up.
  /// Three is enough to cross a handover or a lift, and few enough that a
  /// server which is genuinely gone is reported as gone within seconds.
  public static let maxStreamReconnects = 3

  /**
   How long the node may be out of audio before the listener is told.

   An underrun is raised the instant the scheduled depth reaches zero, which
   is the truth and is what gets counted and logged. It is not, on its own,
   worth drawing: the decode thread refills from its own completion handler,
   so a depth that touches zero and is served again a few milliseconds later
   is a gap nobody heard, and announcing it would flash a spinner on and off
   over music that never stopped.

   A quarter of a second is past the point where a gap is audible as a gap
   rather than as a glitch, and well inside the time a listener takes to
   wonder what happened. A drought that ends before it elapses never reaches
   the interface; one that does not is a dropout, and is drawn as buffering
   for as long as it lasts.
   */
  public static let underrunGraceSec: TimeInterval = 0.25

  /// Whether the node is out of audio right now, so the delayed announcement
  /// below can tell a drought that is still going from one already over.
  private var underrunning = false
  /// Cancels a pending announcement: recovery bumps it, and the work item
  /// that wakes up holding a stale one returns. Same device as `openToken`,
  /// for the same reason — there is no timer to invalidate, only an intent
  /// that may have been superseded.
  private var underrunToken: UInt64 = 0
  /// When the current drought began, for the length reported when it ends.
  private var underrunSince: Date?
  /// Whether reads are in the retry ladder, as the engine was last told.
  /// Kept here rather than asked of the playback because it is the engine's
  /// own record of a signal it received — and because the two reasons for
  /// showing `.buffering` have to be told apart by whoever is clearing one.
  private var readStalled = false
  /// Underruns on the current track. Reset by `beginTrack`, logged on each
  /// one, and the number worth reading out of a device log: a track that
  /// underran forty times played, but not the way anyone would call playing.
  private var underrunsThisTrack = 0

  /**
   Forget the drought in progress, without forgetting the count.

   Called wherever the playback a drought belonged to is being replaced — a new
   track, or a stream being picked back up. Bumping the token is the load-
   bearing part: a pending announcement from the old playback would otherwise
   wake up and draw `buffering` over whatever replaced it.
   */
  private func forgetUnderrun() {
    underrunning = false
    underrunSince = nil
    underrunToken &+= 1
  }

  /**
   How far short of the track's real length an "end of file" may land before it
   is disbelieved.

   Five seconds is past anything an ending can honestly disagree by — encoder
   padding and gapless trims are fractions of a second, and the tag a host
   reads is rounded to whole ones — and far short of the shortfall a truncation
   produces, which is the rest of the song.
   */
  public static let truncationToleranceSec: Double = 5

  /**
   A reader for the next track, opened before anything asks for it.

   A skip that has to fetch is a skip that waits, and on cellular a lossless
   track costs seconds to open — long enough that the button reads as broken.
   The crossfade already opens the next track ahead of time; this is the same
   idea without waiting for the fade.

   Held with the id it was opened for and checked against the id actually
   wanted, so a queue edit cannot make this hand back the wrong track. A stale
   entry is simply not used, and the cost of being wrong is a wasted fetch.
   */
  private var preparedNext: (id: MediaId, reader: TrackReader)?

  /// Whether the next track is open and waiting. Internal so a test can wait
  /// for the preload to *land* rather than for its fetch to start — the two
  /// are a round trip apart, and confusing them makes a flaky test.
  var isNextPreloaded: Bool { preparedNext != nil }
  private var preloading = false

  /**
   When a failed preload may be attempted again, and for which track.

   The preload is driven by the ticker, four times a second. A failure left
   `preparedNext` nil and `preloading` false, which is precisely the state the
   guard admits — so a preload that could not open was retried immediately,
   forever, at 4Hz. Each attempt is a reader open: a content-length probe and,
   on the transcoded path, a stream start. Measured against a real server that
   is thirty requests for one track inside four seconds.

   The log noise is the least of it. Those requests share a connection with the
   audio that is playing, so on a weak link the preload competes with the
   stream for bandwidth and makes the stall it exists to prevent more likely.
   The claim in this file that the feature "turns itself off exactly where it
   would do harm" held only for a low buffer, not for an open that fails while
   the buffer still looks healthy.

   Backed off exponentially, and forgotten as soon as the queue moves on to a
   different next track.
   */
  private var preloadRetryAfter: Date?
  private var preloadFailures = 0
  private var preloadFailedFor: MediaId?
  private static let preloadBackoffCapSec: Double = 30

  /**
   How far ahead the current track must be fetched before the next one is.

   A health check, not a reservoir: a connection that cannot keep ahead of one
   track has no business being asked to fetch a second. On a link that is
   dropping reads the figure collapses toward zero and no preload happens,
   which is the desired answer.

   Two seconds, because **the threshold has to be reachable by the slowest
   configuration that still has to work**, and that is not the one read-ahead
   improves. Read-ahead needs a duration to size itself, and two paths
   deliberately have none: a downloaded track, read from disk where a cushion
   buys nothing, and a stream whose host never said how long it is. Both still
   report what they always did — `bufferedFramesAhead` measuring the fetched
   window, which tops out around 2.2s — so a threshold above that is one they
   can never clear.

   This was briefly raised to 8 on the reasoning that read-ahead had made two
   seconds trivial to clear. It had, *for streams with a duration*. For a
   downloaded album it silently turned gapless off: the preload gate could not
   open, every track fetched its successor at the transition, and nothing
   reported a fault because not preloading is a legal state. Four tests caught
   it. The lesson is the one already in `docs/architecture.md` §12 — a bound
   raised to suit the fast path has to be checked against the slow one — and
   the number stays where the slow path can reach it.
   */
  public static let preloadAfterBufferedSec: Double = 2

  private var activeReader: TrackReader?

  private var ticker: Timer?
  private var transitioning = false

  /**
   How long the current track has actually been playing.

   Two values rather than one start date, because a start date measures wall
   clock and a paused player is not listening. A track left paused overnight
   would report the whole night as listened, and `previousListenedSec` is what
   scrobble thresholds are judged against — so the wrong number here submits
   plays to Last.fm and ListenBrainz for music nobody heard.

   `listenedAccumulated` holds the stretches already played;
   `listeningSince` marks the open one and is nil while paused.
   */
  private var listenedAccumulated: TimeInterval = 0
  private var listeningSince: Date?

  /**
   The fix point the lock screen is extrapolating from.

   `elapsedPlaybackTime` is a fix point, not a clock: iOS advances it itself
   using the rate, which is why it is not re-sent on every tick — doing that
   four times a second makes the lock-screen timer visibly stutter as it is
   yanked back to a value already going stale.

   But the engine's position comes from *rendered* frames, and those stop
   advancing during a buffering stall while the wall clock does not. So the
   two drift apart, always in the same direction: the lock screen runs ahead
   of the audio. Pausing publishes the truth and the number jumps backwards —
   which is what a listener sees, as a paused screen showing an earlier time
   than the playing one did a moment before.
   */
  private var publishedPosition: Double?
  private var publishedAt: Date?

  /**
   How often `progress` is emitted to the host.

   The ticker runs at 4Hz because a crossfade has to start within a frame of
   where it should — that is a *scheduling* rate and not a display one. Every
   tick also emitted `progress`, so a host that asked for one update a second
   got four, and re-rendered four times, and the `progressIntervalMs` it passed
   to `setup` did nothing on this platform while Android honoured it. Same
   field, same contract, two behaviours, and no tool in this repo compares
   them.

   Emission is throttled here; the ticker is untouched.
   */
  public var progressIntervalSec: Double = 1.0
  private var lastProgressEmit: Date?

  private var observers: [NSObjectProtocol] = []

  /// Set while an interruption is in force, so `.ended` only resumes playback
  /// that *this* engine paused — not playback the user had already stopped.
  private var pausedByInterruption = false

  /**
   Where to pick the active track back up once audio can play again.

   Set whenever the system takes the audio graph away from a loaded track — an
   interruption, a format or route change — and read by the next thing that
   starts audio. Kept as a position over the *same* reader rather than dropping
   the playback, because dropping it is what used to send the next play back to
   0:00, re-open the stream over the network, and announce the same track to
   the host a second time.
   */
  private var pendingRestart: (frame: Int64, origin: Int64)?

  /// The system has stopped the engine (or invalidated it) since it last ran.
  /// Anything that starts audio reclaims the session and the graph first.
  private var graphNeedsRestart = false
  private var graphNeedsReset = false

  /// Injectable so the listened-time tests do not have to sleep.
  private let now: () -> Date

  private(set) public var state: PlaybackState = .idle {
    didSet { if state != oldValue { emit(.stateChanged(state)) } }
  }

  public var onEvent: ((Event) -> Void)?

  /**
   Loudness normalisation. Off until the host says otherwise.

   Changing it takes effect on the track already playing as well as the next
   one. The alternative — settling in only at the next track boundary — makes
   the setting feel broken: someone turns it on precisely because what they are
   hearing right now is too loud.
   */
  public var replayGain: ReplayGainSettings = .off {
    didSet {
      guard replayGain != oldValue else { return }
      applyVolume()
    }
  }

  /**
   The user's volume, held here rather than written onto a gain node.

   It has to live somewhere: `AudioGraph.setTrackGain` explains that a fade
   ramps `gain.outputVolume` from 0 to 1 and anything else written there is
   overwritten by the next ramp. Volume was being written exactly there, so it
   survived only until the next fade, skip or track change — and a skip taken
   during a crossfade left the voice stranded at whatever the abandoned ramp
   had reached, with the next volume command writing to a node nothing would
   read again until the following track.

   Multiplied into the player alongside replay gain instead, which is the
   separation that lets the two coexist.
   */
  public var volume: Float = 1 {
    didSet {
      volume = min(max(volume, 0), 1)
      applyVolume()
    }
  }

  /// `volume × replay gain` for a track, which is what the player wants.
  private func playerGain(for track: Track?) -> Float {
    guard let track else { return volume }
    return volume * ReplayGain.linearGain(for: track, settings: replayGain)
  }

  /**
   Push volume to both voices, each for its own track.

   Both, because during a crossfade two of them are audible and leaving one
   behind makes the change lurch halfway through the fade — the same reason
   Android applies it to both.
   */
  private func applyVolume() {
    graph.setTrackGain(graph.activeVoice, to: playerGain(for: queue.activeTrack))
    if transitioning {
      graph.setTrackGain(graph.idleVoice, to: playerGain(for: incomingTrack))
    }
  }

  public init(
    graph: AudioGraph,
    factory: TrackReaderFactory,
    nowPlaying: NowPlayingCenter = NowPlayingCenter(),
    now: @escaping () -> Date = Date.init
  ) {
    self.graph = graph
    self.factory = factory
    self.nowPlaying = nowPlaying
    self.now = now
    wireRemoteCommands()
    observeTheSystem()
  }

  /// The lock screen, Control Centre, headphone buttons and the car all arrive
  /// here. They are wired once at construction rather than per track: a control
  /// that disappears between tracks is worse than one that was never offered.
  /**
   Which controls to advertise.

   Worth being able to change, because the right set is not a property of the
   engine. A podcast wants skip-forward rather than next-track; a live stream
   should not offer a scrubber over a thing with no end. Defaults to the four
   that suit music.

   A control that is offered but does nothing is worse than one that is absent,
   so this is a list of what the host will honour, not everything the framework
   can draw.
   */
  public var remoteCommands: [RemoteCommand] = [.playPause, .next, .previous, .seek] {
    // Re-wired on every set, not only when the list changes. The guard that
    // used to be here read as free — re-registering the same commands is a
    // no-op — but it assumed this engine is the only thing touching
    // `MPRemoteCommandCenter.shared()`, and during the migration off
    // @rntp/player it is not: that library's `destroy()` calls
    // `removeTarget(nil)` on every command, which removes *everyone's*
    // targets. Setting the same list again is then the host's only way to say
    // "put mine back", and the guard turned that into nothing. The symptom is
    // controls greyed out on the lock screen while the now-playing info still
    // updates, because the info centre is a different singleton and survives.
    didSet { wireRemoteCommands() }
  }

  private func wireRemoteCommands() {
    var handlers = RemoteCommandHandlers()
    handlers.play = { [weak self] in try? self?.play() }
    handlers.pause = { [weak self] in self?.pause() }
    handlers.next = { [weak self] in try? self?.skipToNext() }
    handlers.previous = { [weak self] in try? self?.skipToPrevious() }
    handlers.seek = { [weak self] position in try? self?.seek(toSeconds: position) }
    handlers.stop = { [weak self] in self?.stop() }
    nowPlaying.setCommands(remoteCommands, handlers: handlers)
  }

  /**
   Push the current track and state to the lock screen.

   Called on every transition and on pause/resume, *not* on every progress tick.
   `elapsedPlaybackTime` is a fix point that iOS extrapolates from using the
   rate — re-sending it four times a second makes the lock-screen timer stutter
   as it is repeatedly yanked back to a value already going stale.
   */
  private func publishNowPlaying() {
    guard let track = queue.activeTrack, let reader = activeReader else {
      nowPlaying.clear()
      publishedPosition = nil
      return
    }
    let sampleRate = reader.sampleRate > 0 ? reader.sampleRate : 44_100
    let position = Double(activePlayback?.currentFrame ?? 0) / sampleRate
    publishedPosition = position
    publishedAt = now()
    nowPlaying.update(
      .init(
        title: track.title,
        artist: track.artist,
        album: track.album,
        durationSec: trustedDuration,
        positionSec: position,
        isPlaying: state == .playing,
        rate: 1.0,
        isLive: track.continuous
      ),
      artworkUri: track.artworkUri,
      artworkHeaders: track.artworkHeaders
    )
  }

  deinit {
    ticker?.invalidate()
    observers.forEach(NotificationCenter.default.removeObserver)
  }

  // MARK: - The system taking the audio away

  /**
   Three things the system does to a running audio graph, none of which it
   asks permission for.

   None of these were observed. `handleConfigurationChange` existed, documented
   exactly this, and had no callers — so when another app took the route, iOS
   stopped the engine underneath us and this one carried on scheduling into a
   dead graph. Somebody's partner starting Spotify in the car is enough.
   */
  private func observeTheSystem() {
    let centre = NotificationCenter.default

    // The engine is stopped and every scheduled buffer is discarded. Fires on
    // any route change — CarPlay connecting, AirPods, a dock — and there is no
    // way to recover the buffers, so playback has to be rebuilt from where it
    // had reached.
    observers.append(centre.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
    ) { [weak self] _ in
      self?.rebuildAfterConfigurationChange()
    })

    // `AVAudioSession` is iOS-only, and this package also builds for macOS so
    // the logic can be tested without a device. The configuration-change
    // notification above exists on both.
    #if os(iOS) || os(tvOS)
    // Another app has taken the session — a call, or Spotify on the same
    // Bluetooth device.
    observers.append(centre.addObserver(
      forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
    ) { [weak self] note in
      self?.handleInterruption(note)
    })

    // The output vanished. Unplugging headphones must pause rather than
    // continue out of the speaker, which is the one route change with an
    // obvious right answer.
    observers.append(centre.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self,
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable
      else { return }
      self.pause()
    })

    // `mediaserverd` restarted. Everything audio in this process is now
    // invalid — see `recoverFromMediaServicesReset`.
    observers.append(centre.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.recoverFromMediaServicesReset()
    })
    #endif
  }

  /**
   Re-apply the audio session's category and activation.

   Set by the host, because the category is the host's choice — `.playback`,
   `.longFormAudio` — and this class has no business deciding it. It exists as
   a closure rather than a call because a media services reset clears the
   session the host configured once at setup, and nothing was putting it back.
   */
  public var reconfigureAudioSession: (() throws -> Void)?

  /**
   Whether an interruption ending should resume playback.

   Pure, because the rule is the part worth pinning: resume only what this
   engine paused, and only when the system says the interrupting app has
   finished with the session. Resuming otherwise starts music in someone's ear
   after a phone call they took while the player was already stopped.
   */
  static func shouldResumeAfterInterruption(
    wasPausedByUs: Bool, systemSaysResume: Bool
  ) -> Bool {
    wasPausedByUs && systemSaysResume
  }

  /**
   Another app, a call, Siri or an alarm has taken the audio.

   The system stops the engine when it deactivates the session, and says
   nothing to the nodes: every buffer scheduled on them is gone, and a player
   node told to play again on that engine raises rather than failing. So the
   position is taken now and the playback released, and whatever next starts
   audio — the interruption ending, or play from the app, the lock screen,
   AirPods or the car — rebuilds it there instead of resuming a corpse.

   Handled the same whether or not an end ever arrives, which is the case that
   used to break: an app that keeps a non-mixable session (remote desktop,
   video) often never sends one, or sends it without `.shouldResume`, and the
   listener comes back and presses play.
   */
  func interruptionBegan() {
    pausedByInterruption = state == .playing || state == .buffering
    graphNeedsRestart = true
    holdActivePlaybackForRestart()
    pause()
  }

  /// The interruption is over. Resumes only what it paused, and only when the
  /// system says so — see `shouldResumeAfterInterruption`. Otherwise the
  /// engine stays paused at the position it had, ready for the next play.
  func interruptionEnded(shouldResume: Bool) {
    let resume = Self.shouldResumeAfterInterruption(
      wasPausedByUs: pausedByInterruption, systemSaysResume: shouldResume
    )
    pausedByInterruption = false
    if resume { try? play() }
  }

  /**
   Release the active playback and remember where it was.

   Idempotent: a second teardown before anything restarted must not overwrite
   the position with the frame of a playback that has already been stopped.
   */
  private func holdActivePlaybackForRestart() {
    guard pendingRestart == nil, let playback = activePlayback, activeReader != nil else { return }
    pendingRestart = (playback.currentFrame, playback.readerOrigin)
    cancelTransition()
    playback.stopAndWait()
  }

  /**
   Make sure audio can be started: the session active and the graph running.

   Every path that starts sound goes through here. Before, only the interruption
   ending with `.shouldResume` re-activated the session and none of them
   restarted the engine, so play after any other interruption resumed a node on
   a stopped engine.

   A failure leaves the engine paused, with the position and the track kept,
   and is not reported as a playback failure. The usual reason is that another
   app still holds the audio — a call in progress — and a failure event would
   have the host retry or drop a track that is perfectly playable. Pressing play
   again once the other app lets go works.
   */
  private func reclaimAudioIfNeeded() throws {
    guard graphNeedsReset || graphNeedsRestart || !graph.isRunning else { return }
    do {
      if let reconfigure = reconfigureAudioSession {
        try reconfigure()
      } else {
        #if os(iOS) || os(tvOS)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
      }
      if graphNeedsReset {
        try graph.rebuildAfterReset()
      } else {
        try graph.start()
      }
      graphNeedsReset = false
      graphNeedsRestart = false
    } catch {
      NSLog("[yuzic-engine] audio could not be reclaimed: \(error)")
      state = .paused
      closeListeningStretch()
      stopTicking()
      publishNowPlaying()
      throw error
    }
  }

  /**
   Rebuild the active track's playback at `frame`, over the reader it already has.

   No reopen and no track-change event: this is the same second of the same
   song, and the host already knows what is playing. State goes to `.buffering`
   and on to `.playing` when a buffer is actually scheduled, so the host, the
   lock screen and the car see what is really happening.
   */
  private func restartActivePlayback(atFrame frame: Int64, readerOrigin: Int64) throws {
    guard let reader = activeReader, reader.sampleRate > 0 else {
      startTrack(at: queue.activeIndex, fromFrame: frame)
      return
    }
    cancelTransition()
    activePlayback?.stopAndWait()
    graph.reconnect(graph.activeVoice, toSourceRate: reader.sampleRate)
    graph.setTrackGain(graph.activeVoice, to: playerGain(for: queue.activeTrack))
    graph.cut(graph.activeVoice, to: 1)

    let fresh = TrackPlayback(reader: reader, voice: graph.activeVoice)
    wire(fresh)
    fresh.onFirstBufferScheduled = { [weak self, weak fresh] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === fresh, self.state == .buffering else { return }
        self.state = .playing
        self.publishNowPlaying()
      }
    }
    activePlayback = fresh
    state = .buffering
    try fresh.start(atFrame: frame, readerOrigin: readerOrigin)
    if listeningSince == nil { listeningSince = now() }
    publishNowPlaying()
    startTicking()
  }

  #if os(iOS) || os(tvOS)
  private func handleInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

    switch type {
    case .began:
      interruptionBegan()
    case .ended:
      let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      interruptionEnded(shouldResume: options.contains(.shouldResume))
    @unknown default:
      break
    }
  }

  #endif

  /**
   Put playback back together after the system tore the graph down.

   The position is read *before* anything is rebuilt, because restarting the
   engine is what makes it unreadable. Everything else is the ordinary start
   path: a fresh `TrackPlayback` over the same reader, seeking to where the
   listener actually was.
   */
  /**
   Come back from the media server restarting.

   `mediaserverd` is a separate process and it can die — under memory pressure,
   on a Bluetooth handover, in a car. When it comes back, Apple's contract is
   that every audio object this process holds is invalid: the engine, the
   nodes, the units, *and* the session category the host set once at setup.

   Nothing observed this, so nothing put any of it back. The engine kept its
   state, its queue and its now-playing info, and the graph underneath was
   rubble — a track sitting there showing paused, with transport controls that
   did nothing, until the app was force-quit. That is the "sometimes it just
   breaks and the song won't play" report, and it is not a race or a rare
   ordering: it is the whole of the handling for one of the four ways iOS takes
   audio away, missing.

   Unlike a configuration change, the reader is kept. A media services reset
   invalidates *audio* objects; an `AudioFileReader` over an HTTP source is not
   one, and throwing away a warm stream to re-open it from the network would
   turn a recoverable glitch into a stall.

   Left paused deliberately, whatever it was doing before. The other recovery
   paths resume because the listener never stopped listening — a route change
   is the same second of the same song. A media server reset is a crash the
   audio system just had, and starting music unbidden out of whatever output
   iOS has settled on afterwards is not a thing to do on the strength of a
   guess about which one that is.
   */
  private func recoverFromMediaServicesReset() {
    // Read the position and let go of the old playback *first*. Its player
    // node belongs to the graph that is about to be replaced, and once it has
    // been, asking that node where it is traps — `lastRenderTime` asserts on a
    // node with no engine, which is a crash rather than a nil. The same
    // ordering `rebuildAfterConfigurationChange` keeps, for the same reason.
    let frame = pendingRestart?.frame ?? activePlayback?.currentFrame ?? 0
    let origin = pendingRestart?.origin ?? activePlayback?.readerOrigin ?? 0
    activePlayback?.stopAndWait()
    activePlayback = nil

    do {
      // Session first: the graph cannot start into a session that has no
      // category, and after a reset it has none.
      try reconfigureAudioSession?()
      try graph.rebuildAfterReset()
      graphNeedsReset = false
      graphNeedsRestart = false
    } catch {
      // Kept rather than dropped: the next play tries the rebuild again and
      // picks the track up where it was, instead of starting it over.
      graphNeedsReset = true
      if activeReader != nil { pendingRestart = (frame, origin) }
      state = .paused
      publishNowPlaying()
      emit(.failed("audio could not be restarted after a media services reset: \(error)"))
      return
    }
    pendingRestart = nil

    guard let reader = activeReader, reader.sampleRate > 0 else {
      state = .paused
      publishNowPlaying()
      return
    }

    do {
      graph.reconnect(graph.activeVoice, toSourceRate: reader.sampleRate)
      graph.setTrackGain(graph.activeVoice, to: playerGain(for: queue.activeTrack))

      let fresh = TrackPlayback(reader: reader, voice: graph.activeVoice)
      wire(fresh)
      activePlayback = fresh
      graph.cut(graph.activeVoice, to: 1)

      // Scheduled at the position reached and then held, so the play button
      // starts from where the listener was rather than from the top.
      try fresh.start(atFrame: frame, readerOrigin: origin)
      fresh.pause()
      state = .paused
      publishNowPlaying()
    } catch {
      activePlayback = nil
      state = .paused
      publishNowPlaying()
      emit(.failed("audio could not be restarted after a media services reset: \(error)"))
    }
  }

  /**
   The system stopped the engine for a route or format change.

   AirPods switching to their microphone profile, another app changing the
   hardware rate, a voice memo taking the route, a car connecting: the engine
   is stopped and every scheduled buffer discarded. The position is held and
   the playback released either way.

   Playing, it is picked straight back up. Paused — including paused by an
   interruption, when the session is inactive and the engine cannot start at
   all — it is left paused and the next play rebuilds it. That second case
   used to try to start the engine anyway, fail, drop the playback and report a
   playback failure: the next play started the song over, re-opened the
   stream, and the host was told about a broken track that was not broken.
   */
  private func rebuildAfterConfigurationChange() {
    let wasPlaying = state == .playing || state == .buffering
    graphNeedsRestart = true
    // Nothing loaded: the next track to start reclaims the graph first.
    guard activePlayback != nil, activeReader != nil else { return }
    holdActivePlaybackForRestart()
    guard wasPlaying, let pending = pendingRestart else {
      publishNowPlaying()
      return
    }
    do {
      try reclaimAudioIfNeeded()
      pendingRestart = nil
      try restartActivePlayback(atFrame: pending.frame, readerOrigin: pending.origin)
    } catch {
      // Held for the next play; `reclaimAudioIfNeeded` has already left the
      // engine paused and said so.
      pendingRestart = pending
      if state != .paused {
        state = .paused
        closeListeningStretch()
        stopTicking()
        publishNowPlaying()
      }
    }
  }

  // MARK: - Transport

  public func setQueue(_ tracks: [Track], startIndex: Int) {
    stopEverything()
    queue.set(tracks, startIndex: startIndex)
    state = .idle
  }

  public func play() throws {
    /*
     A finished playback cannot be resumed, only restarted.

     `resume()` calls `play()` on the node and then `fill()`, and `fill()`
     returns immediately once `stopped` is set — so resuming a playback that
     has been stopped is silence, with nothing thrown and no way back. Press
     play again and it resumes the same corpse.

     Two ordinary things leave one behind. A stream that failed after its retry
     budget stops the playback and pauses the engine, and a configuration
     change — the AirPod that died mid-track — stops it before rebuilding the
     graph, and leaves it in place if that rebuild throws. Both reach a
     listener the same way: the track is on screen, the button says play, and
     pressing it does nothing at all.

     Restarting from `currentFrame` puts the needle back where it was rather
     than at the top of the track.
     */
    // Audio first: after an interruption or a route change the session is
    // inactive and the engine stopped, and nothing below can play into that.
    try reclaimAudioIfNeeded()

    // The system took the graph away from a loaded track: rebuild it where it
    // was, over the same reader, rather than resuming a node whose buffers are
    // gone or re-opening the stream from the top.
    if let pending = pendingRestart {
      pendingRestart = nil
      do {
        try restartActivePlayback(atFrame: pending.frame, readerOrigin: pending.origin)
      } catch {
        pendingRestart = pending
        state = .paused
        closeListeningStretch()
        stopTicking()
        publishNowPlaying()
        throw error
      }
      return
    }

    if let playback = activePlayback, playback.isFinished {
      startTrack(at: queue.activeIndex, fromFrame: playback.currentFrame)
      return
    }

    if activePlayback == nil {
      startTrack(at: queue.activeIndex, fromFrame: 0)
    } else {
      // Restore the voice, because something may have faded it away while it
      // was paused. The sleep timer does exactly that: it fades to silence and
      // pauses, leaving the gain at zero. Without this, play the next morning
      // resumes a track nobody can hear, with the progress bar advancing
      // normally — which reads as a broken player rather than a sleep timer
      // that did its job.
      //
      // Skipped mid-transition, where both voices are deliberately part-way
      // through a ramp and slamming one to full would be audible.
      if !transitioning {
        graph.cut(graph.activeVoice, to: 1)
      }
      activePlayback?.resume()
      // Reopen the listening stretch the pause closed. Guarded so that calling
      // play() on an already-playing engine does not discard the open stretch
      // and restart it, which would quietly reset the count to zero.
      if listeningSince == nil { listeningSince = now() }
      state = .playing
      publishNowPlaying()
      startTicking()
    }
  }

  public func pause() {
    activePlayback?.pause()
    incomingPlayback?.pause()
    closeListeningStretch()
    state = .paused
    publishNowPlaying()
    stopTicking()
  }

  /// Bank the stretch that has just ended. Idempotent, because pausing an
  /// already-paused player must not bank the same seconds twice.
  private func closeListeningStretch() {
    guard let since = listeningSince else { return }
    listenedAccumulated += now().timeIntervalSince(since)
    listeningSince = nil
  }

  public func stop() {
    stopEverything()
    state = .idle
  }

  public func seek(toSeconds seconds: Double) throws {
    guard let reader = activeReader else { return }
    // A scrub from the lock screen after an interruption is a play at a new
    // position: the graph has to be back first, and the held position is
    // superseded by the one asked for.
    try reclaimAudioIfNeeded()
    pendingRestart = nil
    // A seek during a fade would leave the other voice playing the wrong part
    // of the wrong track; collapse the transition first.
    cancelTransition()
    let frame = Int64(seconds * reader.sampleRate)
    // Waits, unlike everywhere else `stop` is called: the reader below is the
    // one this playback is decoding from, and it cannot be seeked while the
    // old producer is still inside it.
    activePlayback?.stopAndWait()
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    wire(playback)
    activePlayback = playback
    try playback.start(atFrame: frame)
    state = .playing
    // A seek moves the fix point, so the lock screen has to be told or its
    // timer carries on from where the track used to be.
    publishNowPlaying()
    startTicking()
  }

  public func skipToNext() throws {
    // Through the queue, so that repeat is honoured here the same way the
    // automatic advance honours it. Computing `activeIndex + 1` here meant a
    // repeat-all queue wrapped when a track ended and stopped when the user
    // pressed next.
    try move(to: queue.skipNextIndex, userInitiated: true)
  }

  public func skipToPrevious() throws {
    switch PlaybackEngine.previousAction(
      positionSec: progress.positionSec, activeIndex: queue.activeIndex
    ) {
    case .restart: try seek(toSeconds: 0)
    case .goBack: try move(to: queue.activeIndex - 1, userInitiated: true)
    }
  }

  /// What `previous` means, which is not always "the previous track".
  public enum PreviousAction: Equatable { case restart, goBack }

  /// How far into a track `previous` stops meaning "go back" and starts
  /// meaning "start this one again".
  public static let previousRestartsAfterSec: Double = 3

  /**
   Whether `previous` restarts the current track or moves to the one before.

   Past three seconds a person pressing previous almost always means "start
   this again" rather than "leave" — and on the first track there is nothing to
   leave to, so restarting is the only thing it can usefully do. iOS had
   neither rule: it moved unconditionally, which on the first track computed
   -1, was rejected by `move`, and did nothing at all.

   Pure and separate for the same reason `shouldBeginTransition` is: it is the
   decision, and driving three seconds of real audio to test it would test the
   plumbing instead. Android's threshold is the same constant.
   */
  public static func previousAction(positionSec: Double, activeIndex: Int) -> PreviousAction {
    if positionSec > previousRestartsAfterSec || activeIndex == 0 { return .restart }
    return .goBack
  }

  public func skipTo(index: Int) throws {
    try move(to: index, userInitiated: true)
  }

  /**
   Wire the callbacks every playback needs.

   Here rather than at each of the three sites that make one, because the
   failure handler is the kind of thing a fourth site would omit without
   noticing — and omitting it is exactly the bug: a lost stream reported as a
   finished track.
   */
  private func wire(_ playback: TrackPlayback) {
    playback.onEndOfTrack = { [weak self, weak playback] in self?.handleTrackFinished(playback) }

    /*
     A stall is not a pause and not a failure — the connection has gone quiet
     and the reader is retrying — and until now nobody was told.

     `TrackPlayback` has raised `onReadStalled` on the first failed read since
     the retry ladder was written, and nothing ever assigned it. So a listener
     whose connection dropped got up to thirty-three seconds of silence behind
     a play button that still said playing, and then either the music resumed
     or the track died. Both outcomes arrived with no explanation, and the
     buffering state the app already draws was sitting right there.

     That is the shape `docs/architecture.md` §12 calls a function with no
     callers: correct code, written, shipped, never invoked.

     Saying it out loud is also what makes the retry budget defensible. Thirty
     seconds of *unexplained* silence is a bug; thirty seconds of visible
     buffering while a patchy connection is retried is a player doing its job.
     */
    playback.onReadStalled = { [weak self, weak playback] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback else { return }
        // Outside the state guard below, for the same reason the budget reset
        // in `onReadResumed` is: reads being in the ladder is a fact about the
        // connection rather than about what the interface happens to be
        // showing. `onUnderrunEnded` asks it precisely in the case where the
        // engine is already `.buffering` for the other reason.
        self.readStalled = true
        guard self.state == .playing else { return }
        self.state = .buffering
        self.publishNowPlaying()
      }
    }
    playback.onReadResumed = { [weak self, weak playback] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback else { return }
        // Reads are flowing again, so whatever outage was being counted is
        // over and the next one starts with a full budget. Outside the state
        // guard below deliberately: the budget belongs to the outage, not to
        // whether the engine happened to be showing `buffering` at the moment
        // it ended.
        self.reconnectAttempts = 0
        self.readStalled = false
        guard self.state == .buffering else { return }
        self.state = .playing
        self.publishNowPlaying()
      }
    }
    /*
     The other half of the stall pair, and the half that was missing.

     `onReadStalled` speaks for a read that threw. Nothing spoke for a read
     that was merely slow: the depth drained, the node went silent, the
     rendered position stopped, and the engine carried on saying `.playing`
     for as long as the fetch took — up to `HTTPByteFetcher.defaultTimeout`,
     which is eight seconds, with no state change, no count and no line in
     any log. The listener heard the music stop and come back; the engine's
     account of that minute was that it played normally.

     Counted and logged unconditionally, because the count is the instrument
     and a dropout nobody drew is still a dropout that happened. Drawn only
     if it outlasts `underrunGraceSec` — see there for why.
     */
    playback.onUnderrun = { [weak self, weak playback] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback else { return }
        self.underrunning = true
        self.underrunSince = self.now()
        self.underrunsThisTrack += 1
        let at = String(format: "%.1f", self.progress.positionSec)
        let title = self.queue.activeTrack?.title ?? "unknown"
        NSLog("[yuzic-engine] audio underran at \(at)s of \(title) — \(self.underrunsThisTrack) on this track")

        guard self.state == .playing else { return }
        self.underrunToken &+= 1
        let token = self.underrunToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.underrunGraceSec) { [weak self] in
          guard let self, self.underrunToken == token,
                self.underrunning, self.state == .playing else { return }
          self.state = .buffering
          self.publishNowPlaying()
        }
      }
    }
    playback.onUnderrunEnded = { [weak self, weak playback] in
      DispatchQueue.main.async {
        // `underrunning` is in the guard, not just the body. `stopAndWait`
        // lets a read already in flight finish, and that read schedules a
        // buffer — so a playback being torn down can raise this after the
        // engine has moved on. Without the check it would find `.buffering`
        // put up by the reconnection that replaced it, conclude the drought
        // was over and say `playing` over a track that is being re-opened.
        guard let self, self.activePlayback === playback, self.underrunning else { return }
        // Bumped whether or not anything was announced: this is what stops a
        // pending announcement from landing on a drought that is already over.
        self.underrunToken &+= 1
        self.underrunning = false
        if let since = self.underrunSince {
          let gap = String(format: "%.2f", self.now().timeIntervalSince(since))
          NSLog("[yuzic-engine] audio resumed after \(gap)s")
          self.underrunSince = nil
        }
        // Only undo what an underrun drew. A `.buffering` that a *read* stall
        // put up belongs to `onReadResumed`, and clearing it here would say
        // the connection had recovered on the strength of one buffer that
        // was decoded before it broke.
        guard self.state == .buffering, !self.readStalled else { return }
        self.state = .playing
        self.publishNowPlaying()
      }
    }

    // A track that could not be read has *not* finished, and must not advance
    // the queue. `AudioFileReader.read` returns nil at the end and throws on
    // failure; treating both as the end is what made a dropped connection look
    // like the song skipping part-way through.
    playback.onReadFailed = { [weak self, weak playback] error in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback else { return }
        // A sequential stream gets one more thing tried before the track is
        // declared lost — see `reconnectStream`. Every other transport has
        // already exhausted its retries by the time this fires.
        if self.reconnectStream() { return }
        let title = self.queue.activeTrack?.title ?? "this track"
        self.state = .paused
        self.publishNowPlaying()
        self.emit(.failed("Lost the stream for \(title): \(error)"))
      }
    }
  }

  /**
   Pick a transcoded stream back up from where it stopped.

   The sequential transport is the one that cannot retry. `TrackPlayback`'s
   ladder re-reads, which works on a ranged source because the same bytes can
   be asked for again — but a stream's bytes were coming from a producer that
   has since stopped, and reading again only waits on a stream nobody is
   sending. So the ladder was spending its whole budget on a fault it could
   not fix, and the track died at the end of it.

   Recovering here means asking the server for the track *again*, from the
   second reached, with Subsonic's `timeOffset`. That is a different byte
   stream and so a different reader, which is why this rebuilds rather than
   seeks — and why `streamURL` existed for a year with no caller: the piece it
   was written for is this one, and it was never built.

   Returns whether a reconnection was started. False means the caller should
   report the failure it was going to report.
   */
  @discardableResult
  private func reconnectStream() -> Bool {
    guard let reader = activeReader, reader.isSequential, reader.sampleRate > 0,
          let track = queue.activeTrack else { return false }
    // Live radio has no timeline to come back to. `timeOffset` into a stream
    // with no beginning is meaningless, and asking for it would restart the
    // broadcast from wherever the server felt like.
    guard !track.continuous else { return false }
    guard reconnectAttempts < Self.maxStreamReconnects else { return false }

    let resumeAt = progress.positionSec
    // Below a second there is nothing to come back to: the stream failed
    // before it played, which `beginTrack` reports as an open failure with a
    // reason, and reconnecting would replace that with a silent retry loop.
    guard resumeAt >= 1 else { return false }

    reconnectAttempts += 1
    let offsetSec = Int(resumeAt)

    // Said out loud. A reconnection takes as long as a request, and going
    // quiet without a word is the behaviour this whole line of work exists to
    // remove.
    state = .buffering
    publishNowPlaying()
    // The drought belonged to the playback about to be thrown away. Its count
    // stays — it is the track's, and the track is the same one.
    forgetUnderrun()

    activePlayback?.stopAndWait()
    openToken &+= 1
    let token = openToken
    let factory = self.factory

    openQueue.async { [weak self] in
      let opened: TrackReader
      do {
        let reader = try factory.makeReader(for: track, timeOffsetSeconds: offsetSec)
        try reader.open()
        opened = reader
      } catch {
        DispatchQueue.main.async {
          guard let self, self.openToken == token else { return }
          self.state = .paused
          self.publishNowPlaying()
          self.emit(.failed("Lost the stream for \(track.title): \(error)"))
        }
        return
      }

      DispatchQueue.main.async {
        guard let self, self.openToken == token else { return }
        // Same reasoning as `beginTrack`: the voice about to play is the one
        // whose rate has to match the file, and a reconnected stream can come
        // back at a different rate than it left at if the server chose
        // differently. Safe here because the playback above was stopped.
        self.graph.reconnect(self.graph.activeVoice, toSourceRate: opened.sampleRate)
        self.activeReader = opened

        let frame = Int64(resumeAt * opened.sampleRate)
        let playback = TrackPlayback(reader: opened, voice: self.graph.activeVoice)
        self.wire(playback)
        self.activePlayback = playback
        playback.onFirstBufferScheduled = { [weak self, weak playback] in
          DispatchQueue.main.async {
            guard let self, self.activePlayback === playback,
                  self.state == .buffering else { return }
            self.state = .playing
            self.publishNowPlaying()
          }
        }
        do {
          // The new reader's frame zero is `frame` of the track — that is what
          // asking for `timeOffset` bought — so it is seeked to its own
          // beginning while every position reported carries on from where the
          // stream broke.
          try playback.start(atFrame: frame, readerOrigin: frame)
        } catch {
          self.activePlayback = nil
          self.state = .paused
          self.publishNowPlaying()
          self.emit(.failed("Lost the stream for \(track.title): \(error)"))
          return
        }
        self.publishNowPlaying()
        self.startTicking()
      }
    }
    return true
  }

  /**
   Open the next track before anything asks for it.

   Deliberately not routed through `openReader`: that carries the token which
   supersedes an in-flight open, and a preload must neither cancel a skip nor
   be cancelled by one. Best-effort — a failure is silent, because nothing is
   waiting on it and the real open will report for itself.
   */
  private func preloadNextIfIdle(bufferedAheadSec: Double, remainingSec: Double) {
    guard preparedNext == nil, !preloading, !transitioning, state == .playing else { return }

    // A different next track is a different question, so a previous failure
    // says nothing about it.
    if let failedFor = preloadFailedFor, failedFor != queue.nextTrack?.id {
      preloadFailedFor = nil
      preloadFailures = 0
      preloadRetryAfter = nil
    }
    if let retryAfter = preloadRetryAfter, now() < retryAfter { return }
    // Or everything that is left, whichever is less. A flat threshold never
    // fires on a track shorter than it — which is exactly the interlude a
    // listener is most likely to skip out of.
    let enough = remainingSec > 0
      ? min(Self.preloadAfterBufferedSec, remainingSec)
      : Self.preloadAfterBufferedSec
    guard bufferedAheadSec >= enough else { return }
    guard let next = queue.nextTrack else { return }

    preloading = true
    let factory = self.factory
    openQueue.async {
      let opened: TrackReader? = {
        do {
          let reader = try factory.makeReader(for: next)
          try reader.open()
          return reader
        } catch {
          return nil
        }
      }()
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.preloading = false

        guard let opened else {
          // Back off rather than letting the ticker ask again in 250ms.
          self.preloadFailedFor = next.id
          self.preloadFailures += 1
          let delay = min(
            pow(2, Double(self.preloadFailures)),
            Self.preloadBackoffCapSec
          )
          self.preloadRetryAfter = self.now().addingTimeInterval(delay)
          return
        }

        // Checked again on arrival: the queue may have moved while this was in
        // flight, and handing back a reader for a track that is no longer next
        // is how a skip plays the wrong thing.
        guard self.queue.nextTrack?.id == next.id else { return }
        self.preparedNext = (next.id, opened)
        self.preloadFailedFor = nil
        self.preloadFailures = 0
        self.preloadRetryAfter = nil
      }
    }
  }

  // MARK: - Moving between tracks

  /**
   Open a reader off the main thread and continue on it.

   The continuation runs on main, so callers may touch the graph and the
   engine's state exactly as they did when this was inline. It does not run at
   all if something else has since started an open — see `openToken`.
   */
  private func openReader(for track: Track,
                          then continuation: @escaping (Result<TrackReader, Error>) -> Void) {
    openToken &+= 1
    let token = openToken
    let factory = self.factory
    openQueue.async {
      let result = Result<TrackReader, Error> {
        let reader = try factory.makeReader(for: track)
        try reader.open()
        return reader
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.openToken == token else { return }
        continuation(result)
      }
    }
  }


  private func move(to index: Int, userInitiated: Bool) throws {
    guard queue.tracks.indices.contains(index) else {
      if index >= queue.tracks.count { finish() }
      return
    }
    let listened = listenedSeconds()
    cancelTransition()
    // Quiet until the new track begins, which starts it again. Left running,
    // the ticker reads the cut track's last position against the queue's *new*
    // next track: a skip taken inside the fade window, with a crossfade set,
    // began a fade into the track after the one asked for, and that fade's
    // open superseded the skip's own.
    stopTicking()
    let track = queue.tracks[index]

    // The queue moves now, not when the network answers. The lock screen, the
    // car and the interface should show the track that was asked for the
    // moment it is asked for; making them wait on a fetch is what makes a skip
    // feel broken even when it eventually works.
    queue.set(queue.tracks, startIndex: index)
    state = .buffering
    emit(.trackChanged(index: index, id: track.id, previousListenedSec: listened))
    publishNowPlaying()

    // Already open? Then this is instant, which is the whole point of
    // preloading: most skips go to the next track, and the next track is the
    // one that was fetched ahead.
    if let prepared = preparedNext, prepared.id == track.id {
      preparedNext = nil
      graph.cut(graph.activeVoice, to: 0)
      activePlayback?.stop()
      do {
        try beginTrack(at: index, fromFrame: 0, prepared: prepared.reader, announced: true)
      } catch {
        state = .paused
        emit(.failed("Could not play \(track.title): \(error)"))
      }
      return
    }

    // The outgoing track stops now. Keeping it audible until the replacement
    // was ready avoided dead air, but it also meant pressing skip and hearing
    // the same song for several more seconds — the button looking ignored,
    // which reads worse than a short gap. Every other player cuts on the
    // press and buffers into the silence.
    //
    // A skip is a cut, not a fade — `transitionDuration` says so, and here it
    // is honoured by not starting one at all.
    graph.cut(graph.activeVoice, to: 0)
    activePlayback?.stop()

    // The fetch itself stays off the main thread. It runs there once and the
    // interface froze for its whole length, on every skip and at the start of
    // every crossfade.
    openReader(for: track) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        // The outgoing track has already been cut, so there is nothing to fall
        // back to: say so rather than sitting in `.buffering` forever, which
        // is a spinner that never resolves.
        self.state = .paused
        self.publishNowPlaying()
        self.emit(.failed("Could not open \(track.title): \(error)"))
      case .success(let reader):
        do {
          try self.beginTrack(at: index, fromFrame: 0, prepared: reader, announced: true)
        } catch {
          // `.paused` as well as the error, matching the branch above and the
          // prepared-reader path. Emitting alone left the spinner running
          // beside the error toast.
          self.state = .paused
          self.publishNowPlaying()
          self.emit(.failed("Could not play \(track.title): \(error)"))
        }
      }
    }
  }

  /**
   Start the track at `index` from `frame`, with its reader opened off the
   calling thread.

   The automatic advance and `play()` on a queue with nothing loaded used to
   call `beginTrack` with no reader, and `beginTrack` opened one inline: a
   content-length probe and a header parse, each a network round trip, on
   whichever thread asked. For the advance that is the main thread — the
   ticker, the lock screen, the car and every event to the host wait behind it
   — and for a car selection it is the main thread too. Reported as the app
   freezing hard at the end of songs. Skips and crossfades had already been
   moved off it; these two had not.

   The preloaded reader is used when it is for this track, so the ordinary
   advance opens nothing at all — which is also what makes it gapless.
   */
  private func startTrack(at index: Int, fromFrame frame: Int64,
                          previousListenedSec: Double? = nil) {
    guard queue.tracks.indices.contains(index) else {
      finish()
      return
    }
    let track = queue.tracks[index]
    state = .buffering
    // The outgoing playback is finished or absent. A ticker left running over
    // it reads its final position against the queue's new next track, which
    // with a crossfade set begins a fade past the track being opened.
    // `beginTrack` starts the ticker again.
    stopTicking()

    if frame == 0, let prepared = preparedNext, prepared.id == track.id {
      preparedNext = nil
      begin(track, at: index, fromFrame: frame,
            previousListenedSec: previousListenedSec, reader: prepared.reader)
      return
    }

    openReader(for: track) { [weak self] result in
      guard let self else { return }
      switch result {
      case .failure(let error):
        // Say so rather than sitting in `.buffering`, a spinner that never
        // resolves — the automatic advance once swallowed exactly this.
        self.state = .paused
        self.publishNowPlaying()
        self.emit(.failed("Could not open \(track.title): \(error)"))
      case .success(let reader):
        self.begin(track, at: index, fromFrame: frame,
                   previousListenedSec: previousListenedSec, reader: reader)
      }
    }
  }

  private func begin(_ track: Track, at index: Int, fromFrame frame: Int64,
                     previousListenedSec: Double?, reader: TrackReader) {
    // Paused while the reader was opening. Now that opening is not instant
    // there is a window to press pause in, and starting the audio anyway
    // would ignore the press. Loaded and held, so play resumes it.
    let holdPaused = state == .paused
    do {
      try beginTrack(at: index, fromFrame: frame,
                     previousListenedSec: previousListenedSec, prepared: reader)
      if holdPaused { pause() }
    } catch {
      state = .paused
      publishNowPlaying()
      emit(.failed("Could not play \(track.title): \(error)"))
    }
  }

  private func beginTrack(at index: Int, fromFrame frame: Int64,
                          previousListenedSec: Double? = nil,
                          prepared reader: TrackReader,
                          announced: Bool = false) throws {
    guard queue.tracks.indices.contains(index) else {
      finish()
      return
    }
    let track = queue.tracks[index]

    state = .buffering
    // A skip or an advance after an interruption starts audio too. A new track
    // supersedes whatever position was held for the old one.
    try reclaimAudioIfNeeded()
    pendingRestart = nil
    // Always handed a reader that is already open. This used to open one
    // itself when given none, on whatever thread called — see `startTrack` for
    // what that cost.

    // This path starts the track on the *active* voice, so that is the one that
    // has to match the file's rate — reconnecting the idle voice here would
    // prepare the one node that is not about to be used, and leave the playing
    // one on whatever rate it last had (48kHz on a fresh graph). The track then
    // plays 8.8% fast and a semitone and a half sharp, because the node reads
    // the reader's 44.1kHz buffers as 48kHz ones; the position is wrong by the
    // same ratio. Safe to reconnect because this voice is not playing yet; the
    // crossfade path is the one that must use the idle voice.
    graph.reconnect(graph.activeVoice, toSourceRate: reader.sampleRate)

    activeReader = reader
    // A new track is a new budget: reconnections spent on the last one say
    // nothing about this one. The underrun count goes with it — it is a
    // per-track figure, and a pending announcement from the track being
    // replaced must not land on this one.
    underrunsThisTrack = 0
    forgetUnderrun()
    readStalled = false
    reconnectAttempts = 0
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    wire(playback)
    activePlayback = playback

    graph.setTrackGain(graph.activeVoice, to: playerGain(for: track))
    graph.cut(graph.activeVoice, to: 1)

    // `.playing` is announced when audio actually starts, not here. `start()`
    // only dispatches the decode, and that decode blocks on the network — so
    // on a slow connection this used to report playing while nothing had been
    // scheduled, and the player sat at 0:00 behind a pause button with no way
    // to say it was still waiting. Staying in `.buffering` until the first
    // buffer is handed to the node makes the state mean what it says.
    playback.onFirstBufferScheduled = { [weak self, weak playback] in
      DispatchQueue.main.async {
        guard let self, self.activePlayback === playback, self.state == .buffering else { return }
        self.state = .playing
        self.publishNowPlaying()
      }
    }

    try playback.start(atFrame: frame)
    listenedAccumulated = 0
    listeningSince = now()

    // `announced` means the caller already said so — a skip announces the
    // moment the button is pressed rather than when the network answers, and
    // saying it twice would have a host scrobble or redraw for one skip twice.
    // Whatever was preloaded was the *previous* track's successor. Dropping a
    // stale one lets the preloader fetch what is next now, rather than pinning
    // a reader nothing will ask for.
    if preparedNext?.id != queue.nextTrack?.id { preparedNext = nil }

    if !announced {
      emit(.trackChanged(index: index, id: track.id, previousListenedSec: previousListenedSec))
    }
    publishNowPlaying()
    startTicking()
  }

  /// Called when a track runs out with no crossfade to carry it.
  /**
   A track reached its end. Advance, unless it was not the track being heard.

   `finished` is the playback that ended, and it is checked against the active
   one rather than trusted. During a crossfade the *outgoing* track keeps
   playing to its own natural end, several seconds after the crossover has
   already moved the queue on — so without this it advances a second time and
   the listener is thrown into a third track.

   `transitioning` does not cover it: that is cleared at the crossover, which
   is the midpoint of the fade, leaving the whole second half of the window in
   which the outgoing track can still end with the guard already down. Identity
   holds whatever the timing.
   */
  private func handleTrackFinished(_ finished: TrackPlayback?) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // Only a fade that is *running* handles the handover. One that is still
      // being prepared has to be abandoned, or the queue never advances.
      if self.fading { return }
      if self.transitioning {
        self.cancelTransition()
      }
      guard finished == nil || finished === self.activePlayback else { return }
      // An end that arrived a long way before the end of the song is not one.
      if self.endedShortOfItsLength() {
        if self.reconnectStream() { return }
        // Out of reconnections, and advancing now would be the silent skip
        // this check exists to stop. Said out loud instead, the same way a
        // stream lost with an error is.
        let title = self.queue.activeTrack?.title ?? "this track"
        self.state = .paused
        self.publishNowPlaying()
        self.emit(.failed("\(title) stopped before it ended"))
        return
      }
      let listened = self.listenedSeconds()
      // Asks the queue rather than adding one, so repeat is honoured in the
      // one place it has to be: `.one` returns the same index and the track
      // starts again, `.all` wraps at the end instead of finishing.
      guard let next = self.queue.nextIndex else { self.finish(); return }
      self.queue.set(self.queue.tracks, startIndex: next)
      // The most travelled transition in the engine, and the last one that
      // opened its reader inline on the main thread. `startTrack` opens off
      // it, takes the preload when there is one, and reports a failed open
      // rather than leaving a spinner.
      self.startTrack(at: next, fromFrame: 0, previousListenedSec: listened)
    }
  }

  /**
   Whether the track that just "ended" stopped a long way short of its length.

   A track can end early with nothing thrown anywhere, and `TrackPlayback`
   treats a read that returns no frames and no error as the genuine end of the
   file, which is the only thing it can do from there. This was written for the
   sequential transport, where a transcode whose connection dies produces
   exactly that, and it has since had to grow: the ranged transport reaches the
   same place by a different road — see below.
   `StreamingByteSource` is marked finished by its producer's `onFinish`,
   `totalBytes()` drops from the estimate to the bytes that actually arrived,
   and the next read comes back empty at what is now, by every measure the
   reader has, the end of the file. `AudioFileReader` duly returns
   `kAudioFileEndOfFileError`, which is correct and useless.

   Nothing on that path throws, so all of the recovery below it is bypassed:
   the retry ladder, the stall signal, `reconnectStream`. The queue simply
   advances. What the listener gets is a song stopping thirty seconds in and
   the next one starting, with no error, no buffering spinner and nothing in
   any log — the same symptom the read-failure work already fixed, arriving by
   the one route that does not look like a failure.

   The length is what catches it, because it is the one fact the broken
   transport cannot forge: it comes from the host's metadata, not from the
   bytes. `track.durationSec` rather than `trustedDuration` for that reason —
   the latter falls back to a reader-derived length, and on the sequential
   transport that length is the guess that is already wrong.

   **The ranged transport used to be excluded here, and that was a hole.** The
   comment said its length is the server's `Content-Length` and its end really
   is the end, which is true of the *bytes* and says nothing about a reader
   that stopped before reaching them. `AudioFileReader` did exactly that: it
   ended every track at `kExtAudioFileProperty_FileLengthFrames`, which for a
   container with no packet table is extrapolated from the leading frames'
   bitrate and goes short on a front-loaded VBR file. So the one transport
   this check declined to look at was the one where a perfectly healthy
   connection delivered a song that stopped two thirds of the way through —
   the same silent skip, arriving by the one route that had been reasoned out
   of scope. `AudioFileReader.lengthIsMeasured` is the fix for the cause; this
   is the net under it.

   Excluded, deliberately, and each for a reason the hole did not have:

   - Live radio, which has no length to fall short of.
   - A host that did not say how long the track is, leaving nothing to check
     against.
   - Genuine ends, which land inside `truncationToleranceSec`.
   - A ranged track whose *reader* agrees the audio ran out where it did. This
     is what replaces the blanket exclusion, and it answers the worry that
     exclusion was written for: a short file carrying an optimistic tag must
     still be able to finish. On the ranged transport the reader's length is
     an independent witness — it came from the container over a source that
     can be re-read, not from a byte stream that died — so when it says the
     audio ended where playback stopped, the tag is the thing that is wrong
     and the track has genuinely finished. Only a stop short of *both*
     lengths is a truncation.

   That witness is deliberately not consulted on the sequential transport,
   where it is no witness at all: `StreamingByteSource.totalBytes()` collapses
   from its estimate to the bytes that actually arrived the moment the
   producer stops, so the reader's length agrees with any truncation by
   construction. There the host's duration is the only fact left, which is
   what this check was originally built on.
   */
  private func endedShortOfItsLength() -> Bool {
    guard let reader = activeReader else { return false }
    guard let track = queue.activeTrack, !track.continuous else { return false }
    guard let declared = track.durationSec, declared > 0 else { return false }
    let position = progress.positionSec
    guard position < declared - Self.truncationToleranceSec else { return false }
    // See above: on the forward-only transport the reader's length is derived
    // from the bytes that arrived, so it cannot contradict their disappearance.
    if reader.isSequential { return true }
    guard reader.sampleRate > 0, reader.totalFrames > 0 else { return true }
    let readerSec = Double(reader.totalFrames) / reader.sampleRate
    return position < readerSec - Self.truncationToleranceSec
  }

  // Test seams: driving these through real timing would need a track long
  // enough to fade and a link slow enough to lose the race.
  func beginTransitionForTesting(over duration: TimeInterval) { beginTransition(over: duration) }
  /// Drops the preloaded reader, so a test can reach the path where the
  /// crossfade has to fetch for itself.
  func discardPreloadForTesting() { preparedNext = nil }
  func finishActiveTrackForTesting() { handleTrackFinished(activePlayback) }
  /// The notification itself is iOS-only and cannot be posted on a Mac, but
  /// what it triggers is ordinary code — so the recovery is testable even
  /// though the wiring that reaches it is not.
  func recoverFromMediaServicesResetForTesting() { recoverFromMediaServicesReset() }
  /// The configuration-change notification cannot be made to fire on cue, but
  /// what it triggers is ordinary code.
  func configurationChangedForTesting() { rebuildAfterConfigurationChange() }
  /// What the system does to the graph when it takes audio away: stop it.
  func stopGraphForTesting() { graph.stop() }
  var graphIsRunningForTesting: Bool { graph.isRunning }

  /// Raise the stall and recovery signals the reader raises, so a test can
  /// check what the engine does with them without a network that misbehaves
  /// on cue.
  /// Leave a stopped playback in place, which is what a failed stream and a
  /// failed graph rebuild both do, without needing either to happen.
  func stopActivePlaybackForTesting() { activePlayback?.stop() }

  /// Whether the active playback has its handlers attached. `finishActive…`
  /// cannot answer this — it calls `handleTrackFinished` directly and so
  /// passes whether or not `onEndOfTrack` was ever assigned, which is exactly
  /// how the unwired crossfade path went unnoticed.
  var activePlaybackIsWiredForTesting: Bool {
    activePlayback?.onEndOfTrack != nil && activePlayback?.onReadFailed != nil
      // Included for the reason the other two are: `wire` is the one place
      // that attaches handlers precisely so a fourth site cannot omit one,
      // and a check that does not name a handler cannot notice it missing.
      && activePlayback?.onUnderrun != nil
  }
  var activePlaybackIsFinishedForTesting: Bool { activePlayback?.isFinished ?? true }

  func stallActiveTrackForTesting() { activePlayback?.onReadStalled?() }
  func resumeActiveTrackForTesting() { activePlayback?.onReadResumed?() }

  /// Raise the underrun signals, for the same reason: draining a real node on
  /// cue needs a link that goes slow without going wrong, which is the one
  /// condition this whole change exists because nobody can reproduce.
  func underrunActiveTrackForTesting() { activePlayback?.onUnderrun?() }
  func endUnderrunActiveTrackForTesting() { activePlayback?.onUnderrunEnded?() }
  var underrunCountForTesting: Int { underrunsThisTrack }

  /// Fires the *real* wired failure handler, which is the entry point to the
  /// reconnection. Not a shortcut past what is being tested: the alternative
  /// is a test that waits out `TrackPlayback.readRetryBudgetSec`, forty
  /// seconds of it, to reach the same call.
  func failActiveTrackForTesting(_ error: Error) { activePlayback?.onReadFailed?(error) }

  // MARK: - The crossfade

  /**
   Whether the lock screen's fix point needs re-sending.

   True when what iOS is showing — the last published position plus the wall
   time since, since it extrapolates at the playback rate — has drifted from
   the real position by more than a second. A second is under the threshold
   where a listener would notice a correction, and well above the jitter of
   a tick that runs four times a second.

   Pure, so the threshold and the direction can be tested without a lock
   screen. Direction matters: drift is one-sided in practice, because
   rendered frames fall behind wall clock during a stall and never run ahead
   of it, but this is written symmetrically rather than assuming that.
   */
  static func shouldRepublish(
    actual: Double, published: Double?, publishedAt: Date?, now: Date,
    tolerance: Double = 1.0
  ) -> Bool {
    guard let published, let publishedAt else { return true }
    let expected = published + now.timeIntervalSince(publishedAt)
    return abs(actual - expected) > tolerance
  }

  /**
   Whether it is time to start fading into the next track.

   Pure, and separated out because it is the one piece of this worth testing
   directly: everything else here is plumbing around a timer.
   */
  public static func shouldBeginTransition(
    positionSec: Double, durationSec: Double, transitionSec: Double
  ) -> Bool {
    guard transitionSec > 0, durationSec > 0 else { return false }
    return positionSec >= durationSec - transitionSec
  }

  /**
   Which duration to believe when deciding where a track ends.

   The reader derives its length from bytes, and for a transcoding endpoint
   that length is an estimate the server was never obliged to get right — a
   Subsonic or Jellyfin transcode can declare a byte count that maps to far
   less audio than the song contains. Deciding the fade from it starts the
   crossfade in the middle of the track.

   The host's own metadata is the song's real length, so when the two disagree
   by more than a rounding error, that is the one to trust. When they agree,
   the reader's is preferred: it is the decoded truth, exact for a local file
   and already corrected for encoder padding.

   `nil` means the host does not know, which is not the same as zero.
   */
  /**
   How long the current track is, for anything that reports a length.

   Exists so there is exactly one answer. The seek bar and the lock screen were
   computing this separately, and fixing only the first left the second showing
   a byte-derived length — the same wrong number on the surface where it is
   least visible and most irritating. Anything that needs a duration asks here.
   */
  private var trustedDuration: Double {
    guard let reader = activeReader, reader.sampleRate > 0 else { return 0 }
    guard let track = queue.activeTrack, !track.continuous else { return 0 }
    return Self.referenceDuration(
      readerSec: Double(reader.totalFrames) / reader.sampleRate,
      declaredSec: track.durationSec
    )
  }

  public static func referenceDuration(readerSec: Double, declaredSec: Double?) -> Double {
    guard let declaredSec, declaredSec > 0 else { return readerSec }
    guard readerSec > 0 else { return declaredSec }
    let disagreement = abs(readerSec - declaredSec) / declaredSec
    return disagreement > 0.05 ? declaredSec : readerSec
  }

  /**
   Where playback is now, asked rather than waited for.

   The host gets this as an event on a timer, but an event stream is no use to
   something that has just mounted: a screen opened mid-track would show zero
   until the next tick. Cheap enough to ask directly, and it reads the same
   values the tick emits rather than a cached copy that could disagree.
   */
  public var progress: (positionSec: Double, durationSec: Double, bufferedSec: Double) {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else {
      return (0, 0, 0)
    }
    let frame = playback.currentFrame
    let position = Double(frame) / reader.sampleRate
    return (
      position,
      // A live stream has no finish line, and reporting the bytes fetched so
      // far as a duration draws a progress bar that lies. Neither does a
      // byte-derived length that disagrees with the host — see
      // `trustedDuration`, which is the one answer every surface uses.
      trustedDuration,
      // Absolute, not relative: a buffering bar is drawn against the same
      // timeline as the position, so a figure measured from the playhead would
      // sit at the wrong end of it.
      position + Double(reader.bufferedFramesAhead(ofFrame: frame)) / reader.sampleRate
    )
  }

  private func tick() {
    guard let playback = activePlayback, let reader = activeReader, reader.sampleRate > 0 else { return }
    // Read once, through the same accessor `getProgress` uses, so the event
    // and the answer to a direct question cannot drift apart.
    let (position, duration, buffered) = progress
    let sinceLast = lastProgressEmit.map { now().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
    if sinceLast >= progressIntervalSec {
      lastProgressEmit = now()
      emit(.progress(positionSec: position, durationSec: duration, bufferedSec: buffered))
    }

    // Correct the lock screen when it has drifted, rather than on a timer.
    // Re-sending the fix point every tick stutters; leaving it alone lets the
    // error accumulate for the length of a track. Doing it only when the two
    // actually disagree costs one comparison and bounds the error at the
    // threshold.
    if state == .playing, Self.shouldRepublish(
      actual: position, published: publishedPosition,
      publishedAt: publishedAt, now: now()
    ) {
      publishNowPlaying()
    }

    preloadNextIfIdle(bufferedAheadSec: buffered - position, remainingSec: duration - position)

    guard !transitioning else { return }
    let fade = queue.transitionDuration(userInitiated: false)
    // `duration` is already the trusted one — `progress` applies
    // `referenceDuration` so the seek bar and the fade cannot disagree.
    guard Self.shouldBeginTransition(positionSec: position, durationSec: duration, transitionSec: fade) else {
      return
    }
    beginTransition(over: fade)
  }

  private func beginTransition(over duration: TimeInterval) {
    guard let next = queue.nextTrack else { return }
    transitioning = true

    // Already open? Then the fade starts on time. The crossfade used to do its
    // own fetch twelve seconds before the end, which is only early enough if
    // the fetch takes less than twelve seconds — on a slow link it does not,
    // and the fade never happens: the track ends, and the next one is opened
    // from scratch into the silence. Reported as a long gap between tracks on
    // an album that was otherwise playing fine.
    if let prepared = preparedNext, prepared.id == next.id {
      preparedNext = nil
      continueTransition(over: duration, next: next, reader: prepared.reader)
      return
    }

    // Off the main thread, like a skip. This runs from the ticker, which is
    // scheduled on `RunLoop.main`, so opening inline froze the interface at
    // the start of every crossfade — the one moment a listener is most likely
    // to be looking at it. The outgoing track is untouched until the reader
    // arrives, so a slow fetch delays the fade rather than interrupting it.
    openReader(for: next) { [weak self] result in
      guard let self else { return }
      guard case .success(let reader) = result else {
        // Nothing has been touched, so the track simply plays to its end and
        // `handleTrackFinished` takes it from there.
        self.transitioning = false
        if case .failure(let error) = result {
          self.emit(.failed("Could not open \(next.title): \(error)"))
        }
        return
      }
      self.continueTransition(over: duration, next: next, reader: reader)
    }
  }

  private func continueTransition(over duration: TimeInterval, next: Track, reader: TrackReader) {
    do {
      graph.reconnectIdleVoice(toSourceRate: reader.sampleRate)

      let incoming = TrackPlayback(reader: reader, voice: graph.idleVoice, label: "decode.incoming")
      // The fourth site, and the one `wire` warned about in as many words.
      // Without this the track the crossfade brings in has no end-of-track
      // handler, so when it finishes the queue never advances — the music
      // stops with the player still reporting that it is playing — and a lost
      // stream on it is silent too.
      wire(incoming)
      incomingPlayback = incoming
      // Set before the fade begins, not at the crossover: a track arriving at
      // the wrong loudness and being corrected halfway through the fade is
      // audible in a way that the correction itself is supposed to prevent.
      incomingTrack = next
      graph.setTrackGain(graph.idleVoice, to: playerGain(for: next))
      try incoming.start(atFrame: 0)

      let outgoing = activePlayback
      let listened = listenedSeconds()

      // Equal power on both halves: two tracks are audible together here,
      // and linear ramps would sum to a hole in the middle of the crossover.
      fading = true
      graph.fade(graph.idleVoice, to: 1, over: duration, curve: .equalPower)
      graph.fade(graph.activeVoice, to: 0, over: duration, curve: .equalPower) { [weak self] in
        outgoing?.stop()
        self?.incomingPlayback = nil
      }

      // Halfway through is when the incoming track becomes the one being heard,
      // so that is when it becomes the one being reported.
      DispatchQueue.main.asyncAfter(deadline: .now() + duration / 2) { [weak self] in
        guard let self else { return }
        self.graph.swapVoices()
        self.activePlayback = incoming
        self.activeReader = reader
        self.queue.set(self.queue.tracks, startIndex: self.queue.activeIndex + 1)
        // The incoming track has been audible since the fade began, half a
        // fade ago, so it starts with that much already listened rather than
        // from zero.
        self.listenedAccumulated = duration / 2
        self.listeningSince = self.now()
        self.transitioning = false
        self.fading = false
        /*
         Say the state, do not assume it.

         This was the one path that started a track and left `state` alone,
         because at the crossover it is *usually* already `.playing` — so the
         omission was invisible almost every time. It is not always: the
         outgoing track's last seconds run in exactly the window where a patchy
         connection stalls, and `onReadStalled` sets `.buffering`. The stall
         belonged to a playback that is now stopped and discarded, and nothing
         would ever clear it: `onReadResumed` fires on the *outgoing* playback,
         and its guard requires it to still be `self.activePlayback`, which it
         no longer is.

         So the engine crossed into a track that was audibly playing while
         holding `.buffering` for the rest of it. `publishNowPlaying` maps that
         to `MPNowPlayingInfoPropertyPlaybackRate: 0.0` — which is what dims the
         lock screen transport and draws a play glyph over music that is
         playing — while `positionSec` is set from the real playhead on the same
         dictionary and keeps the progress bar advancing normally (#212). It
         also stops `preloadNextIfIdle`, which requires `.playing`, so the track
         after this one is never preloaded either.

         `.playing` unconditionally is correct here rather than a fix for one
         stale value: audio from the incoming voice has been at full gain since
         the crossover, so by the time this runs the engine *is* playing. A
         paused engine cannot reach this — `pause()` pauses `incomingPlayback`
         too, and a fade cannot be running while paused.
         */
        self.state = .playing
        self.emit(.trackChanged(index: self.queue.activeIndex, id: next.id,
                                previousListenedSec: listened))
        self.publishNowPlaying()
      }
    } catch {
      transitioning = false
      emit(.failed(String(describing: error)))
    }
  }

  private func cancelTransition() {
    guard transitioning else { return }
    transitioning = false
    fading = false
    // A fade whose reader is still being fetched has to be abandoned too, or
    // it lands after the thing that cancelled it and starts a crossfade into a
    // track that is no longer next.
    openToken &+= 1
    incomingPlayback?.stop()
    incomingPlayback = nil
    incomingTrack = nil
    graph.cut(graph.idleVoice, to: 0)
    // And the active voice back to full. It was part-way through fading *out*
    // when the fade was abandoned, and leaving it there means the track that
    // goes on playing is quieter than it should be — audible after a seek
    // during a crossfade, and left behind by a skip for the whole next track.
    graph.cut(graph.activeVoice, to: 1)
  }

  // MARK: - Bookkeeping

  /// Played time for the outgoing track, fade included, pauses excluded.
  /// See `Event.trackChanged`.
  private func listenedSeconds() -> Double? {
    guard listeningSince != nil || listenedAccumulated > 0 else { return nil }
    let open = listeningSince.map { now().timeIntervalSince($0) } ?? 0
    return listenedAccumulated + open
  }

  private func finish() {
    stopEverything()
    state = .ended
    nowPlaying.clear()
    emit(.ended)
  }

  private func stopEverything() {
    // An open still in flight belongs to what is being stopped. Without this a
    // `setQueue` or `stop` arriving while a track was opening was followed by
    // that track starting anyway, into a queue that no longer holds it.
    openToken &+= 1
    pendingRestart = nil
    cancelTransition()
    activePlayback?.stop()
    activePlayback = nil
    activeReader = nil
    stopTicking()
  }

  private func startTicking() {
    stopTicking()
    // Four times a second: fast enough that a crossfade starts within a frame
    // of where it should, cheap enough to leave running.
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    ticker = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func stopTicking() {
    ticker?.invalidate()
    ticker = nil
  }

  private func emit(_ event: Event) {
    onEvent?(event)
  }
}
