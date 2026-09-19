import XCTest
import AVFoundation
@testable import YuzicEngineCore

/**
 The end-to-end claim: real encoded audio, delivered a window at a time through
 the cache, decodes into PCM.

 Fixtures are generated rather than committed — a few seconds of broadband
 audio, because silence compresses to nearly nothing and would let a decoder
 skip work a real track makes it do.
 */
final class AudioFileReaderTests: XCTestCase {

  private static var fixtures: [String: Data] = [:]

  /// Encode once for the whole suite; each test gets its own source over the
  /// same bytes.
  private func fixture(format: AudioFormatID, ext: String) throws -> Data {
    let key = ext
    if let cached = Self.fixtures[key] { return cached }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("fixture.\(ext)")
    try? FileManager.default.removeItem(at: url)

    let sampleRate = 44_100.0
    var settings: [String: Any] = [
      AVFormatIDKey: format,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: 2,
    ]
    if format == kAudioFormatLinearPCM {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVLinearPCMIsFloatKey] = false
      settings[AVLinearPCMIsBigEndianKey] = false
    } else {
      settings[AVLinearPCMBitDepthKey] = 16
      settings[AVEncoderBitDepthHintKey] = 16
    }

    var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings)
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
    let seconds = 8
    let chunk = AVAudioFrameCount(sampleRate)
    let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: chunk)!
    buffer.frameLength = chunk
    var phase = 0.0
    for _ in 0..<seconds {
      let left = buffer.floatChannelData![0]
      let right = buffer.floatChannelData![1]
      for index in 0..<Int(chunk) {
        phase += 2.0 * Double.pi * 440.0 / sampleRate
        let sample = Float(0.3 * sin(phase) + Double.random(in: -0.1...0.1))
        left[index] = sample
        right[index] = sample
      }
      try writer!.write(from: buffer)
    }
    // The header is finalised on deallocation. Without this the file reads as
    // empty despite being the right size on disk.
    writer = nil

    let data = try Data(contentsOf: url)
    Self.fixtures[key] = data
    return data
  }

  /// Serves a fixture, so a "download" is deterministic.
  private final class BlobFetcher: ByteFetcher, @unchecked Sendable {
    let blob: Data
    private(set) var requests: [Range<Int64>] = []
    init(_ blob: Data) { self.blob = blob }
    func contentLength() throws -> Int64 { Int64(blob.count) }
    func fetch(_ range: Range<Int64>) throws -> Data {
      requests.append(range)
      let end = min(Int(range.upperBound), blob.count)
      guard Int(range.lowerBound) < end else { return Data() }
      return blob.subdata(in: Int(range.lowerBound)..<end)
    }
  }

  private func read(_ data: Data, window: Int64 = 32 * 1024, prefetchTail: Bool = false)
    throws -> (reader: AudioFileReader, fetcher: BlobFetcher) {
    let fetcher = BlobFetcher(data)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: window)
    if prefetchTail { try source.prefetchTail() }
    let reader = AudioFileReader(source: source)
    try reader.open()
    return (reader, fetcher)
  }

  // MARK: - WAV

  func testDecodesWavThroughTheCache() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    XCTAssertEqual(reader.sampleRate, 44_100)
    XCTAssertEqual(reader.totalFrames, 8 * 44_100, accuracy: 4096)

    let buffer = try XCTUnwrap(try reader.read(frames: 4096))
    XCTAssertEqual(buffer.frameLength, 4096)
    XCTAssertEqual(buffer.format.channelCount, 2)
  }

  // MARK: - Buffered-ahead estimate

  /**
   What the buffering indicator is drawn from.

   Only ever used for display — never for scheduling, the crossfade trigger or
   end-of-track — which is what licenses the crude frames-to-bytes assumption
   underneath. These tests pin the properties a bar actually needs: that it
   reports something when bytes are present, nothing when they are not, and
   never more than exists.
   */
  func testReportsSomethingBufferedOnceBytesAreFetched() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, _) = try read(data, window: 64 * 1024)
    _ = try reader.read(frames: 4096)

    // The failure this replaces was reporting zero forever, which makes a
    // buffering bar indistinguishable from a stalled one.
    XCTAssertGreaterThan(reader.bufferedFramesAhead(ofFrame: 0), 0)
  }

  func testNeverClaimsMoreThanTheFileHolds() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, _) = try read(data, window: 64 * 1024)
    _ = try reader.read(frames: 4096)

    XCTAssertLessThanOrEqual(reader.bufferedFramesAhead(ofFrame: 0), reader.totalFrames)
  }

  func testReportsNothingBufferedBeyondTheEnd() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, _) = try read(data, window: 64 * 1024)
    _ = try reader.read(frames: 4096)

    XCTAssertEqual(reader.bufferedFramesAhead(ofFrame: reader.totalFrames), 0)
  }

  func testReportsNothingBufferedFarAheadOfWhatWasFetched() throws {
    // A small window means a seek to the far end has nothing waiting, and the
    // bar should say so rather than inheriting the figure from the head.
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, _) = try read(data, window: 16 * 1024)
    _ = try reader.read(frames: 4096)

    let nearTheEnd = Int64(Double(reader.totalFrames) * 0.9)
    XCTAssertEqual(reader.bufferedFramesAhead(ofFrame: nearTheEnd), 0)
  }

  func testReportsFullDurationWithAlmostNothingFetched() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, fetcher) = try read(data, window: 16 * 1024)

    // This is the property AVAudioFile does not have: its length is computed
    // once at open, so a partial file reports a partial duration. Here the
    // parser is told the true size and answers correctly having seen a
    // fraction of the bytes.
    XCTAssertEqual(reader.totalFrames, 8 * 44_100, accuracy: 4096)
    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    XCTAssertLessThan(fetched, Int64(data.count) / 2)
  }

  func testSeekingNearTheEndDoesNotPullTheWholeFile() throws {
    let data = try fixture(format: kAudioFormatLinearPCM, ext: "wav")
    let (reader, fetcher) = try read(data, window: 32 * 1024)

    try reader.seek(toFrame: Int64(Double(reader.totalFrames) * 0.9))
    _ = try reader.read(frames: 4096)

    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    // Uncompressed audio seeks by arithmetic, so this should be a couple of
    // windows, nowhere near the 90% of the file being skipped over.
    XCTAssertLessThan(fetched, Int64(data.count) / 2)
  }

  // MARK: - FLAC

  func testDecodesFlacThroughTheCache() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatFLAC, ext: "flac"))
    XCTAssertEqual(reader.sampleRate, 44_100)

    let buffer = try XCTUnwrap(try reader.read(frames: 4096))
    XCTAssertGreaterThan(buffer.frameLength, 0)
  }

  /**
   The measured defect, as a test rather than a note.

   Apple's FLAC decoder ignores the SEEKTABLE and decodes from byte zero, so
   seeking to the end pulls the whole file through the cache. This asserts the
   behaviour we actually get today, so that if a future iOS fixes it — or if
   libFLAC is wired in, which is the plan — this test fails and tells us the
   world changed rather than silently passing.
   */
  func testFlacSeekPullsFarMoreThanItShould() throws {
    let data = try fixture(format: kAudioFormatFLAC, ext: "flac")
    let (reader, fetcher) = try read(data, window: 32 * 1024)

    try reader.seek(toFrame: Int64(Double(reader.totalFrames) * 0.9))
    _ = try reader.read(frames: 4096)

    let fetched = fetcher.requests.reduce(Int64(0)) { $0 + ($1.upperBound - $1.lowerBound) }
    print("FLAC 90% seek: fetched \(fetched) of \(data.count) bytes "
          + "(\(Int(Double(fetched) / Double(data.count) * 100))%)")
    XCTAssertGreaterThan(
      fetched, Int64(Double(data.count) * 0.5),
      "FLAC seek fetched \(fetched) of \(data.count) bytes. If this dropped, Core Audio "
      + "started honouring the SEEKTABLE, or libFLAC is in the path — either way the "
      + "architecture note in docs/architecture.md §9 needs revisiting.")
  }

  // MARK: - ALAC, the opposite failure

  func testAlacNeedsItsTailBeforeItWillOpen() throws {
    let data = try fixture(format: kAudioFormatAppleLossless, ext: "m4a")

    // moov sits at the end of a file AVAudioFile wrote, so a reader that has
    // only the head cannot open it. Confirmed in the spike; asserted here so
    // the tail-prefetch cannot be quietly removed.
    let fetcher = BlobFetcher(data.prefix(data.count / 4))
    let truncated = CachedByteSource(fetcher: fetcher, windowBytes: 32 * 1024)
    let blind = AudioFileReader(source: truncated)
    XCTAssertThrowsError(try blind.open())

    // With the tail fetched first it opens.
    let (reader, _) = try read(data, window: 32 * 1024, prefetchTail: true)
    XCTAssertGreaterThan(reader.totalFrames, 0)
    XCTAssertNotNil(try reader.read(frames: 4096))
  }

  func testReadReturnsNilAtEndOfStream() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    try reader.seek(toFrame: reader.totalFrames)
    XCTAssertNil(try reader.read(frames: 4096))
  }

  // MARK: - A counted length and a guessed one are not the same number

  /**
   What the reported truncation actually was.

   `kExtAudioFileProperty_FileLengthFrames` answers two different questions
   with one number. Where the container carries a packet table — the MP4
   family, an MP3 with a Xing/LAME header — every packet's frames have been
   accounted for and the answer is a count. Where it does not, Core Audio
   extrapolates from the leading frames' bitrate, and a VBR file that opens
   louder than it averages comes back **short**. `read` stopped there anyway,
   returned nil, and `TrackPlayback` had no way to read that as anything but
   the file running out: the queue advanced and the listener heard a song skip
   itself part-way through, over a connection with nothing wrong with it.

   So the reader now separates the two, and these pin the separation. What
   they cannot do is reproduce the shortfall: the format it was reported in is
   MP3, Core Audio decodes MP3 and will not encode it, and there is no way to
   build the fixture in process — the standing gap CONTRIBUTING names and
   `docs/architecture.md` §12 records. Anyone who finds a way to get a small
   VBR MP3 without a Xing header into the suite should drain it here and
   assert it reaches its real end.

   In the meantime what is checkable is the rule rather than the instance:
   this container declares no packet table, so its length is not to be treated
   as a boundary, and `GaplessTrimmingTests` asserts the other half — that a
   container which does declare one still stops where the music does.
   */
  func testAContainerWithNoPacketTableDoesNotClaimAMeasuredLength() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    XCTAssertFalse(reader.lengthIsMeasured,
                   "a length with no packet table behind it was treated as a counted one")
  }

  /**
   Lifting the clamp does not make a file run on past its end.

   The obvious worry about deciding the end from the bytes rather than from a
   declared length: a reader that no longer stops at a number has to stop
   somewhere, and a decoder that keeps being asked after the audio is gone
   would either spin or hand back silence. It does neither — `readProc`
   already distinguishes an empty read at a length the source genuinely knows
   from one before it, which is the decision this change hands the question
   back to.

   Uncompressed, so the two answers coincide exactly and any drift shows.
   */
  func testAnUnmeasuredFileStillEndsWhereItsBytesDo() throws {
    let (reader, _) = try read(try fixture(format: kAudioFormatLinearPCM, ext: "wav"))
    let lengthAtOpen = reader.totalFrames

    var total: Int64 = 0
    var reads = 0
    while let buffer = try reader.read(frames: 4096) {
      total += Int64(buffer.frameLength)
      reads += 1
      if reads > 4_000 { break }
    }

    XCTAssertEqual(total, Int(lengthAtOpen), accuracy: 4096)
    XCTAssertLessThanOrEqual(reads, 4_000, "the reader did not stop when the audio did")
    // And the length is still the length: the upward correction only fires
    // where the decoder actually proves a file longer than it claimed, which
    // for PCM it never can.
    XCTAssertEqual(reader.totalFrames, lengthAtOpen)
  }
}

private func XCTAssertEqual(
  _ lhs: Int64, _ rhs: Int, accuracy: Int64, file: StaticString = #filePath, line: UInt = #line
) {
  XCTAssertLessThanOrEqual(abs(lhs - Int64(rhs)), accuracy, file: file, line: line)
}
