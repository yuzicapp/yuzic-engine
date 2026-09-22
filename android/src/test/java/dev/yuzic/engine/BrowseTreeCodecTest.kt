package dev.yuzic.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BrowseTreeCodecTest {
  private fun track() = TrackRecord().apply {
    id = "song-1"
    uri = "https://music.example/stream/song-1?api_key=secret"
    title = "Roddy"
    artist = "Djo"
    album = "The Crux"
    artworkUri = "https://music.example/cover/1"
    artworkHeaders = mapOf("Authorization" to "Basic abc")
    durationSec = 253.5
    headers = mapOf("X-Emby-Token" to "token")
    followsPrevious = true
    replayGainDb = -6.25
    replayGainPeak = 0.98
    continuous = false
  }

  private fun flat() = listOf(
    FlatBrowseNodeRecord().apply { id = "albums"; title = "Albums" },
    FlatBrowseNodeRecord().apply {
      id = "album-1"; parentId = "albums"; title = "The Crux"
      subtitle = "Djo"; artworkUri = "https://music.example/cover/1"
    },
    FlatBrowseNodeRecord().apply { id = "song-1"; parentId = "album-1"; title = "Roddy"; playable = track() },
  )

  @Test
  fun aTreeComesBackAsItWent() {
    // Everything a selection plays from has to survive, the stream URL and
    // headers most of all: a car plays from this with no JavaScript running.
    val (title, nodes) = BrowseTreeCodec.decode(BrowseTreeCodec.encode("yuzic", flat()))!!
    assertEquals("yuzic", title)
    assertEquals(listOf("albums", "album-1", "song-1"), nodes.map { it.id })
    assertEquals(listOf(null, "albums", "album-1"), nodes.map { it.parentId })
    assertEquals("Djo", nodes[1].subtitle)

    val played = nodes[2].playable!!
    val sent = track()
    assertEquals(sent.uri, played.uri)
    assertEquals(sent.headers, played.headers)
    assertEquals(sent.artworkHeaders, played.artworkHeaders)
    assertEquals(sent.durationSec, played.durationSec)
    assertEquals(sent.replayGainDb, played.replayGainDb)
    assertEquals(sent.replayGainPeak, played.replayGainPeak)
    assertTrue(played.followsPrevious)
    assertFalse(played.continuous)
  }

  @Test
  fun absentFieldsComeBackAbsentNotEmpty() {
    // An empty string where there was nothing renders a blank line in the car,
    // and a zero duration draws a scrubber pinned at the end.
    val bare = listOf(FlatBrowseNodeRecord().apply {
      id = "song-2"; title = "Untitled"; playable = TrackRecord().apply { id = "song-2"; uri = "u"; title = "Untitled" }
    })
    val node = BrowseTreeCodec.decode(BrowseTreeCodec.encode("t", bare))!!.second.single()
    assertNull(node.parentId)
    assertNull(node.subtitle)
    assertNull(node.playable!!.artist)
    assertNull(node.playable!!.durationSec)
    assertNull(node.playable!!.headers)
  }

  @Test
  fun anotherVersionIsNotReadAsThisOne() {
    assertNull(BrowseTreeCodec.decode("""{"v":2,"title":"t","nodes":[]}"""))
    assertNull(BrowseTreeCodec.decode("""{"title":"t","nodes":[]}"""))
  }

  @Test
  fun aRestoredTreeIsBuiltByTheSameRules() {
    // Kept flat so that reading it back goes through buildBrowseTree again,
    // duplicates and orphans handled exactly as for a tree fresh from the host.
    val withNoise = flat() + listOf(
      FlatBrowseNodeRecord().apply { id = "album-1"; parentId = "albums"; title = "A duplicate" },
      FlatBrowseNodeRecord().apply { id = "orphan"; parentId = "nowhere"; title = "Orphan" },
    )
    val (title, nodes) = BrowseTreeCodec.decode(BrowseTreeCodec.encode("yuzic", withNoise))!!
    val root = buildBrowseTree(title, nodes)
    assertEquals(BROWSE_ROOT_ID, root.id)
    val albums = root.children!!.single()
    assertEquals("Albums", albums.title)
    val album = albums.children!!.single()
    assertEquals("The Crux", album.title)
    assertEquals("Roddy", album.children!!.single().playable!!.title)
  }
}
