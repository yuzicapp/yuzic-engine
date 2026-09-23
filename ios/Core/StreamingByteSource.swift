import Foundation

/// Produces a byte stream from the beginning, once. No ranges, no seeking.
public protocol StreamProducer: AnyObject {
  /// Begin delivering. `onData` is called repeatedly off the caller's thread;
  /// `onFinish` once, with an error if the stream broke.
  func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void)
  func stop()
}

/**
 A byte source over a stream that arrives in order and cannot be seeked.

 This is the transcoded path. The server answers `accept-ranges: none` with no
 length, because it is encoding as it sends — measured against a real Navidrome,
 not assumed; see `spikes/ios-reader`.

 What still works, and it is most of what matters:

 - Playing from the start, which is what almost every listen is.
 - Seeking **backwards**, or anywhere already received, because every byte that
   arrives is kept. Random access over the part of the file that exists.
 - Reading slightly ahead of the write head, by waiting for it.

 What cannot work is a seek far past what has arrived. There is no range to
 request; the only way to reach that point is to ask the server for a new
 stream starting there, with Subsonic's `timeOffset`. That is a *reconnection*,
 not a read — the byte offsets of the new stream have nothing to do with the old
 one — so it is handled a layer up by replacing the source and reopening the
 reader, not smuggled in here.

 The user chose this when they chose a bitrate cap, and a slower seek is the
 honest consequence of that choice rather than something to paper over by
 quietly downloading the lossless original instead.
 */
public final class StreamingByteSource: ByteSource {

  /**
   How long a read may wait for the write head to reach it.

   The wait used to be unbounded, and that is the fault this class shipped
   with: a read past what has arrived parked the decode thread on the
   condition variable and never came back. It threw nothing and returned
   nothing, so `TrackPlayback`'s retry ladder never ran, the stall signal never
   fired, and the engine went on reporting `.playing` while the buffered audio
   drained and the track fell silent. Every fix aimed at "a failed read must
   not look like the end of a file" missed it, because this path produces
   neither a failure nor an end.

   Twelve seconds is longer than any healthy gap between chunks — the producer
   delivers continuously once a transcode is running — and short enough that
   the machinery above can react while the listener is still waiting.
   */
  public static let readWaitTimeoutSec: TimeInterval = 12

  private let producer: StreamProducer
  private let estimatedBytes: Int64
  /// Instance rather than static so a test can reach the give-up path in
  /// milliseconds — the real budget is deliberately long, and a suite that
  /// waits it out is a suite people stop running.
  private let readWaitTimeout: TimeInterval

  private let lock = NSCondition()
  private var buffer = Data()
  private var finished = false
  private var failure: Error?
  private var cancelled = false
  private var started = false

  /**
   `estimatedBytes` is what `GetSizeProc` reports until the stream ends.

   It has to be *something* — the parser asks before any bytes arrive. The host
   knows the track's duration and the bitrate it asked for, so
   `duration × bitrate` is available and close. Erring high is deliberate:
   reading past the real end returns nothing, which the parser treats as
   end-of-file, whereas under-reporting makes it stop early and truncate the
   track.
   */
  public init(
    producer: StreamProducer,
    estimatedBytes: Int64,
    readWaitTimeout: TimeInterval = StreamingByteSource.readWaitTimeoutSec
  ) {
    self.producer = producer
    self.estimatedBytes = max(1, estimatedBytes)
    self.readWaitTimeout = readWaitTimeout
  }

  deinit { producer.stop() }

  public func totalBytes() throws -> Int64 {
    lock.lock(); defer { lock.unlock() }
    // Once the stream has ended the true size is known, and it is better than
    // the estimate — a parser that seeks relative to the end wants the real one.
    return finished ? Int64(buffer.count) : estimatedBytes
  }

