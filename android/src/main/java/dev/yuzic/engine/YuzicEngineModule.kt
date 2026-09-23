package dev.yuzic.engine

import android.content.ComponentName
import android.net.Uri
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import java.util.concurrent.TimeUnit
import com.google.common.util.concurrent.ListenableFuture
import expo.modules.kotlin.exception.CodedException
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record

/**
 * A command arrived before the engine existed.
 *
 * The same error iOS raises from `requireEngine`, worded the same way, so a
 * host looking at a rejection cannot tell which platform it came from.
 */
internal class EngineNotSetUpException : CodedException(
  "the engine is not set up — call setup() and wait for it before any command"
)

/**
 * The Expo module surface — the thin part, and now genuinely so. The playback
 * controller is [EngineCore], owned by [PlaybackService] so that it runs
 * whether or not the host's JavaScript does; this file translates the bridge
 * onto it, starts the service, and connects the host's event sink.
 *
 * Expo Modules rather than Nitro because nothing high-frequency crosses this
 * bridge: audio never does, commands are rare, and progress is emitted about
 * once a second. What is large is the *integration* surface — background audio
 * mode, the CarPlay entitlement and scene, the Android foreground service and
 * notification channel — and that is config-plugin work, which is where the
 * Expo Modules API is markedly better. See docs/architecture.md.
 *
 * Function names, argument shapes and event names are the same strings as
 * `ios/YuzicEngineModule.swift`. They are the contract `src/AudioEngine.ts`
 * describes, and a divergence here is a platform-specific bug in the host, which
 * is the worst kind to find.
 */
@UnstableApi
class YuzicEngineModule : Module() {

  private val core get() = PlaybackService.core
  private var controllerFuture: ListenableFuture<MediaController>? = null

  override fun definition() = ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { options: SetupOptions? ->
      configureAudioSession(options?.pauseOnBecomingNoisy ?: true)
      PlaybackService.eventSink = { name, body -> sendEvent(name, body) }
      // Honoured on both platforms, and floored at 100ms on both. iOS once
      // ticked at a fixed 250ms whatever the host asked for.
      core.setProgressInterval((options?.progressIntervalMs ?: 1000).toLong())
      awaitService()
      core.startObservingOnMain()
      core.hostAttached()
    }

    AsyncFunction("teardown") {
      // The sink goes first. Between here and the service actually stopping,
      // the session may still fire — and sending an event into a JS context
      // that is being torn down is a crash rather than a no-op.
      PlaybackService.eventSink = null
      core.detachHost()
      controllerFuture?.let { MediaController.releaseFuture(it) }
      controllerFuture = null
      // The service and graph can outlive this JS module. Explicitly remove the
      // process-held identity so teardown cannot leave it presented to a server
      // selected by the next module instance.
      PlaybackService.clientCertificateTransport.setClientCertificate(null, null)
    }

    // MARK: queue
    //
    // The queue lives natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the notification still
    // has to update, and the car still has to answer its buttons. See
    // [EngineCore] for each of these.

    AsyncFunction("setQueue") { tracks: List<TrackRecord>, startIndex: Int? ->
      core.setQueue(tracks, startIndex ?: 0)
    }

    AsyncFunction("append") { tracks: List<TrackRecord> -> core.append(tracks) }

    AsyncFunction("getActiveIndex") { core.activeIndex }

    // MARK: queue editing
    //
    // The queue object keeps the index rule (see PlaybackQueue), and the player
    // is edited through Media3's own timeline operations rather than by pushing
    // the whole queue again. That difference is the whole point: `setMediaItems`
    // restarts the current item from zero, so re-pushing on every edit would
    // restart the song whenever anything else in the list moved.

    AsyncFunction("insertAt") { index: Int, tracks: List<TrackRecord> -> core.insertAt(index, tracks) }

    AsyncFunction("removeAt") { index: Int -> core.removeAt(index) }

