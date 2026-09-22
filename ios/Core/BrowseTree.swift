import Foundation

/**
 The tree CarPlay and Android Auto browse.

 Handed over whole, for the same reason the queue is native: the car can ask
 while the app's JavaScript is suspended, and a tree that has to be fetched from
 JS is a tree that is sometimes empty at exactly the moment someone is driving.

 The model here is deliberately plain data with no CarPlay types in it. The
 template building is a separate, guarded file — this way the shape, the limits
 and the lookup can be tested on any machine, and only the drawing needs a car.
 */
public struct BrowseNode: Equatable {
  public let id: String
  public let title: String
  public let subtitle: String?
  public let artworkUri: String?
  /**
   Sent only while fetching `artworkUri`, exactly as `Track.artworkHeaders` is
   for the now-playing cover.

   Without it a header-authenticated server answers 401 for every browse
   thumbnail, and the car shows a list of blank squares while the same album's
   cover appears perfectly on the now-playing screen. Headers rather than a
   signed URL because a browse tree is held for the life of the process and
   pushed to the car in advance — a credential baked into the URL outlives the
   session that issued it.
   */
  public let artworkHeaders: [String: String]
  public let children: [BrowseNode]
  /// Present on a leaf: what to play when it is chosen.
  public let playable: Track?
  /// A top-level entry's tab icon. See `BrowseNode.icon` in src/types.ts.
  public let icon: BrowseIcon?
  /// A row that does something rather than playing one thing. See `BrowseAction`.
  public let action: BrowseAction?

  public init(
    id: String,
    title: String,
    subtitle: String? = nil,
    artworkUri: String? = nil,
    artworkHeaders: [String: String] = [:],
    children: [BrowseNode] = [],
    playable: Track? = nil,
    icon: BrowseIcon? = nil,
    action: BrowseAction? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.artworkUri = artworkUri
    self.artworkHeaders = artworkHeaders
    self.children = children
    self.playable = playable
    self.icon = icon
    self.action = action
  }

  /// A leaf plays when chosen, an action row included; a branch opens.
  public var isLeaf: Bool { children.isEmpty }
}

/**
 The icons a top-level entry may ask for. Raw values are the strings
 `BrowseIcon` in src/types.ts allows; one this build does not know is dropped
 rather than guessed at, and the tab is drawn without an icon.
 */
public enum BrowseIcon: String, Equatable {
  case recent, favorites, albums, artists, playlists, downloads, radio, library
}

/**
 What an action row does. `shuffle` plays the tracks beside it in random
 order: the one thing a driver most wants from an album or a playlist, and
 cannot build by hand while moving.

 Deliberately no `layout` on iOS. Android Auto can draw a folder's children
 as a grid; CarPlay's audio lists are rows with artwork, which is the right
 shape for a car screen anyway, so the hint is accepted on the bridge and has
 nothing to do here.
 */
public enum BrowseAction: String, Equatable {
  case shuffle
}

public enum BrowseTree {

  /**
   CarPlay refuses a list longer than this, and Apple's guidance is stricter
   still while driving. A library of ten thousand tracks handed over whole is
   not a browsing experience anyway — the host is expected to shape the tree
   into something navigable, and this is the backstop for when it does not.

   Truncating beats throwing: a car showing the first hundred albums is usable,
   a car showing an error is not.
   */
  public static let maxItemsPerList = 100

  /// Depth-first lookup by id. What a selection callback resolves against.
  public static func find(_ id: String, in root: BrowseNode) -> BrowseNode? {
    if root.id == id { return root }
    for child in root.children {
      if let found = find(id, in: child) { return found }
    }
    return nil
  }

  /// The path from the root to `id`, so a car can rebuild its navigation stack
  /// after the app is relaunched behind it — which happens routinely, since
  /// the system kills backgrounded apps and the car keeps its place.
  public static func path(to id: String, in root: BrowseNode) -> [BrowseNode]? {
    if root.id == id { return [root] }
    for child in root.children {
      if let tail = path(to: id, in: child) { return [root] + tail }
    }
    return nil
  }

  /**
   The children a list should show, capped.

   `limit` is the car's own, which CarPlay reports per connection and which
   some cars set far below this backstop (twelve, in a car that limits lists
   while moving). A list past the car's limit is refused outright, so the
   smaller of the two wins.
   */
  public static func items(of node: BrowseNode, limit: Int = maxItemsPerList) -> [BrowseNode] {
    Array(node.children.prefix(max(0, min(limit, maxItemsPerList))))
  }

