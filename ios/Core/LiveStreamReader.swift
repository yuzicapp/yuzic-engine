import Foundation
import AVFoundation
import AudioToolbox

/**
 Decodes a live stream — internet radio — as it arrives.

 Every other reader here sits on `AudioFileOpenWithCallbacks`, which is a
 *file* parser: it is told a size and reads wherever it likes inside it. A
 broadcast has no size, and that parser's habits are each fatal to one.
 Measured against a real station's MP3 over `StreamingByteSource`:

 - It reads the last 128 bytes of whatever size it is told, looking for an ID3v1
   tag. The size was a 64MB guess, so that read waited out the whole
   `readWaitTimeoutSec` for bytes that were never going to exist.
 - It then scans packets to the end of what has arrived and waits for more,
   another full timeout. Opening a station took two timeouts — 24 seconds.
 - The frame count it settles on is whatever had arrived by then, and
   `AudioFileReader.read` stops there. The station "ended" after about as long
   as it had taken to open, and the queue moved on.
 - `StreamingByteSource` keeps every byte so a transcode can be seeked
   backwards. A broadcast is never seeked, and at 128 kbps that is 58MB an hour
   held for the length of the listen.

 `AudioFileStream` is Core Audio's parser for exactly this case: it is handed
 bytes in order, reports the format once it has seen enough, and yields
 packets as they complete, with no size and no seeking. `AudioConverter` turns
 those packets into PCM. Bytes are dropped once parsed.

 **What it covers.** Whatever `AudioFileStream` parses — MP3 and AAC in ADTS,
 which is what nearly every Icecast and Shoutcast station sends. Ogg is not
 among them; `open` throws `notParseable` for it, and the factory falls back to
 the file path and its Vorbis and Opus decoders. Playlists (`.m3u`, `.pls`) and
 HLS are not audio streams and are not handled here.

 **Pausing does not buffer a broadcast.** Bytes that go unread past
 `maxBufferedBytes` stop the connection, and the next read opens a new one — so
 resuming a station picks up where it is now rather than playing a minute that
 went out while nobody was listening, and a paused station costs no bandwidth.

 **A dropped connection is picked up.** The engine's `reconnectStream` skips
 continuous tracks, because asking for a `timeOffset` into a broadcast means
 nothing; for a station, the same URL again *is* the recovery. So this reader
 reconnects itself, up to `maxReconnects` times per outage.
 */
public final class LiveStreamReader: TrackReader {

  public enum LiveStreamError: Error, Equatable {
    /// A container `AudioFileStream` has no parser for. The factory falls back.
    case notParseable(OSStatus)
    /// Bytes arrived, but not ones that describe any audio.
    case noFormat
    case converterFailed(OSStatus)
    case decodeFailed(OSStatus)
    /// No audio for longer than the read timeout, or a connection that could
    /// not be picked up again. A failure rather than an end: returning nil
    /// would tell the engine the station finished, and it would advance.
    case streamLost(String)
  }

  /// How long a read may wait for bytes. Same budget, and same reasoning, as
  /// `StreamingByteSource.readWaitTimeoutSec`.
  public static let readWaitTimeoutSec: TimeInterval = StreamingByteSource.readWaitTimeoutSec

  /// Unread bytes held before the connection is dropped — about a minute at
  /// 128 kbps, which is far more than playback ever lags a healthy stream by.
  public static let defaultMaxBufferedBytes = 1 << 20

  public static let defaultMaxReconnects = 3

  /// Bytes a stream may send without describing an audio format before open
  /// gives up. An HTML error page is a few kilobytes; audio describes itself in
  /// its first frame.
  static let maxBytesToFindFormat = 256 * 1024

  /// Returned by the converter's input callback when it has no packet to hand
  /// over. Not an error: the converter keeps its state and the read parses more.
  private static let outOfPackets: OSStatus = 0x6E6F_706B  // 'nopk'

