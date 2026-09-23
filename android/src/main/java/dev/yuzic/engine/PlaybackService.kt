package dev.yuzic.engine

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaConstants
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture

/**
 * The service that owns the session, the notification and the browse tree.
 *
 * Its whole reason for existing is docs/architecture.md §3: backgrounded apps
 * have their JavaScript suspended, and the things that must keep working while
 * it is suspended — advancing to the next track, updating the lock screen,
 * answering a steering-wheel button, answering the car's request for a browse
 * node — are exactly the ones users notice. So the queue, the tree and the
 * transitions all live down here, and JS is a client of the same session
 * Android Auto is.
 *
 * `MediaLibraryService` rather than the plainer `MediaSessionService` because
 * the browse tree is not optional: Android Auto asks for a root before it will
 * show the app at all.
 */
@UnstableApi
class PlaybackService : MediaLibraryService() {

  private var session: MediaLibrarySession? = null

  /** Each car's last search, so it can be answered again when the tree changes. */
  private val openSearches =
    java.util.concurrent.ConcurrentHashMap<MediaSession.ControllerInfo, Pair<String, LibraryParams?>>()

  /**
   * The engine state, shared with [YuzicEngineModule].
   *
   * A companion holder rather than a bound-service handle. The module and the
   * service have genuinely different lifetimes — the service outlives the JS
   * context by design, and can be restarted by the system after the process is
   * killed with no module in existence yet — so a binding that assumed both were
   * alive would be wrong in exactly the situation this is built for.
   */
  companion object Engine {
    @Volatile
    var graph: AudioGraph? = null
      private set

    val queue = PlaybackQueue()

    /**
     * Process-lifetime network identity shared by API calls and both voices.
     *
     * The service can outlive the Expo module, so keeping this beside the graph
     * prevents a service restart from quietly rebuilding audio with a different
     * client than the bridge. The module clears it explicitly on teardown.
     */
    val clientCertificateTransport = ClientCertificateTransport()

    /** The root the host handed over via `setBrowseTree`. Null until it does. */
    @Volatile
    var browseRoot: BrowseNodeRecord? = null

    /**
     * Bumped by every `setBrowseTree` and `clearBrowseTree`, so a tree being
     * restored from disk can tell that the host has spoken since it started
     * reading, and stand down. Without it a clear that landed mid-restore,
     * a sign-out's, was undone by the restore finishing.
     */
    val browseTreeGeneration = java.util.concurrent.atomic.AtomicInteger()

    // Declared above `enabledCommands` because a companion's properties are
    // initialised in declaration order, and the one below reads this one. The
    // other way round it compiles as far as the reader's eye and no further.
    val DEFAULT_COMMANDS = setOf("playPause", "next", "previous", "seek")

    /** Which remote controls the host asked to advertise. */
    @Volatile
    var enabledCommands: Set<String> = DEFAULT_COMMANDS

    /**
     * Anything the session needs to tell JS. Set by the module while it is
     * alive and cleared when it goes away — the service must keep working with
     * this null, which is the whole point of it living here.
     */
    @Volatile
    var eventSink: ((String, Map<String, Any?>) -> Unit)? = null

    /**
     * The playback controller, one per process like the graph and the queue.
     *
     * Here rather than in the module because the module only exists while the
     * host's JavaScript does, and a car starts this service without it. See
     * [EngineCore]. Next and previous from the lock screen, the notification
     * and the car reach it directly now; they used to be handed back to the
     * module through callbacks that were null whenever no host was running,
     * which made every one of those buttons dead in exactly the case a car is.
     */
    internal val core = EngineCore()

    /**
     * The tracks behind the media items the last car selection resolved to,
     * by media id, for [EnginePlayer.setMediaItems] to hand to [core].
     *
     * Media3 calls `onSetMediaItems` for the resolution and then
     * `setMediaItems` on the player with what it returned, and a `MediaItem`
     * cannot carry a [TrackRecord]. Replaced on every selection.
     */
    @Volatile
    var controllerTracks: Map<String, TrackRecord> = emptyMap()

    /** Where [EngineCore] keeps the queue for `onPlaybackResumption`. Set in `onCreate`. */
    @Volatile
    internal var resumptionStore: ResumptionStore? = null

    /**
     * Ask the session to re-read `getAvailableCommands`.
     *
     * Needed because the command set now depends on the *queue*, which the
     * player knows nothing about. ExoPlayer announces its own commands when its
     * timeline changes; ours can change when nothing about the player does — an
     * `append` behind the last track turns "next" from impossible into
     * possible, and the player has no reason to mention it.
     *
     * Observed before this existed: after appending, "next" stayed greyed
     * indefinitely on one run and lit within four seconds on another, the
     * difference being whether some unrelated player event happened along to
     * trigger a re-read. Intermittent is worse than broken — a user gets a
     * working button sometimes, with no pattern they can see.
     */
    @Volatile
    var onCommandsMayHaveChanged: (() -> Unit)? = null

    /**
     * Tell connected cars the tree changed. Main thread only.
     *
     * A car asks for the root once, often before the host has set a tree, and
     * then shows what it got until told otherwise. Without this the library
     * stayed empty until the driver left the app and came back.
     */
    @Volatile
    var onBrowseTreeChanged: (() -> Unit)? = null

    /**
     * The session's id. Explicit because Media3's default is `""`, and an empty
     * id cannot satisfy the uniqueness it then enforces.
     */
    private const val SESSION_ID = "yuzic-engine"

    fun attachGraph(graph: AudioGraph) {
      this.graph = graph
    }

    fun detachGraph() {
      graph = null
    }
  }