    AsyncFunction("move") { from: Int, to: Int -> core.move(from, to) }

    AsyncFunction("clearQueue") { core.clearQueue() }

    // The only call that sends tracks *back* across the bridge, which is why it
    // is a device probe rather than a unit test: a declared shape that
    // typechecks and then throws at runtime is this module's recorded history.
    AsyncFunction("getQueue") { core.queueAsMaps() }

    AsyncFunction("setRepeatMode") { mode: String -> core.setRepeatMode(mode) }

    // MARK: transport
    //
    // Play, pause and seek go through the *active voice's* ExoPlayer, which
    // holds exactly one track. Next and previous do not: with a one-item
    // timeline there is nothing for Media3 to seek to, so they ask the engine,
    // which is where the queue is — the same route the media session's own
    // buttons take, so a lock screen and the app cannot disagree about what
    // "next" means.

    AsyncFunction("play") { core.play() }
    AsyncFunction("pause") { core.pause() }
    AsyncFunction("stop") { core.stop() }

    AsyncFunction("seekTo") { positionSec: Double -> core.seekTo(positionSec) }

    AsyncFunction("skipToNext") { core.skipToNext() }

    AsyncFunction("skipToPrevious") { core.skipToPrevious() }

    AsyncFunction("skipToIndex") { index: Int -> core.skipToIndex(index) }

    AsyncFunction("setSpeed") { speed: Double -> core.setSpeed(speed) }

    AsyncFunction("setVolume") { volume: Double -> core.setVolume(volume) }

    // MARK: sleep timer

    AsyncFunction("sleepAfter") { seconds: Double -> core.sleepAfter(seconds) }
    AsyncFunction("cancelSleep") { core.cancelSleep() }

    // MARK: cache
    //
    // Deliberately *not* on the main thread, and this is the one place in the
    // file where that is right. Every player call must hop to main, because
    // ExoPlayer throws off its own thread. `Cache.removeResource` is annotated
    // `@WorkerThread` and walks the index and the filesystem per key, so it
    // must *not* run there. An `AsyncFunction` body already runs on a
    // background dispatcher, which means these three are correct exactly as
    // written and wrapping them in `onMain` — for consistency with everything
    // around them — would be the bug.
    //
    // `configureCache` is still absent, and absent rather than accepted and
    // ignored. `LeastRecentlyUsedCacheEvictor` takes its limit as a constructor
    // argument, so honouring a new one means building a second `SimpleCache`
    // over the same directory — which the class documents as corrupting the
    // index rather than failing — or releasing the live one out from under two
    // players mid-track. Calling it on Android throws at the bridge, which is
    // the truthful answer until one of those has a real fix.

    AsyncFunction("clearCache") { PlaybackService.graph?.clearCache() }

    AsyncFunction("evict") { id: String -> PlaybackService.graph?.evict(id) }

    AsyncFunction("cacheStats") { ->
      val stats = PlaybackService.graph?.cacheStats()
      mapOf(
        "usedBytes" to (stats?.usedBytes ?: 0L),
        "maxBytes" to (stats?.maxBytes ?: 0L),
        "entryCount" to (stats?.entryCount ?: 0),
      )
    }

    // MARK: mutual TLS

    /**
     * Import now rather than at the first request. Wrong passwords and malformed
     * PKCS#12 files therefore reject on the import screen, and the old working
     * identity remains active if replacement fails. Null or empty clears both
     * API and audio because both snapshot the same process-lifetime transport.
     */
    AsyncFunction("setClientCertificate") { pkcs12Base64: String?, password: String? ->
      PlaybackService.clientCertificateTransport.setClientCertificate(pkcs12Base64, password)
    }

