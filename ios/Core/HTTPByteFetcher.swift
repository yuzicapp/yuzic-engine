import Foundation

/**
 Fetches byte ranges over HTTP.

 Synchronous on purpose. `AudioFile_ReadProc` has no async form, so somewhere a
 thread has to wait; doing it here keeps the waiting in one place, off the
 render thread, behind a producer that stays a few seconds ahead. A stall then
 costs buffer-ahead rather than a dropout.

 Two threads reach this class now — a decode read and `CachedByteSource`'s
 read-ahead — and they are serialised *there*, by `fetchLock`, rather than
 here. This class keeps one `inFlight` task and `cancel` cancels it, so two
 concurrent `fetch` calls would have the second overwrite the first's handle
 and a seek would abandon the wrong request.

 The interesting part is not the request, it is what happens when the server
 will not do ranges. A music server transcoding on the fly usually cannot: it
 does not know the length of a file it has not finished producing, so it answers
 200 with the whole body rather than 206 with a window. That is not an error and
 must not be treated as one — it is a different mode, and `rangesSupported`
 says which mode we are in so the cache can stop asking for windows it will
 never get.
 */
public final class HTTPByteFetcher: ByteFetcher, @unchecked Sendable {

  public enum HTTPFetchError: Error {
    case badStatus(Int)
    case noLength
    case transport(String)
  }

  private let url: URL
  private let headers: [String: String]
  private let session: URLSession
  private let timeout: TimeInterval

  /// False once the server has shown it ignores `Range`. Until the first probe
  /// this is nil — unknown, rather than assumed either way.
  public private(set) var rangesSupported: Bool?

  private var cachedLength: Int64?

  /// Guards the two fields below, which a cancel touches from the seeking
  /// thread while `perform` is parked on its semaphore.
  private let state = NSLock()
  private var inFlight: URLSessionDataTask?
  private var cancelled = false

  /**
   How long one range request may take before it is a stall.

   Was 30 seconds, which is a "has the server died" timeout and not a "is this
   read healthy" one — and it was doing the second job. A window is 256KB; on
   any connection worth playing over it lands in a second or two. Meanwhile
   `perform` blocks the decode thread on a semaphore for the whole interval,
   so a stalled read produced about two seconds of buffered audio and then
   thirty seconds of silence before anything above it even learned there was a
   problem. Reported as a track cutting out around the half-minute mark.

   Eight seconds is long enough to ride out a cell handover and short enough
   that the retry ladder above can actually do its job while the listener is
   still waiting rather than after they have given up.
   */
  public static let defaultTimeout: TimeInterval = 8

  public init(
    url: URL,
    headers: [String: String] = [:],
    session: URLSession = .shared,
    timeout: TimeInterval = HTTPByteFetcher.defaultTimeout
  ) {
    self.url = url
    self.headers = headers
    self.session = session
    self.timeout = timeout
  }

  /**
   Total size, and the range-support probe in the same round trip.

   A one-byte ranged GET rather than HEAD: plenty of media servers answer HEAD
   differently from GET, or not at all, and the answer that matters is what a
   real ranged read will do. `Content-Range: bytes 0-0/12345` gives the length
   and proves ranges work at once.
   */
  public func contentLength() throws -> Int64 {
    if let cachedLength { return cachedLength }

    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
    request.setValue("bytes=0-0", forHTTPHeaderField: "Range")

    let response = try performHeaders(request)

    if response.statusCode == 206, let total = Self.totalFromContentRange(response) {
      rangesSupported = true
      cachedLength = total
      return total
    }

    // 200 means the server ignored the Range header and is sending everything.
    rangesSupported = false
    let declared = response.value(forHTTPHeaderField: "Content-Length").flatMap { Int64($0) }
    guard let declared, declared > 0 else {
      // A transcoding endpoint often declines to say. Nothing above can work
      // without a length, so the caller has to fall back to downloading the
      // whole thing before playing.
      throw HTTPFetchError.noLength
    }
    cachedLength = declared
    return declared
  }

  public func fetch(_ range: Range<Int64>) throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

    if rangesSupported != false {
      // HTTP ranges are inclusive at both ends; ours are half-open.
      request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
    }

    let (data, response) = try perform(request)