  override fun onCreate() {
    super.onCreate()

    // `Engine.graph`, not `this.graph`: the graph lives on the companion so it
    // survives the service being restarted by the system with no module alive.
    // `this` here is the service instance, which does not have one.
    val graph = Engine.graph ?: AudioGraph(
      this,
      clientCertificateTransport.audioCallFactory,
    ).also { attachGraph(it) }

    // AudioAttributes with handleAudioFocus is what makes the engine a good
    // citizen: ducking for navigation prompts, pausing for a call, and resuming
    // afterwards. Set on both voices, because during a crossfade both are
    // producing audio and a focus loss must silence the pair.
    val attributes = AudioAttributes.Builder()
      .setUsage(C.USAGE_MEDIA)
      .setContentType(C.AUDIO_CONTENT_TYPE_MUSIC)
      .build()
    graph.voiceA.player.setAudioAttributes(attributes, true)
    graph.voiceB.player.setAudioAttributes(attributes, true)

    // Media3 keeps a per-process registry of session ids and refuses a
    // duplicate, which took the service down here with
    // `IllegalStateException: Session ID must be unique. ID=`.
    //
    // **`setId` is the fix, and the other party is not us.** `@rntp/player`
    // also builds a `MediaLibrarySession`, and it also takes Media3's default
    // empty id. In a host that runs rntp as its player while the engine is
    // loaded beside it, both ask for `""` and the second one throws. Confirmed
    // on a device: `dumpsys media_session` lists
    // `androidx.media3.session.id.` and `androidx.media3.session.id.yuzic-engine`
    // in one process, and `dumpsys activity services` shows
    // `TrackPlayerPlaybackService` and this one under the same pid.
    //
    // So the id has to be *ours*, not merely non-empty. Any name would do; the
    // thing that matters is not sharing a namespace with another library that
    // never expected company.
    //
    // Two earlier versions of this comment were wrong, in opposite directions.
    // The first said the empty string was the defect — it was not, `""` is a
    // fine unique id for one session. The second said `setId` fixed nothing
    // because two sessions named "yuzic-engine" would collide too — true, and
    // irrelevant, because there was never a second engine session. Both
    // guessed at the second party instead of looking for it.
    //
    // `session == null` below is instance state and cannot see across service
    // instances, so it is inert. Left in place: it costs nothing and the
    // condition it names is real even if it is not the one that happened. Do
    // not "fix" it by moving the handle to the companion — the two-engine-
    // session case it would guard against has not been shown to be reachable,
    // and a shared handle brings its own hazard of one instance releasing
    // another's live session.
    if (session == null) {
      val enginePlayer = EnginePlayer(graph)
      // The queue decides part of the command set, so the module needs a way to
      // say "ask again" when it changes something the player cannot see.
      onCommandsMayHaveChanged = { enginePlayer.notifyAvailableCommandsChanged() }
      val librarySession = MediaLibrarySession.Builder(this, enginePlayer, LibraryCallback())
        .setId(SESSION_ID)
        .build()
      session = librarySession
      onBrowseTreeChanged = {
        val root = browseRoot
        librarySession.notifyChildrenChanged(BROWSE_ROOT_ID, root?.children?.size ?: 0, null)
        // A search the car is showing is answered again from the new tree,
        // including one held while the saved tree was read back.
        openSearches.forEach { (browser, search) ->
          librarySession.notifySearchResultChanged(
            browser, search.first, searchBrowseTree(root, search.first).size, search.second,
          )
        }
      }
    }

    resumptionStore = ResumptionStore.forContext(this)
    restoreBrowseTree()
    // The advance, the crossfade and the progress clock all hang off this, and
    // a car can start playback with no host to call `setup`.
    core.startObservingOnMain()
  }