    /**
     * JavaScript fetch cannot present a client identity. This narrow request
     * path uses the same pooled OkHttp client that Media3 snapshots for audio.
     */
    AsyncFunction("clientCertificateRequest") { options: ClientCertificateRequestRecord ->
      val result = PlaybackService.clientCertificateTransport.request(
        url = options.url,
        method = options.method,
        headers = options.headers,
        bodyBase64 = options.bodyBase64,
        timeoutMs = options.timeoutMs,
      )
      mapOf(
        "status" to result.status,
        "headers" to result.headers,
        "bodyBase64" to result.bodyBase64,
      )
    }

    // MARK: reading the state, rather than waiting to be told

    AsyncFunction("getState") { core.currentStateName() }

    AsyncFunction("getProgress") { core.progress() }

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { bands: List<EqBandRecord> ->
      PlaybackService.graph?.setEqualizer(
        bands.map {
          AudioGraph.Band(
            frequencyHz = it.frequencyHz.toFloat(),
            gainDb = it.gainDb.toFloat(),
            q = (it.q ?: 1.0).toFloat(),
          )
        }
      )
    }

    AsyncFunction("setReplayGain") { options: ReplayGainRecord ->
      core.setReplayGain(
        ReplayGainSettings(
          mode = ReplayGainMode.from(options.mode),
          preampDb = options.preampDb,
          untaggedPreampDb = options.untaggedPreampDb,
          preventClipping = options.preventClipping,
        )
      )
    }

    AsyncFunction("setCrossfade") { options: CrossfadeRecord? -> core.setCrossfade(options) }

    AsyncFunction("setSampleRateMode") { mode: String -> core.setSampleRateMode(mode) }

    // MARK: platform surfaces
    //
    // [PlaybackService] has no other way to be handed a browse tree, and a
    // MediaLibraryService with no root is invisible in the car.

    /**
     * Take the tree the way the bridge actually sends it.
     *
     * `(title, flatNodes)`, not one nested record: an Expo `Record` cannot
     * contain itself, so `src/browseTree.ts` flattens to a list with parent
     * references and the native side rebuilds. This declared the nested shape
     * and would have thrown on the first call — the arity alone is wrong.
     *
     * Worth noting how it survived: the two platforms were compared by
     * function *name*, and the names matched. Signatures are the other half.
     */
    AsyncFunction("setBrowseTree") { title: String, nodes: List<FlatBrowseNodeRecord> ->
      core.setBrowseTree(appContext.reactContext, title, nodes)
    }

    AsyncFunction("clearBrowseTree") { core.clearBrowseTree(appContext.reactContext) }

