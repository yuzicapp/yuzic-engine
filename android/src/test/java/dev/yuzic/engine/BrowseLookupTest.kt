package dev.yuzic.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowseLookupTest {
  private fun node(id: String, vararg children: BrowseNodeRecord) = BrowseNodeRecord().apply {
    this.id = id
    title = id
    this.children = children.toList()
  }

  @Test
  fun theRootHasNoChildrenBeforeThereIsATree() {
    // Not an error: Android Automotive shows an error as "isn't working right
    // now", and an empty list as a library that has not loaded yet.
    val children = browseChildren(null, BROWSE_ROOT_ID)
    assertTrue(children!!.isEmpty())
  }

  @Test
  fun anythingElseBeforeThereIsATreeIsUnknown() {
    assertNull(browseChildren(null, "album:1"))
  }

  @Test
  fun theRootIdStillWorksOnceTheTreeArrives() {
    // A car that connected early is subscribed to the root id it was given.
    val root = node(BROWSE_ROOT_ID, node("albums"), node("playlists"))
    assertEquals(listOf("albums", "playlists"), browseChildren(root, BROWSE_ROOT_ID)!!.map { it.id })
  }

  @Test
  fun aNestedNodeListsItsChildren() {
    val root = node(BROWSE_ROOT_ID, node("albums", node("album:1"), node("album:2")))
    assertEquals(listOf("album:1", "album:2"), browseChildren(root, "albums")!!.map { it.id })
  }

  @Test
  fun anIdNotInTheTreeIsUnknown() {
    assertNull(browseChildren(node(BROWSE_ROOT_ID, node("albums")), "album:9"))
  }

  @Test
  fun aLeafHasNoChildrenRatherThanNone() {
    val root = node(BROWSE_ROOT_ID, BrowseNodeRecord().apply { id = "track:1" })
    assertTrue(browseChildren(root, "track:1")!!.isEmpty())
  }
}