  /**
   * Bring back the last tree the host set, when this process has none.
   *
   * The case this is for is a car starting the service in a process that had
   * died: no JavaScript is running, and none will until someone opens the
   * app's own screen. See [BrowseTreeStore]. Off the main thread, because a
   * full tree is thousands of rows to decrypt and parse, and a car that asks
   * meanwhile gets the stand-in and is told when this lands. A tree the host
   * sets in the meantime wins: this only fills an empty slot.
   */
  private fun restoreBrowseTree() {
    if (browseRoot != null) return
    val generation = browseTreeGeneration.get()
    val store = BrowseTreeStore.forContext(this)
    val main = android.os.Handler(android.os.Looper.getMainLooper())
    restoring = true
    Thread {
      val restored = store.load()?.let { (title, nodes) -> buildBrowseTree(title, nodes) }
      main.post {
        restoring = false
        if (restored != null && browseRoot == null && browseTreeGeneration.get() == generation) {
          browseRoot = restored
        }
        // Also when nothing was restored: a search held for the restore is
        // owed an answer either way.
        onBrowseTreeChanged?.invoke()
      }
    }.apply { name = "yuzic-engine-browse-restore" }.start()
  }

  /**
   * True while the saved tree is being read back. Main thread writes; binder
   * threads read.
   *
   * A search that arrives meanwhile is held rather than answered, because
   * Android Automotive's search is one-shot: it reopens its search screen
   * the moment the process starts, takes the first answer as final, and an
   * empty one showed "Media isn't available" for a query that would match.
   */
  @Volatile
  private var restoring = false

  override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaLibrarySession? = session

  /**
   * Swiping the app away should not stop the music if it is playing — that is
   * what the notification's own close action is for — but leaving a paused
   * foreground service alive after the task is gone is how apps end up in
   * battery-blame screens.
   */
  override fun onTaskRemoved(rootIntent: Intent?) {
    val player = session?.player
    if (player == null || !player.playWhenReady || player.mediaItemCount == 0) {
      stopSelf()
    }
  }

  override fun onDestroy() {
    onCommandsMayHaveChanged = null
    onBrowseTreeChanged = null
    core.serviceStopping()
    session?.run {
      player.release()
      release()
    }
    session = null
    graph?.release()
    detachGraph()
    super.onDestroy()
  }

  // MARK: - Browse tree

  /**
   * The host app's label, which titles the empty root served before a tree
   * arrives. See [standInRoot] for why this and not a setup option.
   */
  private val appLabel: String by lazy { applicationInfo.loadLabel(packageManager).toString() }