    switch response.statusCode {
    case 206:
      rangesSupported = true
      return data
    case 200:
      // The server sent the whole file regardless of what we asked for. Slice
      // out the part wanted rather than failing: the read is still correct,
      // it just cost more than it should have.
      rangesSupported = false
      let start = min(Int(range.lowerBound), data.count)
      let end = min(Int(range.upperBound), data.count)
      return start < end ? data.subdata(in: start..<end) : Data()
    default:
      throw HTTPFetchError.badStatus(response.statusCode)
    }
  }

  /**
   Abandon the request in flight, and refuse to start another until `resume`.

   A seek is the caller here. Without this the semaphore below is waited on
   unconditionally, so a seek issued while a window is being fetched costs the
   rest of that request — up to `timeout`, and on a stalled connection that is
   the whole 30 seconds. Cancelling the task makes URLSession fire the
   completion handler with an error almost immediately, which signals the
   semaphore and lets the read throw.

   The flag matters as much as the cancellation: `ensure` fetches in a loop, so
   without it the next window would be requested before the seek has had a
   chance to point the source somewhere else.
   */
  public func cancel() {
    state.lock()
    cancelled = true
    let task = inFlight
    state.unlock()
    task?.cancel()
  }

  public func resume() {
    state.lock(); cancelled = false; state.unlock()
  }

  private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()

    let task = session.dataTask(with: request) { data, response, error in
      if let error {
        box.value = .failure(Self.isCancellation(error)
          ? ByteSourceError.cancelled
          : HTTPFetchError.transport(String(describing: error)))
      } else if let http = response as? HTTPURLResponse {
        box.value = .success((data ?? Data(), http))
      } else {
        box.value = .failure(HTTPFetchError.transport("no response"))
      }
      semaphore.signal()
    }

    state.lock()
    // Checked under the same lock that `cancel` takes, so a cancel arriving
    // between the check and the store cannot be missed: either it sees the
    // task and cancels it, or it sets the flag before we look.
    if cancelled { state.unlock(); throw ByteSourceError.cancelled }
    inFlight = task
    state.unlock()

    task.resume()

    /*
     A deadline, because `timeoutInterval` is not one.

     URLSession applies it as `timeoutIntervalForRequest` — the maximum gap
     *between* bytes — while `timeoutIntervalForResource` on `URLSession.shared`
     is seven days. A server dribbling one byte every few seconds therefore
     keeps the request alive indefinitely and parks the decode thread here for
     as long as it likes, with nothing thrown: the same hang that
     `StreamingByteSource.read` had, one layer down.

     Twice the idle timeout: a healthy 256KB window arrives well inside it, and
     anything slower than half a byte per `timeout` seconds is not a stream
     anyone can listen to.
    */
    if semaphore.wait(timeout: .now() + timeout * 2) == .timedOut {
      task.cancel()
      state.lock()
      if inFlight === task { inFlight = nil }
      state.unlock()
      throw HTTPFetchError.transport("request exceeded \(timeout * 2)s wall clock")
    }

    state.lock()
    if inFlight === task { inFlight = nil }
    state.unlock()

    switch box.value {
    case .success(let pair): return pair
    case .failure(let error): throw error
    case nil: throw HTTPFetchError.transport("no result")
    }
  }

  /**
   Send a request and return as soon as its headers arrive, abandoning the body.

   The length probe used to wait for the whole response. From a server that
   honours `Range` that is one byte, and it cost nothing. From one that ignores
   it the body is everything: a whole transcode, fetched only to learn there is
   no length and then requested a second time by the streaming transport — or,
   from an internet radio station, a broadcast that never ends. That probe ran
   into the wall-clock deadline below and threw, so no station could be opened
   at all. Everything the probe reads is in the status line and the headers.

   Same cancellation and deadline rules as `perform`.
   */
  private func performHeaders(_ request: URLRequest) throws -> HTTPURLResponse {
    let probe = HeaderProbe()
    let task = session.dataTask(with: request)
    // A task delegate rather than a session one, so the shared session and the
    // client-certificate session both work unchanged: anything the probe does
    // not implement — the certificate challenge included — still goes to the
    // session's own delegate.
    task.delegate = probe

    state.lock()
    if cancelled { state.unlock(); throw ByteSourceError.cancelled }
    inFlight = task
    state.unlock()

    task.resume()
    let answered = probe.done.wait(timeout: .now() + timeout * 2) == .success

    state.lock()
    if inFlight === task { inFlight = nil }
    state.unlock()

    guard answered else {
      task.cancel()
      throw HTTPFetchError.transport("request exceeded \(timeout * 2)s wall clock")
    }
    let (response, error) = probe.outcome
    if let response { return response }
    if let error, Self.isCancellation(error) { throw ByteSourceError.cancelled }
    throw HTTPFetchError.transport(error.map { String(describing: $0) } ?? "no response")
  }

  /// Takes the response, refuses the body, and says when either has happened.
  private final class HeaderProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var response: HTTPURLResponse?
    private var error: Error?

    var outcome: (HTTPURLResponse?, Error?) {
      lock.lock(); defer { lock.unlock() }
      return (response, error)
    }

    func urlSession(
      _ session: URLSession,
      dataTask: URLSessionDataTask,
      didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      lock.lock()
      self.response = response as? HTTPURLResponse
      lock.unlock()
      completionHandler(.cancel)
      done.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      lock.lock()
      let answered = response != nil
      if !answered { self.error = error }
      lock.unlock()
      if !answered { done.signal() }
    }
  }

  /// The completion handler writes this from the session's queue while
  /// `perform` reads it after the semaphore; the signal is the barrier, but the
  /// box keeps the compiler's concurrency checking honest about the capture.
  private final class ResultBox: @unchecked Sendable {
    var value: Result<(Data, HTTPURLResponse), Error>?
  }

  /// A cancelled task surfaces as `NSURLErrorCancelled`, and that is a seek
  /// doing its job — not a transport failure worth reporting as one.
  private static func isCancellation(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
  }

  /// `Content-Range: bytes 0-0/12345` → 12345.
  static func totalFromContentRange(_ response: HTTPURLResponse) -> Int64? {
    guard let header = response.value(forHTTPHeaderField: "Content-Range") else { return nil }
    guard let slash = header.lastIndex(of: "/") else { return nil }
    let tail = header[header.index(after: slash)...]
    // "*" means the server knows the range but not the whole size.
    return Int64(tail.trimmingCharacters(in: .whitespaces))
  }
}
