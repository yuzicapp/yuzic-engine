#if canImport(CarPlay)
import CarPlay
import UIKit

/**
 The CarPlay screen.

 Deliberately the thinnest file in the engine. Everything it decides — what a
 selection means, how deep the tree goes, what gets truncated — lives in
 `BrowseTree` and `CarPlayCoordinator`, where it can be tested on a Mac with no
 car and no phone. What is left here is drawing, and drawing is the only part
 that genuinely needs the hardware.

 The app has to name this class in its Info.plist scene configuration for the
 system to ever construct it; the config plugin writes that entry. It is
 `@objc` and explicitly named for the same reason — the system looks it up by
 string, and Swift's mangled name is not the string in the plist.
 */
@objc(YuzicCarPlaySceneDelegate)
public final class YuzicCarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

  private var interfaceController: CPInterfaceController?

  /**
   Kept for the life of the scene, not per template.

   CarPlay rebuilds a template on every push and on every root change, so a
   loader owned by `listTemplate` would start empty each time and re-fetch the
   same fifty covers on every navigation, over a phone connection, while
   someone is driving.
   */
  private let artwork = BrowseArtworkLoader()

  public func templateApplicationScene(
    _ scene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    self.interfaceController = interfaceController
    interfaceController.setRootTemplate(rootTemplate(), animated: false, completion: nil)

    // A library that finishes loading after the car connects should appear on
    // its own. Without this the driver sees an empty list and has to back out
    // and re-enter to get a populated one, which is both baffling and exactly
    // the kind of fiddling nobody should do while moving.
    CarPlayCoordinator.shared.setRootChangeHandler { [weak self] in
      guard let self, let controller = self.interfaceController else { return }
      // A new tree may not contain the tracks the old covers belonged to.
      self.artwork.clear()
      controller.setRootTemplate(self.rootTemplate(), animated: false, completion: nil)
    }
  }

  public func templateApplicationScene(
    _ scene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    CarPlayCoordinator.shared.setRootChangeHandler(nil)
    self.interfaceController = nil
  }

  // MARK: - Templates

  private func rootTemplate() -> CPTemplate {
    guard let root = CarPlayCoordinator.shared.root else {
      // Not an error state — the host has simply not pushed a tree yet. An
      // empty list says so quietly; an alert would be alarming and useless at
      // sixty miles an hour.
      return CPListTemplate(title: "Library", sections: [])
    }
    return listTemplate(for: root)
  }

  private func listTemplate(for node: BrowseNode) -> CPListTemplate {
    let items = BrowseTree.items(of: node).map { child -> CPListItem in
      let item = CPListItem(text: child.title, detailText: child.subtitle)
      // A chevron on a branch, nothing on a leaf. The driver should be able to
      // tell at a glance whether tapping opens or plays.
      item.accessoryType = child.isLeaf ? .none : .disclosureIndicator
      item.handler = { [weak self] _, completion in
        self?.handle(child, completion: completion)
      }
      loadArtwork(child, into: item)
      return item
    }
    return CPListTemplate(title: node.title, sections: [CPListSection(items: items)])
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
      CarPlayCoordinator.shared.select(node.id)
      // Playing should land on the now-playing screen, which CarPlay provides
      // from the now-playing info the engine already publishes — there is no
      // second copy of the metadata to keep in sync here.
      interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, _ in
        completion()
      }
      return
    }
    interfaceController?.pushTemplate(listTemplate(for: node), animated: true) { _, _ in
      completion()
    }
  }
}
#endif
