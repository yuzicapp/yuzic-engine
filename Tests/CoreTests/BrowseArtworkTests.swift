import XCTest
@testable import YuzicEngineCore

/**
 Cover art for the car's browse rows.

 `BrowseNode.artworkUri` was carried across the bridge from the day the browse
 tree existed and read by nothing — the scene delegate built each row with a
 title, a subtitle and an accessory, and never an image. What these cover is
 the part that is not drawing: which request a row produces, and how many
 times the same image is fetched when the car asks for the same list again.
 */
final class BrowseArtworkTests: XCTestCase {

  /// Records what it was asked for and answers on demand, so a test can hold a
  /// request open and ask what the loader does with a second one meanwhile.
  private final class FakeFetcher: BrowseArtworkFetching {
    private(set) var requests: [URLRequest] = []
    private var pending: [(Data?) -> Void] = []
    var answerImmediatelyWith: Data?

    func fetch(_ request: URLRequest, completion: @escaping (Data?) -> Void) {
      requests.append(request)
      if let answerImmediatelyWith {
        completion(answerImmediatelyWith)
      } else {
        pending.append(completion)
      }
    }

    func answerAll(with data: Data?) {
      let waiting = pending
      pending = []
      for completion in waiting { completion(data) }
    }
  }

  private func node(
    uri: String? = "https://library.test/cover/1.jpg",
    headers: [String: String] = [:]
  ) -> BrowseNode {
    BrowseNode(id: "n1", title: "An Album", artworkUri: uri, artworkHeaders: headers)
  }

  // MARK: - The request a row produces

  func testNoRequestForANodeWithNoArtwork() {
    XCTAssertNil(BrowseArtworkLoader.request(for: node(uri: nil)))
  }

  func testNoRequestForAnEmptyArtworkUri() {
    // An empty string is not a URL, and `URL(string:)` is happy to build
    // something useless from one.
    XCTAssertNil(BrowseArtworkLoader.request(for: node(uri: "")))
  }

  /**
   The headers reach the request.

   This is the whole point of the field. Without them a header-authenticated
   server answers 401 for every thumbnail, and the car shows blank squares
   while the same cover renders on the now-playing screen.
   */
  func testArtworkHeadersAreSentWithTheRequest() {
    let request = BrowseArtworkLoader.request(
      for: node(headers: ["Authorization": "Basic abc", "X-Emby-Token": "xyz"])
    )

    XCTAssertEqual(request?.value(forHTTPHeaderField: "Authorization"), "Basic abc")
    XCTAssertEqual(request?.value(forHTTPHeaderField: "X-Emby-Token"), "xyz")
  }

  func testAnUnprotectedServerSendsNoHeaders() {
    let request = BrowseArtworkLoader.request(for: node())

    XCTAssertEqual(request?.allHTTPHeaderFields ?? [:], [:])
  }

  // MARK: - Asking the same thing twice

