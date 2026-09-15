import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 Coming back after the system takes the audio away.

 An interruption — a call, Siri, an alarm, another app with a non-mixable
 session — and a route or format change both stop the engine underneath the
 player, and discard every buffer scheduled on it. What followed used to depend
 on luck. Play resumed a node on a stopped engine, which raises an Objective-C
 exception rather than returning an error. A configuration change while paused
 tried to start an engine the inactive session would not allow, dropped the
 playback, and reported a playback failure, so the next play started the song
 over and re-opened the stream.

 The notifications are iOS-only or cannot be made to fire on cue, so these drive
 what they trigger: `interruptionBegan`, `interruptionEnded(shouldResume:)` and
 the configuration-change handler, with the graph stopped the way the system
 stops it. The recovery is the part that was wrong.
 */
final class InterruptionRecoveryTests: XCTestCase {

  private final class CountingFactory: TrackReaderFactory {
    let data: Data
    private(set) var readersMade = 0
    init(data: Data) { self.data = data }

    func makeReader(for track: Track) throws -> TrackReader {
      readersMade += 1
      return AudioFileReader(source: CachedByteSource(fetcher: Memory(data), windowBytes: 64 * 1024))
    }

    private final class Memory: ByteFetcher, @unchecked Sendable {
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

  private var engine: PlaybackEngine!
  private var factory: CountingFactory!
  private var graph: AudioGraph!
  private var trackChanges = 0
  private var failures: [String] = []
  private var states: [PlaybackEngine.PlaybackState] = []

  override func setUpWithError() throws {
    let fixture = try EncodedFixture.wav(seconds: 30)
    factory = CountingFactory(data: fixture.data)
    graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    engine = PlaybackEngine(graph: graph, factory: factory)
    trackChanges = 0
    failures = []
    states = []
    engine.onEvent = { [unowned self] event in
      switch event {
      case .trackChanged: self.trackChanges += 1
      case .failed(let message): self.failures.append(message)
      case .stateChanged(let state): self.states.append(state)
      default: break
      }
    }
  }