  private inner class LibraryCallback : MediaLibrarySession.Callback {

    override fun onConnect(
      session: MediaSession,
      controller: MediaSession.ControllerInfo,
    ): MediaSession.ConnectionResult {
      // The advertised command set is the host's call (`setCommands`), and it is
      // applied here rather than remembered somewhere and applied later: this is
      // the only moment Media3 asks, and a car that connected before the host
      // called setCommands must still get a working transport.
      val available = Player.Commands.Builder().apply {
        add(Player.COMMAND_GET_TIMELINE)
        add(Player.COMMAND_GET_CURRENT_MEDIA_ITEM)
        add(Player.COMMAND_GET_METADATA)
        if ("playPause" in enabledCommands) {
          add(Player.COMMAND_PLAY_PAUSE)
        }
        if ("stop" in enabledCommands) add(Player.COMMAND_STOP)
        if ("next" in enabledCommands) {
          add(Player.COMMAND_SEEK_TO_NEXT)
          add(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM)
        }
        if ("previous" in enabledCommands) {
          add(Player.COMMAND_SEEK_TO_PREVIOUS)
          add(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM)
        }
        if ("seek" in enabledCommands) add(Player.COMMAND_SEEK_IN_CURRENT_MEDIA_ITEM)
        if ("skipForward" in enabledCommands) add(Player.COMMAND_SEEK_FORWARD)
        if ("skipBackward" in enabledCommands) add(Player.COMMAND_SEEK_BACK)
        // How a car plays what it browsed: Media3 checks these before it will
        // pass a selection on at all, and with them missing every selection
        // in Android Auto and Android Automotive was dropped without a word
        // before it reached this service. Granted now that `onSetMediaItems`
        // resolves a selection and the engine plays it.
        add(Player.COMMAND_SET_MEDIA_ITEM)
        add(Player.COMMAND_CHANGE_MEDIA_ITEMS)
        add(Player.COMMAND_PREPARE)
      }.build()

      return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
        .setAvailablePlayerCommands(available)
        .build()
    }

    override fun onGetLibraryRoot(
      session: MediaLibrarySession,
      browser: MediaSession.ControllerInfo,
      params: LibraryParams?,
    ): ListenableFuture<LibraryResult<MediaItem>> {
      // A car that asks before the host has set a tree gets an empty
      // browsable root, not an error. An error here makes the app look broken
      // in the launcher; an empty root looks like a library still loading,
      // which is what it is. Its children have to be empty too, not an
      // error, which `browseChildren` sees to, and asked for as an item it has
      // to be the same stand-in, which `browseNode` sees to, or the car's
      // subscription is refused. It has the real root's id so the car is
      // still subscribed when the tree arrives.
      val root = browseRoot ?: standInRoot(appLabel)
      // The defaults for every list the car draws: rows, unless a node asks
      // for a grid (see `itemFor`). Sent with the root because that is where
      // a car reads them. Search support is advertised by Media3 on its own,
      // from the session commands a controller is granted.
      val extras = Bundle().apply {
        putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE, MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM)
        putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE, MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM)
      }
      return Futures.immediateFuture(
        LibraryResult.ofItem(
          itemFor(root, browser, topLevel = false),
          LibraryParams.Builder().setExtras(extras).build(),
        )
      )
    }

    override fun onGetChildren(
      session: MediaLibrarySession,
      browser: MediaSession.ControllerInfo,
      parentId: String,
      page: Int,
      pageSize: Int,
      params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
      val children = (
        browseChildren(browseRoot, parentId)
          ?: return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
        ).map { child -> itemFor(child, browser, topLevel = parentId == BROWSE_ROOT_ID) }

      // Paged because Android Auto asks for pages and some head units enforce
      // a hard limit per response. Serving the whole list regardless of `page`
      // is a common bug that shows the first screen repeating forever.
      val from = (page * pageSize).coerceAtMost(children.size)
      val to = (from + pageSize).coerceAtMost(children.size)
      return Futures.immediateFuture(
        LibraryResult.ofItemList(ImmutableList.copyOf(children.subList(from, to)), params)
      )
    }

    /**
     * A car's selection, resolved against the tree into what to play.
     *
     * The car sends ids and nothing else; a legacy controller's play-from-id
     * arrives here too, as a single item with no start index. See
     * [carSelection] for the rules. The items returned carry the tracks' own
     * ids, and [controllerTracks] carries the tracks, because Media3 hands the
     * items straight to the player's `setMediaItems` next.
     */
    override fun onSetMediaItems(
      mediaSession: MediaSession,
      controller: MediaSession.ControllerInfo,
      mediaItems: MutableList<MediaItem>,
      startIndex: Int,
      startPositionMs: Long,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
      val root = browseRoot
      // A spoken request arrives as one item with no id and the words in its
      // request metadata. It is the one selection Play's review checks by
      // name (VC-1), and before this it failed like any unknown id.
      val spoken = mediaItems.singleOrNull()?.takeIf { it.mediaId.isEmpty() }
      val chosen = (
        if (spoken != null) voiceSelection(root, spoken.requestMetadata.searchQuery.orEmpty())
        else carSelection(root, mediaItems.map { it.mediaId }, startIndex.coerceAtLeast(0))
        ) ?: return Futures.immediateFailedFuture(UnsupportedOperationException("nothing playable was chosen"))
      val (tracks, at) = chosen
      controllerTracks = tracks.associateBy { it.id }
      val position = if (startPositionMs == C.TIME_UNSET) 0L else startPositionMs
      return Futures.immediateFuture(
        MediaSession.MediaItemsWithStartPosition(tracks.map { it.toNowPlayingMediaItem() }, at, position)
      )
    }

    /** Resolved the same way, for a controller that adds rather than replaces. */
    override fun onAddMediaItems(
      mediaSession: MediaSession,
      controller: MediaSession.ControllerInfo,
      mediaItems: MutableList<MediaItem>,
    ): ListenableFuture<MutableList<MediaItem>> {
      val tracks = mediaItems.mapNotNull { browseNode(browseRoot, it.mediaId, appLabel)?.playable }
      if (tracks.isEmpty()) {
        return Futures.immediateFailedFuture(UnsupportedOperationException("nothing playable was chosen"))
      }
      controllerTracks = controllerTracks + tracks.associateBy { it.id }
      return Futures.immediateFuture(tracks.map { it.toNowPlayingMediaItem() }.toMutableList())
    }

    override fun onGetItem(
      session: MediaLibrarySession,
      browser: MediaSession.ControllerInfo,
      mediaId: String,
    ): ListenableFuture<LibraryResult<MediaItem>> {
      val root = browseRoot
      val node = browseNode(root, mediaId, appLabel)
        ?: return Futures.immediateFuture(LibraryResult.ofError(LibraryResult.RESULT_ERROR_BAD_VALUE))
      val topLevel = root?.children.orEmpty().any { it.id == node.id }
      return Futures.immediateFuture(LibraryResult.ofItem(itemFor(node, browser, topLevel), null))
    }

    /**
     * A search from the car's search box.
     *
     * Answered from the tree already pushed, never from the server: see
     * [searchBrowseTree]. Media3 has advertised search to every car all along,
     * because the default session commands include it, and the default answer
     * was an error, so the car drew a search button that never found anything.
     */
    override fun onSearch(
      session: MediaLibrarySession,
      browser: MediaSession.ControllerInfo,
      query: String,
      params: LibraryParams?,
    ): ListenableFuture<LibraryResult<Void>> {
      openSearches[browser] = query to params
      val root = browseRoot
      // Held until the saved tree is back; see `restoring`.
      if (root == null && restoring) return Futures.immediateFuture(LibraryResult.ofVoid())
      session.notifySearchResultChanged(browser, query, searchBrowseTree(root, query).size, params)
      return Futures.immediateFuture(LibraryResult.ofVoid())
    }

    override fun onDisconnected(session: MediaSession, controller: MediaSession.ControllerInfo) {
      openSearches.remove(controller)
    }

    override fun onGetSearchResult(
      session: MediaLibrarySession,
      browser: MediaSession.ControllerInfo,
      query: String,
      page: Int,
      pageSize: Int,
      params: LibraryParams?,
    ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> {
      val hits = searchBrowseTree(browseRoot, query).map { itemFor(it, browser, topLevel = false) }
      val from = (page * pageSize).coerceIn(0, hits.size)
      val to = (from + pageSize).coerceAtMost(hits.size)
      return Futures.immediateFuture(LibraryResult.ofItemList(ImmutableList.copyOf(hits.subList(from, to)), params))
    }

    /**
     * Something asked to play with nothing loaded: Android Auto reconnecting,
     * a headset's play button, the system's resume card.
     *
     * The queue in memory if there is one, else the one [EngineCore] kept.
     * Media3 hands the result to the player's `setMediaItems`, and starts it
     * only when the request was for playback, so a car connecting shows what
     * was playing without starting it, which Play's review asks for (MA-1).
     */
    override fun onPlaybackResumption(
      mediaSession: MediaSession,
      controller: MediaSession.ControllerInfo,
      isForPlayback: Boolean,
    ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
      val live = queue.tracks
      val saved = if (live.isNotEmpty()) {
        val position = graph?.activeVoice?.player?.currentPosition ?: 0L
        ResumptionStore.Saved(live.toList(), queue.activeIndex, position.coerceAtLeast(0L))
      } else {
        resumptionStore?.load()
      } ?: return Futures.immediateFailedFuture(UnsupportedOperationException("nothing to resume"))
      controllerTracks = saved.tracks.associateBy { it.id }
      return Futures.immediateFuture(
        MediaSession.MediaItemsWithStartPosition(
          saved.tracks.map { it.toNowPlayingMediaItem() },
          saved.index.coerceIn(0, saved.tracks.size - 1),
          saved.positionMs,
        )
      )
    }

    override fun onCustomCommand(
      session: MediaSession,
      controller: MediaSession.ControllerInfo,
      customCommand: SessionCommand,
      args: android.os.Bundle,
    ): ListenableFuture<SessionResult> {
      // Anything the session cannot answer alone is forwarded to the host, which
      // replies by driving the ordinary API — the `remoteCommand` event in
      // src/types.ts. If JS is asleep the sink is null and the command is
      // dropped, which is correct: there is nothing that could answer it.
      eventSink?.invoke(
        "onRemoteCommand",
        mapOf("command" to customCommand.customAction),
      )
      return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
    }
  }

  /**
   * One row as the car draws it.
   *
   * The row's id is the node's, not the track's. The same track can sit in an
   * album and in a playlist, the car hands back whichever id it was shown, and
   * that id has to say which place was tapped. The track's own id is what the
   * queue carries once it plays.
   *
   * - A top-level entry is a tab, and carries the icon the host named.
   * - A shuffle row carries the shuffle icon, and plays.
   * - Anything else carries its cover, served by [BrowseArtworkProvider], and
   *   the car that asked is granted it.
   * - A node with a layout sets how its own children are drawn.
   * - A track kept on the device is marked downloaded, which the car shows.
   */
  private fun itemFor(node: BrowseNodeRecord, browser: MediaSession.ControllerInfo?, topLevel: Boolean): MediaItem {
    val playable = node.playable
    val isAction = node.action == BROWSE_ACTION_SHUFFLE
    val artwork = when {
      topLevel && node.icon != null -> iconUri(node.icon)
      isAction -> iconUri("shuffle")
      else -> null
    } ?: BrowseArtworkProvider.carUriFor(this, node)?.also { uri ->
      browser?.let { BrowseArtworkProvider.grantTo(this, it.packageName, uri) }
    }

    val extras = Bundle()
    when (node.layout) {
      "grid" -> MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_GRID_ITEM
      "list" -> MediaConstants.EXTRAS_VALUE_CONTENT_STYLE_LIST_ITEM
      else -> null
    }?.let { style ->
      extras.putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE, style)
      extras.putInt(MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE, style)
    }
    if (playable?.uri?.startsWith("file:") == true) {
      extras.putLong(MediaConstants.EXTRAS_KEY_DOWNLOAD_STATUS, MediaConstants.EXTRAS_VALUE_STATUS_DOWNLOADED)
    }

    val metadata = MediaMetadata.Builder()
      .setTitle(node.title)
      .setSubtitle(node.subtitle ?: playable?.artist)
      .setArtist(playable?.artist)
      .setAlbumTitle(playable?.album)
      .setArtworkUri(artwork)
      .setIsBrowsable(playable == null && !isAction)
      .setIsPlayable(playable != null || isAction)
      .setMediaType(
        if (playable != null || isAction) MediaMetadata.MEDIA_TYPE_MUSIC
        else MediaMetadata.MEDIA_TYPE_FOLDER_MIXED
      )
      .apply { if (!extras.isEmpty) setExtras(extras) }
      .build()
    return MediaItem.Builder().setMediaId(node.id).setMediaMetadata(metadata).build()
  }

  /** A bundled icon as a URI the car can open, or null for a name the engine has none for. */
  private fun iconUri(name: String?): Uri? {
    if (name == null || name !in CAR_ICONS) return null
    return Uri.Builder()
      .scheme(ContentResolver.SCHEME_ANDROID_RESOURCE)
      .authority(packageName)
      .appendPath("drawable")
      .appendPath("yuzic_car_$name")
      .build()
  }
}

