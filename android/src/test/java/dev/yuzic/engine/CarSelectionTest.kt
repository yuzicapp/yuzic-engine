package dev.yuzic.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CarSelectionTest {
  private fun track(id: String) = TrackRecord().apply { this.id = id; uri = "https://music.example/$id"; title = id }

  private fun leaf(id: String) = BrowseNodeRecord().apply { this.id = id; title = id; playable = track(id) }

  private fun folder(id: String, vararg children: BrowseNodeRecord) = BrowseNodeRecord().apply {
    this.id = id
    title = id
    this.children = children.toList()
  }

  private val tree = folder(
    BROWSE_ROOT_ID,
    folder("albums", folder("album-1", leaf("a1"), leaf("a2"), leaf("a3"))),
    folder("playlists", folder("mix", leaf("p1"), leaf("a2"))),
  )

  private fun ids(selection: Pair<List<TrackRecord>, Int>?) = selection?.first?.map { it.id }

  @Test
  fun aTrackChosenInAnAlbumQueuesTheAlbumFromThere() {
    // The album is the context the driver believes they are in, and they
    // cannot pick a follow-up while moving.
    val chosen = carSelection(tree, listOf("a2"), 0)
    assertEquals(listOf("a1", "a2", "a3"), ids(chosen))
    assertEquals(1, chosen!!.second)
  }

  @Test
  fun aFolderChosenToPlayPlaysFromTheTop() {
    val chosen = carSelection(tree, listOf("album-1"), 0)
    assertEquals(listOf("a1", "a2", "a3"), ids(chosen))
    assertEquals(0, chosen!!.second)
  }

  @Test
  fun severalIdsPlayAsGivenFromTheirIndex() {
    val chosen = carSelection(tree, listOf("p1", "missing", "a3"), 1)
    assertEquals(listOf("p1", "a3"), ids(chosen))
    assertEquals(1, chosen!!.second)
  }

  @Test
  fun anIdTheTreeDoesNotKnowPlaysNothingRatherThanSomethingElse() {
    assertNull(carSelection(tree, listOf("gone"), 0))
    assertNull(carSelection(null, listOf("a1"), 0))
    assertNull(carSelection(tree, emptyList(), 0))
  }

  @Test
  fun anEmptyFolderPlaysNothing() {
    assertNull(carSelection(folder(BROWSE_ROOT_ID, folder("empty")), listOf("empty"), 0))
  }
}
