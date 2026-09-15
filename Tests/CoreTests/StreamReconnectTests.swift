import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 Picking a transcoded stream back up after it breaks.

 The sequential transport is the one that cannot retry a read: the bytes came
 from a producer that has stopped, and asking for them again waits on a stream
 nobody is sending. `TrackPlayback`'s ladder therefore spent its whole budget
 on a fault it could not fix and the track died at the end of it — which is the
 shape of the cut-out people reported from a moving car, on transcoded streams
 only.

 What these cover is the recovery: a new request for the same track from the
 second reached, and a position that carries on from there rather than
 restarting at zero.
 */
final class StreamReconnectTests: XCTestCase {

  // MARK: - Fixtures

  /// A source over an in-memory blob that can be told it is sequential, which
  /// is the only property of the transport the engine's decision reads.
  private final class BlobSource: ByteSource {
    let blob: Data
    let sequential: Bool
    init(_ blob: Data, sequential: Bool) {
      self.blob = blob
      self.sequential = sequential
    }
    var isSequential: Bool { sequential }
    func totalBytes() throws -> Int64 { Int64(blob.count) }
    func read(offset: Int64, count: Int) throws -> Data {
      let end = min(Int(offset) + count, blob.count)
      guard Int(offset) < end else { return Data() }
      return blob.subdata(in: Int(offset)..<end)
    }
    func availableBytes(from offset: Int64) -> Int64 {
      max(0, Int64(blob.count) - offset)
    }
    func cancel() {}
    func resume() {}
  }

  /// Records what it was asked for, which is the assertion that matters: a
  /// reconnection is a *new request carrying an offset*, and a factory that
  /// were handed zero would be restarting the track from the top.
  private final class RecordingFactory: TrackReaderFactory {
    let data: Data
    let sequential: Bool
    private(set) var offsetsAsked: [Int] = []
    /// Refuse every open from this attempt onwards, to drive the path where
    /// reconnecting itself fails.
    var refuseFromAttempt: Int?

    init(data: Data, sequential: Bool) {
      self.data = data
      self.sequential = sequential
    }

    func makeReader(for track: Track) throws -> TrackReader {
      try makeReader(for: track, timeOffsetSeconds: 0)
    }

