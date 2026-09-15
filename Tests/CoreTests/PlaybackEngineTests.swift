import XCTest
import AVFoundation
@testable import YuzicEngineCore

final class PlaybackEngineTests: XCTestCase {

  /**
   The crossfade trigger.

   Pure, and the one part of the engine worth testing directly — the rest is
   plumbing around a timer, and this is the decision the plumbing exists to
   make. `transitionDuration` decides how long a fade is; this decides when it
   starts, and the two are separate so each can be wrong on its own terms.
   */
  func testTransitionStartsExactlyAFadeBeforeTheEnd() {
    let begins = PlaybackEngine.shouldBeginTransition

    // Eight-second fade on a 240-second track: nothing at 231, everything from
    // 232 onward.
    XCTAssertFalse(begins(231, 240, 8))
    XCTAssertTrue(begins(232, 240, 8))
    XCTAssertTrue(begins(239, 240, 8))
  }

  func testNoTransitionWhenThereIsNoFade() {
    // transitionDuration returning zero is how every "cut, do not fade" rule is
    // expressed — a continuous stream, a segue, a manual skip. All of them
    // arrive here as a zero and must not start anything.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 239, durationSec: 240, transitionSec: 0))
  }

  func testNoTransitionWhenTheDurationIsUnknown() {
    // Live radio has no finish line to count backwards from.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 600, durationSec: 0, transitionSec: 8))
  }

