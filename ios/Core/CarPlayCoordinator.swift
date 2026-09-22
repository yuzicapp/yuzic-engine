import Foundation

/**
 The handover point between the engine and the car.

 A singleton, which is not a choice so much as an admission: CarPlay hands the
 app a scene delegate it constructs itself, at a moment the app does not choose,
 and there is nowhere to inject anything. The delegate has to find the tree and
 the play callback from somewhere global.

 Everything the car needs lives here so it is available even when the app's
 JavaScript is suspended — which it usually is. Someone starts driving, the
 phone connects, the car asks for a root list, and there is no JS runtime awake
 to build one. A tree pushed down in advance is a tree that is there.
 */
public final class CarPlayCoordinator {

  public static let shared = CarPlayCoordinator()

  /// What the car's "Up Next" list shows: the queue, and which entry is playing.
  public struct QueueSnapshot: Equatable {
    public let tracks: [Track]
    public let activeIndex: Int

    public init(tracks: [Track], activeIndex: Int) {
      self.tracks = tracks
      self.activeIndex = activeIndex
    }

    /// The tracks after the playing one, each with its index in the queue.
    public func upcoming(limit: Int) -> [(index: Int, track: Track)] {
      guard activeIndex + 1 < tracks.count, limit > 0 else { return [] }
      let range = (activeIndex + 1)..<min(tracks.count, activeIndex + 1 + limit)
      return range.map { ($0, tracks[$0]) }
    }
  }

  private let lock = NSLock()
  private var rootValue: BrowseNode?
  private var onPlayValue: (([Track], Int) -> Void)?
  private var onRootChangeValue: (() -> Void)?
  private var nowPlayingValue: String?
  private var onNowPlayingChangeValue: (() -> Void)?
  private var queueValue: (() -> QueueSnapshot)?
  private var onSkipValue: ((Int) -> Void)?
  /// Injected so a test can pin the order; `shuffled()` everywhere else.
  var shuffle: ([Track]) -> [Track] = { $0.shuffled() }

  private init() {}

  public var root: BrowseNode? {
    lock.lock(); defer { lock.unlock() }
    return rootValue
  }

  /**
   Replace the tree. Notifies the scene, if one is connected, so a library
   that finishes loading after the car connects still shows up rather than
   leaving an empty list until the driver backs out and re-enters.

   A tree equal to the one already held changes nothing and notifies nobody.
   Hosts re-send the same library often (a setting changes, the network comes
   back), and every notification is the car redrawing under the driver's
   finger.
   */
  public func setRoot(_ node: BrowseNode?) {
    lock.lock()
    guard rootValue != node else {
      lock.unlock()
      return
    }
    rootValue = node
    let notify = onRootChangeValue
    lock.unlock()
    DispatchQueue.main.async { notify?() }
  }

  public func setPlayHandler(_ handler: (([Track], Int) -> Void)?) {
    lock.lock(); onPlayValue = handler; lock.unlock()
  }

  public func setRootChangeHandler(_ handler: (() -> Void)?) {
    lock.lock(); onRootChangeValue = handler; lock.unlock()
  }

  /// The id of the track playing now, so the car can mark its row.
  public var nowPlayingId: String? {
    lock.lock(); defer { lock.unlock() }
    return nowPlayingValue
  }

  public func setNowPlaying(_ id: String?) {
    lock.lock()
    guard nowPlayingValue != id else {
      lock.unlock()
      return
    }
    nowPlayingValue = id
    let notify = onNowPlayingChangeValue
    lock.unlock()
    DispatchQueue.main.async { notify?() }
  }

  public func setNowPlayingChangeHandler(_ handler: (() -> Void)?) {
    lock.lock(); onNowPlayingChangeValue = handler; lock.unlock()
  }

  /// Where the car reads the queue from, and how it jumps within it. Set by
  /// the engine once it exists; nil before, which the car shows as no queue.
  public func setQueueSource(_ source: (() -> QueueSnapshot)?, skip: ((Int) -> Void)?) {
    lock.lock()
    queueValue = source
    onSkipValue = skip
    lock.unlock()
  }

  public var queue: QueueSnapshot? {
    lock.lock()
    let source = queueValue
    lock.unlock()
    return source?()
  }

  public func skip(to index: Int) {
    lock.lock()
    let skip = onSkipValue
    lock.unlock()
    skip?(index)
  }

  /// What a selection in the car means: play everything under the chosen node,
  /// starting at the chosen one.
  public func select(_ id: String) {
    lock.lock()
    let root = rootValue
    let play = onPlayValue
    lock.unlock()

    guard let root, let node = BrowseTree.find(id, in: root) else { return }
    let parent = BrowseTree.path(to: id, in: root).flatMap { $0.count >= 2 ? $0[$0.count - 2] : nil }

    if node.action == .shuffle {
      // Every track beside the shuffle row, in random order.
      let tracks = parent.map { BrowseTree.tracks(under: $0) } ?? []
      if !tracks.isEmpty { play?(shuffle(tracks), 0) }
      return
    }

    if node.playable != nil, let parent {
      // A track chosen inside an album should queue the album and start there,
      // not play one track and stop. The parent is the context the driver
      // thinks they are in. Located by row, not by track id: the same track
      // can appear twice in a playlist, and the one tapped is where to start.
      let rows = parent.children.filter { $0.playable != nil }
      let tracks = rows.compactMap(\.playable)
      let index = rows.firstIndex { $0.id == id } ?? 0
      play?(tracks, index)
      return
    }

    let tracks = BrowseTree.tracks(under: node)
    if !tracks.isEmpty { play?(tracks, 0) }
  }
}
