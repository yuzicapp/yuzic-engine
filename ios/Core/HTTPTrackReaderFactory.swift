import Foundation
import AudioToolbox

/**
 Turns a `Track` into something decodable, picking the transport.

 This is the one place that knows there are two, and the choice is not a
 setting — it is discovered. A direct stream answers a ranged request with 206
 and a length, and gets the random-access cache. A transcoding endpoint answers
 200, `accept-ranges: none`, and often no length at all, and gets the
 sequential one. Measured against a real Navidrome; see docs/architecture.md §10.

 The app does not choose deliberately either: yuzic sends `format`/`maxBitRate`
 for every quality except Original, and that setting is per-network. So the same
 track is randomly accessible on WiFi at Original and forward-only on cellular
 at 192kbps, and nothing above here should have to care.
 */
public final class HTTPTrackReaderFactory: TrackReaderFactory {

  /**
   Bits per second assumed when a streaming server will not say how long its
   output is. Only used to answer `GetSizeProc` before the stream ends.

   Erring high is deliberate: reading past the real end reads as end-of-file,
   while under-reporting truncates the track. **320 kbps did not err high.** It
   is a ceiling for transcoded output and roughly a third of what a lossless
   original actually costs — a CD-rate FLAC runs about 1100 kbps — so a
   lossless track taken down this path was told it was three and a half times
   smaller than it is. Measured on a real library: a 3:21 FLAC at 1105 kbps was
   reported as 8 MB, which the parser read as a 58-second track, cutting it
   short and starting a twelve-second crossfade at 46 seconds.

   Set above *uncompressed* hi-res so the same mistake cannot be made by a
   format rather than a bitrate. The ceiling that matters is 24-bit/192kHz
   stereo at 9.22 Mbps uncompressed — a FLAC of it runs about 5.5 — and this
   sits comfortably past it. Anything below is covered by a wide margin:

       16/44.1 stereo   1.41 Mbps uncompressed
       24/96  stereo    4.61
       24/192 stereo    9.22

   Over-reporting is free: nothing derives a *duration* from this any more —
   see `PlaybackEngine.referenceDuration`, which trusts the host's metadata —
   so it only has to be large enough that the parser keeps reading until the
   bytes genuinely run out. Under-reporting truncates the track, which is the
   fault this constant caused when it was 320 kbps, so the margin is the point.
   */
  public static let assumedBitrate: Double = 20_000_000

  /**
   Where fetched audio is kept between tracks. Nil keeps the old behaviour —
   in memory, for the life of the track — which is what the tests want and
   what a host that never calls `configureCache` gets.

   Only the ranged path is cached. A transcoded stream is produced on the fly
   and its bytes are not the file: two plays at different bitrates are
   different audio under the same id, and storing either as *the* cached copy
   would serve the wrong one back.
   */
  private let cache: DiskCache?

  /**
   Presented to servers that ask the client to prove who it is.

   Held here because this is the one place both transports are built, and both
   need it: a library behind mutual TLS refuses the audio request exactly as it
   refuses the API one. Nil is the ordinary case and costs nothing — the ranged
   path keeps using the shared session it always used.
   */
  private var clientCertificate: ClientCertificate?

  /// One session for every ranged fetch, so the client-certificate handshake —
  /// the expensive kind — is done once and the connection reused, rather than
  /// repeated for every track.
  private var session: URLSession

  /// Guards the two above. Readers are made on the engine's open queue while
  /// a certificate is set from the main thread, so these are genuinely shared.
  private let lock = NSLock()

  public init(cache: DiskCache? = nil, clientCertificate: ClientCertificate? = nil) {
    self.cache = cache
    self.clientCertificate = clientCertificate
    self.session = clientCertificate.map { makeClientCertificateSession(certificate: $0) } ?? .shared
  }

  /**
   Change the certificate presented from here on.

   Settable rather than fixed at construction because a certificate is
   imported, replaced and removed while the app is running, and rebuilding the
   engine around it would stop the music to change a setting. It takes effect
   for the next reader opened; the track playing keeps the connection it
   already authenticated.

   The old session is invalidated rather than dropped — a `URLSession` holds
   its delegate strongly until it is, which would keep a removed certificate's
   identity alive for as long as the process ran.
   */
  public func setClientCertificate(_ certificate: ClientCertificate?) {
    lock.lock()
    let previous = session
    clientCertificate = certificate
    session = certificate.map { makeClientCertificateSession(certificate: $0) } ?? .shared
    lock.unlock()
    if previous !== URLSession.shared { previous.finishTasksAndInvalidate() }
  }

  /// Read together, because a fetcher built with one and a producer built with
  /// the other would authenticate as two different clients.
  private var transport: (session: URLSession, certificate: ClientCertificate?) {
    lock.lock(); defer { lock.unlock() }
    return (session, clientCertificate)
  }

  public func makeReader(for track: Track) throws -> TrackReader {
    try makeReader(for: track, timeOffsetSeconds: 0)
  }