/**
 * The names `BrowseIcon` in src/types.ts allows, plus shuffle, each drawn by a
 * `res/drawable/yuzic_car_*` vector.
 */
private val CAR_ICONS = setOf(
  "recent", "favorites", "albums", "artists", "playlists", "downloads", "radio", "library", "shuffle",
)

/**
 * One `Player` for a session that is really two players.
 *
 * `MediaSession` takes exactly one `Player`, and the pair of voices is an
 * implementation detail of the crossfade that the notification, the lock screen
 * and the car have no business knowing about. This routes every call to whichever
 * voice is currently foreground.
 *
 * `SimpleBasePlayer` is the sanctioned way to write a custom `Player` and was
 * the first choice, but it wants the entire state re-derived into an immutable
 * `State` on every change — and ExoPlayer's own state is already correct here.
 * The only thing wrong with it is *which instance* holds it. Forwarding is the
 * smaller lie.
 */
@UnstableApi
private class EnginePlayer(private val graph: AudioGraph) :
  androidx.media3.common.ForwardingPlayer(graph.voiceA.player) {

  private val active: Player get() = graph.activeVoice.player

  // Every getter whose answer depends on which voice is live, which since the
  // engine drives its own advances means *what is loaded* as well as *where
  // playback is*.
  //
  // This block used to cover only the second group, on the stated grounds that
  // the metadata and timeline "live on the foreground voice, which is also the
  // wrapped one whenever `activeIsA`". That was true while `swapVoices()` was
  // never called. It is not true now: the crossfade swaps, so after an odd
  // number of fades the wrapped player is the *idle* voice, and the session
  // read its metadata from a track that had finished playing. Observed on
  // device — the lock screen showed the previous track's title, artist and
  // album while the current one played, and would have shown it in the car.
  //
  // The comment named its own precondition and the precondition quietly
  // stopped holding, which is why the failure was invisible: nothing about
  // this file changed.
  override fun getCurrentPosition(): Long = active.currentPosition
  override fun getDuration(): Long = active.duration
  override fun getBufferedPosition(): Long = active.bufferedPosition
  override fun getPlaybackState(): Int = active.playbackState
  override fun getPlayWhenReady(): Boolean = active.playWhenReady
  override fun isPlaying(): Boolean = active.isPlaying

  override fun getCurrentMediaItem(): MediaItem? = active.currentMediaItem
  override fun getMediaMetadata(): MediaMetadata = active.mediaMetadata
  override fun getCurrentTimeline(): androidx.media3.common.Timeline = active.currentTimeline
  override fun getCurrentMediaItemIndex(): Int = active.currentMediaItemIndex
  override fun getCurrentPeriodIndex(): Int = active.currentPeriodIndex
  override fun getMediaItemCount(): Int = active.mediaItemCount
  override fun getContentPosition(): Long = active.contentPosition
  override fun getContentDuration(): Long = active.contentDuration
  override fun getContentBufferedPosition(): Long = active.contentBufferedPosition
  override fun getTotalBufferedDuration(): Long = active.totalBufferedDuration
  override fun isPlayingAd(): Boolean = active.isPlayingAd

  override fun play() {
    // The lock screen and Android Auto reach playback through here, so this
    // needs the same re-establish as the module's `play`: `play()` alone does
    // nothing to a player left in `STATE_IDLE` by a failed stream or a `stop`,
    // and the car's play button would simply do nothing.
    if (active.playbackState == Player.STATE_IDLE) active.prepare()
    active.play()
  }

  override fun pause() {
    // Both, not just the active one. Pausing mid-crossfade while the outgoing
    // voice keeps playing is the exact failure the two-player arrangement makes
    // possible, and it sounds like the app is haunted.
    graph.voiceA.player.pause()
    graph.voiceB.player.pause()
  }

  override fun setPlayWhenReady(playWhenReady: Boolean) {
    if (playWhenReady) active.play() else pause()
  }

  override fun seekTo(positionMs: Long) {
    active.seekTo(positionMs)
  }

  override fun stop() {
    graph.voiceA.player.stop()
    graph.voiceB.player.stop()
  }

  // Next and previous do not walk the timeline any more, because there is no
  // timeline to walk: one track per voice. They ask the engine, which is where
  // the queue actually is. Both spellings are overridden because Media3 picks
  // between them by which commands the session advertises, and a controller
  // that chose the other one would silently do nothing.
  override fun seekToNext() = askEngineToSkipNext()

  override fun seekToNextMediaItem() = askEngineToSkipNext()

  override fun seekToPrevious() = askEngineToSkipPrevious()

  override fun seekToPreviousMediaItem() = askEngineToSkipPrevious()

  private fun askEngineToSkipNext() {
    PlaybackService.core.skipToNext()
  }

  private fun askEngineToSkipPrevious() {
    PlaybackService.core.skipToPrevious()
  }

  // A car's selection, after `onSetMediaItems` resolved it. The engine owns the
  // queue and each voice holds one track, so the list is handed to the engine
  // rather than to a voice: set on the voice, it would play the first track
  // and then pause, because the voices are told not to advance by themselves,
  // and none of the engine's queue, crossfade or events would know about it.
  override fun setMediaItems(mediaItems: MutableList<MediaItem>, startIndex: Int, startPositionMs: Long) =
    handToEngine(mediaItems, startIndex, if (startPositionMs == C.TIME_UNSET) 0L else startPositionMs)

  override fun setMediaItems(mediaItems: MutableList<MediaItem>, resetPosition: Boolean) =
    handToEngine(mediaItems, 0, 0L)

  override fun setMediaItems(mediaItems: MutableList<MediaItem>) = handToEngine(mediaItems, 0, 0L)

  override fun setMediaItem(mediaItem: MediaItem) = handToEngine(mutableListOf(mediaItem), 0, 0L)

  override fun setMediaItem(mediaItem: MediaItem, startPositionMs: Long) =
    handToEngine(mutableListOf(mediaItem), 0, startPositionMs)

  override fun setMediaItem(mediaItem: MediaItem, resetPosition: Boolean) =
    handToEngine(mutableListOf(mediaItem), 0, 0L)

  private fun handToEngine(items: List<MediaItem>, startIndex: Int, positionMs: Long) {
    val known = PlaybackService.controllerTracks
    val tracks = items.mapNotNull { known[it.mediaId] }
    if (tracks.isEmpty()) return
    PlaybackService.core.setQueueFromController(tracks, startIndex.coerceIn(0, tracks.size - 1), positionMs)
  }

  // The engine prepares the track it loads. Forwarded, this would reach the
  // wrapped voice, which after a crossfade is the idle one holding a stopped
  // track with `playWhenReady` still set, and preparing it would start it.
  override fun prepare() {
    if (active.playbackState == Player.STATE_IDLE && active.mediaItemCount > 0) active.prepare()
  }

  /**
   * The player's own commands, plus the two only the engine can answer.
   *
   * ExoPlayer decides `COMMAND_SEEK_TO_NEXT` by looking at its timeline, and
   * each voice holds exactly one track — so it reports that there is nowhere to
   * go, and a controller that believes it never sends the command at all. The
   * override above would then never run: the button is not ignored, it is
   * greyed out before it is pressed.
   *
   * Whether there is a next track is the *queue's* answer, not the player's,
   * and `nextIndex` is the same call the engine itself advances on — so repeat
   * is honoured here for free, and the lock screen stops offering "next" at the
   * end of a queue that does not wrap.
   */
  override fun getAvailableCommands(): Player.Commands =
    active.availableCommands.buildUpon()
      .addIf(Player.COMMAND_SEEK_TO_NEXT, PlaybackService.queue.nextIndex != null)
      .addIf(Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM, PlaybackService.queue.nextIndex != null)
      // Previous is always offered: below the restart threshold it goes back a
      // track, above it it restarts this one, so it does something useful even
      // on the first track of a queue.
      .addIf(Player.COMMAND_SEEK_TO_PREVIOUS, true)
      .addIf(Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM, PlaybackService.queue.activeIndex > 0)
      .build()

  /**
   * The listeners this player has been given, kept as well as forwarded.
   *
   * `ForwardingPlayer` hands registration straight to the wrapped player and
   * keeps no record, which is fine until something other than the player needs
   * to raise an event — here, a command set that depends on the queue. Media3's
   * session registers through this method like any other listener, so calling
   * it back directly is enough to make it re-read.
   */
  private val listeners = java.util.concurrent.CopyOnWriteArraySet<Player.Listener>()

  /** Main thread only, like every other player callback. */
  fun notifyAvailableCommandsChanged() {
    val commands = availableCommands
    listeners.forEach { it.onAvailableCommandsChanged(commands) }
  }

  override fun addListener(listener: Player.Listener) {
    listeners.add(listener)
    // Both, because the session must keep hearing about state after a swap. The
    // alternative — re-registering on every crossover — races the swap and
    // loses the first event after it.
    graph.voiceA.player.addListener(listener)
    graph.voiceB.player.addListener(listener)
  }

  override fun removeListener(listener: Player.Listener) {
    listeners.remove(listener)
    graph.voiceA.player.removeListener(listener)
    graph.voiceB.player.removeListener(listener)
  }
}