  private let makeProducer: () -> StreamProducer
  private let hint: AudioFileTypeID
  private let readWaitTimeout: TimeInterval
  private let reconnectDelay: TimeInterval
  private let maxReconnects: Int
  private let maxBufferedBytes: Int

  // Shared with the producer's callback thread, under `condition`.
  private let condition = NSCondition()
  private var pending = Data()
  private var discontinuity = false
  private var producer: StreamProducer?
  private var generation = 0
  private var reconnects = 0
  private var bytesSinceConnect = 0
  private var failure: String?
  private var cancelled = false
  private var closed = false
  /// The connection was dropped for being unread; the next read opens one.
  private var idle = false

  // The reading thread's alone. `AudioFileStream` calls back synchronously
  // from inside `AudioFileStreamParseBytes`, on the thread that called it.
  private var stream: AudioFileStreamID?
  private var converter: AudioConverterRef?
  private var sourceFormat = AudioStreamBasicDescription()
  private var formatKnown = false
  private var formatFromList = false
  private var readyToProducePackets = false
  private var packets: [Packet] = []
  private var opened = false

  private struct Packet {
    let data: Data
    let variableFrames: UInt32
  }

  /// The converter's input has to outlive the callback that hands it over.
  private var inputBytes: UnsafeMutableRawPointer?
  private var inputCapacity = 0
  private let inputDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)

  public private(set) var sampleRate: Double = 0
  /// Zero: a broadcast has no length, and the engine draws no progress for one.
  public var totalFrames: Int64 { 0 }
  public var isSequential: Bool { true }
  public private(set) var outputFormat: AVAudioFormat?

  /// Connections made so far, for tests of the reconnection.
  var connectionsMadeForTesting: Int {
    condition.lock(); defer { condition.unlock() }
    return generation
  }

  public init(
    hint: AudioFileTypeID = 0,
    readWaitTimeout: TimeInterval = LiveStreamReader.readWaitTimeoutSec,
    reconnectDelay: TimeInterval = 1,
    maxReconnects: Int = LiveStreamReader.defaultMaxReconnects,
    maxBufferedBytes: Int = LiveStreamReader.defaultMaxBufferedBytes,
    makeProducer: @escaping () -> StreamProducer
  ) {
    self.hint = hint
    self.readWaitTimeout = readWaitTimeout
    self.reconnectDelay = reconnectDelay
    self.maxReconnects = maxReconnects
    self.maxBufferedBytes = maxBufferedBytes
    self.makeProducer = makeProducer
  }

  deinit {
    condition.lock()
    closed = true
    let producer = self.producer
    self.producer = nil
    condition.unlock()
    producer?.stop()
    if let converter { AudioConverterDispose(converter) }
    if let stream { AudioFileStreamClose(stream) }
    free(inputBytes)
    inputDescription.deallocate()
  }

  // MARK: - TrackReader

  /// Idempotent, as `TrackReader` requires: the factory opens a reader and the
  /// engine opens it again.
  public func open() throws {
    if opened { return }

    if stream == nil {
      var id: AudioFileStreamID?
      let context = Unmanaged.passUnretained(self).toOpaque()
      let status = AudioFileStreamOpen(context, Self.propertyListener, Self.packetsProc, hint, &id)
      guard status == noErr, let id else { throw LiveStreamError.notParseable(status) }
      stream = id
      startProducer()
    }

    // Ogg is sniffed before the parser sees it: `AudioFileStream` has no Ogg
    // parser, and handing it one fails in a way that looks like a bad stream
    // rather than an unsupported one.
    if try waitForHead(count: 4).starts(with: [0x4F, 0x67, 0x67, 0x53]) {  // "OggS"
      throw LiveStreamError.notParseable(kAudioFileStreamError_UnsupportedFileType)
    }

    var parsed = 0
    while !(formatKnown && readyToProducePackets) {
      guard parsed < Self.maxBytesToFindFormat else { throw LiveStreamError.noFormat }
      guard let chunk = try nextChunk() else { throw ByteSourceError.cancelled }
      parsed += chunk.data.count
      let status = parse(chunk)
      guard status == noErr else { throw LiveStreamError.notParseable(status) }
    }

    try makeConverter()
    opened = true
  }

  /// A broadcast is always read from where it is now. The engine seeks a
  /// reader when it rebuilds after a route change; there is nowhere else to go.
  public func seek(toFrame frame: Int64) throws {}

  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    try open()
    guard let converter, let outputFormat,
          let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else {
      return nil
    }

    let channels = Int(outputFormat.channelCount)
    let list = AudioBufferList.allocate(maximumBuffers: channels)
    defer { free(list.unsafeMutablePointer) }
    let context = Unmanaged.passUnretained(self).toOpaque()
    var produced: AVAudioFrameCount = 0

    while produced < frames {
      if packets.isEmpty {
        // Cancelled: unwind with what has been decoded, the way a seek
        // abandons a read on the other readers.
        guard let chunk = try nextChunk() else { break }
        // A chunk the parser rejects mid-broadcast is skipped rather than
        // raised. Frames resynchronise on the next header, and failing the
        // read would stop a station over one bad packet.
        _ = parse(chunk)
        continue
      }

      let remaining = frames - produced
      for channel in 0..<channels {
        list[channel] = AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: remaining * 4,
          mData: UnsafeMutableRawPointer(buffer.floatChannelData![channel].advanced(by: Int(produced)))
        )
      }
      var ioFrames = remaining
      let status = AudioConverterFillComplexBuffer(
        converter, Self.converterInput, context, &ioFrames, list.unsafeMutablePointer, nil
      )
      produced += ioFrames
      if status != noErr && status != Self.outOfPackets {
        throw LiveStreamError.decodeFailed(status)
      }
    }

    guard produced > 0 else { return nil }
    buffer.frameLength = produced
    return buffer
  }

  /// No buffering figure for a broadcast: nothing draws one, and nothing
  /// downstream of it — the preload — has a next track to fetch.
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 { 0 }

  public func cancelPendingReads() {
    condition.lock()
    cancelled = true
    condition.broadcast()
    condition.unlock()
  }

  public func resumePendingReads() {
    condition.lock()
    cancelled = false
    condition.unlock()
  }

  // MARK: - The connection

  private func startProducer() {
    condition.lock()
    generation += 1
    let current = generation
    bytesSinceConnect = 0
    let producer = makeProducer()
    self.producer = producer
    condition.unlock()

    producer.begin(
      onData: { [weak self] chunk in self?.received(chunk, generation: current) },
      onFinish: { [weak self] error in self?.connectionEnded(error, generation: current) }
    )
  }

  private func received(_ chunk: Data, generation current: Int) {
    condition.lock()
    guard current == generation, !closed else { condition.unlock(); return }
    pending.append(chunk)
    bytesSinceConnect += chunk.count
    // A connection that has delivered real audio has recovered, so the next
    // outage gets a full budget. Not on the first byte: an error page is bytes.
    if bytesSinceConnect >= 64 * 1024 { reconnects = 0 }

    var dropped: StreamProducer?
    if pending.count > maxBufferedBytes {
      // Nobody is reading — the station is paused. Let go rather than hold a
      // broadcast nobody is hearing; see the type's documentation.
      dropped = producer
      producer = nil
      generation += 1
      pending.removeAll()
      discontinuity = true
      idle = true
    }
    condition.broadcast()
    condition.unlock()
    dropped?.stop()
  }

  private func connectionEnded(_ error: Error?, generation current: Int) {
    condition.lock()
    guard current == generation, !closed, !idle else { condition.unlock(); return }
    let reason = error.map { String(describing: $0) } ?? "the station closed the stream"
    guard reconnects < maxReconnects else {
      failure = reason
      condition.broadcast()
      condition.unlock()
      return
    }
    reconnects += 1
    let delay = reconnectDelay * Double(reconnects)
    condition.unlock()

    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.condition.lock()
      let stillCurrent = current == self.generation && !self.closed
      if stillCurrent { self.discontinuity = true }
      self.condition.unlock()
      if stillCurrent { self.startProducer() }
    }
  }

  /// The first `count` bytes, without consuming them.
  private func waitForHead(count: Int) throws -> [UInt8] {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(readWaitTimeout)
    while pending.count < count && !cancelled && failure == nil {
      if !condition.wait(until: deadline) { break }
    }
    if cancelled { throw ByteSourceError.cancelled }
    if pending.isEmpty {
      throw LiveStreamError.streamLost(failure ?? "no audio arrived within \(readWaitTimeout)s")
    }
    return [UInt8](pending.prefix(count))
  }

  private struct Chunk {
    let data: Data
    let discontinuous: Bool
  }

  /// The next bytes to parse, waiting for them. Nil when cancelled.
  private func nextChunk() throws -> Chunk? {
    var reopen = false
    condition.lock()
    if idle && pending.isEmpty {
      idle = false
      reopen = true
    }
    condition.unlock()
    if reopen { startProducer() }

    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(readWaitTimeout)
    while pending.isEmpty && !cancelled && failure == nil {
      if !condition.wait(until: deadline) {
        throw LiveStreamError.streamLost("no audio arrived within \(readWaitTimeout)s")
      }
    }
    if cancelled { return nil }
    if pending.isEmpty, let failure { throw LiveStreamError.streamLost(failure) }

    let count = min(pending.count, 16 * 1024)
    let data = Data(pending.prefix(count))
    pending.removeFirst(count)
    let discontinuous = discontinuity
    discontinuity = false
    return Chunk(data: data, discontinuous: discontinuous)
  }

  // MARK: - Parsing and decoding

  private func parse(_ chunk: Chunk) -> OSStatus {
    guard let stream else { return kAudioFileStreamError_NotOptimized }
    let flags: AudioFileStreamParseFlags = chunk.discontinuous ? .discontinuity : []
    return chunk.data.withUnsafeBytes { raw in
      AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, flags)
    }
  }

  private func makeConverter() throws {
    guard let stream else { throw LiveStreamError.noFormat }
    var source = sourceFormat
    var output = AudioStreamBasicDescription(
      mSampleRate: source.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    var made: AudioConverterRef?
    let status = AudioConverterNew(&source, &output, &made)
    guard status == noErr, let made else { throw LiveStreamError.converterFailed(status) }
    converter = made

    var cookieSize: UInt32 = 0
    if AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, nil) == noErr,
       cookieSize > 0 {
      var cookie = [UInt8](repeating: 0, count: Int(cookieSize))
      if AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookie) == noErr {
        AudioConverterSetProperty(made, kAudioConverterDecompressionMagicCookie, cookieSize, cookie)
      }
    }

    // Everything downstream is stereo. A mono station goes to both sides
    // rather than to the left alone, which is what an unmapped converter does.
    if source.mChannelsPerFrame == 1 {
      var map: [Int32] = [0, 0]
      AudioConverterSetProperty(
        made, kAudioConverterChannelMap, UInt32(2 * MemoryLayout<Int32>.size), &map
      )
    }

    sampleRate = source.mSampleRate
    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: source.mSampleRate, channels: 2, interleaved: false
    )
  }

  private static func canDecode(_ formatID: AudioFormatID) -> Bool {
    var size: UInt32 = 0
    guard AudioFormatGetPropertyInfo(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size) == noErr else {
      return false
    }
    var ids = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
    guard AudioFormatGetProperty(kAudioFormatProperty_DecodeFormatIDs, 0, nil, &size, &ids) == noErr else {
      return false
    }
    return ids.contains(formatID)
  }

  private static let propertyListener: AudioFileStream_PropertyListenerProc = { client, streamID, propertyID, _ in
    let reader = Unmanaged<LiveStreamReader>.fromOpaque(client).takeUnretainedValue()
    switch propertyID {
    case kAudioFileStreamProperty_DataFormat:
      // The list below, when a stream has one, is more complete: HE-AAC reports
      // its AAC core here and the full format there.
      guard !reader.formatFromList else { return }
      var format = AudioStreamBasicDescription()
      var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
      if AudioFileStreamGetProperty(streamID, propertyID, &size, &format) == noErr {
        reader.sourceFormat = format
        reader.formatKnown = true
      }
    case kAudioFileStreamProperty_FormatList:
      var size: UInt32 = 0
      guard AudioFileStreamGetPropertyInfo(streamID, propertyID, &size, nil) == noErr, size > 0 else { return }
      let count = Int(size) / MemoryLayout<AudioFormatListItem>.size
      var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
      guard AudioFileStreamGetProperty(streamID, propertyID, &size, &items) == noErr else { return }
      // Most complete first; take the first this system can decode.
      if let usable = items.first(where: { canDecode($0.mASBD.mFormatID) }) {
        reader.sourceFormat = usable.mASBD
        reader.formatKnown = true
        reader.formatFromList = true
      }
    case kAudioFileStreamProperty_ReadyToProducePackets:
      reader.readyToProducePackets = true
    default:
      break
    }
  }

  private static let packetsProc: AudioFileStream_PacketsProc = { client, byteCount, packetCount, input, descriptions in
    let reader = Unmanaged<LiveStreamReader>.fromOpaque(client).takeUnretainedValue()
    if let descriptions {
      for index in 0..<Int(packetCount) {
        let description = descriptions[index]
        let data = Data(
          bytes: input.advanced(by: Int(description.mStartOffset)),
          count: Int(description.mDataByteSize)
        )
        reader.packets.append(Packet(data: data, variableFrames: description.mVariableFramesInPacket))
      }
    } else {
      // Constant-size packets carry no descriptions.
      let size = Int(reader.sourceFormat.mBytesPerPacket)
      guard size > 0 else {
        reader.packets.append(Packet(data: Data(bytes: input, count: Int(byteCount)), variableFrames: 0))
        return
      }
      var offset = 0
      while offset + size <= Int(byteCount) {
        reader.packets.append(Packet(data: Data(bytes: input.advanced(by: offset), count: size), variableFrames: 0))
        offset += size
      }
    }
  }

  private static let converterInput: AudioConverterComplexInputDataProc = { _, ioPacketCount, ioData, outDescriptions, client in
    let reader = Unmanaged<LiveStreamReader>.fromOpaque(client!).takeUnretainedValue()
    guard !reader.packets.isEmpty else {
      ioPacketCount.pointee = 0
      return LiveStreamReader.outOfPackets
    }
    let packet = reader.packets.removeFirst()
    let count = packet.data.count
    if reader.inputCapacity < count {
      reader.inputBytes = realloc(reader.inputBytes, count)
      reader.inputCapacity = count
    }
    packet.data.copyBytes(to: reader.inputBytes!.assumingMemoryBound(to: UInt8.self), count: count)

    ioData.pointee.mNumberBuffers = 1
    ioData.pointee.mBuffers.mData = reader.inputBytes
    ioData.pointee.mBuffers.mDataByteSize = UInt32(count)
    ioData.pointee.mBuffers.mNumberChannels = reader.sourceFormat.mChannelsPerFrame
    if let outDescriptions {
      reader.inputDescription.pointee = AudioStreamPacketDescription(
        mStartOffset: 0, mVariableFramesInPacket: packet.variableFrames, mDataByteSize: UInt32(count)
      )
      outDescriptions.pointee = reader.inputDescription
    }
    ioPacketCount.pointee = 1
    return noErr
  }
}