  public func makeReader(for track: Track, timeOffsetSeconds: Int) throws -> TrackReader {
    // A broadcast is a third transport: no length, no ranges, no end. The file
    // parsers below wait for a size that does not exist — see
    // `LiveStreamReader`. Ogg stations are the exception it hands back, and
    // they take the path below as before.
    if track.continuous, let url = URL(string: track.uri), !url.isFileURL {
      let certificate = transport.certificate
      let reader = LiveStreamReader(hint: Self.typeHint(for: track.uri)) {
        HTTPStreamProducer(url: url, headers: track.headers, clientCertificate: certificate)
      }
      do {
        try reader.open()
        return reader
      } catch LiveStreamReader.LiveStreamError.notParseable {
        // Fall through to the file path.
      } catch LiveStreamReader.LiveStreamError.noFormat {
        // Fall through: the file path reports the status that explains it.
      }
    }

    let source = try makeSource(for: track, timeOffsetSeconds: timeOffsetSeconds)

    // Sniffed from the bytes, not from the URI. A stream URL carries no
    // extension — `/rest/stream.view?id=…` is the same shape whatever the
    // file is — and a server may transcode on the way out, so the only honest
    // answer to "what is this" is the first four bytes.
    switch try Self.oggCodec(source) {
    case .vorbis:
      let reader = VorbisFileReader(source: source)
      try reader.open()
      return reader
    case .opus:
      let reader = OpusFileReader(source: source)
      try reader.open()
      return reader
    case nil:
      break
    }

    // Raw FLAC, by its own four-byte magic, decoded by libFLAC rather than by
    // Core Audio. Not a quality choice — Core Audio decodes FLAC correctly —
    // but a streaming one: its parser seeks backwards, which a transcoded
    // stream cannot serve at all, and reads from the start of the file to any
    // seek point, which defeats the ranged cache. See `FLACFileReader` and
    // docs/architecture.md §10.
    if try Self.isRawFLAC(source) {
      let reader = FLACFileReader(source: source)
      try reader.open()
      return reader
    }

    let reader = AudioFileReader(source: source)
    try reader.open(hint: Self.typeHint(for: track.uri))
    return reader
  }

  /**
   Whether this is a raw FLAC stream.

   `fLaC` is a four-byte magic exactly like `OggS`, and read the same way —
   from the bytes rather than the URI, because a Subsonic stream URL says
   nothing about what it is about to send.

   FLAC *inside* Ogg is deliberately not claimed here: `oggCodec` runs first
   and answers nil for it, and this check requires the raw signature, so an
   `.oga` carrying FLAC goes to Core Audio exactly as it did before. Narrow on
   purpose — the format in the field is raw `.flac`.

   A read that *fails* is not an answer, for the reason `oggCodec` spells out
   at length: a nil from a timeout is indistinguishable from a nil meaning "an
   MP3", so this throws and lets the caller decide.
   */
  static func isRawFLAC(_ source: ByteSource) throws -> Bool {
    let head = try source.read(offset: 0, count: 4)
    guard head.count >= 4 else { return false }
    return [UInt8](head).starts(with: [0x66, 0x4C, 0x61, 0x43])  // "fLaC"
  }

  /// The codecs the engine carries its own decoder for.
  enum OggCodec { case vorbis, opus }

  /**
   Which codec an Ogg stream carries, or nil for anything else.

   The container is not enough to choose by: Ogg holds Vorbis, Opus and FLAC
   behind the same `OggS` capture pattern, and handing one decoder another's
   stream fails with a header error rather than falling back. The codec name
   sits in the first page's body, so identifying it costs the same single read
   the container check did.

   FLAC-in-Ogg is deliberately not claimed. Core Audio decodes raw `.flac` and
   this engine carries no FLAC decoder, so answering nil sends it down the
   Core Audio path — which will fail on the Ogg wrapper, exactly as it does
   today rather than newly.

   A read that *fails* is not an answer, and it used to be given as one: the
   `nil` returned for a timeout or a 5xx is indistinguishable from the `nil`
   that means "this is an MP3", so a genuine `.ogg` went to Core Audio — which
   carries no Vorbis decoder at all — and failed to open. The two formats this
   function exists to rescue were the two it made unplayable. It throws now,
   and the caller decides.

   Too *few* bytes is still an answer: a twelve-byte file is not an Ogg
   stream.
   */
  static func oggCodec(_ source: ByteSource) throws -> OggCodec? {
    let head = try source.read(offset: 0, count: 64)
    guard head.count >= 12 else { return nil }
    let bytes = [UInt8](head)
    guard bytes.starts(with: [0x4F, 0x67, 0x67, 0x53]) else { return nil }  // "OggS"

    // Searched for rather than read at a fixed offset, because the page
    // header's length varies with its segment table.
    if contains(bytes, [0x76, 0x6F, 0x72, 0x62, 0x69, 0x73]) { return .vorbis }   // "vorbis"
    if contains(bytes, [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64]) { return .opus }  // "OpusHead"
    return nil
  }

