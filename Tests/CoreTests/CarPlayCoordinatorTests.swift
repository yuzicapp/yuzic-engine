import XCTest
@testable import YuzicEngineCore

/**
 What a tap in the car actually does.

 This is the whole reason the coordinator holds no CarPlay types: the decision
 worth getting right — that choosing a track inside an album queues the album —
 is testable here, and the scene delegate is left with nothing but drawing.
 */
final class CarPlayCoordinatorTests: XCTestCase {

  private func track(_ id: String) -> Track {
    Track(id: id, uri: "https://example.test/\(id)", title: id)
  }

  private func library() -> BrowseNode {
    BrowseNode(id: "root", title: "Library", children: [
      BrowseNode(id: "album:1", title: "First", children: [
        BrowseNode(id: "t:1", title: "One", playable: track("t:1")),
        BrowseNode(id: "t:2", title: "Two", playable: track("t:2")),
        BrowseNode(id: "t:3", title: "Three", playable: track("t:3")),
      ]),
      BrowseNode(id: "empty", title: "Nothing here"),
    ])
  }

  /// Captures what the engine was asked to play.
  private func coordinator() -> (CarPlayCoordinator, () -> ([Track], Int)?) {
    let coordinator = CarPlayCoordinator.shared
    var captured: ([Track], Int)?
    coordinator.setRoot(library())
    coordinator.setPlayHandler { tracks, index in captured = (tracks, index) }
    return (coordinator, { captured })
  }

  override func tearDown() {
    // Order matters, and finding that out was the point. The coordinator is a
    // singleton — CarPlay constructs its scene delegate itself, so there is
    // nowhere to inject one — which means state survives between tests.
    // Clearing the root first fires the *previous* test's change handler
    // during teardown, and an expectation fulfilled twice is a crash, not a
    // failure. Detach the handler before touching anything it observes.
    CarPlayCoordinator.shared.setRootChangeHandler(nil)
    CarPlayCoordinator.shared.setNowPlayingChangeHandler(nil)
    CarPlayCoordinator.shared.setPlayHandler(nil)
    CarPlayCoordinator.shared.setQueueSource(nil, skip: nil)
    CarPlayCoordinator.shared.setRoot(nil)
    CarPlayCoordinator.shared.setNowPlaying(nil)
    CarPlayCoordinator.shared.shuffle = { $0.shuffled() }
    super.tearDown()
  }

  func testChoosingATrackQueuesItsAlbumAndStartsThere() {
    // Playing one track and stopping is the wrong reading of a tap. The album
    // is the context the driver believes they are in, and they cannot pick a
    // follow-up track while driving.
    let (coordinator, captured) = self.coordinator()
    coordinator.select("t:2")
    let (tracks, index) = captured()!
    XCTAssertEqual(tracks.map(\.id), ["t:1", "t:2", "t:3"])
    XCTAssertEqual(index, 1)
  }

  func testChoosingAnAlbumPlaysItFromTheTop() {
    let (coordinator, captured) = self.coordinator()
    coordinator.select("album:1")
    let (tracks, index) = captured()!
    XCTAssertEqual(tracks.map(\.id), ["t:1", "t:2", "t:3"])
    XCTAssertEqual(index, 0)
  }

  func testChoosingAnEmptyNodePlaysNothing() {
    // Rather than clearing the queue and stopping whatever is currently on.
    let (coordinator, captured) = self.coordinator()
    coordinator.select("empty")
    XCTAssertNil(captured())
  }

  func testUnknownIdIsIgnored() {
    let (coordinator, captured) = self.coordinator()
    coordinator.select("nope")
    XCTAssertNil(captured())
  }

  func testSelectingWithNoTreeIsHarmless() {
    let coordinator = CarPlayCoordinator.shared
    coordinator.setRoot(nil)
    var called = false
    coordinator.setPlayHandler { _, _ in called = true }
    coordinator.select("t:1")
    XCTAssertFalse(called)
  }

  func testSettingTheRootNotifiesAConnectedScene() {
    // A library that loads after the car connects has to appear on its own;
    // otherwise the driver backs out and re-enters to refresh it.
    let coordinator = CarPlayCoordinator.shared
    let notified = expectation(description: "root change")
    coordinator.setRootChangeHandler { notified.fulfill() }
    coordinator.setRoot(library())
    wait(for: [notified], timeout: 1.0)
  }

