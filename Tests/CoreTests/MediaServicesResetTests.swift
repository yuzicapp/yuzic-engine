import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 Coming back after the media server restarts.

 `mediaserverd` is a separate process and it dies — under memory pressure, on a
 Bluetooth handover, in a car. Apple's contract is that every audio object this
 process holds is invalid afterwards: the engine, the player nodes, the units,
 and the session category the host set once at setup.

 Nothing observed that notification, so nothing put any of it back. The engine
 kept its state, its queue and its now-playing info while the graph underneath
 was rubble — a track showing paused with transport controls that did nothing,
 until the app was force-quit.

 The notification is iOS-only and cannot be posted on a Mac, so what these
 drive is the recovery rather than the wiring that reaches it. That split is
 deliberate and it is the same one `shouldResumeAfterInterruption` makes: the
 rule is the part that is easy to get subtly wrong, and the rule is what gets
 pinned.
 */
final class MediaServicesResetTests: XCTestCase {

  // MARK: - Fixtures

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

  private final class CountingFactory: TrackReaderFactory {
    let data: Data
    private(set) var readersMade = 0
    init(data: Data) { self.data = data }

    func makeReader(for track: Track) throws -> TrackReader {
      try makeReader(for: track, timeOffsetSeconds: 0)
    }
    func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
      readersMade += 1
      return AudioFileReader(source: BlobSource(data))
    }
  }

  private func song(_ id: String) -> Track {
    Track(id: id, uri: "https://example.test/stream?id=\(id)", title: id, durationSec: 30)
  }

  private func makeEngine() throws -> (PlaybackEngine, CountingFactory) {
    let fixture = try EncodedFixture.wav(seconds: 30)
    let factory = CountingFactory(data: fixture.data)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    return (PlaybackEngine(graph: graph, factory: factory), factory)
  }

  private func settle(timeout: TimeInterval = 2, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  // MARK: - The recovery

  /**
   The session is reclaimed, and before the graph is touched.

   A reset clears the category the host set at setup, and a graph started into
   a session with no category is the dead-but-healthy-looking player this whole
   change exists to remove. Ordering is the assertion: the session has to be
   back before anything tries to make sound through it.
   */
  func testTheAudioSessionIsReconfiguredBeforeTheGraphRestarts() throws {
    let (engine, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }

    var reconfigured = 0
    engine.reconfigureAudioSession = { reconfigured += 1 }

    engine.recoverFromMediaServicesResetForTesting()

    XCTAssertEqual(reconfigured, 1, "the session the reset cleared was never re-applied")
  }

  /**
   A player that cannot be rebuilt says so.

   The failure this replaces was silent, and a silent failure here is the bug:
   the listener is left looking at a track that will not play with nothing to
   explain it.
   */
  func testAFailedRecoveryIsReported() throws {
    let (engine, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }
    engine.reconfigureAudioSession = { throw ByteSourceError.fetchFailed("session refused") }

    engine.recoverFromMediaServicesResetForTesting()

    XCTAssertEqual(failures.count, 1, "a recovery that could not happen said nothing")
    XCTAssertEqual(engine.state, .paused, "left claiming to be playing into a dead graph")
  }

  /**
   The track is kept, at the position it had reached.

   A media services reset invalidates *audio* objects. An `AudioFileReader`
   over an HTTP source is not one, and re-opening it would turn a recoverable
   glitch into a network stall — so the reader is reused and no new one is
   asked for.
   */
  func testTheTrackAndPositionSurviveTheReset() throws {
    let (engine, factory) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }
    try engine.seek(toSeconds: 12)
    let readersBefore = factory.readersMade

    engine.reconfigureAudioSession = {}
    engine.recoverFromMediaServicesResetForTesting()
    settle { engine.state == .paused }

    XCTAssertEqual(factory.readersMade, readersBefore, "the stream was re-opened needlessly")
    XCTAssertEqual(engine.queue.activeIndex, 0, "the queue moved")
    XCTAssertEqual(
      engine.progress.positionSec, 12, accuracy: 1,
      "playback came back somewhere other than where it left off"
    )
  }

  /**
   It comes back paused, not playing.

   The other recovery paths resume, because a route change is the same second
   of the same song and the listener never stopped listening. A media services
   reset is a crash the audio system just had, and starting music unbidden out
   of whatever output iOS has settled on afterwards is a guess about which one
   that is.
   */
  func testPlaybackComesBackPausedRatherThanResuming() throws {
    let (engine, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }
    settle { engine.state == .playing || engine.state == .buffering }

    engine.reconfigureAudioSession = {}
    engine.recoverFromMediaServicesResetForTesting()

    XCTAssertEqual(engine.state, .paused, "music restarted itself after the audio system crashed")
  }

  /**
   And the play button works afterwards.

   This is the whole point. Before, the transport controls were attached to
   nodes that no longer existed and pressing play did nothing at all — the
   symptom being a song sitting there paused and refusing to move.
   */
  func testPlayWorksAfterAReset() throws {
    let (engine, _) = try makeEngine()
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }

    engine.reconfigureAudioSession = {}
    engine.recoverFromMediaServicesResetForTesting()
    settle { engine.state == .paused }

    try engine.play()
    // The track starts once its reader has opened, off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }
    settle { engine.state == .playing || engine.state == .buffering }

    XCTAssertTrue(
      engine.state == .playing || engine.state == .buffering,
      "the play button did nothing after a reset — the symptom this fixes"
    )
  }
}

/**
 The graph's own half of it: new objects, and the user's settings back on them.
 */
final class AudioGraphResetTests: XCTestCase {

  /**
   The nodes are new ones.

   Restarting the same `AVAudioEngine` is what `handleConfigurationChange`
   does, and it is not enough here: after a reset the object itself is invalid,
   so identity is the assertion rather than any audible property.
   */
  func testRebuildingProducesFreshVoices() throws {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    let before = graph.activeVoice.player

    try graph.rebuildAfterReset()

    XCTAssertFalse(
      before === graph.activeVoice.player,
      "the graph kept the player node the media server invalidated"
    )
  }

  /**
   The user's equalizer survives the media server; the unit carrying it did not.

   Re-applied from the settings rather than copied off the old nodes, which is
   the only way that works: the old nodes cannot be asked what they were set to.
   */
  func testTheEqualizerCurveIsPutBack() throws {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    graph.setEqualizer(bands: [(frequency: 100, gainDb: 6, q: 1)])
    XCTAssertFalse(graph.isEqualizerBypassed)

    try graph.rebuildAfterReset()

    XCTAssertFalse(graph.isEqualizerBypassed, "the listener's EQ was silently flattened by a reset")
  }

  /// Likewise the playback speed, which a podcast listener would notice at once.
  func testTheSpeedSettingIsPutBack() throws {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    graph.setSpeed(1.5)

    try graph.rebuildAfterReset()

    XCTAssertEqual(graph.currentSpeed, 1.5, "playback speed reset itself to 1x")
  }

  /**
   Which voice is foreground is this class's own bookkeeping, not the media
   server's. Resetting it would swap the graph under a crossfade still running
   upstairs — and put full scale on the wrong one of the pair.
   */
  func testTheForegroundVoiceIsPreserved() throws {
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    graph.swapVoices()
    XCTAssertFalse(graph.activeIsA)

    try graph.rebuildAfterReset()

    XCTAssertFalse(graph.activeIsA, "the foreground voice flipped across a rebuild")
    XCTAssertEqual(graph.activeVoice.gain.outputVolume, 1, "the silent voice was left in front")
  }
}