  public func availableBytes(from offset: Int64) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    return max(0, Int64(buffer.count) - offset)
  }

  /// The one source this is true of, and the reason the flag exists.
  public var isSequential: Bool { true }

  /// False until the producer's own `onFinish` fires. Until then
  /// `totalBytes()` is `duration × bitrate` and nothing may treat reaching it
  /// as reaching the end of the audio.
  public var isFinished: Bool {
    lock.lock(); defer { lock.unlock() }
    return finished
  }

  /**
   Unblock any waiting read. **Does not stop the producer**, and must not.

   The contract on `ByteSource` is precisely "unblocks any waiting read" — it
   is what lets a seek get a decode thread off the condition variable so the
   reader can be pointed somewhere else. For the ranged transport that is all
   `cancel` can mean anyway: a cancelled range request is reissued at the new
   offset and nothing is lost.

   This class has exactly one producer, started once behind `startIfNeeded`'s
   `started` guard, and `HTTPStreamProducer.stop()` cancels the task *and*
   invalidates the session. So stopping it here ended the transcode for good
   while `resume()` — which only clears a flag — implied the opposite. Every
   seek runs `cancelPendingReads()`/`resumePendingReads()` over the same
   source, so one seek killed the stream and left a source that could only
   time out: twelve seconds of silence per read, then a failure. Downloads
   were unaffected, which is what made it look like a network fault.

   Letting the download continue through a seek is also simply better: the
   buffer keeps filling while the reader is repositioned, so a backward seek
   lands in bytes that are already there. Teardown is `deinit`'s job, and it
   already does it.
   */
  public func cancel() {
    lock.lock()
    cancelled = true
    lock.broadcast()
    lock.unlock()
  }

  public func resume() {
    lock.lock(); cancelled = false; lock.unlock()
  }

  public func read(offset: Int64, count: Int) throws -> Data {
    guard offset >= 0 else { throw ByteSourceError.outOfBounds }
    startIfNeeded()

    lock.lock()
    defer { lock.unlock() }

    let wantedEnd = offset + Int64(count)
    // Wait for the write head to pass what was asked for. A reader slightly
    // ahead of the download is the normal case, not an error — but only for
    // as long as the stream is actually moving. Bounded, because an unbounded
    // wait here is indistinguishable from a hung player: see
    // `readWaitTimeoutSec`.
    let deadline = Date().addingTimeInterval(readWaitTimeout)
    while Int64(buffer.count) < wantedEnd && !finished && !cancelled && failure == nil {
      if !lock.wait(until: deadline) {
        throw ByteSourceError.fetchFailed(
          "stream did not reach \(wantedEnd) within \(readWaitTimeout)s "
          + "(have \(buffer.count))"
        )
      }
    }

    if cancelled { throw ByteSourceError.cancelled }
    if let failure { throw ByteSourceError.fetchFailed(String(describing: failure)) }

    guard offset < Int64(buffer.count) else { return Data() }
    let end = min(Int(wantedEnd), buffer.count)
    return buffer.subdata(in: Int(offset)..<end)
  }

  private func startIfNeeded() {
    lock.lock()
    guard !started else { lock.unlock(); return }
    started = true
    lock.unlock()

    producer.begin(
      onData: { [weak self] chunk in
        guard let self else { return }
        self.lock.lock()
        self.buffer.append(chunk)
        self.lock.broadcast()
        self.lock.unlock()
      },
      onFinish: { [weak self] error in
        guard let self else { return }
        self.lock.lock()
        self.failure = error
        self.finished = true
        self.lock.broadcast()
        self.lock.unlock()
      }
    )
  }
}

/**
 A `StreamProducer` over an ordinary HTTP GET.

 No `Range` header at all: this is for the endpoint that already said it will
 not honour one, and sending it anyway invites a server to answer 206 for part
 of a stream it is generating, which nobody wants.
 */
public final class HTTPStreamProducer: NSObject, StreamProducer, URLSessionDataDelegate {

  private let request: URLRequest
  private var session: URLSession?
  private var task: URLSessionDataTask?
  private var onData: ((Data) -> Void)?
  private var onFinish: ((Error?) -> Void)?

  /// Presented when the server asks for one; nil for the ordinary case where
  /// it does not. Held rather than borrowed from a shared session because this
  /// class is already its own `URLSessionDataDelegate` — it needs the data
  /// callbacks — and a session may only have one delegate.
  private let clientCertificate: ClientCertificate?

  public init(
    url: URL,
    headers: [String: String] = [:],
    timeout: TimeInterval = 30,
    clientCertificate: ClientCertificate? = nil
  ) {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    self.request = request
    self.clientCertificate = clientCertificate
    super.init()
  }

  public func begin(onData: @escaping (Data) -> Void, onFinish: @escaping (Error?) -> Void) {
    self.onData = onData
    self.onFinish = onFinish
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    self.session = session
    task = session.dataTask(with: request)
    task?.resume()
  }

  public func stop() {
    task?.cancel()
    session?.invalidateAndCancel()
    session = nil
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    answerAuthenticationChallenge(
      challenge, with: clientCertificate, completionHandler: completionHandler
    )
  }

  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    onData?(data)
  }

  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    onFinish?(error)
  }
}

/// Builds the URL for restarting a transcoded stream partway in.
///
/// Subsonic's answer to seeking when ranges are unavailable, confirmed working
/// against a real server, and the default. `param` is the track's
/// `seekReconnectParam`, so a server that spells it differently can say so.
/// The result is a *different* stream, so whoever calls this has to replace
/// the source and reopen the reader rather than treating it as a seek.
public func streamURL(
  base: URL, timeOffsetSeconds: Int, param: String = Track.defaultSeekReconnectParam
) -> URL {
  guard timeOffsetSeconds > 0,
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
    return base
  }
  var items = components.queryItems ?? []
  items.removeAll { $0.name == param }
  items.append(URLQueryItem(name: param, value: String(timeOffsetSeconds)))
  components.queryItems = items
  return components.url ?? base
}
