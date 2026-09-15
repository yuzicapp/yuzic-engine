import XCTest
import AVFoundation
import AudioToolbox
@testable import YuzicEngineCore

/// A connection whose bytes the test hands over, and which ends only when told.
final class ControlledProducer: StreamProducer, @unchecked Sendable {
  private let lock = NSLock()
  private var onData: ((Data) -> Void)?
  private var onFinish: ((Error?) -> Void)?
  private let initial: Data
  private(set) var stopped = false

  init(initial: Data = Data()) { self.initial = initial }

  func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
    lock.lock()
    self.onData = onData
    self.onFinish = onFinish
    lock.unlock()
    let initial = self.initial
    guard !initial.isEmpty else { return }
    // Off the caller's thread, the way URLSession delivers.
    DispatchQueue.global().async { onData(initial) }
  }

  func stop() { lock.lock(); stopped = true; lock.unlock() }

  func send(_ data: Data) {
    lock.lock(); let deliver = onData; lock.unlock()
    deliver?(data)
  }

  func end(_ error: Error?) {
    lock.lock(); let finish = onFinish; lock.unlock()
    finish?(error)
  }
}

/// AAC in ADTS — the framing internet radio sends: self-describing frames one
/// after another, no header at the front and no index at the end.
enum LiveFixture {
  static func adts(seconds: Int) throws -> Data {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-engine-live-tests", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("tone-\(seconds).aac")

    if !FileManager.default.fileExists(atPath: url.path) {
      let sampleRate = 44_100.0
      var writer: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
      ])
      let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate))!
      buffer.frameLength = AVAudioFrameCount(sampleRate)
      var phase = 0.0
      for _ in 0..<seconds {
        for index in 0..<Int(sampleRate) {
          phase += 2.0 * Double.pi * 440.0 / sampleRate
          let sample = Float(0.5 * sin(phase))
          buffer.floatChannelData![0][index] = sample
          buffer.floatChannelData![1][index] = sample
        }
        try writer!.write(from: buffer)
      }
      writer = nil
    }
    return try Data(contentsOf: url)
  }
}

final class LiveStreamReaderTests: XCTestCase {

  private func adts() throws -> Data {
    let data = try LiveFixture.adts(seconds: 4)
    // Precondition, not the subject: the fixture has to be ADTS or every test
    // below is testing something other than a radio stream.
    // The ADTS syncword: twelve set bits, then layer bits of zero.
    XCTAssertEqual(data[data.startIndex], 0xFF, "fixture is not ADTS")
    XCTAssertEqual(data[data.startIndex + 1] & 0xF6, 0xF0, "fixture is not ADTS")
    return data
  }

  private func openInBackground(_ reader: LiveStreamReader) -> (XCTestExpectation, () -> Error?) {
    let opened = expectation(description: "open returns")
    var failure: Error?
    DispatchQueue.global().async {
      do { try reader.open() } catch { failure = error }
      opened.fulfill()
    }
    return (opened, { failure })
  }

  /**
   A station opens as soon as it has described itself.

   The file parser waited for the end of a stream that has none — twice, one
   read timeout each — so a station took 24 seconds to start. Here the timeout
   is set long enough that either wait would fail the test.
   */
  func testOpensWithoutWaitingForAnEndThatNeverComes() throws {
    let data = try adts()
    let producer = ControlledProducer(initial: data.prefix(data.count / 4))
    let reader = LiveStreamReader(readWaitTimeout: 5) { producer }

    let started = Date()
    try reader.open()

    XCTAssertLessThan(Date().timeIntervalSince(started), 2, "open waited on bytes that do not exist")
    XCTAssertEqual(reader.sampleRate, 44_100)
    XCTAssertEqual(reader.totalFrames, 0, "a broadcast has no length")
    XCTAssertTrue(reader.isSequential)
  }

  /**
   Audio that arrives after opening is played.

   The file parser fixed its frame count at open and `read` stopped there, so a
   station ended itself after about as long as it had taken to start.
   */
  func testDecodesAudioThatArrivesAfterItOpened() throws {
    let data = try adts()
    let quarter = data.count / 4
    let producer = ControlledProducer(initial: data.prefix(quarter))
    let reader = LiveStreamReader(readWaitTimeout: 0.5) { producer }
    try reader.open()

    DispatchQueue.global().async {
      var offset = quarter
      while offset < data.count {
        let end = min(offset + 4096, data.count)
        producer.send(data.subdata(in: offset..<end))
        offset = end
        usleep(2_000)
      }
    }

    var decoded = 0
    while true {
      do {
        guard let buffer = try reader.read(frames: 22_050) else { break }
        decoded += Int(buffer.frameLength)
      } catch {
        break   // the stream went quiet once the fixture ran out
      }
    }
    // Four seconds went in; well over the first second has to come out.
    XCTAssertGreaterThan(decoded, 44_100 * 3, "decoding stopped at what had arrived when it opened")
  }

