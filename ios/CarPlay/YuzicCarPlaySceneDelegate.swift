#if canImport(CarPlay)
import CarPlay
import UIKit

/**
 The CarPlay screen.

 Deliberately the thinnest file in the engine. Everything it decides — what a
 selection means, how deep the tree goes, what gets truncated, when the root is
 tabs — lives in `BrowseTree` and `CarPlayCoordinator`, where it can be tested
 on a Mac with no car and no phone. What is left here is drawing, and drawing
 is the only part that genuinely needs the hardware.

 The app has to name this class in its Info.plist scene configuration for the
 system to ever construct it; the config plugin writes that entry. It is
 `@objc` and explicitly named for the same reason — the system looks it up by
 string, and Swift's mangled name is not the string in the plist.
 */
@objc(YuzicCarPlaySceneDelegate)
public final class YuzicCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate,
  CPNowPlayingTemplateObserver {

  private var interfaceController: CPInterfaceController?
  private var coordinator: CarPlayCoordinator { .shared }

  /**
   Kept for the life of the scene, not per template.

   CarPlay rebuilds a template on every push and on every root change, so a
   loader owned by `listTemplate` would start empty each time and re-fetch the
   same fifty covers on every navigation, over a phone connection, while
   someone is driving.
   */
  private let artwork = BrowseArtworkLoader()

  /**
   What the root was last drawn as. A new tree of the same shape refreshes the
   lists already on screen in place; any other change rebuilds. Rebuilding
   pops every screen the driver had pushed, and hosts re-send the tree for all
   kinds of reasons, so doing it on every change took the driver back to the
   top while they were choosing.
   */
  private enum Shape: Equatable {
    case placeholder
    case list
    case tabs([String])
  }
  private var drawnShape: Shape?

  /// Every list the car is showing or could go back to, by the node it shows.
  private let lists = NSMapTable<NSString, CPListTemplate>.strongToWeakObjects()

  /// Rows that play a track, by the track's id, so the playing one can be marked.
  private var rowsByTrack: [String: NSHashTable<CPListItem>] = [:]

  public func templateApplicationScene(
    _ scene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController

    // The now-playing screen can be shown by the system at any moment, from
    // the car's own home screen, so it is configured here rather than when
    // something is first played.
    let nowPlaying = CPNowPlayingTemplate.shared
    nowPlaying.isUpNextButtonEnabled = true
    nowPlaying.isAlbumArtistButtonEnabled = false
    nowPlaying.add(self)

    interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)

    // A library that finishes loading after the car connects should appear on
    // its own. Without this the driver sees an empty list and has to back out
    // and re-enter to get a populated one, which is both baffling and exactly
    // the kind of fiddling nobody should do while moving.
    coordinator.setRootChangeHandler { [weak self] in self?.treeChanged() }
    coordinator.setNowPlayingChangeHandler { [weak self] in self?.markNowPlaying() }
  }

  public func templateApplicationScene(
    _ scene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    coordinator.setRootChangeHandler(nil)
    coordinator.setNowPlayingChangeHandler(nil)
    CPNowPlayingTemplate.shared.remove(self)
    self.interfaceController = nil
    drawnShape = nil
    lists.removeAllObjects()
    rowsByTrack.removeAll()
  }

  // MARK: - Templates

  private func shape(of root: BrowseNode?) -> Shape {
    guard let root else { return .placeholder }
    return BrowseTree.drawsAsTabs(root, maximumTabs: CPTabBarTemplate.maximumTabCount)
      ? .tabs(BrowseTree.tabIds(of: root))
      : .list
  }

  private func rootTemplate() -> CPTemplate {
    let root = coordinator.root
    drawnShape = shape(of: root)
    lists.removeAllObjects()
    rowsByTrack.removeAll()

    guard let root else {
      // Not an error state — the host has simply not pushed a tree yet, which
      // on a cold launch from the car lasts only until the app's JavaScript
      // has started. An empty list says so quietly; an alert would be
      // alarming and useless at sixty miles an hour.
      return CPListTemplate(title: Self.appName, sections: [])
    }

    guard case .tabs = drawnShape else { return listTemplate(for: root) }
    let tabs = root.children.map { entry -> CPListTemplate in
      let list = listTemplate(for: entry)
      list.tabTitle = entry.title
      list.tabImage = Self.symbol(for: entry.icon)
      return list
    }
    return CPTabBarTemplate(templates: tabs)
  }

  private func treeChanged() {
    guard let controller = interfaceController else { return }
    let root = coordinator.root
    let next = shape(of: root)
    guard let root, next != .placeholder, next == drawnShape else {
      controller.setRootTemplate(rootTemplate(), animated: false, completion: nil)
      return
    }
    // Same shape: every list still around is refreshed where it stands. A
    // list whose node is gone keeps what it showed, and a tap on one of its
    // rows finds nothing and plays nothing, which is the same rule a stale id
    // follows everywhere else.
    rowsByTrack.removeAll()
    let enumerator = lists.keyEnumerator()
    while let key = enumerator.nextObject() as? NSString {
      guard let list = lists.object(forKey: key), let node = BrowseTree.find(key as String, in: root) else { continue }
      list.updateSections(sections(for: node))
      if case .tabs = next, root.children.contains(where: { $0.id == node.id }) {
        list.tabTitle = node.title
      }
    }
  }

  private func listTemplate(for node: BrowseNode) -> CPListTemplate {
    let list = CPListTemplate(title: node.title, sections: sections(for: node))
    lists.setObject(list, forKey: node.id as NSString)
    return list
  }

  private func sections(for node: BrowseNode) -> [CPListSection] {
    // The car's own limit, read each time: it can change while connected,
    // when a car limits lists once it starts moving.
    let items = BrowseTree.items(of: node, limit: CPListTemplate.maximumItemCount).map(item(for:))
    return [CPListSection(items: items)]
  }

  private func item(for child: BrowseNode) -> CPListItem {
    let item = CPListItem(text: child.title, detailText: child.subtitle)
    // A chevron on a branch, nothing on a leaf. The driver should be able to
    // tell at a glance whether tapping opens or plays.
    item.accessoryType = child.isLeaf ? .none : .disclosureIndicator
    item.handler = { [weak self] _, completion in
      self?.handle(child, completion: completion)
    }

    if child.action == .shuffle {
      item.setImage(UIImage(systemName: "shuffle"))
      return item
    }

    if let trackId = child.playable?.id {
      let rows = rowsByTrack[trackId] ?? NSHashTable<CPListItem>.weakObjects()
      rows.add(item)
      rowsByTrack[trackId] = rows
      item.playingIndicatorLocation = .trailing
      item.isPlaying = trackId == coordinator.nowPlayingId
    }
    loadArtwork(child, into: item)
    return item
  }

  /// Move the playing mark to the row of the track that is playing now.
  private func markNowPlaying() {
    let playing = coordinator.nowPlayingId
    for (trackId, rows) in rowsByTrack {
      for item in rows.allObjects {
        item.isPlaying = trackId == playing
      }
    }
    rowsByTrack = rowsByTrack.filter { $0.value.count > 0 }
  }

  /**
   Put a row's cover on it once it arrives.

   Asynchronous and unordered on purpose: the list is shown immediately with
   whatever art is already cached, and the rest fills in. Making the template
   wait would hold the screen blank on a slow connection, which is the worse
   trade for someone who has just plugged in and wants to pick something.

   The item is held weakly. A driver can push and pop templates faster than a
   request completes, and a strong reference here would keep whole screens of
   rows alive for as long as a stalled server took to answer.
   */
  private func loadArtwork(_ node: BrowseNode, into item: CPListItem) {
    guard node.artworkUri?.isEmpty == false else { return }
    artwork.image(for: node) { [weak item] data in
      guard let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async { item?.setImage(image) }
    }
  }

  private func handle(_ node: BrowseNode, completion: @escaping () -> Void) {
    if node.isLeaf {
      coordinator.select(node.id)
      showNowPlaying(completion: completion)
      return
    }
    interfaceController?.pushTemplate(listTemplate(for: node), animated: true) { _, _ in
      completion()
    }
  }

  /**
   Playing should land on the now-playing screen, which CarPlay provides from
   the now-playing info the engine already publishes — there is no second copy
   of the metadata to keep in sync here.

   Pushing the shared template when it is already on the stack is refused, so a
   driver who went back from it and chose something else is returned to it.
   */
  private func showNowPlaying(completion: @escaping () -> Void) {
    guard let controller = interfaceController else {
      completion()
      return
    }
    let nowPlaying = CPNowPlayingTemplate.shared
    if controller.topTemplate === nowPlaying {
      completion()
    } else if controller.templates.contains(where: { $0 === nowPlaying }) {
      controller.pop(to: nowPlaying, animated: true) { _, _ in completion() }
    } else {
      controller.pushTemplate(nowPlaying, animated: true) { _, _ in completion() }
    }
  }

  // MARK: - Up Next

  /**
   The queue after the playing track, from the now-playing screen.

   Read from the engine when asked rather than kept in step, since it is shown
   rarely and is right by construction when read. A row jumps to that track.
   */
  public func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    guard let controller = interfaceController, let queue = coordinator.queue else { return }
    let rows = queue.upcoming(limit: CPListTemplate.maximumItemCount).map { entry -> CPListItem in
      let item = CPListItem(text: entry.track.title, detailText: entry.track.artist)
      item.handler = { [weak self] _, completion in
        self?.coordinator.skip(to: entry.index)
        self?.interfaceController?.popTemplate(animated: true) { _, _ in completion() }
      }
      loadArtwork(
        BrowseNode(
          id: entry.track.id, title: entry.track.title,
          artworkUri: entry.track.artworkUri, artworkHeaders: entry.track.artworkHeaders
        ),
        into: item
      )
      return item
    }
    let list = CPListTemplate(title: nowPlayingTemplate.upNextTitle, sections: [CPListSection(items: rows)])
    controller.pushTemplate(list, animated: true, completion: nil)
  }

  public func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {}

  // MARK: - Names and symbols

  private static var appName: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? ""
  }

  /// The SF Symbol for a tab. Nil for an icon the host did not name, which
  /// CarPlay draws as a tab with its title alone.
  private static func symbol(for icon: BrowseIcon?) -> UIImage? {
    let name: String
    switch icon {
    case .recent: name = "clock"
    case .favorites: name = "heart"
    case .albums: name = "square.stack"
    case .artists: name = "music.mic"
    case .playlists: name = "music.note.list"
    case .downloads: name = "arrow.down.circle"
    case .radio: name = "dot.radiowaves.left.and.right"
    case .library: name = "music.note"
    case nil: return nil
    }
    return UIImage(systemName: name)
  }
}
#endif