  func testAnImageIsFetchedOnceAndKept() {
    // CarPlay rebuilds a template on every push and every root change. A list
    // of fifty albums re-fetched on each of those is fifty requests per
    // navigation, over a phone connection, while someone is driving.
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x01])
    let loader = BrowseArtworkLoader(fetcher: fetcher)

    loader.image(for: node()) { _ in }
    loader.image(for: node()) { _ in }
    loader.image(for: node()) { _ in }

    XCTAssertEqual(fetcher.requests.count, 1)
  }

  func testTheCachedImageIsHandedBack() {
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x07])
    let loader = BrowseArtworkLoader(fetcher: fetcher)
    loader.image(for: node()) { _ in }

    var second: Data?
    loader.image(for: node()) { second = $0 }

    XCTAssertEqual(second, Data([0x07]))
  }

  func testConcurrentAsksForOneImageBecomeOneRequest() {
    // Rows are built in a loop, so every row of an album's tracks asks for the
    // same cover in the same turn — before any of them can have completed.
    let fetcher = FakeFetcher()
    let loader = BrowseArtworkLoader(fetcher: fetcher)

    var answered: [Data?] = []
    loader.image(for: node()) { answered.append($0) }
    loader.image(for: node()) { answered.append($0) }
    loader.image(for: node()) { answered.append($0) }
    XCTAssertEqual(fetcher.requests.count, 1, "one image, one request")

    fetcher.answerAll(with: Data([0x09]))

    XCTAssertEqual(answered, [Data([0x09]), Data([0x09]), Data([0x09])],
                   "everyone waiting got the image, not just the first asker")
  }

  func testADifferentImageIsADifferentRequest() {
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x01])
    let loader = BrowseArtworkLoader(fetcher: fetcher)

    loader.image(for: node(uri: "https://library.test/cover/1.jpg")) { _ in }
    loader.image(for: node(uri: "https://library.test/cover/2.jpg")) { _ in }

    XCTAssertEqual(fetcher.requests.count, 2)
  }

  // MARK: - Failure and bounds

  func testAFailedFetchIsNotCached() {
    // A cached failure is permanent: the row would stay blank for the life of
    // the process, including after the connection came back.
    let fetcher = FakeFetcher()
    let loader = BrowseArtworkLoader(fetcher: fetcher)

    loader.image(for: node()) { _ in }
    fetcher.answerAll(with: nil)
    loader.image(for: node()) { _ in }

    XCTAssertEqual(fetcher.requests.count, 2)
    XCTAssertEqual(loader.count, 0)
  }

  func testANodeWithNoArtworkAnswersWithoutFetching() {
    let fetcher = FakeFetcher()
    let loader = BrowseArtworkLoader(fetcher: fetcher)

    var called = false
    loader.image(for: node(uri: nil)) { data in
      called = true
      XCTAssertNil(data)
    }

    XCTAssertTrue(called, "a row with no art still has to hear back")
    XCTAssertEqual(fetcher.requests.count, 0)
  }

  func testTheCacheIsBounded() {
    // A long drive through a large library must not grow this without end.
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x01])
    let loader = BrowseArtworkLoader(fetcher: fetcher, capacity: 3)

    for i in 0..<10 {
      loader.image(for: node(uri: "https://library.test/cover/\(i).jpg")) { _ in }
    }

    XCTAssertEqual(loader.count, 3)
  }

  func testTheOldestImageIsTheOneDropped() {
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x01])
    let loader = BrowseArtworkLoader(fetcher: fetcher, capacity: 2)

    loader.image(for: node(uri: "https://library.test/a.jpg")) { _ in }
    loader.image(for: node(uri: "https://library.test/b.jpg")) { _ in }
    // Touch `a` so `b` becomes the least recently used.
    loader.image(for: node(uri: "https://library.test/a.jpg")) { _ in }
    loader.image(for: node(uri: "https://library.test/c.jpg")) { _ in }

    let before = fetcher.requests.count
    loader.image(for: node(uri: "https://library.test/a.jpg")) { _ in }

    XCTAssertEqual(fetcher.requests.count, before, "the recently used image was evicted")
  }

  func testClearingForgetsEverything() {
    // The tree was replaced, so the old covers may not belong to anything
    // still in it.
    let fetcher = FakeFetcher()
    fetcher.answerImmediatelyWith = Data([0x01])
    let loader = BrowseArtworkLoader(fetcher: fetcher)
    loader.image(for: node()) { _ in }

    loader.clear()
    loader.image(for: node()) { _ in }

    XCTAssertEqual(fetcher.requests.count, 2)
  }

  // MARK: - The tree carries the headers at all

  func testHeadersSurviveTheTreeBeingRebuilt() {
    // The tree crosses the bridge flat and is reassembled on this side; a
    // field dropped in `assemble` is a field the car never sees.
    let tree = BrowseTree.build(title: "Library", from: [
      BrowseTree.FlatNode(id: "album-1", title: "An Album"),
      BrowseTree.FlatNode(
        id: "track-1",
        parentId: "album-1",
        title: "A Track",
        artworkUri: "https://library.test/cover/1.jpg",
        artworkHeaders: ["Authorization": "Basic abc"]
      ),
    ])

    let track = tree.children.first?.children.first

    XCTAssertEqual(track?.artworkHeaders, ["Authorization": "Basic abc"])
  }
}
