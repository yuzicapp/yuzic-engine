import Foundation

/**
 Cover art for the rows in the car's browse list.

 `BrowseNode.artworkUri` has been carried across the bridge since the browse
 tree existed and was read by nothing: the scene delegate built every row with
 a title, a subtitle and an accessory, and never an image. So a library that
 shows covers everywhere else showed a column of blank squares in the car —
 the shape this project keeps finding, a field written, carried, stored, and
 never used.

 What makes this more than a `setImage` call is that the car asks for the same
 rows repeatedly. CarPlay rebuilds a template on every push and on every root
 change, and a list of fifty albums re-fetched on each of those is fifty
 requests per navigation, over a phone connection, while someone is driving. So
 this keeps what it has already fetched, and collapses concurrent asks for the
 same image into one request.

 The transport is injected. Everything here except the actual `URLSession` call
 is ordinary logic — the cache, the de-duplication, the header construction —
 and injecting it is what lets `swift test` cover that on any machine, the same
 split `NowPlaying` makes for the lock-screen cover.
 */
public protocol BrowseArtworkFetching: AnyObject {
  func fetch(_ request: URLRequest, completion: @escaping (Data?) -> Void)
}

/// The real one. Short timeout because this is decorative: a server that hangs
/// must not hold a row's image slot open while the driver scrolls past it.
public final class URLSessionArtworkFetcher: BrowseArtworkFetching {
  private let session: URLSession
  private let timeout: TimeInterval

  public init(session: URLSession = .shared, timeout: TimeInterval = 10) {
    self.session = session
    self.timeout = timeout
  }

  public func fetch(_ request: URLRequest, completion: @escaping (Data?) -> Void) {
    var request = request
    request.timeoutInterval = timeout
    session.dataTask(with: request) { data, response, _ in
      // A 401 returns a body — an HTML error page — and handing that to an
      // image decoder produces nothing useful and no explanation. Checked here
      // so a credential problem looks like a credential problem.
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        completion(nil)
        return
      }
      completion(data)
    }.resume()
  }
}

public final class BrowseArtworkLoader {

  /**
   How many images are kept.

   A car list is tens of rows, not thousands, and the tree is replaced whenever
   the library reloads. Sized to hold a screen's worth several times over
   without letting a long drive through a large library grow without bound.
   */
  public static let defaultCapacity = 120

  private let fetcher: BrowseArtworkFetching
  private let capacity: Int

  private let lock = NSLock()
  private var cache: [String: Data] = [:]
  /// Least-recently-used last, so eviction takes from the front.
  private var order: [String] = []
  /// Asks already in flight, so the same image is fetched once however many
  /// rows want it.
  private var waiting: [String: [(Data?) -> Void]] = [:]

  public init(
    fetcher: BrowseArtworkFetching = URLSessionArtworkFetcher(),
    capacity: Int = BrowseArtworkLoader.defaultCapacity
  ) {
    self.fetcher = fetcher
    self.capacity = max(1, capacity)
  }

  /**
   The request for one node's artwork, or nil if it has none.

   Separated out because it is the part worth checking: a header dropped here
   is a blank square in the car and a 401 in a log nobody reads.
   */
  public static func request(for node: BrowseNode) -> URLRequest? {
    guard let uri = node.artworkUri, !uri.isEmpty, let url = URL(string: uri) else { return nil }
    var request = URLRequest(url: url)
    for (field, value) in node.artworkHeaders {
      request.setValue(value, forHTTPHeaderField: field)
    }
    return request
  }

  /**
   Hand back a row's image data, from memory if it is there.

   `completion` runs on whatever thread the fetch finished on — the caller is
   the one that knows it needs the main thread to touch a list item, and hops
   there itself.
   */
  public func image(for node: BrowseNode, completion: @escaping (Data?) -> Void) {
    guard let request = Self.request(for: node), let key = request.url?.absoluteString else {
      completion(nil)
      return
    }

    lock.lock()
    if let cached = cache[key] {
      touch(key)
      lock.unlock()
      completion(cached)
      return
    }
    // Already being fetched: join the queue rather than asking again. Fifty
    // rows of the same album art is one request, not fifty.
    if waiting[key] != nil {
      waiting[key]?.append(completion)
      lock.unlock()
      return
    }
    waiting[key] = [completion]
    lock.unlock()

    fetcher.fetch(request) { [weak self] data in
      guard let self else {
        completion(nil)
        return
      }
      self.lock.lock()
      if let data {
        self.cache[key] = data
        self.touch(key)
        self.evictIfNeeded()
      }
      let waiters = self.waiting.removeValue(forKey: key) ?? []
      self.lock.unlock()
      for waiter in waiters { waiter(data) }
    }
  }

  /// Forget everything. The tree was replaced, so the old covers may not even
  /// belong to tracks that are still in it.
  public func clear() {
    lock.lock()
    cache.removeAll()
    order.removeAll()
    lock.unlock()
  }

  public var count: Int {
    lock.lock(); defer { lock.unlock() }
    return cache.count
  }

  /// Caller holds the lock.
  private func touch(_ key: String) {
    order.removeAll { $0 == key }
    order.append(key)
  }

  /// Caller holds the lock.
  private func evictIfNeeded() {
    while order.count > capacity, let oldest = order.first {
      order.removeFirst()
      cache.removeValue(forKey: oldest)
    }
  }
}