    func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
      offsetsAsked.append(timeOffsetSeconds)
      if let refuseFromAttempt, offsetsAsked.count >= refuseFromAttempt {
        throw ByteSourceError.fetchFailed("server refused the reconnection")
      }
      return AudioFileReader(source: BlobSource(data, sequential: sequential))
    }
  }

  private func song(_ id: String, durationSec: Double? = 30) -> Track {
    Track(id: id, uri: "https://example.test/stream?id=\(id)", title: id, durationSec: durationSec)
  }

  private func makeEngine(sequential: Bool) throws -> (PlaybackEngine, RecordingFactory) {
    let fixture = try EncodedFixture.wav(seconds: 30)
    let factory = RecordingFactory(data: fixture.data, sequential: sequential)
    let graph = AudioGraph(sampleRate: 44_100)
    try graph.startOffline(sampleRate: 44_100)
    return (PlaybackEngine(graph: graph, factory: factory), factory)
  }

  private func settle(timeout: TimeInterval = 3, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /// Puts the playhead somewhere there is something to come back *to*. A
  /// stream that fails in its first second has nothing to resume and is
  /// deliberately not reconnected.
  private func playAndSeek(_ engine: PlaybackEngine, toSeconds seconds: Double) throws {
    engine.setQueue([song("a")], startIndex: 0)
    try engine.play()
    // A seek needs a reader, and the track's opens off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }
    try engine.seek(toSeconds: seconds)
  }

  // MARK: - The recovery

  /**
   A broken stream is asked for again from where it stopped.

   Before this the failure went straight to `.failed` and the track was over.
   The offset is the whole point: without it the listener is thrown back to
   0:00 of a track they were eight seconds into.
   */
  func testABrokenStreamIsReopenedAtThePositionReached() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try playAndSeek(engine, toSeconds: 8)

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    engine.failActiveTrackForTesting(ByteSourceError.fetchFailed("stream went away"))
    settle { factory.offsetsAsked.count >= 2 }

    XCTAssertEqual(factory.offsetsAsked.last, 8, "reopened from the second reached, not from the top")
    XCTAssertEqual(failures, [], "the track was recovered, so nothing was lost")
  }

  /**
   The position survives the reconnection.

   The reopened stream's own frame zero is eight seconds into the track, so a
   reader counting from zero would report the listener back at the beginning
   while the audio carried on correctly — a progress bar that jumps backwards
   and a scrobble that never reaches its threshold. `readerOrigin` is what
   keeps the two apart.
   */
  func testPositionCarriesOnAcrossAReconnection() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try playAndSeek(engine, toSeconds: 8)

    engine.failActiveTrackForTesting(ByteSourceError.fetchFailed("stream went away"))
    settle { factory.offsetsAsked.count >= 2 }
    settle { engine.progress.positionSec >= 8 }

    // Asserted before the position, because without it this test passes on a
    // track that simply stopped: a dead playback keeps reporting the frame it
    // died at, which is also >= 8. The position only means something once a
    // reconnection is known to have happened.
    XCTAssertEqual(factory.offsetsAsked.count, 2, "no reconnection was attempted")
    XCTAssertGreaterThanOrEqual(
      engine.progress.positionSec, 8,
      "reported position went backwards across a reconnection"
    )
  }

  /**
   A seekable source is left alone.

   Reconnecting a ranged track would throw away a working transport and its
   disk cache to solve a problem it does not have: its retry ladder can ask
   for the same bytes again, and by the time this fires it already has.
   */
  func testARangedTrackIsNotReconnected() throws {
    let (engine, factory) = try makeEngine(sequential: false)
    try playAndSeek(engine, toSeconds: 8)

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    engine.failActiveTrackForTesting(ByteSourceError.fetchFailed("stream went away"))
    settle { !failures.isEmpty }

    XCTAssertEqual(factory.offsetsAsked.count, 1, "nothing should have been reopened")
    XCTAssertEqual(failures.count, 1, "a ranged failure is still reported as a failure")
  }

  /**
   Reconnection is bounded.

   The failure being recovered from is, from here, indistinguishable from a
   server that has stopped answering. Unbounded, a dead server would be asked
   for the same track for as long as the app ran.
   */
  func testReconnectionGivesUpAfterItsBudget() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try playAndSeek(engine, toSeconds: 8)

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }
    var lastOpens = factory.offsetsAsked.count

    // Injected until the budget is spent rather than a fixed number of times,
    // because an injected failure can legitimately be dropped: `onReadFailed`
    // hops to the main queue and then checks `activePlayback === playback`, so
    // one arriving while a reconnection is swapping the playback out finds a
    // different object and returns. That is correct — a failure belongs to the
    // playback that raised it — but it means "four injections" is not the same
    // thing as "four failures seen", and asserting on the former was a 3-in-4
    // flake here. Each miss cost a full `settle` timeout, which is why a
    // failing run took six seconds and a passing one a tenth.
    //
    // Looping cannot run away: the budget is only refilled by `onReadResumed`,
    // which fires when reads flow again, and the source in this fixture is
    // never asked to fail a read — so once the budget is spent the next
    // failure the engine *does* see is reported. The bound is a safety net for
    // a genuine hang, not a tuning knob.
    for _ in 1...20 {
      if !failures.isEmpty { break }
      engine.failActiveTrackForTesting(ByteSourceError.fetchFailed("stream went away"))
      settle(timeout: 1) { !failures.isEmpty || factory.offsetsAsked.count > lastOpens }
      lastOpens = factory.offsetsAsked.count
    }

    XCTAssertEqual(
      factory.offsetsAsked.count, PlaybackEngine.maxStreamReconnects + 1,
      "one open for the track itself, then the budget, and no more"
    )
    XCTAssertEqual(failures.count, 1, "the track is given up once the budget is spent")
  }

  /**
   A reconnection that cannot be opened is reported rather than swallowed.

   The failure path this replaced at least said something. Retrying into
   silence would be the same defect in a new place — see the recurring shapes
   in `docs/architecture.md` §12.
   */
  func testAFailedReconnectionIsReported() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try playAndSeek(engine, toSeconds: 8)
    factory.refuseFromAttempt = 2

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    engine.failActiveTrackForTesting(ByteSourceError.fetchFailed("stream went away"))
    settle { !failures.isEmpty }

    // Both halves matter. Without the first this passes on the old behaviour,
    // where the failure was reported because nothing was ever tried.
    XCTAssertEqual(factory.offsetsAsked.count, 2, "the reconnection was not attempted")
    XCTAssertEqual(failures.count, 1, "a reconnection that could not open must still be said out loud")
  }

  // MARK: - The URL

  func testTimeOffsetIsAddedAndReplacedRatherThanAppendedTwice() {
    let base = URL(string: "https://example.test/rest/stream.view?id=7&format=mp3")!
    let once = streamURL(base: base, timeOffsetSeconds: 30)
    let twice = streamURL(base: once, timeOffsetSeconds: 45)

    XCTAssertEqual(
      twice.query?.components(separatedBy: "&").filter { $0.hasPrefix("timeOffset=") },
      ["timeOffset=45"],
      "a second reconnection must replace the first offset, not stack another on it"
    )
  }

  func testAZeroOffsetLeavesTheURLAlone() {
    let base = URL(string: "https://example.test/rest/stream.view?id=7")!
    XCTAssertEqual(streamURL(base: base, timeOffsetSeconds: 0), base)
  }
}