  /// A station that goes quiet fails a read. Returning nil would say the
  /// broadcast ended, and the engine would advance past it.
  func testAStationThatGoesQuietFailsTheReadRatherThanEnding() throws {
    let data = try adts()
    let producer = ControlledProducer(initial: data.prefix(data.count / 8))
    let reader = LiveStreamReader(readWaitTimeout: 0.3) { producer }
    try reader.open()

    var sawEnd = false
    var sawFailure = false
    let deadline = Date().addingTimeInterval(5)
    while !sawEnd && !sawFailure && Date() < deadline {
      do {
        if try reader.read(frames: 22_050) == nil { sawEnd = true }
      } catch LiveStreamReader.LiveStreamError.streamLost {
        sawFailure = true
      }
    }
    XCTAssertFalse(sawEnd, "a silent station was reported as finished")
    XCTAssertTrue(sawFailure)
  }

  /// A dropped connection is opened again, and the audio carries on.
  func testADroppedConnectionIsPickedUpAgain() throws {
    let data = try adts()
    let half = data.count / 2
    var producers: [ControlledProducer] = []
    let lock = NSLock()
    let reader = LiveStreamReader(readWaitTimeout: 1, reconnectDelay: 0.01) {
      lock.lock(); defer { lock.unlock() }
      let producer = ControlledProducer(initial: producers.isEmpty ? data.prefix(half) : data.suffix(from: half))
      producers.append(producer)
      return producer
    }
    try reader.open()

    lock.lock(); let first = producers[0]; lock.unlock()
    first.end(URLError(.networkConnectionLost))

    var decoded = 0
    while true {
      do {
        guard let buffer = try reader.read(frames: 22_050) else { break }
        decoded += Int(buffer.frameLength)
      } catch {
        break
      }
    }
    XCTAssertEqual(reader.connectionsMadeForTesting, 2, "the station should have been reconnected once")
    XCTAssertGreaterThan(decoded, 44_100 * 3, "audio should carry on from the second connection")
  }

  /// And a station that cannot be reached again is reported, not retried forever.
  func testReconnectionGivesUp() throws {
    let data = try adts()
    let reader = LiveStreamReader(readWaitTimeout: 1, reconnectDelay: 0.01, maxReconnects: 2) {
      let producer = ControlledProducer()
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { producer.end(URLError(.cannotConnectToHost)) }
      return producer
    }
    XCTAssertThrowsError(try reader.open())
    XCTAssertLessThanOrEqual(reader.connectionsMadeForTesting, 3, "one connection and two retries")
    _ = data
  }

  /// A paused station lets go of the connection rather than buffering a
  /// broadcast nobody is hearing, and the next read picks it up again.
  func testUnreadBytesDropTheConnectionAndReadingReopensIt() throws {
    let data = try adts()
    // Sized from the fixture rather than fixed: an encoded tone is far smaller
    // than its nominal bitrate, and a fixed range ran off its end.
    let head = data.count / 4
    var producers: [ControlledProducer] = []
    let lock = NSLock()
    let reader = LiveStreamReader(readWaitTimeout: 1, maxBufferedBytes: data.count / 4) {
      lock.lock(); defer { lock.unlock() }
      let producer = ControlledProducer(initial: data.prefix(head))
      producers.append(producer)
      return producer
    }
    try reader.open()

    lock.lock(); let first = producers[0]; lock.unlock()
    // Nobody reads while this arrives: well over the cap.
    first.send(data.suffix(from: head))
    XCTAssertTrue(first.stopped, "the connection should be dropped once unread bytes pass the cap")

    XCTAssertNotNil(try reader.read(frames: 4_096), "reading again should reconnect")
    XCTAssertEqual(reader.connectionsMadeForTesting, 2)
  }

  /// Ogg is left to the decoders that read it.
  func testOggIsHandedBack() {
    var ogg = Data([0x4F, 0x67, 0x67, 0x53])
    ogg.append(Data(count: 256))
    let reader = LiveStreamReader(readWaitTimeout: 1) { ControlledProducer(initial: ogg) }
    XCTAssertThrowsError(try reader.open()) { error in
      guard case LiveStreamReader.LiveStreamError.notParseable = error else {
        return XCTFail("expected notParseable, got \(error)")
      }
    }
  }

  /// A read parked waiting for the station comes back when cancelled, so a
  /// stop does not wait out the read timeout.
  func testCancellingUnblocksAWaitingRead() throws {
    let data = try adts()
    let producer = ControlledProducer(initial: data.prefix(data.count / 8))
    let reader = LiveStreamReader(readWaitTimeout: 10) { producer }
    try reader.open()

    let returned = expectation(description: "read returns")
    DispatchQueue.global().async {
      while (try? reader.read(frames: 22_050)) != nil {}
      returned.fulfill()
    }
    Thread.sleep(forTimeInterval: 0.3)
    reader.cancelPendingReads()
    wait(for: [returned], timeout: 2)
  }

  /// End to end through `TrackPlayback`: a station reaches the output.
  func testAStationIsAudible() throws {
    let data = try adts()
    let producer = ControlledProducer(initial: data)
    let reader = LiveStreamReader(readWaitTimeout: 2) { producer }
    try reader.open()

    let graph = AudioGraph(sampleRate: reader.sampleRate)
    try graph.startOffline(sampleRate: reader.sampleRate)
    let playback = TrackPlayback(reader: reader, voice: graph.activeVoice)
    try playback.start()

    let deadline = Date().addingTimeInterval(2)
    while graph.activeVoice.player.isPlaying == false && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
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
    XCTAssertGreaterThan(rms, 0.05, "decoded radio did not reach the output")
    playback.stop()
  }
}