  func testTheSameTreeAgainNotifiesNobody() {
    // Hosts re-send the library for all kinds of reasons, and every
    // notification is the car redrawing under the driver's finger.
    let coordinator = CarPlayCoordinator.shared
    coordinator.setRoot(library())
    let notified = expectation(description: "root change")
    notified.isInverted = true
    coordinator.setRootChangeHandler { notified.fulfill() }
    coordinator.setRoot(library())
    wait(for: [notified], timeout: 0.3)
  }

  func testAShuffleRowPlaysTheTracksBesideItShuffled() {
    let coordinator = CarPlayCoordinator.shared
    coordinator.shuffle = { $0.reversed() }
    coordinator.setRoot(BrowseNode(id: "root", title: "Library", children: [
      BrowseNode(id: "album:1", title: "First", children: [
        BrowseNode(id: "album:1/shuffle", title: "Shuffle", action: .shuffle),
        BrowseNode(id: "album:1/t:1", title: "One", playable: track("t:1")),
        BrowseNode(id: "album:1/t:2", title: "Two", playable: track("t:2")),
      ]),
    ]))
    var captured: ([Track], Int)?
    coordinator.setPlayHandler { captured = ($0, $1) }
    coordinator.select("album:1/shuffle")
    XCTAssertEqual(captured?.0.map(\.id), ["t:2", "t:1"])
    XCTAssertEqual(captured?.1, 0)
  }

  func testATrackListedTwiceStartsAtTheRowThatWasTapped() {
    // A playlist can hold the same song twice. Finding the start by track id
    // started at the first copy whichever was tapped.
    let coordinator = CarPlayCoordinator.shared
    coordinator.setRoot(BrowseNode(id: "root", title: "Library", children: [
      BrowseNode(id: "mix", title: "Mix", children: [
        BrowseNode(id: "mix/0", title: "One", playable: track("t:1")),
        BrowseNode(id: "mix/1", title: "Two", playable: track("t:2")),
        BrowseNode(id: "mix/2", title: "One again", playable: track("t:1")),
      ]),
    ]))
    var captured: ([Track], Int)?
    coordinator.setPlayHandler { captured = ($0, $1) }
    coordinator.select("mix/2")
    XCTAssertEqual(captured?.0.map(\.id), ["t:1", "t:2", "t:1"])
    XCTAssertEqual(captured?.1, 2)
  }

  func testTheNowPlayingMarkIsAnnouncedOnlyWhenItMoves() {
    let coordinator = CarPlayCoordinator.shared
    coordinator.setNowPlaying("t:1")
    let moved = expectation(description: "now playing change")
    coordinator.setNowPlayingChangeHandler { moved.fulfill() }
    coordinator.setNowPlaying("t:1")
    coordinator.setNowPlaying("t:2")
    wait(for: [moved], timeout: 1.0)
    XCTAssertEqual(coordinator.nowPlayingId, "t:2")
  }

  func testUpNextIsTheQueueAfterThePlayingTrack() {
    let snapshot = CarPlayCoordinator.QueueSnapshot(
      tracks: ["a", "b", "c", "d"].map(track), activeIndex: 1
    )
    XCTAssertEqual(snapshot.upcoming(limit: 10).map { $0.index }, [2, 3])
    XCTAssertEqual(snapshot.upcoming(limit: 1).map { $0.track.id }, ["c"])
    XCTAssertTrue(CarPlayCoordinator.QueueSnapshot(tracks: [track("a")], activeIndex: 0).upcoming(limit: 5).isEmpty)
  }

  func testAJumpFromUpNextReachesTheEngine() {
    let coordinator = CarPlayCoordinator.shared
    var skipped: Int?
    coordinator.setQueueSource({ .init(tracks: [], activeIndex: 0) }, skip: { skipped = $0 })
    coordinator.skip(to: 3)
    XCTAssertEqual(skipped, 3)
    coordinator.setQueueSource(nil, skip: nil)
    XCTAssertNil(coordinator.queue)
  }
}
