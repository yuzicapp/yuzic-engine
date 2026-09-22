package dev.yuzic.engine

/**
 * The id the root is served under, whether it is the host's tree or the empty
 * stand-in from before there was one.
 *
 * One id for both because a car subscribes to the root it was given. It used
 * to be `yuzic:root` for the stand-in and `root` for the real tree, so a car
 * that connected before `setBrowseTree` stayed subscribed to an id the tree
 * never contained. `root` is what iOS's `BrowseTree.build` uses too.
 */
internal const val BROWSE_ROOT_ID = "root"

/**
 * The node the car is told about when it asks for [id] itself, rather than
 * for its children, or null for an id that is not in the tree.
 *
 * With no tree yet, the root is the empty stand-in, not missing. This is the
 * question Media3 asks before it accepts a subscription: its default
 * `onSubscribe` calls `onGetItem` for the parent and refuses unless that is a
 * browsable item. Answering the root with an error made every car that opened
 * the app before `setBrowseTree` unsubscribed, so the `notifyChildrenChanged`
 * sent when the tree arrived reached nobody, and the library stayed empty
 * until the driver left and came back.
 */
internal fun browseNode(root: BrowseNodeRecord?, id: String): BrowseNodeRecord? {
  if (root == null) return if (id == BROWSE_ROOT_ID) standInRoot() else null
  return findBrowseNode(root, id)
}

/** The root served before the host has set a tree: browsable and empty. */
internal fun standInRoot() = BrowseNodeRecord().apply {
  id = BROWSE_ROOT_ID
  title = "yuzic"
  children = emptyList()
}

/**
 * What the car gets when it opens [parentId]: its children, or null for an id
 * that is not in the tree.
 *
 * With no tree yet, the root has no children rather than not existing. The
 * difference is what the driver sees: Android Automotive shows an error
 * result as "isn't working right now", and an empty list as a library that
 * has not loaded yet, which is the truth.
 */
internal fun browseChildren(root: BrowseNodeRecord?, parentId: String): List<BrowseNodeRecord>? {
  if (root == null) return if (parentId == BROWSE_ROOT_ID) emptyList() else null
  return findBrowseNode(root, parentId)?.let { it.children.orEmpty() }
}

/**
 * Depth-first walk of the tree the host handed over.
 *
 * Linear, and deliberately so for now: the tree arrives whole and is usually
 * a few hundred nodes. If it grows to the point where this shows up, the fix
 * is an id→node index built once in `setBrowseTree`, not a cleverer walk.
 */
internal fun findBrowseNode(node: BrowseNodeRecord?, id: String): BrowseNodeRecord? {
  if (node == null) return null
  if (node.id == id) return node
  node.children?.forEach { child ->
    findBrowseNode(child, id)?.let { return it }
  }
  return null
}