  private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard haystack.count >= needle.count else { return false }
    for start in 0...(haystack.count - needle.count)
    where Array(haystack[start..<start + needle.count]) == needle {
      return true
    }
    return false
  }

  func makeSource(for track: Track, timeOffsetSeconds: Int = 0) throws -> ByteSource {
    guard let url = URL(string: track.uri) else {
      throw ByteSourceError.fetchFailed("unusable uri: \(track.uri)")
    }

    if url.isFileURL {
      // A downloaded track. Whole and seekable, so the ranged path with a
      // trivially cheap fetcher.
      return CachedByteSource(fetcher: try FileByteFetcher(url: url))
    }

    // A non-zero offset is only ever asked for on a stream that has already
    // been established as sequential, so the probe below is skipped rather
    // than repeated. Not just to save the request: if the server answered
    // with a length this time, the probe would hand back a *seekable* source
    // whose byte zero is `timeOffsetSeconds` into the track, and every
    // position the engine computed from it would be wrong by that offset
    // while looking entirely well-formed.
    if timeOffsetSeconds > 0 {
      return streamingSource(url: url, track: track, timeOffsetSeconds: timeOffsetSeconds)
    }

    let fetcher = HTTPByteFetcher(url: url, headers: track.headers, session: transport.session)
    do {
      _ = try fetcher.contentLength()
    } catch HTTPByteFetcher.HTTPFetchError.noLength {
      // The one error that really does mean "transcode in progress": the
      // server is encoding as it sends and cannot say how long the result will
      // be.
      return streamingSource(url: url, track: track, timeOffsetSeconds: timeOffsetSeconds)
    } catch {
      // Everything else is a broken server, an expired token or a timeout, and
      // catching them all here turned each into a silent downgrade: the track
      // spent the rest of its life on the sequential transport, with no
      // forward seek, no disk cache, and a length guessed from an assumed
      // bitrate. A 401 then surfaced as "could not open" from the parser a few
      // hundred bytes in rather than as the status that explains it.
      throw error
    }

    if fetcher.rangesSupported == false {
      return streamingSource(url: url, track: track, timeOffsetSeconds: timeOffsetSeconds)
    }

    let source = CachedByteSource(fetcher: fetcher, cache: cache, cacheId: track.id)
    // MP4-family containers keep `moov` at the tail unless written faststart,
    // and the parser's first reads go there. Without this an ALAC or AAC track
    // will not open until the whole file has landed — confirmed in the spike.
    if Self.isMP4Family(url: url) {
      try? source.prefetchTail()
    }
    return source
  }

  private func streamingSource(
    url: URL, track: Track, timeOffsetSeconds: Int = 0
  ) -> ByteSource {
    // What is left of the track, not all of it: a stream restarted 90 seconds
    // in is 90 seconds shorter, and the estimate is what the parser is told
    // the file weighs. Handing it the whole duration made a reconnected
    // stream claim bytes that were never going to arrive.
    let seconds = max(0, (track.durationSec ?? 0) - Double(timeOffsetSeconds))
    let estimate = seconds > 0
      ? Int64(seconds * Self.assumedBitrate / 8)
      : Int64(64 * 1024 * 1024)
    let producer = HTTPStreamProducer(
      url: streamURL(base: url, timeOffsetSeconds: timeOffsetSeconds),
      headers: track.headers,
      clientCertificate: transport.certificate
    )
    return StreamingByteSource(producer: producer, estimatedBytes: estimate)
  }

  /// Saves the parser sniffing, which costs extra reads at the head — and here
  /// a read is a network request rather than a memcpy.
  static func typeHint(for uri: String) -> AudioFileTypeID {
    switch (uri as NSString).pathExtension.lowercased() {
    case "mp3": return kAudioFileMP3Type
    case "m4a", "mp4", "aac": return kAudioFileM4AType
    case "flac": return kAudioFileFLACType
    case "wav": return kAudioFileWAVEType
    case "aif", "aiff": return kAudioFileAIFFType
    default: return 0
    }
  }

  static func isMP4Family(url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    if ["m4a", "mp4", "m4b", "aac"].contains(ext) { return true }
    // Subsonic-style URLs carry the format in the query rather than the path.
    let query = url.query?.lowercased() ?? ""
    return query.contains("format=m4a") || query.contains("format=aac")
  }
}

/// A local file, behind the same interface as the network. Lets a downloaded
/// track and a streamed one take exactly the same path.
final class FileByteFetcher: ByteFetcher, @unchecked Sendable {
  private let handle: FileHandle
  private let size: Int64

  init(url: URL) throws {
    handle = try FileHandle(forReadingFrom: url)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
  }

  deinit { try? handle.close() }

  func contentLength() throws -> Int64 { size }

  func fetch(_ range: Range<Int64>) throws -> Data {
    try handle.seek(toOffset: UInt64(range.lowerBound))
    let count = Int(min(range.upperBound, size) - range.lowerBound)
    guard count > 0 else { return Data() }
    return handle.readData(ofLength: count)
  }
}
