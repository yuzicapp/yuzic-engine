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

/** The same cap iOS uses, for the same reason: a bad parent id must not recurse forever. */
internal const val BROWSE_MAX_DEPTH = 16

/**
 * Rebuild the nested tree from the flat list, mirroring `BrowseTree.build`
 * in `ios/Core/BrowseTree.swift` rule for rule.
 *
 * The rules are the ones architecture.md §11 states, and each is a decision
 * rather than a detail:
 *
 * - **Duplicate ids keep the first.** Selection resolves by id, so the
 *   alternative is a car playing something other than what it displayed.
 * - **Orphans are dropped, not promoted.** A half-loaded library should show
 *   less, not show a flat pile of tracks where albums were expected. Falling
 *   out of the grouping rather than being handled: a node whose parent is
 *   not in `childrenByParent` is simply never assembled.
 * - **Depth is capped**, at the same 16 as iOS, so a tree that references
 *   itself through a bad parent id cannot recurse forever.
 */
internal fun buildBrowseTree(title: String, flat: List<FlatBrowseNodeRecord>): BrowseNodeRecord {
  val seen = mutableSetOf<String>()
  val childrenByParent = mutableMapOf<String, MutableList<FlatBrowseNodeRecord>>()
  val roots = mutableListOf<FlatBrowseNodeRecord>()

  for (node in flat) {
    if (!seen.add(node.id)) continue
    val parentId = node.parentId
    if (parentId != null) {
      childrenByParent.getOrPut(parentId) { mutableListOf() }.add(node)
    } else {
      roots.add(node)
    }
  }

  fun assemble(node: FlatBrowseNodeRecord, depth: Int): BrowseNodeRecord =
    BrowseNodeRecord().apply {
      id = node.id
      // Qualified: the enclosing function's `title` parameter is nearer in
      // scope than this record's field, and is a val.
      this.title = node.title
      subtitle = node.subtitle
      artworkUri = node.artworkUri
      artworkHeaders = node.artworkHeaders
      playable = node.playable
      layout = node.layout
      icon = node.icon
      action = node.action
      children = if (depth >= BROWSE_MAX_DEPTH) emptyList()
      else childrenByParent[node.id].orEmpty().map { assemble(it, depth + 1) }
    }

  return BrowseNodeRecord().apply {
    id = BROWSE_ROOT_ID
    this.title = title
    children = roots.map { assemble(it, 1) }
  }
}

/** The one action a row can carry today. See `BrowseNode.action` in src/types.ts. */
internal const val BROWSE_ACTION_SHUFFLE = "shuffle"

/**
 * What a car's selection plays: the tracks, in order, and where to start.
 *
 * A car hands over ids from the tree, and nothing else. Resolved here, against
 * the tree, rather than trusted, so a stale id plays nothing instead of
 * something else.
 *
 * - **A track chosen inside an album or playlist queues all of it and starts
 *   there**, as on iOS (docs/architecture.md §11): the album is the context
 *   the driver believes they are in, and they cannot pick a follow-up while
 *   moving.
 * - **A shuffle row plays the tracks beside it in random order.**
 * - **A folder chosen to play plays its tracks from the top.**
 * - **Several ids play as given**, from [startIndex], dropping any the tree
 *   does not know.
 *
 * Null when nothing chosen can be played. [shuffle] is a parameter so the
 * order can be pinned in a test.
 */
internal fun carSelection(
  root: BrowseNodeRecord?,
  ids: List<String>,
  startIndex: Int,
  shuffle: (List<TrackRecord>) -> List<TrackRecord> = { it.shuffled() },
): Pair<List<TrackRecord>, Int>? {
  if (root == null || ids.isEmpty()) return null
  if (ids.size == 1) {
    val id = ids.single()
    val node = findBrowseNode(root, id) ?: return null
    if (node.action == BROWSE_ACTION_SHUFFLE) {
      val tracks = findParentOf(root, id)?.children.orEmpty().mapNotNull { it.playable }
      return if (tracks.isEmpty()) null else shuffle(tracks) to 0
    }
    if (node.playable == null) {
      val tracks = node.children.orEmpty().mapNotNull { it.playable }
      return if (tracks.isEmpty()) null else tracks to 0
    }
    val siblings = findParentOf(root, id)?.children.orEmpty().filter { it.playable != null }
    val at = siblings.indexOfFirst { it.id == id }
    if (at < 0) return listOf(node.playable!!) to 0
    return siblings.map { it.playable!! } to at
  }
  val tracks = ids.mapNotNull { findBrowseNode(root, it)?.playable }
  if (tracks.isEmpty()) return null
  return tracks to startIndex.coerceIn(0, tracks.size - 1)
}

