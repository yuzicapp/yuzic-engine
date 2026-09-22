import XCTest
@testable import YuzicEngineCore

/**
 The browse tree's shape, lookup and limits.

 All of this is testable precisely because `BrowseNode` has no CarPlay types in
 it. The parts that need a car are confined to the template layer, which is
 thin, and the parts that decide what the car *shows* are here.
 */
final class BrowseTreeTests: XCTestCase {

  private func track(_ id: String) -> Track {
    Track(id: id, uri: "https://example.test/\(id)", title: id)
  }

  private func library() -> BrowseNode {
    BrowseNode(id: "root", title: "Library", children: [
      BrowseNode(id: "albums", title: "Albums", children: [
        BrowseNode(id: "album:1", title: "First", children: [
          BrowseNode(id: "t:1", title: "One", playable: track("t:1")),
          BrowseNode(id: "t:2", title: "Two", playable: track("t:2")),
        ]),
      ]),
      BrowseNode(id: "playlists", title: "Playlists"),
    ])
  }

  func testFindsANestedNode() {
    XCTAssertEqual(BrowseTree.find("t:2", in: library())?.title, "Two")
  }

  func testMissingIdIsNil() {
    XCTAssertNil(BrowseTree.find("nope", in: library()))
  }

  func testPathRebuildsTheNavigationStack() {
    // The car keeps its place across app relaunches, which happen routinely
    // when the system reclaims a backgrounded app.
    let path = BrowseTree.path(to: "t:1", in: library())
    XCTAssertEqual(path?.map(\.id), ["root", "albums", "album:1", "t:1"])
  }

  func testTracksUnderABranchAreInOrder() {
    // Choosing an album means playing the album, not opening it.
    let album = BrowseTree.find("album:1", in: library())!
    XCTAssertEqual(BrowseTree.tracks(under: album).map(\.id), ["t:1", "t:2"])
  }

  func testTracksUnderALeafIsJustThatTrack() {
    let leaf = BrowseTree.find("t:2", in: library())!
    XCTAssertEqual(BrowseTree.tracks(under: leaf).map(\.id), ["t:2"])
  }

  func testTracksUnderAnEmptyBranchIsEmpty() {
    let empty = BrowseTree.find("playlists", in: library())!
    XCTAssertTrue(BrowseTree.tracks(under: empty).isEmpty)
  }

  func testLongListsAreTruncatedRatherThanRejected() {
    // CarPlay refuses an over-long list outright. A car showing the first
    // hundred albums is usable; a car showing an error is not.
    let many = (0..<250).map { BrowseNode(id: "a\($0)", title: "Album \($0)") }
    let node = BrowseNode(id: "albums", title: "Albums", children: many)
    let items = BrowseTree.items(of: node)
    XCTAssertEqual(items.count, BrowseTree.maxItemsPerList)
    XCTAssertEqual(items.first?.id, "a0")
  }

  func testShortListsAreLeftAlone() {
    XCTAssertEqual(BrowseTree.items(of: library()).count, 2)
  }

  func testTheCarsOwnLimitWinsWhenItIsSmaller() {
    // Some cars allow twelve rows while moving and refuse a longer list.
    let many = (0..<50).map { BrowseNode(id: "a\($0)", title: "Album \($0)") }
    let node = BrowseNode(id: "albums", title: "Albums", children: many)
    XCTAssertEqual(BrowseTree.items(of: node, limit: 12).count, 12)
    XCTAssertEqual(BrowseTree.items(of: node, limit: 500).count, 50)
  }

  func testTheRootIsTabsOnlyWhenEveryEntryIsAFolderAndTheyFit() {
    let folder = { (id: String) in BrowseNode(id: id, title: id, children: [BrowseNode(id: "\(id)/x", title: "x")]) }
    let four = BrowseNode(id: "root", title: "L", children: ["a", "b", "c", "d"].map(folder))
    XCTAssertTrue(BrowseTree.drawsAsTabs(four, maximumTabs: 4))
    XCTAssertFalse(BrowseTree.drawsAsTabs(four, maximumTabs: 3))
    XCTAssertFalse(BrowseTree.drawsAsTabs(BrowseNode(id: "root", title: "L", children: [folder("a")]), maximumTabs: 4))
    let withLeaf = BrowseNode(id: "root", title: "L", children: [folder("a"), BrowseNode(id: "t", title: "t", playable: track("t"))])
    XCTAssertFalse(BrowseTree.drawsAsTabs(withLeaf, maximumTabs: 4))
    XCTAssertEqual(BrowseTree.tabIds(of: four), ["a", "b", "c", "d"])
  }

  func testIconsAndActionsSurviveTheRebuild() {
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "albums", title: "Albums", icon: .albums),
      .init(id: "albums/shuffle", parentId: "albums", title: "Shuffle", action: .shuffle),
    ])
    XCTAssertEqual(built.children.first?.icon, .albums)
    XCTAssertEqual(built.children.first?.children.first?.action, .shuffle)
    XCTAssertTrue(built.children.first?.children.first?.isLeaf ?? false)
  }

  // MARK: - Building from the flat form

  func testRebuildsNestingFromParentReferences() {
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "albums", title: "Albums"),
      .init(id: "album:1", parentId: "albums", title: "First"),
      .init(id: "t:1", parentId: "album:1", title: "One", playable: track("t:1")),
    ])
    XCTAssertEqual(BrowseTree.path(to: "t:1", in: built)?.map(\.id),
                   ["root", "albums", "album:1", "t:1"])
  }

  func testPreservesTheOrderEntriesArrivedIn() {
    // Album order is a decision the host already made; re-sorting here would
    // silently override it.
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "c", title: "Third"),
      .init(id: "a", title: "First"),
      .init(id: "b", title: "Second"),
    ])
    XCTAssertEqual(built.children.map(\.id), ["c", "a", "b"])
  }

  func testOrphansAreDroppedRatherThanPromoted() {
    // A half-loaded library should show less, not show a flat pile of tracks
    // where albums were expected.
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "albums", title: "Albums"),
      .init(id: "stray", parentId: "missing", title: "Nowhere"),
    ])
    XCTAssertEqual(built.children.map(\.id), ["albums"])
    XCTAssertNil(BrowseTree.find("stray", in: built))
  }

  func testDuplicateIdsKeepTheFirst() {
    // The alternative is an id that finds something other than what the car
    // showed under it.
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "a", title: "Original"),
      .init(id: "a", title: "Impostor"),
    ])
    XCTAssertEqual(built.children.count, 1)
    XCTAssertEqual(built.children.first?.title, "Original")
  }

  func testAMalformedParentChainCannotRecurseForever() {
    // A cycle cannot be reached from the root, so it simply vanishes — which
    // is the right outcome for code running while someone is driving.
    let built = BrowseTree.build(title: "Library", from: [
      .init(id: "a", parentId: "b", title: "A"),
      .init(id: "b", parentId: "a", title: "B"),
    ])
    XCTAssertTrue(built.children.isEmpty)
  }

  func testAnEmptyLibraryBuildsAnEmptyRoot() {
    let built = BrowseTree.build(title: "Library", from: [])
    XCTAssertTrue(built.children.isEmpty)
    XCTAssertEqual(built.title, "Library")
  }
}
