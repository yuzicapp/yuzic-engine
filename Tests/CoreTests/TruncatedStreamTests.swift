import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 A track that "ends" long before it ends.

 This is the last route by which a broken transcode reached the listener as a
 song skipping itself part-way through, and the one that survived every earlier
 fix because it does not look like a failure anywhere along its length.

 A read that returns no frames and no error is, to `TrackPlayback`, the genuine
 end of the file — the only thing it can conclude from there. A transcoded
 stream whose connection dies produces exactly that: `StreamingByteSource` is
 marked finished by its producer, `totalBytes()` drops from the estimate to the
 bytes that arrived, and the next read comes back empty at what is now the end
 of the file by every measure the reader has. So `onEndOfTrack` fires, not
 `onReadFailed`, and the retry ladder, the stall signal and `reconnectStream`
 are all stepped over. The queue advances. Nothing is logged, because from the
 engine's point of view nothing went wrong.

 The length is what catches it, because it is the one fact the broken transport
 cannot forge — it came from the host's metadata, not from the bytes.

 **The ranged transport was excluded from all of this, and that was wrong.**
 The exclusion was argued from the bytes — a `Content-Length` is not a guess,
 so the end of the bytes is the end of the file — and the argument never
 covered a reader that stopped *before* the bytes ran out. `AudioFileReader`
 did precisely that on any container with no packet table, where Core Audio
 extrapolates the frame count from the opening seconds' bitrate and a
 front-loaded VBR file therefore comes back short. So the last place this
 check was not looking was a listener with a perfectly good connection
 hearing a song stop two thirds of the way through.

 The fix for the cause is `AudioFileReader.lengthIsMeasured`; the tests below
 are the net under it. What the old exclusion was protecting — a genuinely
 short file with an optimistic tag, which must still be allowed to finish —
 is kept by asking the reader as a second opinion rather than by declining to
 ask at all.
 */
final class TruncatedStreamTests: XCTestCase {

  // MARK: - Fixtures

  /// A source over an in-memory blob that can be told it is sequential, which
  /// is the property the truncation check reads. Same shape as
  /// `StreamReconnectTests` uses, and for the same reason: the transport's
  /// behaviour is not what is under test here, only what the engine concludes.
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

  private final class RecordingFactory: TrackReaderFactory {
    let data: Data
    let sequential: Bool
    private(set) var offsetsAsked: [Int] = []

    init(data: Data, sequential: Bool) {
      self.data = data
      self.sequential = sequential
    }

    func makeReader(for track: Track) throws -> TrackReader {
      try makeReader(for: track, timeOffsetSeconds: 0)
    }

