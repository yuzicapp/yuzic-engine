import Foundation

/**
 A plain HTTP client that presents the engine's client certificate.

 The engine owns a client certificate so it can *stream audio* from a server
 behind mutual TLS. But the app reaches the same server for everything else —
 logging in, listing albums, fetching artwork — through JavaScript's `fetch`,
 which is `NSURLSession` with no identity to offer and no way to give it one.
 Against a server that requires a certificate that request fails at the
 handshake, so the login never succeeds and no track is ever asked for: the
 audio-side support cannot be reached at all.

 So the certificate has to be usable for ordinary requests too, and this is the
 narrow way through. It is deliberately *not* a general-purpose networking
 layer — the app keeps using `fetch` for every server that does not need a
 certificate, and only routes through here when one is set. Redirects, cookies,
 and caching are `URLSession`'s defaults; nothing is reimplemented.

 Bodies cross the bridge base64-encoded. Album art and a Subsonic error are
 both "bytes" as far as this is concerned, and base64 is the only encoding that
 survives arbitrary bytes over a JSON bridge without a second guess about
 charset. The caller decodes.
 */
public final class ClientCertificateHTTP {

  public enum RequestError: Error, LocalizedError {
    /// The URL could not be parsed. Reported before opening a connection.
    case invalidURL(String)
    /// The response was not HTTP — a `file:` or `data:` URL reached here.
    case notHTTP

    public var errorDescription: String? {
      switch self {
      case .invalidURL(let url): return "Not a valid URL: \(url)"
      case .notHTTP: return "The response was not an HTTP response."
      }
    }
  }

  /// What a completed request came back with. Modelled on the parts of
  /// `Response` the callers actually read; there is no reason to invent more.
  public struct Result {
    public let status: Int
    public let headers: [String: String]
    public let bodyBase64: String
  }

  /// The session the requests go through, rebuilt whenever the certificate
  /// changes. Held rather than made per request for the same reason the audio
  /// path holds one: a mutual-TLS handshake is the expensive kind, and
  /// `URLSession` pools connections across requests only within one session.
  private var session: URLSession?
  private let lock = NSLock()

  public init() {}

  /**
   Point the client at a certificate, or clear it.

   Clearing matters as much as setting. The engine keeps whatever it was last
   given until told otherwise, so switching to a server that needs no
   certificate must actively drop the old one — otherwise those requests
   present an identity issued for somewhere else, which is both wrong and a
   quiet way to leak which other server the person uses.

   The old session is invalidated rather than dropped: `URLSession` holds its
   delegate — and therefore the identity — strongly until it is, which would
   keep a removed certificate alive for as long as the process ran.
   */
  public func setClientCertificate(_ certificate: ClientCertificate?) {
    lock.lock()
    let previous = session
    session = certificate.map { makeClientCertificateSession(certificate: $0) }
    lock.unlock()
    previous?.finishTasksAndInvalidate()
  }

  /// Whether a certificate is currently set. The caller uses this to decide
  /// whether a request needs to come through here at all.
  public var hasClientCertificate: Bool {
    lock.lock()
    defer { lock.unlock() }
    return session != nil
  }

  /// The session to send the next request through, read under the lock.
  ///
  /// Synchronous on purpose: `NSLock`'s `lock()` and `unlock()` are
  /// unavailable from an asynchronous context — a hard error in the Swift 6
  /// language mode — because holding one across a suspension point blocks a
  /// cooperative thread. Taking the lock here, in a function that cannot
  /// suspend, keeps the same protection without that risk.
  private func currentSession() -> URLSession {
    lock.lock()
    defer { lock.unlock() }
    return session ?? .shared
  }

  /**
   Perform a request, presenting the certificate if one is set.

   With no certificate set this still works — it falls back to a shared
   session — so the caller gets one answer to "did this request happen"
   rather than having to branch. The app only routes here when a certificate
   exists, but a request in flight while one is being removed should complete
   rather than trap.
   */
  public func request(
    url: String,
    method: String,
    headers: [String: String],
    bodyBase64: String?,
    timeoutMs: Int
  ) async throws -> Result {
    guard let parsed = URL(string: url) else { throw RequestError.invalidURL(url) }

    let active = currentSession()

    var request = URLRequest(url: parsed)
    request.httpMethod = method
    request.timeoutInterval = TimeInterval(timeoutMs) / 1000.0
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if let bodyBase64, let body = Data(base64Encoded: bodyBase64) {
      request.httpBody = body
    }

    let (data, response) = try await active.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw RequestError.notHTTP }

    // Header names are matched case-insensitively by every caller here, and
    // HTTP does not promise a case, so they are lowered once rather than at
    // each lookup on the other side of the bridge.
    var headerFields: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      guard let name = key as? String, let text = value as? String else { continue }
      headerFields[name.lowercased()] = text
    }

    return Result(
      status: http.statusCode,
      headers: headerFields,
      bodyBase64: data.base64EncodedString()
    )
  }
}