  private func settle(timeout: TimeInterval = 3, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /// Two tracks, the first loaded and positioned twelve seconds in.
  private func playingAtTwelveSeconds() throws {
    engine.setQueue([
      Track(id: "a", uri: "https://example.test/a", title: "a", durationSec: 30),
      Track(id: "b", uri: "https://example.test/b", title: "b", durationSec: 30),
    ], startIndex: 0)
    try engine.play()
    settle { engine.activePlaybackIsWiredForTesting }
    try engine.seek(toSeconds: 12)
    settle { engine.state == .playing }
    trackChanges = 0
    states = []
  }

  /// What the system does when it takes the audio: stop the engine, then tell us.
  private func interrupt() {
    engine.stopGraphForTesting()
    engine.interruptionBegan()
  }

  private func assertPlayingAtTwelve(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
    settle { engine.state == .playing }
    XCTAssertEqual(engine.state, .playing, message, file: file, line: line)
    XCTAssertTrue(engine.graphIsRunningForTesting, "the graph was never restarted", file: file, line: line)
    XCTAssertFalse(engine.activePlaybackIsFinishedForTesting, "left holding a stopped playback", file: file, line: line)
    XCTAssertEqual(engine.progress.positionSec, 12, accuracy: 1, "came back somewhere other than where it was", file: file, line: line)
    XCTAssertEqual(factory.readersMade, 1, "the stream was re-opened to resume the same second", file: file, line: line)
    XCTAssertEqual(trackChanges, 0, "the host was told about a track change that did not happen", file: file, line: line)
    XCTAssertEqual(failures, [], "a recovered interruption was reported as a failure", file: file, line: line)
  }

  // MARK: - Interruptions

  func testAnInterruptionPausesAndHoldsThePosition() throws {
    try playingAtTwelveSeconds()
    interrupt()

    XCTAssertEqual(engine.state, .paused)
    XCTAssertEqual(engine.progress.positionSec, 12, accuracy: 1)
    XCTAssertEqual(failures, [])
  }

  /// A call ends, and the system says to carry on.
  func testTheSystemSayingResumePicksUpWhereItWas() throws {
    try playingAtTwelveSeconds()
    interrupt()
    engine.interruptionEnded(shouldResume: true)

    assertPlayingAtTwelve("did not resume after the system said to")
    XCTAssertEqual(states.suffix(2), [.buffering, .playing], "the host should see buffering, then playing")
  }

  /// A non-mixable app — remote desktop, a video — ends without `.shouldResume`.
  /// The engine stays paused; pressing play works.
  func testAnInterruptionThatDoesNotSayResumeStaysPausedAndPlayWorks() throws {
    try playingAtTwelveSeconds()
    interrupt()
    engine.interruptionEnded(shouldResume: false)
    XCTAssertEqual(engine.state, .paused, "music started without the system saying it could")

    try engine.play()
    assertPlayingAtTwelve("play did nothing after an interruption that did not resume")
  }

  /// The case reported: the other app never sends an end at all, and the
  /// listener comes back and presses play — from the app, the lock screen,
  /// AirPods or the car, which all arrive at `play()`.
  func testPlayWorksWhenTheInterruptionNeverEnds() throws {
    try playingAtTwelveSeconds()
    interrupt()

    try engine.play()
    assertPlayingAtTwelve("play did nothing while the interruption was never ended")
  }

  /// Playback the listener had already paused is not started by a call ending.
  func testAnInterruptionOfPausedPlaybackDoesNotStartIt() throws {
    try playingAtTwelveSeconds()
    engine.pause()
    interrupt()
    engine.interruptionEnded(shouldResume: true)

    XCTAssertEqual(engine.state, .paused)
    try engine.play()
    assertPlayingAtTwelve("play did nothing after a call during a pause")
  }

  /// And audio actually comes out, rather than a state that says playing over a
  /// node whose buffers were thrown away.
  func testResumedPlaybackIsAudible() throws {
    try playingAtTwelveSeconds()
    interrupt()
    try engine.play()
    settle { engine.state == .playing }
    Thread.sleep(forTimeInterval: 0.3)

    let rendered = try graph.renderOffline(frames: 8192)
    var sum: Float = 0
    for channel in 0..<Int(rendered.format.channelCount) {
      for frame in 0..<Int(rendered.frameLength) {
        let sample = rendered.floatChannelData![channel][frame]
        sum += sample * sample
      }
    }
    let rms = (sum / Float(max(1, Int(rendered.frameLength) * Int(rendered.format.channelCount)))).squareRoot()
    XCTAssertGreaterThan(rms, 0.05, "resumed after an interruption into silence")
  }

  func testASeekWhileInterruptedPlaysFromTheNewPosition() throws {
    try playingAtTwelveSeconds()
    interrupt()

    try engine.seek(toSeconds: 20)
    settle { engine.state == .playing }

    XCTAssertTrue(engine.graphIsRunningForTesting)
    XCTAssertEqual(engine.progress.positionSec, 20, accuracy: 1)
    XCTAssertEqual(failures, [])
  }

  func testASkipWhileInterruptedStartsTheNextTrack() throws {
    try playingAtTwelveSeconds()
    interrupt()

    try engine.skipToNext()
    settle { engine.state == .playing && engine.queue.activeIndex == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1)
    XCTAssertTrue(engine.graphIsRunningForTesting)
    XCTAssertEqual(engine.state, .playing)
    XCTAssertLessThan(engine.progress.positionSec, 2, "the next track should start from its top")
    XCTAssertEqual(failures, [])
  }

  // MARK: - Route and format changes

  /// AirPods switching profile, a car connecting: picked straight back up.
  func testAConfigurationChangeWhilePlayingCarriesOn() throws {
    try playingAtTwelveSeconds()
    engine.stopGraphForTesting()
    engine.configurationChangedForTesting()

    assertPlayingAtTwelve("a route change while playing stopped the music")
  }

  /**
   A format change during an interruption — the other app switching the
   hardware rate — leaves the engine paused and intact.

   It used to try to start the engine into an inactive session, drop the
   playback when that failed, and report a failure; play then started the song
   over.
   */
  func testAConfigurationChangeDuringAnInterruptionKeepsTheTrack() throws {
    try playingAtTwelveSeconds()
    interrupt()
    engine.configurationChangedForTesting()

    XCTAssertEqual(engine.state, .paused, "a route change started music during an interruption")
    XCTAssertEqual(failures, [], "a route change during an interruption was reported as a failure")

    try engine.play()
    assertPlayingAtTwelve("play after a format change during an interruption lost the track")
  }

  /// Several teardowns before anything restarts: the position is the first one's.
  func testRepeatedTeardownsKeepTheOriginalPosition() throws {
    try playingAtTwelveSeconds()
    interrupt()
    engine.configurationChangedForTesting()
    interrupt()
    engine.configurationChangedForTesting()

    try engine.play()
    assertPlayingAtTwelve("repeated teardowns lost the position")
  }

  /// A configuration change with nothing loaded still leaves the next play able to start.
  func testAConfigurationChangeWithNothingLoadedDoesNotBreakTheNextPlay() throws {
    engine.setQueue([Track(id: "a", uri: "https://example.test/a", title: "a", durationSec: 30)], startIndex: 0)
    engine.stopGraphForTesting()
    engine.configurationChangedForTesting()

    try engine.play()
    settle { engine.state == .playing }
    XCTAssertEqual(engine.state, .playing)
    XCTAssertTrue(engine.graphIsRunningForTesting)
  }

  // MARK: - The session

  /// The host's session hook is what reclaims the audio, on every path back.
  func testPlayAfterAnInterruptionReclaimsTheSession() throws {
    try playingAtTwelveSeconds()
    var reclaimed = 0
    engine.reconfigureAudioSession = { reclaimed += 1 }
    interrupt()

    try engine.play()
    settle { engine.state == .playing }
    XCTAssertEqual(reclaimed, 1, "play after an interruption never re-activated the session")

    // And not again for an ordinary pause and resume, which never lost it.
    engine.pause()
    try engine.play()
    XCTAssertEqual(reclaimed, 1)
  }

  /**
   Another app still holds the audio — a call in progress — and play is pressed.

   The engine stays paused with the track and position kept, and says nothing
   about a failure: a failure event would have the host retry or drop a track
   that is fine. Pressing play once the call is over works.
   */
  func testPlayWhileAudioIsStillTakenStaysPausedAndRecoversLater() throws {
    try playingAtTwelveSeconds()
    struct CallInProgress: Error {}
    engine.reconfigureAudioSession = { throw CallInProgress() }
    interrupt()

    XCTAssertThrowsError(try engine.play())
    XCTAssertEqual(engine.state, .paused)
    XCTAssertEqual(failures, [], "a session still held by a call is not a broken track")
    XCTAssertEqual(engine.progress.positionSec, 12, accuracy: 1)

    engine.reconfigureAudioSession = {}
    try engine.play()
    assertPlayingAtTwelve("play did not recover once the other app let go")
  }
}