/**
 * The rows a search in the car shows, best first.
 *
 * Searched here, over the tree the host already pushed, because a car search
 * arrives exactly when a server may not answer and JavaScript may not be
 * running. It finds what the car can already browse, which is the promise a
 * search box inside the car makes.
 *
 * Every word of the query has to appear in the title or the subtitle, ignoring
 * case and accents, so "beatles abbey" finds Abbey Road by the Beatles. Rows
 * whose title matches rank above rows that match only by artist. Folders rank
 * above tracks on a tie, since "play Abbey Road" means the album. The same
 * track listed under two folders is shown once, and action rows never are.
 */
internal fun searchBrowseTree(root: BrowseNodeRecord?, query: String, limit: Int = 50): List<BrowseNodeRecord> {
  val words = searchWords(query)
  if (root == null || words.isEmpty()) return emptyList()

  data class Hit(val node: BrowseNodeRecord, val score: Int, val order: Int)
  val hits = mutableListOf<Hit>()
  val seenTracks = mutableSetOf<String>()
  val seenFolders = mutableSetOf<String>()
  var order = 0

  fun visit(node: BrowseNodeRecord, depth: Int) {
    if (depth > BROWSE_MAX_DEPTH) return
    node.children.orEmpty().forEach { child ->
      val title = normalise(child.title)
      val subtitle = normalise(child.subtitle.orEmpty())
      // Depth 1 is a tab, which is navigation rather than something to find.
      val searchable = child.action == null && depth >= 2
      if (searchable && words.all { title.contains(it) || subtitle.contains(it) }) {
        val playable = child.playable
        val fresh = if (playable != null) seenTracks.add(playable.id)
        else seenFolders.add("$title|$subtitle")
        if (fresh) {
          val joined = words.joinToString(" ")
          val base = when {
            title == joined -> 0
            title.startsWith(joined) -> 1
            words.all { title.contains(it) } -> 2
            else -> 3
          }
          hits += Hit(child, base * 2 + if (playable == null) 0 else 1, order++)
        }
      }
      visit(child, depth + 1)
    }
  }
  visit(root, 1)

  return hits.sortedWith(compareBy({ it.score }, { it.order })).take(limit).map { it.node }
}

/**
 * What a spoken request plays: "play Abbey Road", or just "play yuzic".
 *
 * An empty query is the driver asking for music without saying which, and gets
 * the first thing the host put in the tree, from the top: the host orders its
 * tabs, so this is its answer, not a guess made here. Otherwise the best search
 * hit plays the way a tap on it would. Null when nothing matches, which the
 * assistant reports as the app not finding it, and which is true.
 */
internal fun voiceSelection(root: BrowseNodeRecord?, query: String): Pair<List<TrackRecord>, Int>? {
  if (root == null) return null
  if (searchWords(query).isEmpty()) {
    val first = root.children.orEmpty().firstOrNull { tracksUnder(it).isNotEmpty() } ?: return null
    return tracksUnder(first) to 0
  }
  val best = searchBrowseTree(root, query, limit = 1).firstOrNull() ?: return null
  if (best.playable != null) return carSelection(root, listOf(best.id), 0)
  val tracks = tracksUnder(best)
  return if (tracks.isEmpty()) null else tracks to 0
}

/** Every track under a node, in order, the way iOS's `BrowseTree.tracks(under:)` walks it. */
internal fun tracksUnder(node: BrowseNodeRecord, depth: Int = 0): List<TrackRecord> {
  node.playable?.let { return listOf(it) }
  if (depth >= BROWSE_MAX_DEPTH) return emptyList()
  return node.children.orEmpty().flatMap { tracksUnder(it, depth + 1) }
}

private fun searchWords(query: String): List<String> =
  normalise(query).split(Regex("\\s+")).filter { it.isNotEmpty() }

/** Lower case with accents taken off, so "Beyonce" finds "Beyoncé". */
private fun normalise(text: String): String =
  java.text.Normalizer.normalize(text, java.text.Normalizer.Form.NFD)
    .replace(Regex("\\p{M}+"), "")
    .lowercase()
    .trim()

/** The node whose children include [id], or null. Depth-first, like [findBrowseNode]. */
internal fun findParentOf(node: BrowseNodeRecord, id: String): BrowseNodeRecord? {
  node.children?.forEach { child ->
    if (child.id == id) return node
    findParentOf(child, id)?.let { return it }
  }
  return null
}