    func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
      offsetsAsked.append(timeOffsetSeconds)
      return AudioFileReader(source: BlobSource(data, sequential: sequential))
    }
  }

  private func song(_ id: String, durationSec: Double? = 30, continuous: Bool = false) -> Track {
    Track(
      id: id,
      uri: "https://example.test/stream?id=\(id)",
      title: id,
      durationSec: durationSec,
      continuous: continuous
    )
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

  /// Two tracks, playing the first, with the playhead put somewhere specific.
  /// The second exists so "advanced" and "did not advance" are distinguishable
  /// — with a queue of one, both look like the end of the queue.
  private func play(
    _ engine: PlaybackEngine, upTo seconds: Double, first: Track
  ) throws {
    engine.setQueue([first, song("b")], startIndex: 0)
    try engine.play()
    // A seek needs a reader, and the track's opens off the main thread.
    settle { engine.activePlaybackIsWiredForTesting }
    try engine.seek(toSeconds: seconds)
  }

  // MARK: - The check

  /**
   A stream that stops a third of the way in is reopened, not advanced.

   The symptom this exists to remove: a song cutting out around thirty seconds
   and the next one starting, over the network only, with no error toast and
   nothing in any log.
   */
  func testAStreamThatEndsFarShortOfTheTrackIsReconnected() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try play(engine, upTo: 8, first: song("a"))

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    engine.finishActiveTrackForTesting()
    settle { factory.offsetsAsked.count >= 2 }

    XCTAssertEqual(factory.offsetsAsked.last, 8, "reopened from the second reached")
    XCTAssertEqual(engine.queue.activeIndex, 0, "the queue advanced past a track that had not ended")
    XCTAssertEqual(failures, [], "the track was recovered, so nothing was lost")
  }

  /**
   A track that plays to its end still advances.

   The check has to be invisible to every honest ending, which is almost all of
   them. Erring the other way would strand a listener at the end of every song.
   */
  func testATrackThatReachesItsEndAdvancesNormally() throws {
    let (engine, factory) = try makeEngine(sequential: true)
    try play(engine, upTo: 29, first: song("a"))

    engine.finishActiveTrackForTesting()
    settle { engine.queue.activeIndex == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1, "a finished track did not advance the queue")
    XCTAssertEqual(factory.offsetsAsked.last, 0, "the next track was reopened at an offset")
  }

  /**
   Within the tolerance is an ending, not a truncation.

   A host's duration is a rounded tag and a decoder's last frame is where the
   padding ran out; the two disagree by fractions of a second as a matter of
   course. Five seconds is past anything that disagreement can produce.
   */
  func testASmallShortfallIsStillAnEnding() throws {
    let (engine, _) = try makeEngine(sequential: true)
    try play(engine, upTo: 27, first: song("a"))

    engine.finishActiveTrackForTesting()
    settle { engine.queue.activeIndex == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1, "a three-second shortfall was treated as a truncation")
  }

  /**
   A ranged track whose file really is shorter than its tag still advances.

   This used to read "a ranged track's end is believed", full stop, on the
   reasoning that its length is the server's `Content-Length` and its end
   really is the end. The first half of that is true of the *bytes*. It says
   nothing about a reader that stopped before reaching them, which is exactly
   what `AudioFileReader` did whenever the container had no packet table and
   its length was extrapolated from the opening seconds' bitrate — so the one
   transport the check declined to look at was the one where a healthy
   connection still delivered two thirds of a song. See `endedShortOfItsLength`.

   What the old exclusion was protecting is kept, and it is this: a short file
   carrying an optimistic tag has to be able to finish, or a listener is
   stranded at the end of it forever. The reader is what tells the two apart
   now. Thirty seconds of audio behind a tag claiming ninety: the reader says
   the audio ran out where playback stopped, so the tag is the thing that is
   wrong and the track has genuinely ended.
   */
  func testARangedTrackWhoseFileIsAsShortAsItPlayedStillAdvances() throws {
    let (engine, factory) = try makeEngine(sequential: false)
    try play(engine, upTo: 29, first: song("a", durationSec: 90))

    engine.finishActiveTrackForTesting()
    // The queue moves at once and the next track opens off the main thread —
    // or was already opened by the preload — so wait for the handover itself
    // rather than for the index, which is set before any open has run.
    settle { engine.queue.activeIndex == 1 && engine.activePlaybackIsWiredForTesting && engine.state != .buffering }

    XCTAssertEqual(engine.queue.activeIndex, 1, "a ranged track's honest ending was disbelieved")
    // A reconnection is a request for the track from an offset. Counting opens
    // instead depended on whether the preload had landed yet.
    XCTAssertEqual(factory.offsetsAsked.filter { $0 > 0 }, [], "a ranged track was reconnected")
  }

  /**
   A ranged read that stopped short of its *own* file is not an ending.

   The hole the test above used to be. Both lengths disagree with where this
   stopped — the host says thirty seconds and the reader, which parsed the
   container over a source that can be re-read, says thirty as well — and
   playback got eight. Nothing about that is an end of file, whatever came
   back from the read.

   Not recovered, because there is nothing on this transport to recover with:
   `reconnectStream` asks the server for the track again from the second
   reached, which is what a forward-only stream needs and what a ranged one
   already has. So it is reported, which is the whole point — the symptom
   being removed is a song stopping and the next one starting with nothing
   said anywhere.
   */
  func testARangedReadThatStoppedShortOfItsOwnFileIsNotAnEnding() throws {
    let (engine, _) = try makeEngine(sequential: false)
    try play(engine, upTo: 8, first: song("a"))

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    engine.finishActiveTrackForTesting()
    settle { !failures.isEmpty }

    XCTAssertEqual(engine.queue.activeIndex, 0, "a truncated ranged read advanced the queue")
    XCTAssertFalse(failures.isEmpty, "a truncated ranged read said nothing")
  }

  /**
   Live radio has no length to fall short of.

   A broadcast's `durationSec` is whatever the host happened to send, and
   measuring an endless stream against it would reconnect a station forever.
   */
  func testLiveRadioIsNotMeasuredAgainstADuration() throws {
    let (engine, _) = try makeEngine(sequential: true)
    try play(engine, upTo: 8, first: song("a", continuous: true))

    engine.finishActiveTrackForTesting()
    settle { engine.queue.activeIndex == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1, "a continuous stream was treated as truncated")
  }

  /**
   A host that never said how long the track is leaves nothing to check.

   `nil` is not zero and it is not a truncation: it is the absence of the one
   fact this check depends on, so the old behaviour stands.
   */
  func testATrackWithNoDeclaredLengthIsAdvanced() throws {
    let (engine, _) = try makeEngine(sequential: true)
    try play(engine, upTo: 8, first: song("a", durationSec: nil))

    engine.finishActiveTrackForTesting()
    settle { engine.queue.activeIndex == 1 }

    XCTAssertEqual(engine.queue.activeIndex, 1, "a track with no declared length was held back")
  }

  /**
   Out of reconnections, the track is reported — not skipped.

   This is the point of the whole change. A silent advance is what the listener
   experienced as the bug; if the stream genuinely cannot be picked back up,
   the honest outcome is to say so, which is what every other lost-stream path
   in this engine already does.
   */
  func testAnUnrecoverableTruncationIsReportedRatherThanSkipped() throws {
    let (engine, _) = try makeEngine(sequential: true)
    try play(engine, upTo: 8, first: song("a"))

    var failures: [String] = []
    engine.onEvent = { if case .failed(let message) = $0 { failures.append(message) } }

    // Spend the budget, then one more. Each reconnection reopens at the same
    // eight seconds and the reader ends there again, which is the shape of a
    // server that keeps handing back the same truncated encode.
    for _ in 0...PlaybackEngine.maxStreamReconnects {
      engine.finishActiveTrackForTesting()
      settle(timeout: 1) { !failures.isEmpty }
    }

    XCTAssertEqual(engine.queue.activeIndex, 0, "the track was skipped instead of reported")
    XCTAssertFalse(failures.isEmpty, "a track that could not be recovered said nothing")
  }
}