  func testAFadeLongerThanTheTrackStartsImmediately() {
    // Clamping is transitionDuration's job, not this one's; if a long fade does
    // arrive here it should still behave sensibly rather than never firing.
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(positionSec: 0, durationSec: 5, transitionSec: 10))
  }

  // MARK: - Which duration decides where a track ends

  /**
   A byte-derived duration that disagrees with the host loses.

   Reported from a real library: a song crossfaded into the next at about
   forty seconds instead of near its end. With a twelve-second fade that puts
   the reader's idea of the track at roughly fifty seconds — a transcoding
   endpoint declaring a byte length that maps to a fraction of the song. The
   host knows the real length from the server's metadata, and had it all along.
   */
  func testTheHostsDurationWinsWhenTheReaderIsWildlyShort() {
    // 52s of "file" against a 200s song: trust the song.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 52, declaredSec: 200), 200)
    // And the fade then starts where it should, not at forty seconds.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(positionSec: 40, durationSec: 200, transitionSec: 12))
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(positionSec: 188, durationSec: 200, transitionSec: 12))
  }

  /**
   The real case, with the real numbers.

   Movements — *Pulse*, 3:21 of FLAC at 1105 kbps, streamed over cellular where
   the forward-only path applies. The size handed to the parser was
   `duration × assumedBitrate`, and 320 kbps is about a third of what lossless
   costs — so 201.6s became 8 MB, which at the real byte rate reads as 58
   seconds. A twelve-second crossfade then began at 46.
   */
  func testTheAlbumThatReportedThis() {
    let declared = 201.6                     // Navidrome and the FLAC header agree
    let readerThought = 8_064_000.0 / (1_105_000.0 / 8)   // ≈ 58.4s

    let trusted = PlaybackEngine.referenceDuration(readerSec: readerThought, declaredSec: declared)
    XCTAssertEqual(trusted, declared)

    // Before: a fade beginning three quarters of the way through the track.
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(
      positionSec: 47, durationSec: readerThought, transitionSec: 12))
    // After: nothing until the song is actually ending.
    XCTAssertFalse(PlaybackEngine.shouldBeginTransition(
      positionSec: 47, durationSec: trusted, transitionSec: 12))
    XCTAssertTrue(PlaybackEngine.shouldBeginTransition(
      positionSec: 190, durationSec: trusted, transitionSec: 12))
  }

  /// The assumption has to clear lossless, or the same fault returns by format.
  func testTheAssumedBitrateClearsUncompressedHiRes() {
    // 24-bit/192kHz stereo is 9.22 Mbps uncompressed — the realistic ceiling.
    // Clearing it means no format can be under-reported and truncated, which
    // is what 320 kbps did to an ordinary CD-rate FLAC.
    let uncompressed24_192 = 24.0 * 192_000 * 2
    XCTAssertGreaterThan(HTTPTrackReaderFactory.assumedBitrate, uncompressed24_192,
                         "must exceed uncompressed hi-res, not just transcoded output")
  }

  func testTheReaderWinsWhenTheTwoAgree() {
    // Exact for a local file, and already corrected for encoder padding, so a
    // small disagreement should not throw away the more precise number.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 199.5, declaredSec: 200), 199.5)
  }

  func testAnUnknownHostDurationLeavesTheReaderInCharge() {
    // `nil` is "the host does not know", which is not zero.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 200, declaredSec: nil), 200)
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 200, declaredSec: 0), 200)
    // And a live stream, which has no finish line either way, still cannot fade.
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 0, declaredSec: nil), 0)
  }

  func testAReaderThatKnowsNothingDefersToTheHost() {
    XCTAssertEqual(PlaybackEngine.referenceDuration(readerSec: 0, declaredSec: 200), 200)
  }

  /**
   A skip does not block the main thread, and cuts the old track at once.

   `open()` on a remote track is a network round trip, and it used to run
   inline on the main thread — so a car skip froze the interface for the length
   of the fetch, and the lock screen could not show the new track until it
   finished. Reported as thirteen seconds before the car display changed.

   The factory here blocks inside `makeReader` the way a slow network would.
   That the assertions run at all while it is blocked is the point: if the open
   were still inline, this thread would be stuck inside `skipToNext`.

   The outgoing track is cut on the press rather than left playing until the
   replacement arrives. Keeping it audible avoided dead air but made the button
   look ignored, which reads worse than a short gap.
   */
  func testASkipCutsAtOnceWithoutBlockingTheMainThread() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()

    let opening = DispatchSemaphore(value: 0)   // the fetch has started
    let release = DispatchSemaphore(value: 0)   // let it finish
    factory.onMakeReader = { id in
      guard id == "b" else { return }
      opening.signal()
      // Bounded. An unbounded wait here holds the open queue forever when the
      // test fails before signalling — which wedged a `swift test` run for two
      // hours and kept the SwiftPM lock with it, so every later build sat
      // behind a test that had already failed.
      _ = release.wait(timeout: .now() + 10)
    }

    try engine.skipToNext()

    // Main thread is free: we reached here while the fetch is outstanding.
    XCTAssertEqual(opening.wait(timeout: .now() + 3), .success,
                   "the open should have started on another thread")
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 0,
                   "the old track should be cut on the press, not left playing")
    XCTAssertEqual(engine.queue.activeIndex, 1,
                   "and the queue should already show what was asked for")

    release.signal()
    settle { graph.activeVoice.gain.outputVolume == 1 }
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1, "the new track becomes audible")
  }

  /**
   The next track is opened before anything asks for it.

   A skip that has to fetch is a skip that waits: on cellular a lossless track
   costs seconds to open, which is what made the car's screen sit unchanged
   after the button was pressed. Since most skips go to the track that is
   already next, opening it ahead turns the common case into no fetch at all.
   */
  func testTheNextTrackIsOpenedAhead() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()

    settle(timeout: 5) { engine.isNextPreloaded }
    XCTAssertTrue(engine.isNextPreloaded,
                  "the next track should be opened while the current one plays")
    XCTAssertTrue(factory.opened.contains("b"))
  }

  /// And the skip then uses it rather than fetching again.
  func testASkipToAPreloadedTrackDoesNotFetchAgain() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    // The preload having *landed*, not merely started: the reader is recorded
    // when the fetch begins and stored a round trip later.
    settle(timeout: 5) { engine.isNextPreloaded }
    XCTAssertTrue(engine.isNextPreloaded, "precondition: the next track is ready")

    var openedAfterSkip: [MediaId] = []
    factory.onMakeReader = { openedAfterSkip.append($0) }

    try engine.skipToNext()
    settle { graph.activeVoice.gain.outputVolume == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1)
    XCTAssertFalse(openedAfterSkip.contains("b"),
                   "the skip refetched a track it had already opened")
  }

  /**
   A struggling stream is not asked to fetch a second track.

   The gate is a health check, not a reservoir: a connection that cannot keep
   two seconds ahead of what is playing has no business being asked for
   another. On the link this was reported from, reads were failing outright.
   */
  func testNothingIsPreloadedWhileTheCurrentTrackIsStarved() {
    // Below the threshold, and with plenty of track left to go.
    XCTAssertLessThan(0.4, PlaybackEngine.preloadAfterBufferedSec)
    // The threshold has to be reachable, or the feature never runs at all:
    // `bufferedFramesAhead` reports the read window, measured at ~2.2s here.
    XCTAssertLessThanOrEqual(PlaybackEngine.preloadAfterBufferedSec, 2.2)
  }

  /**
   A track that ends while the crossfade is still fetching still advances.

   `transitioning` exists to stop the ticker starting a second fade, and
   `handleTrackFinished` read it as "a fade is running, it will hand over".
   That was true while the crossfade's reader was opened synchronously — the
   flag and a running fade were the same thing. Opening it asynchronously
   split them, and on a link where the fetch takes longer than the fade is
   long, the track ended into a flag that said someone else was handling it.
   Nobody was: reported as a long silence after a song, and then the next one
   arriving with no crossfade at all, because the fade finally started against
   a track that was already over.
   */
  func testATrackEndingWhileTheFadeIsStillLoadingStillAdvances() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    settle(timeout: 5) { engine.isNextPreloaded }
    // Drop it: this test is about the path where the crossfade has to fetch
    // for itself, which is where the flag and a running fade come apart.
    engine.discardPreloadForTesting()

    // Hold the crossfade's own fetch open, the way a slow link would.
    let fetching = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { id in
      guard id == "b" else { return }
      fetching.signal()
      // Bounded. An unbounded wait here holds the open queue forever when the
      // test fails before signalling — which wedged a `swift test` run for two
      // hours and kept the SwiftPM lock with it, so every later build sat
      // behind a test that had already failed.
      _ = release.wait(timeout: .now() + 10)
    }

    var advancedTo: Int?
    engine.onEvent = { if case .trackChanged(let index, _, _) = $0 { advancedTo = index } }

    // A fade that is merely being prepared must not swallow the end of track.
    engine.beginTransitionForTesting(over: 12)
    _ = fetching.wait(timeout: .now() + 3)
    engine.finishActiveTrackForTesting()

    // Two opens of "b" wait on the fixture now: the abandoned fade's, and the
    // advance's own, which no longer runs inline. Let both through.
    release.signal()
    release.signal()
    settle { advancedTo == 1 }

    XCTAssertEqual(advancedTo, 1,
                   "the queue must advance rather than wait on a fade that never started")
  }

  /**
   A track reaching its end does not open the next one on the main thread.

   The automatic advance is the most travelled transition in the engine, and
   it was the one still opening inline: `handleTrackFinished` runs on main and
   called `beginTrack` with no reader, so `makeReader` and `open()` — a
   content-length probe and a header parse, each a network round trip — ran on
   the thread that drives the ticker, the lock screen, the car and every bridge
   event. Reported as the app freezing hard at the end of songs.

   The factory blocks the way a slow link does. If the open were inline, the
   runloop turn that delivers the end of track would be stuck inside it and
   `settle` could not come back until the fixture's own ten-second bound.
   */
  func testATrackEndingDoesNotOpenTheNextOneOnTheMainThread() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    settle(timeout: 5) { engine.isNextPreloaded }
    // The path without a preload: a link too slow to have fetched ahead.
    engine.discardPreloadForTesting()

    let opening = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { id in
      guard id == "b" else { return }
      opening.signal()
      _ = release.wait(timeout: .now() + 10)
    }

    var advancedTo: Int?
    engine.onEvent = { if case .trackChanged(let index, _, _) = $0 { advancedTo = index } }

    engine.finishActiveTrackForTesting()
    // Queued behind the end-of-track delivery. If the advance opened inline,
    // the turn that runs it would sit in the fixture for its ten-second bound
    // and this marker could not run until then.
    var turned = false
    DispatchQueue.main.async { turned = true }
    let started = Date()
    settle { turned && engine.state == .buffering }
    let mainWasHeldFor = Date().timeIntervalSince(started)

    XCTAssertEqual(opening.wait(timeout: .now() + 3), .success, "the next track was never opened")
    XCTAssertTrue(turned)
    XCTAssertLessThan(mainWasHeldFor, 2,
                      "the main thread was held for the length of the next track's open")
    XCTAssertNil(advancedTo, "precondition: the open is still outstanding")

    release.signal()
    settle { advancedTo == 1 && graph.activeVoice.gain.outputVolume == 1 }
    XCTAssertEqual(advancedTo, 1, "the queue advances once the track has opened")
    XCTAssertEqual(engine.queue.activeIndex, 1)
  }

  /// And a natural end uses the reader the preload already opened, the same way
  /// a skip does, rather than fetching the track a second time.
  func testATrackEndingUsesThePreloadedReader() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    settle(timeout: 5) { engine.isNextPreloaded }
    XCTAssertTrue(engine.isNextPreloaded, "precondition: the next track is ready")

    var openedAfterEnd: [MediaId] = []
    factory.onMakeReader = { openedAfterEnd.append($0) }

    engine.finishActiveTrackForTesting()
    settle { engine.queue.activeIndex == 1 && graph.activeVoice.gain.outputVolume == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1)
    XCTAssertFalse(openedAfterEnd.contains("b"),
                   "the advance refetched a track the preload had already opened")
  }

  /**
   `play()` on a queue with nothing loaded returns before the reader is open.

   A car selection calls it on the main thread, so opening inline froze the car
   and the phone together for the length of the fetch.
   */
  func testPlayingAFreshQueueDoesNotOpenOnTheCallingThread() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { _ in _ = release.wait(timeout: .now() + 10) }

    let started = Date()
    try engine.play()
    let returnedAfter = Date().timeIntervalSince(started)
    release.signal()

    XCTAssertLessThan(returnedAfter, 1, "play() waited for the reader to open")
    settle { graph.activeVoice.gain.outputVolume == 1 && engine.activePlaybackIsWiredForTesting }
    XCTAssertTrue(engine.activePlaybackIsWiredForTesting, "the track starts once it has opened")
  }

  /// And a pause pressed while it opens is kept, rather than the track starting
  /// anyway once the network answers.
  func testAPauseWhileAFreshQueueOpensIsKept() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { _ in _ = release.wait(timeout: .now() + 10) }

    try engine.play()
    engine.pause()
    release.signal()

    settle { engine.activePlaybackIsWiredForTesting }
    XCTAssertTrue(engine.activePlaybackIsWiredForTesting, "the track is still loaded")
    XCTAssertEqual(engine.state, .paused)
  }

  /// A queue replaced while its first track opens does not start that track.
  func testReplacingTheQueueAbandonsAnOpenInFlight() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { id in if id == "a" { _ = release.wait(timeout: .now() + 10) } }

    try engine.play()
    engine.setQueue([song("b")], startIndex: 0)
    release.signal()

    let deadline = Date().addingTimeInterval(0.5)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    XCTAssertEqual(engine.state, .idle, "a track from the replaced queue started")
    XCTAssertFalse(engine.activePlaybackIsWiredForTesting)
  }

  /**
   A skip inside the fade window goes to the track asked for.

   The ticker kept running over the cut track while the skip's reader opened,
   read its last position against the queue's new next track, and — with a
   crossfade set — began a fade into the track after the one asked for. That
   fade's open superseded the skip's, so the skip never landed.
   */
  func testASkipNearTheEndDoesNotFadeIntoTheTrackAfterIt() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 0)
    try engine.play()
    settle { engine.state == .playing }

    // No runloop turns between these, so no tick lands before the skip.
    try engine.seek(toSeconds: 2.5)
    engine.queue.crossfade = CrossfadeSettings(durationSec: 1, mode: .always)
    engine.discardPreloadForTesting()

    let release = DispatchSemaphore(value: 0)
    factory.onMakeReader = { id in if id == "b" { _ = release.wait(timeout: .now() + 2) } }
    try engine.skipToNext()

    // Several ticks while the skip's open is outstanding.
    let deadline = Date().addingTimeInterval(0.8)
    while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    release.signal()
    settle { graph.activeVoice.gain.outputVolume == 1 && engine.activePlaybackIsWiredForTesting }
    let settleMore = Date().addingTimeInterval(1)
    while Date() < settleMore { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }

    XCTAssertEqual(engine.queue.activeIndex, 1, "the skip was overtaken by a fade into the track after it")
  }

  // MARK: - Volume, and the node it is allowed to touch

  /**
   Volume goes to the player, not to the gain node the crossfade ramps.

   This is the whole bug. `setVolume` wrote `gain.outputVolume` directly —
   the node `AudioGraph.setTrackGain` documents as belonging to fades, where
   "anything else written there is overwritten by the next ramp". So volume
   lasted until the next fade, skip or track change, and a skip taken during a
   crossfade left the voice stranded at whatever the abandoned ramp had
   reached, with the next volume command writing somewhere nothing would read
   again until the following track. Reported from a car: skip went silent, and
   the volume button then stopped the music entirely until the app restarted.
   */
  func testVolumeGoesToThePlayerNotTheFadeNode() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 0.5

    XCTAssertEqual(graph.activeVoice.player.volume, 0.5, accuracy: 0.0001)
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1,
                   "the gain node belongs to the fade and must be left alone")
  }

  /// A skip used to discard volume, because the new track's gain was cut to 1.
  func testVolumeSurvivesASkip() throws {
    let (engine, factory, graph) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    engine.volume = 0.4

    try engine.skipToNext()
    // Wait for the handover itself, not for the reader being *made* — that is
    // recorded on the open queue, before `beginTrack` has run back on main.
    settle { graph.activeVoice.gain.outputVolume == 1 }

    XCTAssertEqual(graph.activeVoice.player.volume, 0.4, accuracy: 0.0001,
                   "the next track should play at the volume the user chose")
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1, "and at full fade gain")
  }

  /// Volume and replay gain are two multiplications, and both must survive.
  func testVolumeComposesWithReplayGain() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 0.5
    let atFullVolume = graph.activeVoice.player.volume
    engine.volume = 1.0
    let expectedGain = graph.activeVoice.player.volume

    XCTAssertEqual(atFullVolume, expectedGain * 0.5, accuracy: 0.0001,
                   "halving volume should halve whatever replay gain decided")
  }

  func testVolumeIsClamped() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    engine.volume = 5
    XCTAssertEqual(graph.activeVoice.player.volume, 1, accuracy: 0.0001)
    engine.volume = -2
    XCTAssertEqual(graph.activeVoice.player.volume, 0, accuracy: 0.0001)
  }

  // MARK: - Repeat and the user's own skip

  /**
   A user skip obeys repeat, the same as an automatic advance does.

   `nextIndex` is where the queue's repeat rules live: under `.all` it wraps
   with `(activeIndex + 1) % count`. The automatic advance asks it. `skipToNext`
   did not — it computed `activeIndex + 1` directly, which on the last track is
   out of range, and `move` reads an index past the end as "the queue is
   finished" and stops playback.

   So the same queue, on the same track, in the same repeat mode, wrapped when
   the track ended by itself and stopped the music when the user pressed next.
   Android already asked `nextIndex` here; this is iOS catching up.
   */
  func testSkipToNextWrapsUnderRepeatAll() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 1)
    engine.queue.repeatMode = .all
    try engine.play()

    try engine.skipToNext()

    XCTAssertEqual(engine.queue.activeIndex, 0, "next on the last track should wrap to the first")
    XCTAssertNotEqual(engine.state, .idle, "wrapping should keep playing, not finish")
  }

  /**
   What `previous` means, which is not always "the previous track".

   iOS moved unconditionally: on the first track that computed -1, `move`
   rejected it, and the button did nothing at all. Android has had both rules
   since the model port — past three seconds, or on the first track, previous
   restarts. These are the same rule, now on both platforms.
   */
  func testPreviousRestartsPastThreeSeconds() {
    let action = PlaybackEngine.previousAction

    // Early in a track, previous means the previous track.
    XCTAssertEqual(action(0.5, 2), .goBack)
    XCTAssertEqual(action(3.0, 2), .goBack, "exactly three seconds is not yet past it")

    // Past the threshold it means "start this one again".
    XCTAssertEqual(action(3.1, 2), .restart)
    XCTAssertEqual(action(90, 2), .restart)
  }

  func testPreviousOnTheFirstTrackRestartsRatherThanDoingNothing() {
    // There is nothing before the first track, and the old behaviour computed
    // -1 and was silently rejected. Restarting is the only useful meaning.
    XCTAssertEqual(PlaybackEngine.previousAction(positionSec: 0.5, activeIndex: 0), .restart)
    XCTAssertEqual(PlaybackEngine.previousAction(positionSec: 90, activeIndex: 0), .restart)
  }

  /**
   Repeat-one is deliberately not wrapped onto a user skip.

   `nextIndex` under `.one` returns the *current* index, because that is what
   should play when this track ends. A person pressing next has asked to leave
   this track, so the skip advances rather than replaying it — the two callers
   want different answers from the same repeat mode, and that is why the skip
   cannot simply delegate to `nextIndex` in every case.
   */
  func testSkipToNextUnderRepeatOneStillAdvances() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    engine.queue.repeatMode = .one
    try engine.play()

    try engine.skipToNext()

    XCTAssertEqual(engine.queue.activeIndex, 1, "a person pressing next wants the next track, not this one again")
  }

  // MARK: - Queue movement, driven through the real graph

  /// Hands out readers over an in-memory WAV, so the engine can be driven with
  /// no network and no audio hardware.
  private final class FixtureFactory: TrackReaderFactory {
    let data: Data
    private(set) var opened: [MediaId] = []
    /// Called as a reader is made, so a test can look at the graph at exactly
    /// the moment the engine would be blocking on a network round trip.
    var onMakeReader: ((MediaId) -> Void)?
    /// Ids whose open should fail, for driving the preload's failure path.
    var failOpensFor: Set<MediaId> = []
    init(data: Data) { self.data = data }

    func makeReader(for track: Track) throws -> TrackReader {
      opened.append(track.id)
      onMakeReader?(track.id)
      if failOpensFor.contains(track.id) {
        throw ByteSourceError.fetchFailed("open refused by fixture")
      }
      let source = CachedByteSource(fetcher: MemoryFetcher(data), windowBytes: 32 * 1024)
      return AudioFileReader(source: source)
    }

    private final class MemoryFetcher: ByteFetcher, @unchecked Sendable {
      let blob: Data
      init(_ blob: Data) { self.blob = blob }
      func contentLength() throws -> Int64 { Int64(blob.count) }
      func fetch(_ range: Range<Int64>) throws -> Data {
        let end = min(Int(range.upperBound), blob.count)
        guard Int(range.lowerBound) < end else { return Data() }
        return blob.subdata(in: Int(range.lowerBound)..<end)
      }
    }
  }

  private func song(_ id: String, durationSec: Double? = 3) -> Track {
    Track(id: id, uri: "file:///\(id).wav", title: id, durationSec: durationSec)
  }

  /**
   Drive the main runloop until a condition holds.

   A skip opens its reader off the main thread and lands the handover back on
   it, so the effect of `skipToNext` is not visible on the line after the call.
   That is the point — the fetch no longer blocks the interface — but it means
   a test has to let the runloop turn rather than assert immediately.
   */
  private func settle(timeout: TimeInterval = 3, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  private func makeEngine() throws -> (PlaybackEngine, FixtureFactory, AudioGraph) {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    return (PlaybackEngine(graph: graph, factory: factory), factory, graph)
  }

  /**
   Resuming restores a voice something else faded away.

   The sleep timer fades to silence and pauses, which leaves the gain at zero.
   Resuming without restoring it plays a track nobody can hear while the
   progress bar advances normally — and that reads as a broken player rather
   than a sleep timer that worked.
   */
  func testResumingAfterAFadeToSilenceIsAudible() throws {
    let (engine, _, graph) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }

    // What the sleep timer leaves behind.
    graph.cut(graph.activeVoice, to: 0)
    engine.pause()
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 0)

    try engine.play()
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1)
  }

  /**
   The play path reconnects the voice it actually plays on.

   `makeEngine` builds graph and fixture both at 44.1kHz, so the two rates
   agree and no mismatch can arise — which is exactly why every other test here
   passed while the direct-play path was reconnecting the wrong voice. This one
   pairs a 44.1kHz file with the 48kHz graph real hardware usually gives you.

   The failure is audible: the node reads the reader's 44.1kHz buffers as
   48kHz ones, so the track plays 8.8% fast and about 1.5 semitones sharp. The
   position is wrong by the same ratio — `playerTime.sampleTime` counts in the
   connection's frames while `AudioFileReader.sampleRate` reports the file's —
   so the playhead runs ahead and the crossfade starts early.
   */
  func testPlayingReconnectsTheVoiceItPlaysOn() throws {
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 48_000)
    try graph.startOffline(sampleRate: 48_000)
    let engine = PlaybackEngine(graph: graph, factory: factory)

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }

    XCTAssertEqual(
      graph.activeVoice.player.outputFormat(forBus: 0).sampleRate, 44_100,
      "the playing voice must carry the file's rate, or its position is wrong"
    )
  }

  // MARK: - The system taking the audio away

  /**
   Resuming after an interruption, which is only ever conditional.

   Two things have to be true: the system has to say the interrupting app is
   finished with the session, and the pause has to have been *ours*. Resuming
   playback the listener had already stopped — because a call arrived while
   the player sat paused — starts music in someone's ear for no reason.

   The wiring around this cannot be tested without a device; the rule can, and
   the rule is the part that is easy to get wrong.
   */
  func testResumesOnlyWhatItPausedItself() {
    XCTAssertTrue(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: true, systemSaysResume: true))
  }

  func testDoesNotResumePlaybackTheListenerHadAlreadyStopped() {
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: false, systemSaysResume: true))
  }

  /// The system withholding `.shouldResume` is a decision, not an omission —
  /// it is how it says another app is still using the session.
  func testDoesNotResumeWhenTheSystemSaysNotTo() {
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: true, systemSaysResume: false))
    XCTAssertFalse(PlaybackEngine.shouldResumeAfterInterruption(
      wasPausedByUs: false, systemSaysResume: false))
  }

  func testPlayingOpensTheTrackAtTheStartIndex() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 1)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }

    // First, not only: once "b" plays, the preload may fetch "c" behind it.
    XCTAssertEqual(factory.opened.first, "b")
    XCTAssertFalse(factory.opened.contains("a"))
  }

  /**
   `play()` means "asked to play", not "playing".

   `TrackPlayback.start` dispatches the decode and returns; the decode blocks
   on the network. The engine used to announce `.playing` right there, which
   is why a slow connection could leave a pause button showing over a
   position frozen at 0:00 with nothing able to say it was still waiting.

   So the state stays `.buffering` until a buffer actually reaches the node.
   This test asserts both halves — the state immediately after the call, and
   the transition once audio exists — because the first without the second
   would pass just as well if playback never started at all.
   */
  func testStateIsBufferingUntilAudioActuallyStarts() throws {
    let (engine, _, _) = try makeEngine()

    var seen: [PlaybackEngine.PlaybackState] = []
    engine.onEvent = { if case .stateChanged(let state) = $0 { seen.append(state) } }

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    XCTAssertEqual(engine.state, .buffering, "announced playing before any audio was scheduled")

    let playing = expectation(description: "reaches playing once a buffer is scheduled")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    XCTAssertEqual(engine.state, .playing)
    XCTAssertEqual(seen, [.buffering, .playing], "the host should see the wait, then the start")
  }

  /**
   A stall says so, and recovery says so too.

   `TrackPlayback` has raised `onReadStalled` on the first failed read since
   the retry ladder was written, and for just as long nothing assigned it — so
   a listener whose connection dropped watched a play button sit there through
   up to thirty-three seconds of silence. The engine already had a state for
   exactly this and the app already draws it.

   This is the §12 shape: correct code, written, shipped, never invoked. A test
   that only checked "does playback recover" would pass against the unwired
   version, because recovery was never the broken part.
   */
  func testAStallIsAnnouncedAndClearedOnRecovery() throws {
    let (engine, _, _) = try makeEngine()

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    let playing = expectation(description: "reaches playing before the stall")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    var seen: [PlaybackEngine.PlaybackState] = []
    engine.onEvent = { if case .stateChanged(let state) = $0 { seen.append(state) } }

    // The engine answers these on main, as it does every other state change,
    // so the run loop has to turn before the answer exists.
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

    engine.stallActiveTrackForTesting()
    settle()
    XCTAssertEqual(engine.state, .buffering, "a stalled read left the player claiming to play")

    engine.resumeActiveTrackForTesting()
    settle()
    XCTAssertEqual(engine.state, .playing, "reads resumed and the player stayed in buffering")

    XCTAssertEqual(seen, [.buffering, .playing], "the host was not told either way")
  }

  /**
   Play works again after the thing that was playing has died.

   Reported from a phone: an AirPod ran out of battery mid-track, and after it
   disconnected the song could not be started again at all.

   `resume()` cannot revive a stopped `TrackPlayback` — it calls `play()` on the
   node and then `fill()`, which returns immediately once `stopped` is set. So
   the engine sat holding something that could never sound again, and `play()`
   kept resuming it. Two ordinary paths leave one behind: a stream that failed
   after its retry budget, and a configuration change whose graph rebuild threw
   after stopping the old playback.

   Driven through `stopActivePlaybackForTesting` rather than by pulling a real
   Bluetooth device, because what is being tested is the engine's response to a
   dead playback, not how it got one.
   */
  func testPlayRestartsAPlaybackThatCanNoLongerSound() throws {
    let (engine, _, _) = try makeEngine()

    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    let playing = expectation(description: "reaches playing before the device dies")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    engine.stopActivePlaybackForTesting()
    XCTAssertTrue(engine.activePlaybackIsFinishedForTesting,
                  "the fixture did not leave a stopped playback behind")

    try engine.play()
    settle { !engine.activePlaybackIsFinishedForTesting }

    XCTAssertFalse(engine.activePlaybackIsFinishedForTesting,
                   "play resumed the dead playback instead of starting a live one")
    XCTAssertNotEqual(engine.state, .idle)
  }

  /**
   A preload that cannot open backs off instead of hammering the server.

   The preload is driven by the ticker, four times a second, and its guard
   admits exactly the state a failure leaves behind — `preparedNext` nil,
   `preloading` false. So a next track that would not open was retried
   immediately and forever. Against a real Navidrome that was thirty stream
   requests for one track in four seconds.

   The reason it matters is not the log: those opens share a connection with
   the audio being played, so on a weak link the preload competes with the
   stream and makes the stall it exists to prevent more likely.

   Counted rather than timed — the assertion is "it stopped asking", which is
   the property. A handful of attempts is fine; dozens is the bug.
   */
  func testAFailingPreloadStopsHammering() throws {
    let (engine, factory, _) = try makeEngine()

    engine.setQueue([song("a"), song("b")], startIndex: 0)
    factory.failOpensFor = ["b"]
    try engine.play()

    let playing = expectation(description: "reaches playing")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    // Three seconds of ticker: twelve chances to ask.
    RunLoop.current.run(until: Date().addingTimeInterval(3))

    let attemptsOnB = factory.opened.filter { $0 == "b" }.count
    XCTAssertGreaterThan(attemptsOnB, 0, "the preload never tried at all")
    XCTAssertLessThan(attemptsOnB, 5,
                      "a failing preload is still being retried at ticker rate (\(attemptsOnB) opens in 3s)")
  }

  /**
   A track brought in by a crossfade still ends properly.

   `wire` attaches `onEndOfTrack`, `onReadFailed` and the stall signals, and it
   says in its own comment that it exists "because the failure handler is the
   kind of thing a fourth site would omit without noticing". There were four
   sites. `continueTransition` was the one that omitted it.

   So every track entered through a crossfade had no end-of-track handler: it
   played to its last sample, `notifyEndIfDrained` called nothing, and the
   queue never advanced — the music stopped with the engine still reporting
   that it was playing. A read failure on that track was silent for the same
   reason.

   Drives the crossfade, lets the crossover happen, and then asks the track
   that is now active to finish. If the handler is attached the queue moves.
   */
  func testATrackEnteredByCrossfadeStillAdvancesTheQueue() throws {
    let (engine, _, _) = try makeEngine()

    var advancedTo: [Int] = []
    engine.onEvent = { if case .trackChanged(let index, _, _) = $0 { advancedTo.append(index) } }

    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 0)
    try engine.play()

    let playing = expectation(description: "reaches playing")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    // A short fade, then wait out the crossover so "b" is the active playback.
    engine.beginTransitionForTesting(over: 0.4)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))

    XCTAssertEqual(engine.queue.activeIndex, 1, "the crossfade did not hand over")

    // Asked of the playback itself. Driving `finishActiveTrackForTesting`
    // instead would call `handleTrackFinished` directly and pass either way,
    // which is how this went unnoticed in the first place.
    XCTAssertTrue(engine.activePlaybackIsWiredForTesting,
                  "the track the crossfade brought in has no end-of-track or "
                  + "failure handler, so finishing it will advance nothing and "
                  + "a lost stream on it will be silent")
  }

  /**
   A stall on the outgoing track does not follow the crossfade into the next one.

   Reported from a phone's lock screen (#212): the transport controls dim and
   the glyph shows play, while the progress bar advances normally and the audio
   plays. Intermittent, and only ever later in a track — which is the tell.

   The last seconds of a track are exactly where `beginTransition` runs, and
   also where a patchy connection stalls. `onReadStalled` sets `.buffering` on
   the outgoing playback, and the recovery that would clear it —
   `onReadResumed` — guards on the stalled playback still being
   `activePlayback`. After the crossover it is not, so nothing ever clears it.

   `continueTransition` was the only path that starts a track without stating
   the state, so the engine crossed into audible music holding `.buffering`.
   `publishNowPlaying` maps that to a published playback rate of 0, which is
   what dims iOS's transport and draws the wrong glyph, while `positionSec` on
   the same dictionary keeps the bar moving. It also blocks
   `preloadNextIfIdle`, so the track after that one is never prefetched.

   Asserted on `state` rather than on the published dictionary because
   `NowPlayingTests` already covers the state → rate mapping in both
   directions; what was broken is which state arrives there.
   */
  func testAStallBeforeACrossfadeDoesNotLeaveTheNextTrackBuffering() throws {
    let (engine, _, _) = try makeEngine()

    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 0)
    try engine.play()

    let playing = expectation(description: "reaches playing")
    let deadline = Date().addingTimeInterval(5)
    DispatchQueue.global().async {
      while Date() < deadline && engine.state != .playing { usleep(10_000) }
      playing.fulfill()
    }
    wait(for: [playing], timeout: 6)

    // The connection goes quiet in the outgoing track's last seconds. This is
    // the engine's own stall signal, so it takes the same path a real dropped
    // read does rather than a state written by the test.
    engine.stallActiveTrackForTesting()
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    XCTAssertEqual(engine.state, .buffering, "the stall was not announced at all")

    // Then the track ends anyway and the crossfade carries the next one in.
    engine.beginTransitionForTesting(over: 0.4)
    RunLoop.current.run(until: Date().addingTimeInterval(1.5))

    XCTAssertEqual(engine.queue.activeIndex, 1, "the crossfade did not hand over")
    XCTAssertEqual(engine.state, .playing,
                   "the engine crossed into a playing track still holding the "
                   + "outgoing track's stall, so it publishes a playback rate "
                   + "of 0 over advancing audio and never preloads again")
  }

  func testSkippingMovesTheQueueAndOpensTheNewTrack() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b"), song("c")], startIndex: 0)
    try engine.play()
    try engine.skipToNext()

    // The queue moves immediately — the lock screen should not wait on a fetch.
    XCTAssertEqual(engine.queue.activeIndex, 1)
    // The reader arrives once the open completes off the main thread.
    settle { factory.opened == ["a", "b"] }
    XCTAssertEqual(factory.opened, ["a", "b"])
  }

  func testSkippingPastTheEndFinishesRatherThanCrashing() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()

    var ended = false
    engine.onEvent = { if case .ended = $0 { ended = true } }
    try engine.skipToNext()

    XCTAssertTrue(ended)
    XCTAssertEqual(engine.state, .ended)
  }

  func testSkippingBackwardsBeforeTheStartDoesNothing() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }
    try engine.skipToPrevious()

    // Not an error, and not a wrap-around to the end of the queue — which
    // would open "b" as the *active* track, first after "a". The preload may
    // fetch "b" as next, so what is asserted is that "a" was not reopened and
    // nothing moved.
    XCTAssertEqual(factory.opened.first, "a")
    XCTAssertEqual(factory.opened.filter { $0 == "a" }.count, 1)
    XCTAssertEqual(engine.queue.activeIndex, 0)
  }

  func testTrackChangeReportsWhatWasListenedTo() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a"), song("b")], startIndex: 0)

    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }
    Thread.sleep(forTimeInterval: 0.2)
    try engine.skipToNext()

    // Without this a host scrobbling on "half the track or four minutes" has
    // nothing to measure once a crossfade is involved, because position never
    // reaches duration.
    XCTAssertNotNil(listened)
    XCTAssertGreaterThan(listened ?? 0, 0.1)
  }

  /**
   Paused time is not listened time.

   `previousListenedSec` is what a host judges a scrobble threshold against —
   "half the track, or four minutes" — so counting the pause submits a play to
   Last.fm and ListenBrainz for music nobody heard. A track paused overnight
   and skipped in the morning would clear any threshold there is.

   The clock is injected rather than slept through, so the pause here is an
   hour long and the test still takes no time. Sleeping would only have let me
   test a pause of a few hundred milliseconds, which is precisely the size of
   pause that does not matter.
   */
  func testAPauseDoesNotCountAsListening() throws {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    let engine = PlaybackEngine(graph: graph, factory: factory, now: { clock })

    engine.setQueue([song("a"), song("b")], startIndex: 0)

    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    // The listening clock starts when the track does, which is once its reader
    // has opened — not when play was asked for.
    settle { engine.activePlaybackIsWiredForTesting }
    clock.addTimeInterval(30)      // listened
    engine.pause()
    clock.addTimeInterval(3600)    // did not listen
    try engine.play()
    clock.addTimeInterval(10)      // listened
    try engine.skipToNext()

    XCTAssertEqual(listened ?? 0, 40, accuracy: 0.001,
                   "the hour spent paused was counted as listening")
  }

  /// Pausing twice must not bank the same stretch twice.
  func testPausingAnAlreadyPausedTrackDoesNotDoubleCount() throws {
    var clock = Date(timeIntervalSince1970: 1_000_000)
    let fixture = try EncodedFixture.wav(seconds: 3)
    let factory = FixtureFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    let engine = PlaybackEngine(graph: graph, factory: factory, now: { clock })

    engine.setQueue([song("a"), song("b")], startIndex: 0)
    var listened: Double?
    engine.onEvent = {
      if case .trackChanged(_, _, let seconds) = $0, let seconds { listened = seconds }
    }

    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }
    clock.addTimeInterval(20)
    engine.pause()
    clock.addTimeInterval(5)
    engine.pause()
    try engine.skipToNext()

    XCTAssertEqual(listened ?? 0, 20, accuracy: 0.001)
  }

  func testPauseAndResumeDoNotReopenTheTrack() throws {
    let (engine, factory, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }
    engine.pause()
    XCTAssertEqual(engine.state, .paused)
    try engine.play()

    XCTAssertEqual(engine.state, .playing)
    XCTAssertEqual(factory.opened, ["a"], "resuming re-decoded the track from scratch")
  }

  func testStateGoesIdleOnStop() throws {
    let (engine, _, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    engine.stop()
    XCTAssertEqual(engine.state, .idle)
  }
}