    AsyncFunction("setCommands") { commands: List<String> ->
      PlaybackService.enabledCommands = commands.toSet()
      // Deliberately not re-issued to already-connected controllers. Media3 asks
      // for the command set once, at connect; a car that is already connected
      // keeps the set it was given until it reconnects. Forcing a reconnect to
      // apply a new set would drop the notification mid-track, which is a worse
      // trade than a stale button.
    }
  }

  /**
   * Wait for the service, and therefore for the graph, to exist.
   *
   * `configureAudioSession` starts the service by binding a `MediaController`,
   * and `buildAsync` is exactly what it says — it returns immediately and the
   * service is created some time later, in `PlaybackService.onCreate`, which is
   * where `graph` comes from. Nothing used to wait for that, so `setup()`
   * resolved while the graph was still null.
   *
   * The host takes `setup` resolving as "the engine is ready" and releases
   * every queued command on it. Those commands then found no graph and were
   * optional-chained into silence: the app opened on a cold launch, showed the
   * restored queue, and sat paused with nothing in any log. `startObserving`
   * had already returned early for the same reason, so no state or progress
   * events were flowing either — which is why it looked like a dead player
   * rather than a slow one.
   *
   * Blocking is safe here and nowhere near the main thread: an `AsyncFunction`
   * body runs on Expo's module queue, and the future completes on the main
   * looper. The timeout is the point of the bound — a service that never binds
   * must not hold `setup` open for the life of the process, and the commands
   * that follow will reject by name rather than vanish.
   */
  private fun awaitService() {
    val future = controllerFuture ?: return
    try {
      future.get(SERVICE_START_TIMEOUT_SEC, TimeUnit.SECONDS)
    } catch (_: Throwable) {
      // Swallowed deliberately, and it is the one swallow left: setup has done
      // everything else it can, and failing it outright would leave the host
      // with no engine at all rather than one whose commands report why they
      // cannot run.
    }
  }

  /**
   * The Android counterpart to claiming the audio session.
   *
   * There is no session to claim — focus is requested per playback by the
   * `AudioAttributes` the service sets — so what this actually does is start
   * the service. Connecting a `MediaController` is the sanctioned way: it binds
   * the service, which is what makes it survivable, and Media3 promotes it to
   * the foreground itself once something is playing. Calling
   * `startForegroundService` directly instead is the usual route to an
   * `ForegroundServiceDidNotStartInTimeException`.
   *
   * `pauseOnBecomingNoisy` is honoured on the players rather than here; it is
   * passed down so the two platforms take the same argument even though Android
   * spends it in a different place.
   */
  private fun configureAudioSession(pauseOnBecomingNoisy: Boolean) {
    val context = appContext.reactContext ?: throw Exceptions.ReactContextLost()

    // On the main thread, like every other player touch. On the first
    // `setup()` of a process the service does not exist yet (it is started by
    // the `buildAsync` below), so `graph` is null and nothing is touched; every
    // call after that finds a graph, and touching it from here threw `Player is
    // accessed on the wrong thread`.
    core.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)

    // Idempotent, as the contract in src/AudioEngine.ts requires: a second call
    // reconfigures rather than restarting, because tearing the session down
    // mid-playback is audible.
    if (controllerFuture != null) return

    val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
    controllerFuture = MediaController.Builder(context, token).buildAsync()
  }

  companion object {
    /**
     * How long `setup` waits for the service to bind.
     *
     * Generous, because this happens once per process and the alternative to
     * waiting is the silent dead player it exists to prevent. Bounded, because
     * a service that never binds must not hold `setup` open forever — the host
     * would sit behind its own readiness gate with no engine and no error.
     */
    private const val SERVICE_START_TIMEOUT_SEC = 10L
  }
}

// MARK: - Records
//
// Shapes crossing the bridge. Kept flat and optional-tolerant: a host that
// omits a field means "no information", which is not the same as a zero — the
// replay-gain pair is exactly that distinction.
//
// These mirror the `Record` structs at the bottom of ios/YuzicEngineModule.swift
// field for field. Where Swift can say `Double?` and mean absent, Kotlin says
// `Double?` too, and neither is allowed to quietly default to 0.

class SetupOptions : Record {
  @Field var progressIntervalMs: Int = 1000
  @Field var pauseOnBecomingNoisy: Boolean = true
}

class TrackRecord : Record {
  @Field var id: String = ""
  @Field var uri: String = ""
  @Field var title: String = ""
  @Field var artist: String? = null
  @Field var album: String? = null
  @Field var artworkUri: String? = null
  @Field var artworkHeaders: Map<String, String>? = null
  @Field var durationSec: Double? = null
  @Field var headers: Map<String, String>? = null
  @Field var followsPrevious: Boolean = false
  @Field var replayGainDb: Double? = null
  @Field var replayGainPeak: Double? = null
  @Field var continuous: Boolean = false
}

class EqBandRecord : Record {
  @Field var frequencyHz: Double = 0.0
  @Field var gainDb: Double = 0.0
  @Field var q: Double? = null
}

class ClientCertificateRequestRecord : Record {
  @Field var url: String = ""
  @Field var method: String = "GET"
  @Field var headers: Map<String, String> = emptyMap()
  /** Base64 because a request body may be arbitrary bytes. Null for a GET. */
  @Field var bodyBase64: String? = null
  /** Same default request ceiling as iOS and the TypeScript contract. */
  @Field var timeoutMs: Int = 30_000
}