  /**
   Whether the root should be drawn as tabs: two or more top-level entries,
   every one of them a folder, and no more than the car allows. Otherwise a
   single list, which is also the answer for a tree with one entry, where a tab
   bar of one tab is a title with extra chrome.
   */
  public static func drawsAsTabs(_ root: BrowseNode, maximumTabs: Int) -> Bool {
    let entries = root.children
    return entries.count >= 2 && entries.count <= maximumTabs && entries.allSatisfy { !$0.isLeaf }
  }

  /// Ids of the top-level entries, in order. Two trees with the same answer can
  /// be refreshed in place rather than rebuilt, which keeps the driver where
  /// they were.
  public static func tabIds(of root: BrowseNode) -> [String] {
    root.children.map(\.id)
  }

  // MARK: - Building

  /**
   One node as it arrives from JavaScript: flat, with a parent reference.

   The tree is not sent as a tree because a recursive `Record` is not something
   Expo's bridge can decode — `@Field` cannot describe a type containing itself.
   Flattening on the way over and rebuilding here costs one pass and keeps the
   shape honest, which is better than the usual alternative of sending JSON in
   a string and parsing it twice.
   */
  public struct FlatNode {
    public let id: String
    /// `nil` means a top-level entry.
    public let parentId: String?
    public let title: String
    public let subtitle: String?
    public let artworkUri: String?
    /// Sent only while fetching `artworkUri` — see `BrowseNode.artworkHeaders`.
    public let artworkHeaders: [String: String]
    public let playable: Track?
    public let icon: BrowseIcon?
    public let action: BrowseAction?

    public init(
      id: String, parentId: String? = nil, title: String,
      subtitle: String? = nil, artworkUri: String? = nil,
      artworkHeaders: [String: String] = [:], playable: Track? = nil,
      icon: BrowseIcon? = nil, action: BrowseAction? = nil
    ) {
      self.id = id
      self.parentId = parentId
      self.title = title
      self.subtitle = subtitle
      self.artworkUri = artworkUri
      self.artworkHeaders = artworkHeaders
      self.playable = playable
      self.icon = icon
      self.action = action
    }
  }

  /// How deep a tree may go. Not a real limit anyone should hit — it is a
  /// stop against a malformed parent chain turning into unbounded recursion,
  /// in code that runs while someone is driving.
  static let maxDepth = 16

  /**
   Rebuild the tree, preserving the order entries arrived in.

   Deliberately forgiving. A node whose parent is missing is dropped rather
   than promoted to the top level: a library that half-loaded should show less,
   not show a flat pile of tracks where albums were expected. Duplicate ids
   keep the first, since the alternative is a node reachable by an id that
   finds something else.
   */
  public static func build(title: String, rootId: String = "root", from flat: [FlatNode]) -> BrowseNode {
    var seen = Set<String>()
    var childrenByParent: [String: [FlatNode]] = [:]
    var roots: [FlatNode] = []

    for node in flat where !seen.contains(node.id) {
      seen.insert(node.id)
      if let parentId = node.parentId {
        childrenByParent[parentId, default: []].append(node)
      } else {
        roots.append(node)
      }
    }

    func assemble(_ node: FlatNode, depth: Int) -> BrowseNode {
      let children = depth >= maxDepth
        ? []
        : (childrenByParent[node.id] ?? []).map { assemble($0, depth: depth + 1) }
      return BrowseNode(
        id: node.id,
        title: node.title,
        subtitle: node.subtitle,
        artworkUri: node.artworkUri,
        artworkHeaders: node.artworkHeaders,
        children: children,
        playable: node.playable,
        icon: node.icon,
        action: node.action
      )
    }

    return BrowseNode(
      id: rootId,
      title: title,
      children: roots.map { assemble($0, depth: 1) }
    )
  }

  /// Every playable track under a node, in order — what "play this album"
  /// means when a branch rather than a leaf is chosen.
  public static func tracks(under node: BrowseNode) -> [Track] {
    if let playable = node.playable { return [playable] }
    return node.children.flatMap { tracks(under: $0) }
  }
}