final class SleepTimerTests: XCTestCase {

  func testFiresEarlyByTheFadeSoTheMusicHasGoneWhenAsked() {
    let expectation = expectation(description: "fired")
    var handedFade: TimeInterval?

    let timer = SleepTimer { fade in
      handedFade = fade
      expectation.fulfill()
    }
    // Half a second requested: the fade is clamped to half of it, so it fires
    // after 0.25s having asked for a 0.25s fade — the music is gone at 0.5s
    // rather than beginning to go then.
    timer.schedule(after: 0.5)

    wait(for: [expectation], timeout: 2)
    XCTAssertEqual(handedFade ?? 0, 0.25, accuracy: 0.05)
  }

  func testCancellingStopsItFiring() {
    let timer = SleepTimer { _ in XCTFail("a cancelled timer fired") }
    timer.schedule(after: 0.3)
    timer.cancel()
    XCTAssertNil(timer.firesAt)
    Thread.sleep(forTimeInterval: 0.5)
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }

  func testRemainingCountsDown() {
    let timer = SleepTimer { _ in }
    timer.schedule(after: 60)
    let remaining = timer.remainingSeconds ?? 0
    XCTAssertGreaterThan(remaining, 58)
    XCTAssertLessThanOrEqual(remaining, 60)
  }

  func testSchedulingAgainReplacesTheFirst() {
    let timer = SleepTimer { _ in XCTFail("the replaced timer fired") }
    timer.schedule(after: 0.2)
    timer.schedule(after: 60)
    XCTAssertGreaterThan(timer.remainingSeconds ?? 0, 30)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
  }
}
