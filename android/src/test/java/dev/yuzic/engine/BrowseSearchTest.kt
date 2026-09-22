package dev.yuzic.engine

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Search and spoken requests, both answered from the tree already pushed.
 *
 * Node ids here are path-shaped, as the host builds them, and the tracks keep
 * their own ids: the same song under two folders is two rows with one track.
 */
class BrowseSearchTest {
  private fun track(id: String, title: String = id, artist: String? = null) = TrackRecord().apply {
    this.id = id
    uri = "https://music.example/$id"
    this.title = title
    this.artist = artist
  }

  private fun leaf(id: String, track: TrackRecord) = BrowseNodeRecord().apply {
    this.id = id
    title = track.title
    subtitle = track.artist
    playable = track
  }

  private fun folder(id: String, title: String, subtitle: String? = null, vararg children: BrowseNodeRecord) =
    BrowseNodeRecord().apply {
      this.id = id
      this.title = title
      this.subtitle = subtitle
      this.children = children.toList()
    }

  private val come = track("song-come", "Come Together", "The Beatles")
  private val something = track("song-something", "Something", "The Beatles")
  private val halo = track("song-halo", "Halo", "Beyoncé")

  private val tree = folder(
    BROWSE_ROOT_ID, "yuzic", null,
    folder(
      "favorites", "Favorites", null,
      BrowseNodeRecord().apply { id = "favorites/shuffle"; title = "Shuffle"; action = BROWSE_ACTION_SHUFFLE },
      leaf("favorites/song-halo", halo),
      leaf("favorites/song-come", come),
    ),
    folder(
      "albums", "Albums", null,
      folder(
        "albums/abbey", "Abbey Road", "The Beatles",
        BrowseNodeRecord().apply { id = "albums/abbey/shuffle"; title = "Shuffle"; action = BROWSE_ACTION_SHUFFLE },
        leaf("albums/abbey/song-come", come),
        leaf("albums/abbey/song-something", something),
      ),
    ),
  )

  private fun ids(nodes: List<BrowseNodeRecord>) = nodes.map { it.id }

  @Test
  fun everyWordHasToMatchTheTitleOrTheSubtitle() {
    assertEquals(listOf("albums/abbey"), ids(searchBrowseTree(tree, "beatles abbey")))
  }

  @Test
  fun caseAndAccentsAreIgnored() {
    assertEquals(listOf("favorites/song-halo"), ids(searchBrowseTree(tree, "BEYONCE")))
  }

  @Test
  fun aTrackUnderTwoFoldersIsFoundOnce() {
    val hits = searchBrowseTree(tree, "come together")
    assertEquals(1, hits.size)
    assertEquals("song-come", hits.single().playable!!.id)
  }

  @Test
  fun aTitleMatchRanksAboveAnArtistMatchAndAFolderAboveATrack() {
    // "the beatles" matches the album and both tracks by artist alone, so the
    // album wins the tie, and nothing outranks a title match.
    val hits = ids(searchBrowseTree(tree, "the beatles"))
    assertEquals("albums/abbey", hits.first())
    assertEquals("albums/abbey/song-something", ids(searchBrowseTree(tree, "something")).first())
  }

  @Test
  fun tabsAndShuffleRowsAreNeverResults() {
    assertTrue(searchBrowseTree(tree, "favorites").isEmpty())
    assertTrue(searchBrowseTree(tree, "shuffle").isEmpty())
  }

  @Test
  fun anEmptyQueryFindsNothing() {
    assertTrue(searchBrowseTree(tree, "   ").isEmpty())
    assertTrue(searchBrowseTree(null, "halo").isEmpty())
  }

  @Test
  fun aSpokenAlbumPlaysTheAlbumFromTheTop() {
    val (tracks, at) = voiceSelection(tree, "abbey road")!!
    assertEquals(listOf("song-come", "song-something"), tracks.map { it.id })
    assertEquals(0, at)
  }

  @Test
  fun aSpokenTrackPlaysItWhereItWasFound() {
    val (tracks, at) = voiceSelection(tree, "something")!!
    assertEquals(listOf("song-come", "song-something"), tracks.map { it.id })
    assertEquals(1, at)
  }

  @Test
  fun justAskingForMusicPlaysTheFirstTab() {
    // "Play yuzic": the host ordered the tabs, so the first one is its answer.
    val (tracks, at) = voiceSelection(tree, "")!!
    assertEquals(listOf("song-halo", "song-come"), tracks.map { it.id })
    assertEquals(0, at)
  }

  @Test
  fun somethingNotInTheTreePlaysNothing() {
    assertNull(voiceSelection(tree, "a song nobody has"))
    assertNull(voiceSelection(null, ""))
  }
}