/**
 * One node on the way across the bridge, as `FlatBrowseNode` in
 * `src/browseTree.ts` sends it.
 *
 * Flat because an Expo `Record` cannot contain itself — `@Field` has no way to
 * describe recursion — so the tree travels as a list with parent references
 * and is rebuilt on this side. A bridge artifact, not a shape anyone designs
 * against.
 */
class FlatBrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var parentId: String? = null
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  /** Sent only while fetching `artworkUri`, by [BrowseArtworkProvider]. */
  @Field var artworkHeaders: Map<String, String> = emptyMap()
  @Field var playable: TrackRecord? = null
  @Field var layout: String? = null
  @Field var icon: String? = null
  @Field var action: String? = null
}

class ReplayGainRecord : Record {
  @Field var mode: String = "off"
  @Field var preampDb: Double = 0.0
  @Field var untaggedPreampDb: Double = 0.0
  @Field var preventClipping: Boolean = true
}

class CrossfadeRecord : Record {
  @Field var durationSec: Double = 0.0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Boolean = true
}

/**
 * A node of the browse tree, as [buildBrowseTree] assembles it from the flat
 * records. Never crosses the bridge itself; the shape is `BrowseNode` in
 * src/types.ts.
 */
class BrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  @Field var artworkHeaders: Map<String, String>? = null
  @Field var children: List<BrowseNodeRecord>? = null
  @Field var playable: TrackRecord? = null
  /** `list` or `grid`: how this node's children are drawn. See `BrowseNode.layout`. */
  @Field var layout: String? = null
  /** A top-level entry's tab icon. See `BrowseNode.icon`. */
  @Field var icon: String? = null
  /** `shuffle`: plays the tracks beside it in random order. See `BrowseNode.action`. */
  @Field var action: String? = null
}

/**
 * The shape `getQueue` sends back to JS.
 *
 * Built by hand rather than returning the `Record`, because what crosses here
 * has to match `Track` in `src/types.ts` exactly — the host reads these back
 * after every edit — and an omitted field is a silent null on the other side
 * rather than a compile error on this one. Nulls are kept rather than dropped
 * so the absent fields are visible in the payload.
 */
fun TrackRecord.toMap(): Map<String, Any?> = mapOf(
  "id" to id, "uri" to uri, "title" to title, "artist" to artist,
  "album" to album, "artworkUri" to artworkUri, "artworkHeaders" to artworkHeaders, "durationSec" to durationSec,
  "headers" to headers, "followsPrevious" to followsPrevious,
  "replayGainDb" to replayGainDb, "replayGainPeak" to replayGainPeak,
  "continuous" to continuous,
)

/**
 * A track as the player and the session see it. Protected artwork
 * deliberately has no URI: Media3 cannot attach request headers to an artwork
 * URI, and handing it one would cause a second, unauthenticated fetch.
 *
 * The cache key is the host's `MediaId`, not the URI. Subsonic and Jellyfin
 * both hand out URLs carrying a token that rotates, so keying the cache on the
 * URI would re-download the same audio every session and the LRU would fill
 * with duplicates of one album.
 *
 * Browse rows are built by `PlaybackService.itemFor`, from the node rather
 * than the track.
 */
@UnstableApi
fun TrackRecord.toNowPlayingMediaItem(artworkData: ByteArray? = null): MediaItem = MediaItem.Builder()
  .setMediaId(id)
  .setUri(Uri.parse(uri))
  .setCustomCacheKey(id)
  .setMediaMetadata(
    MediaMetadata.Builder()
      .setTitle(title)
      .setArtist(artist)
      .setAlbumTitle(album)
      .apply {
        when {
          artworkData != null -> setArtworkData(artworkData, MediaMetadata.PICTURE_TYPE_FRONT_COVER)
          artworkHeaders.isNullOrEmpty() -> setArtworkUri(artworkUri?.let { Uri.parse(it) })
        }
      }
      .setIsBrowsable(false)
      .setIsPlayable(true)
      .build()
  )
  .build()
