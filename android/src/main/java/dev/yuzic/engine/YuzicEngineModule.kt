package dev.yuzic.engine

import android.content.ComponentName
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import com.google.common.util.concurrent.ListenableFuture
import expo.modules.kotlin.exception.CodedException
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

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
 * The Expo module surface — the thin part. Everything of substance lives in
 * [AudioGraph], [PlaybackQueue] and [PlaybackService]; this file only translates.
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

  private val queue get() = PlaybackService.queue
  private var controllerFuture: ListenableFuture<MediaController>? = null

  /**
   * Identifies the current now-playing artwork request. Network callbacks can
   * arrive after a skip, so only the request belonging to the current player
   * and track may update the session metadata.
   *
   * Main-thread confined: reads and increments happen in [onMain] or a main
   * handler callback.
   */
  private var artworkRequestToken = 0L

  override fun definition() = ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { options: SetupOptions? ->
      configureAudioSession(options?.pauseOnBecomingNoisy ?: true)
      PlaybackService.eventSink = { name, body -> sendEvent(name, body) }
      // The session's transport buttons need the engine, not the timeline.
      PlaybackService.onSkipToNext = { skipToNextTrack() }
      PlaybackService.onSkipToPrevious = { skipToPreviousTrack() }
      // Honoured, unlike on iOS, which declares the same field and then ticks
      // at a hardcoded 250ms regardless. Worth not copying: the host asked.
      progressIntervalMs = (options?.progressIntervalMs ?: 1000).coerceAtLeast(100).toLong()
      awaitService()
      onMain { startObserving() }
    }

    AsyncFunction("teardown") {
      // The sink goes first. Between here and the service actually stopping,
      // the session may still fire — and sending an event into a JS context
      // that is being torn down is a crash rather than a no-op.
      PlaybackService.eventSink = null
      PlaybackService.onSkipToNext = null
      PlaybackService.onSkipToPrevious = null
      onMain {
        artworkRequestToken += 1
        stopObserving()
      }
      sleepTimer.cancel()
      controllerFuture?.let { MediaController.releaseFuture(it) }
      controllerFuture = null
      TrackHeaders.clear()
      // The service and graph can outlive this JS module. Explicitly remove the
      // process-held identity so teardown cannot leave it presented to a server
      // selected by the next module instance.
      PlaybackService.clientCertificateTransport.setClientCertificate(null, null)
    }

    // MARK: queue
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the notification still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { tracks: List<TrackRecord>, startIndex: Int? ->
      queue.set(tracks, startIndex ?: 0)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      cancelTransition()
      // Loaded, not started. The contract (`AudioEngine.setQueue`) is that
      // playback does not start, and iOS keeps it — its `setQueue` stops and
      // goes idle. Android called `loadActiveTrack()` with its default
      // `play = true`, so every queue the host loaded to sit paused began
      // sounding anyway: a queue restored on cold launch, or a shuffle toggled
      // while paused, started playing with nothing pressed. A host that wants
      // sound calls `play` next; the async-function queue is serial and both
      // post to the main looper, so that `play` lands after this load.
      // Nothing is paused here either, so a `play` already given is kept.
      //
      // Android Auto is deliberately not touched by this. A car selection never
      // reaches `setQueue`: `PlaybackService` overrides neither
      // `onAddMediaItems` nor `onSetMediaItems`, so Media3's default controller
      // path (setMediaItems, prepare, play) starts playback on its own.
      loadActiveTrack(play = false)
      // Unconditionally, because the interesting case is the empty one.
      // `loadActiveTrack` returns early when there is no active track, so
      // `setQueue(emptyList())` takes the queue from n tracks to none while
      // calling no player method at all — and "next" would go on being
      // advertised for a track that is no longer there. The non-empty case
      // does not need this (the media item changes and the player says so),
      // but over-calling is free and the exemption is the part that was wrong.
      commandsMayHaveChanged()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
      // The first track of a queue was the one track that never announced
      // itself. `onTrackChange` was sent only from `advanceTo` and from the
      // crossfade, both of which describe *leaving* a track — so a host that
      // learns what is playing from `trackChange` alone (as an iOS host can:
      // there the event comes from `beginTrack`, which runs for the first
      // track too) knew nothing until the second track began. `setQueue` is
      // this side's `beginTrack`: `loadActiveTrack` above has already made
      // the track active, though it sounds only once the host calls `play`.
      queue.activeTrack?.let { active ->
        sendEvent(
          "onTrackChange",
          mapOf(
            "index" to queue.activeIndex,
            "id" to active.id,
            // Nothing preceded it, so there is nothing listened to report.
            "previousListenedSec" to null,
          ),
        )
      }
    }

    AsyncFunction("append") { tracks: List<TrackRecord> ->
      queue.append(tracks)
      tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
      // No player call. The voice holds only the track being played, so
      // appending changes what happens *next* and nothing that is happening.
      // Which is exactly why the session has to be told: "next" may have gone
      // from impossible to possible and nothing else will mention it.
      commandsMayHaveChanged()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    AsyncFunction("getActiveIndex") {
      queue.activeIndex
    }

    // MARK: queue editing
    //
    // The queue object keeps the index rule (see PlaybackQueue), and the player
    // is edited through Media3's own timeline operations rather than by pushing
    // the whole queue again. That difference is the whole point: `setMediaItems`
    // restarts the current item from zero, so re-pushing on every edit would
    // restart the song whenever anything else in the list moved.

    AsyncFunction("insertAt") { index: Int, tracks: List<TrackRecord> ->
      if (tracks.isNotEmpty()) {
        val at = index.coerceIn(0, queue.tracks.size)
        queue.insert(tracks, at)
        tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
        commandsMayHaveChanged()
        sendEvent("onQueueChange", emptyMap<String, Any?>())
      }
    }

    AsyncFunction("removeAt") { index: Int ->
      if (index in queue.tracks.indices) {
        queue.remove(index)
        commandsMayHaveChanged()
        sendEvent("onQueueChange", emptyMap<String, Any?>())
      }
    }

    AsyncFunction("move") { from: Int, to: Int ->
      if (from in queue.tracks.indices) {
        val destination = to.coerceIn(0, queue.tracks.size - 1)
        if (from != destination) {
          queue.move(from, destination)
          commandsMayHaveChanged()
          sendEvent("onQueueChange", emptyMap<String, Any?>())
        }
      }
    }

    AsyncFunction("clearQueue") {
      // Before anything is cleared, as iOS does: a clear that empties the app's
      // idea of the queue and leaves the player holding the old one is worse
      // than one that refuses outright and says why.
      val player = requireGraph().activeVoice.player
      queue.clear()
      cancelTransition()
      onMain {
        artworkRequestToken += 1
        player.clearMediaItems()
      }
      TrackHeaders.clear()
      commandsMayHaveChanged()
      sendEvent("onQueueChange", emptyMap<String, Any?>())
    }

    // The only call that sends tracks *back* across the bridge, which is why it
    // is a device probe rather than a unit test: a declared shape that
    // typechecks and then throws at runtime is this module's recorded history.
    AsyncFunction("getQueue") {
      queue.tracks.map { it.toMap() }
    }

    AsyncFunction("setRepeatMode") { mode: String ->
      queue.repeatMode = mode
      // Media3 owns the timeline, so repeat is its decision to make rather than
      // something this module arranges by hand. The queue keeps its own copy
      // because `nextTrack` — and therefore the crossfade — has to agree.
      val media3 = when (mode) {
        "one" -> Player.REPEAT_MODE_ONE
        "all" -> Player.REPEAT_MODE_ALL
        else -> Player.REPEAT_MODE_OFF
      }
      val graph = requireGraph()
      onMain {
        graph.voiceA.player.repeatMode = media3
        graph.voiceB.player.repeatMode = media3
      }
      // `all` gives the last track a next and `off` takes it away again.
      commandsMayHaveChanged()
    }

    // MARK: transport
    //
    // Play, pause and seek go through the *active voice's* ExoPlayer, which
    // holds exactly one track. Next and previous do not: with a one-item
    // timeline there is nothing for Media3 to seek to, so they ask the engine,
    // which is where the queue is — the same route the media session's own
    // buttons take, so a lock screen and the app cannot disagree about what
    // "next" means.
    //
    // All of it via `onPlayer`/`onMain`, because a player may only be touched
    // on the thread that built it and an `AsyncFunction` body is not that
    // thread.

    /*
     `play()` on ExoPlayer only sets `playWhenReady`. A player in `STATE_IDLE`
     — where a fatal `PlaybackException` leaves it, and where `stop()` puts it
     — produces nothing until `prepare()` is called, and `prepare` is reached
     from exactly two places here, both of which load a *different* track. So
     after a stream failed, or after a host `stop()`, pressing play did nothing
     at all and there was no error to say why.

     The same defect iOS had, in this platform's vocabulary: there, `play()`
     resumed a `TrackPlayback` that had been stopped and could never sound
     again. Both now re-establish instead of resuming a corpse.
    */
    AsyncFunction("play") {
      onPlayer {
        if (it.playbackState == Player.STATE_IDLE) it.prepare()
        it.play()
      }
    }
    AsyncFunction("pause") { onPlayer { it.pause() } }
    AsyncFunction("stop") { onPlayer { it.stop() } }

    AsyncFunction("seekTo") { positionSec: Double ->
      onPlayer { it.seekTo((positionSec * 1000).toLong()) }
    }

    AsyncFunction("skipToNext") { skipToNextTrack() }

    AsyncFunction("skipToPrevious") {
      // Media3's own "previous" rewinds to the head of the current track first
      // when far enough in, which is the platform convention and what the car's
      // button is expected to do. Deliberately not overridden to always change
      // track: that would be this engine disagreeing with every other player on
      // the device.
      skipToPreviousTrack()
    }

    AsyncFunction("skipToIndex") { index: Int ->
      onMain {
        if (index in queue.tracks.indices) {
          cancelTransition()
          advanceTo(index, listenedSeconds())
        }
      }
    }

    // Both voices, for the same reason the equalizer sets both: during a
    // crossfade the pair is audible together, and a speed applied to one of
    // them would be heard as the two drifting apart.
    AsyncFunction("setSpeed") { speed: Double ->
      val rate = speed.coerceIn(0.25, 4.0).toFloat()
      val graph = requireGraph()
      onMain {
        graph.voiceA.player.setPlaybackSpeed(rate)
        graph.voiceB.player.setPlaybackSpeed(rate)
      }
    }

    /**
     * The user's volume, which is not the fade and not the track's own gain.
     *
     * Written to [ExoPlayer.setVolume] on *both* voices. Both, because during a
     * crossfade two players are producing audio and setting one would make the
     * change audible as a lurch halfway through the fade. The fade itself rides
     * on `FadeAudioProcessor`, so this cannot fight it — which is the separation
     * [AudioGraph.Voice] exists to keep.
     */
    AsyncFunction("setVolume") { volume: Double ->
      userVolume = volume.coerceIn(0.0, 1.0).toFloat()
      onMain { applyVolume() }
    }

    // MARK: sleep timer

    AsyncFunction("sleepAfter") { seconds: Double -> sleepTimer.schedule(seconds) }
    AsyncFunction("cancelSleep") { sleepTimer.cancel() }

    // MARK: cache
    //
    // Deliberately *not* on the main thread, and this is the one place in the
    // file where that is right. "Reaching the player" below says every player
    // call must hop to main, because ExoPlayer throws off its own thread.
    // `Cache.removeResource` is annotated `@WorkerThread` and walks the index
    // and the filesystem per key, so it must *not* run there. An
    // `AsyncFunction` body already runs on a background dispatcher, which means
    // these three are correct exactly as written and wrapping them in `onMain`
    // — for consistency with everything around them — would be the bug.
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

    AsyncFunction("getState") { readPlayer("idle") { stateName(it) } }

    /**
     * Asked rather than waited for — the same reason as iOS. A screen mounting
     * mid-track would otherwise show zero until the next tick.
     */
    AsyncFunction("getProgress") {
      readPlayer(mapOf("positionSec" to 0.0, "durationSec" to 0.0, "bufferedSec" to 0.0)) {
        mapOf(
          "positionSec" to it.currentPosition.coerceAtLeast(0) / 1000.0,
          // Media3 says TIME_UNSET for a duration it does not know yet, and for
          // a live stream. The contract says 0 there, not a negative sentinel
          // leaking into a progress bar.
          "durationSec" to it.duration.let { ms -> if (ms == androidx.media3.common.C.TIME_UNSET) 0.0 else ms / 1000.0 },
          // Absolute, on the same timeline as the position — matching iOS, and
          // for the reason it gives: a buffering bar is drawn against the same
          // scale as the progress bar. Media3's `bufferedPosition` is already
          // absolute, so this is the raw figure rather than a difference.
          "bufferedSec" to it.bufferedPosition.coerceAtLeast(0) / 1000.0,
        )
      }
    }

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

    /**
     * Loudness normalisation, from the host's tags.
     *
     * Folded into the player's volume together with the user's setting, because
     * both are static multipliers and there is only one channel free — the fade
     * processor is the crossfade's and must stay that way. Recomputed on the
     * active track whenever either half changes.
     */
    AsyncFunction("setReplayGain") { options: ReplayGainRecord ->
      replayGain = ReplayGainSettings(
        mode = ReplayGainMode.from(options.mode),
        preampDb = options.preampDb,
        untaggedPreampDb = options.untaggedPreampDb,
        preventClipping = options.preventClipping,
      )
      onMain { applyVolume() }
    }

    AsyncFunction("setCrossfade") { options: CrossfadeRecord? ->
      queue.crossfade = options
    }

    AsyncFunction("setSampleRateMode") { mode: String ->
      // Enforced rather than merely recorded: overlapping sources have to share
      // a rate, so matching the source and crossfading are mutually exclusive.
      // The engine resolves the contradiction instead of leaving two settings
      // to fight, and tells the host it did.
      //
      // Android reaches the same conclusion by a different route than iOS. There
      // is no `setPreferredSampleRate` here, so nothing stops the engine
      // mechanically — but honouring the source rate means letting one
      // AudioTrack dictate the output configuration, and the second voice would
      // be resampled into it silently, which is exactly the thing the mode is
      // asked for to avoid. Refusing is more honest than pretending.
      if (mode == "match-source" && queue.crossfade != null) {
        queue.crossfade = null
        sendEvent(
          "onError",
          mapOf(
            "code" to "CROSSFADE_DISABLED",
            "message" to "Crossfade turned off: matching the source sample rate cannot overlap two tracks.",
          ),
        )
      }
      queue.sampleRateMode = mode
    }

    // MARK: platform surfaces
    //
    // These two have no counterpart in ios/YuzicEngineModule.swift yet — it is a
    // partial file and stops before them. They are declared here anyway because
    // [PlaybackService] has no other way to be handed a browse tree, and a
    // MediaLibraryService with no root is invisible in the car. Names and
    // argument shapes are taken from `src/AudioEngine.ts` so that the iOS
    // implementations, when they land, have nothing to negotiate.

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
      PlaybackService.browseRoot = buildBrowseTree(title, nodes)
    }

    AsyncFunction("clearBrowseTree") {
      PlaybackService.browseRoot = null
    }

    AsyncFunction("setCommands") { commands: List<String> ->
      PlaybackService.enabledCommands = commands.toSet()
      // Deliberately not re-issued to already-connected controllers. Media3 asks
      // for the command set once, at connect; a car that is already connected
      // keeps the set it was given until it reconnects. Forcing a reconnect to
      // apply a new set would drop the notification mid-track, which is a worse
      // trade than a stale button.
    }
  }

  // MARK: - Reaching the player
  //
  // ExoPlayer checks the calling thread on every method and throws if it is not
  // the one the player was built on. That is the service's main thread, because
  // `PlaybackService.onCreate` is where the graph is made. An Expo
  // `AsyncFunction` body runs on a background dispatcher, so *every* call has to
  // hop — there is no such thing as a cheap read here.

  /** The same cap iOS uses, for the same reason: a bad parent id must not recurse forever. */
  private val BROWSE_MAX_DEPTH = 16

  private val main = Handler(Looper.getMainLooper())

  /**
   * The two static multipliers that share `ExoPlayer.volume`.
   *
   * Held here rather than read back off the player, because the product of the
   * pair is what the player stores — asking it for the volume would give the
   * product and there would be no way to change one without inventing the
   * other.
   */
  private var userVolume: Float = 1.0f
  private var replayGain: ReplayGainSettings = ReplayGainSettings.OFF

  /**
   * Fade the music out, then pause — not the other way round, and not a cut.
   *
   * Music stopping mid-bar is the thing that wakes people, which defeats the
   * whole feature. The pause is scheduled for the end of the fade rather than
   * chained to a completion callback because `FadeAudioProcessor` has none: it
   * ramps in the audio thread and nothing tells anyone when it arrives.
   */
  private val sleepTimer = SleepTimer { fadeSeconds ->
    val graph = PlaybackService.graph ?: return@SleepTimer
    // Linear, explicitly: this is one voice going to silence with nothing to
    // sum against, so equal power would hold it near full volume for half the
    // fade and then drop it. Sleep is the case that curve is worst for.
    graph.ramp(graph.activeVoice, 0f, fadeSeconds, AudioGraph.FadeCurve.LINEAR)
    main.postDelayed({
      graph.activeVoice.player.pause()
      // Put the fade back where it was found. Without this, pressing play the
      // next morning starts a track at zero gain and looks like a dead player
      // — the same bug the iOS engine calls out at PlaybackEngine.swift:163.
      graph.ramp(graph.activeVoice, 1f, 0.0, AudioGraph.FadeCurve.LINEAR)
    }, (fadeSeconds * 1000).toLong())
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
   * The graph, or a thrown error — never a silent no-op.
   *
   * Used by commands. Getters keep their fallbacks on purpose, which is the
   * same split iOS makes in `requireEngine`: "nothing is playing" is a truthful
   * answer before setup, and a progress poll that throws during launch would be
   * noise rather than signal.
   */
  private fun requireGraph(): AudioGraph =
    PlaybackService.graph ?: throw EngineNotSetUpException()

  /**
   * Fire-and-forget onto the active voice.
   *
   * The check is deliberately *outside* `onMain`. A command posted to the main
   * thread and only then found to have no graph has already resolved its
   * promise successfully, so the failure has nowhere left to go — the listener
   * presses play, nothing happens, and nothing is reported. Resolving the
   * player here means the throw happens on the calling thread and reaches the
   * host as a rejection, which is what iOS has always done.
   */
  private fun onPlayer(block: (ExoPlayer) -> Unit) {
    val player = requireGraph().activeVoice.player
    onMain { block(player) }
  }

  private fun onMain(block: () -> Unit) {
    if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
  }

  /**
   * Read something off the player and wait for it.
   *
   * Blocking, which is why it is only used by the two imperative getters and
   * never on a path that runs per frame. The timeout is not a nicety: if the
   * main thread is wedged, returning the default late is survivable and
   * deadlocking the JS call is not.
   */
  private fun <T> readPlayer(fallback: T, block: (ExoPlayer) -> T): T {
    val player = PlaybackService.graph?.activeVoice?.player ?: return fallback
    if (Looper.myLooper() == Looper.getMainLooper()) return block(player)

    var result = fallback
    val done = CountDownLatch(1)
    main.post {
      try {
        result = block(player)
      } finally {
        done.countDown()
      }
    }
    done.await(1, TimeUnit.SECONDS)
    return result
  }

  /**
   * Media3's playback state, in the vocabulary `PlaybackState` in src/types.ts
   * uses.
   *
   * `READY` splits on `playWhenReady`, because Media3 calls a paused track ready
   * and the host's word for that is "paused". Collapsing the two is how a play
   * button ends up showing the wrong glyph.
   */
  private fun stateName(player: ExoPlayer): String = when (player.playbackState) {
    Player.STATE_IDLE -> "idle"
    Player.STATE_BUFFERING -> "buffering"
    Player.STATE_READY -> if (player.playWhenReady) "playing" else "paused"
    Player.STATE_ENDED -> "ended"
    else -> "idle"
  }

  /**
   * Keep [PlaybackQueue.activeIndex] level with the player after a skip.
   *
   * The queue is the thing `getActiveIndex` answers from and the thing the
   * transition rules read, but Media3 owns the timeline and moves the playhead
   * itself. Without this the two disagree the moment anyone presses next, and
   * the crossfade rules start reasoning about the wrong pair of tracks.
   */
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
  private fun buildBrowseTree(title: String, flat: List<FlatBrowseNodeRecord>): BrowseNodeRecord {
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
        playable = node.playable
        children = if (depth >= BROWSE_MAX_DEPTH) emptyList()
        else childrenByParent[node.id].orEmpty().map { assemble(it, depth + 1) }
      }

    return BrowseNodeRecord().apply {
      id = "root"
      this.title = title
      children = roots.map { assemble(it, 1) }
    }
  }

  // MARK: - Telling the host what happened
  //
  // Until this existed, `onProgress`, `onStateChange` and `onTrackChange` were
  // declared in `Events(...)` and emitted by nothing, so a host on Android
  // could ask where it was and never be told. The three come from two places:
  // Media3 pushes state and track transitions, and position has to be polled
  // because no player anywhere reports it continuously.

  private var progressIntervalMs: Long = 1000
  private var lastState: String? = null
  /**
   * How long the current track has actually been audible.
   *
   * Two values rather than a start time, for the same two reasons the iOS
   * engine keeps them (`PlaybackEngine.listenedAccumulated`): a start time
   * measures wall clock, and a paused player is not listening. This figure is
   * `previousListenedSec`, which hosts judge scrobble thresholds against, so
   * counting a pause submits plays to Last.fm and ListenBrainz for music
   * nobody heard.
   *
   * `listeningSinceMillis` is 0 while nothing is audible.
   */
  private var listenedAccumulatedMillis: Long = 0
  private var listeningSinceMillis: Long = 0
  private var observing = false

  private var lastProgressEmitMillis: Long = 0

  /**
   * One timer, two rates.
   *
   * It runs at a fixed 250ms because that is what deciding when to start a
   * crossfade needs — the fade should begin within a frame or so of its mark.
   * `onProgress` is emitted at `progressIntervalMs`, which is a *display*
   * setting and stays honoured. Running the whole thing at the display rate
   * would be cheaper and wrong: a host that asked for progress once every five
   * seconds would silently get its crossfades up to five seconds late, which is
   * a setting about a progress bar changing what the audio does.
   */
  private val ticker = object : Runnable {
    override fun run() {
      val now = System.currentTimeMillis()
      if (now - lastProgressEmitMillis >= progressIntervalMs) {
        lastProgressEmitMillis = now
        emitProgress()
      }
      maybeBeginTransition()
      main.postDelayed(this, TICK_INTERVAL_MS)
    }
  }

  private val playerListener = object : Player.Listener {
    override fun onPlaybackStateChanged(state: Int) {
      emitStateIfChanged()
      if (state != Player.STATE_ENDED) return
      // Identity, not timing. This listener is on both voices, and an outgoing
      // voice reaching its own natural end during the second half of a fade is
      // not the current track finishing — advancing on it is the double-advance
      // iOS hit, in the shape Android grows it in. Asking whether the *active*
      // voice is the one that ended holds whatever the timing.
      val graph = PlaybackService.graph ?: return
      if (graph.activeVoice.player.playbackState != Player.STATE_ENDED) return
      handleTrackFinished()
    }

    /**
     * Open or close the listening stretch as audio starts and stops.
     *
     * Asks whether *any* voice is playing rather than trusting this callback's
     * own argument, because this listener is attached to both. During a
     * crossfade the pair overlaps, and the outgoing voice reporting `false` at
     * the end of a fade does not mean the listener stopped hearing anything —
     * taking it at face value would stop the clock while the incoming track
     * plays on.
     */
    override fun onIsPlayingChanged(isPlaying: Boolean) {
      if (anyVoicePlaying()) openListeningStretch() else closeListeningStretch()
      emitStateIfChanged()
    }
    override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) = emitStateIfChanged()

    override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
      sendEvent(
        "onError",
        mapOf(
          "code" to "PLAYBACK_FAILED",
          "message" to (error.message ?: error.errorCodeName),
        ),
      )
    }
  }

  /** Main thread only — both the listener and the ticker touch the player. */
  private fun startObserving() {
    if (observing) return
    val graph = PlaybackService.graph ?: return
    // Both voices, because during a crossfade the one that matters changes
    // halfway through and a listener on only the foreground player would go
    // quiet for the second half of every transition.
    graph.voiceA.player.addListener(playerListener)
    graph.voiceB.player.addListener(playerListener)
    observing = true
    // Deliberately *not* started here. This used to set the origin at setup,
    // so the first track change reported the time since the engine was set up
    // rather than the time anyone spent listening — two runs of the same
    // scenario reported 15.3s and 33.8s, which varied with how long the tester
    // took to press play. The clock starts when audio does, in
    // `onIsPlayingChanged`.
    resetListened()
    lastProgressEmitMillis = 0
    main.postDelayed(ticker, TICK_INTERVAL_MS)
  }

  /** True while either voice is producing audio. Main thread only. */
  private fun anyVoicePlaying(): Boolean {
    val graph = PlaybackService.graph ?: return false
    return graph.voiceA.player.isPlaying || graph.voiceB.player.isPlaying
  }

  /** Start counting. Idempotent, so an already-open stretch is not restarted. */
  private fun openListeningStretch() {
    if (listeningSinceMillis == 0L) listeningSinceMillis = System.currentTimeMillis()
  }

  /** Bank the open stretch. Idempotent, so a second pause cannot count it twice. */
  private fun closeListeningStretch() {
    if (listeningSinceMillis == 0L) return
    listenedAccumulatedMillis += System.currentTimeMillis() - listeningSinceMillis
    listeningSinceMillis = 0L
  }

  /**
   * Played seconds for the track that is ending, or null if it never played.
   *
   * Null rather than zero: a host cannot tell a track nobody heard from one
   * heard for under half a second if both arrive as 0.0, and only one of those
   * should ever be considered for a scrobble.
   */
  private fun listenedSeconds(): Double? {
    val open = if (listeningSinceMillis > 0) System.currentTimeMillis() - listeningSinceMillis else 0L
    val total = listenedAccumulatedMillis + open
    return if (total > 0) total / 1000.0 else null
  }

  /** Zero the count for a new track, keeping the clock running if audio is. */
  private fun resetListened() {
    listenedAccumulatedMillis = 0
    listeningSinceMillis = if (anyVoicePlaying()) System.currentTimeMillis() else 0L
  }

  private fun stopObserving() {
    val graph = PlaybackService.graph
    graph?.voiceA?.player?.removeListener(playerListener)
    graph?.voiceB?.player?.removeListener(playerListener)
    main.removeCallbacks(ticker)
    observing = false
    lastState = null
  }

  /**
   * Only on an actual change, matching the iOS engine, where `state` emits from
   * a `didSet` guarded on inequality. Media3 fires its callbacks more often
   * than the state changes — `onPlayWhenReadyChanged` alone repeats for every
   * pause reason — and a host re-rendering on each one is a cost it did not ask
   * for.
   */
  private fun emitStateIfChanged() {
    val player = PlaybackService.graph?.activeVoice?.player ?: return
    val state = stateName(player)

    /*
     `ended` means the queue ran out, not that a track did.

     `setPauseAtEndOfMediaItems(true)` makes every track end in `STATE_ENDED`,
     including the ones with another track behind them, and this is called
     before the advance — so a host saw `playing → ended → buffering → playing`
     at every boundary while iOS emitted `ended` only when the queue was
     actually finished. A host that clears now-playing on `ended`, which is the
     obvious reading, misbehaved on Android alone.

     Suppressed rather than renamed, and `lastState` is deliberately not
     updated: the advance that follows emits `buffering` a moment later, and
     that is the honest description of what is happening.
    */
    if (state == "ended" && queue.nextIndex != null) return

    if (state == lastState) return
    lastState = state
    sendEvent("onStateChange", mapOf("state" to state))
  }

  private fun emitProgress() {
    val player = PlaybackService.graph?.activeVoice?.player ?: return
    val duration = player.duration
    sendEvent(
      "onProgress",
      mapOf(
        "positionSec" to player.currentPosition.coerceAtLeast(0) / 1000.0,
        "durationSec" to if (duration == androidx.media3.common.C.TIME_UNSET) 0.0 else duration / 1000.0,
        // Absolute, as in `getProgress` and on iOS — see Progress.bufferedSec.
        "bufferedSec" to player.bufferedPosition.coerceAtLeast(0) / 1000.0,
      ),
    )
  }

  /**
   * Tell the session the command set may have moved.
   *
   * Called after any queue change that does not touch the player, because those
   * are exactly the ones nothing else will announce. Cheap, idempotent, and
   * safe to over-call: it re-reads a set and hands it to listeners that compare
   * before acting.
   */
  private fun commandsMayHaveChanged() = onMain {
    PlaybackService.onCommandsMayHaveChanged?.invoke()
  }

  /**
   * Push `user volume × replay gain` to both voices, each for its own track.
   *
   * Both, because during a crossfade two of them are audible and leaving one
   * behind makes the change lurch halfway through the fade. Each for its own
   * track, because the two rarely share a gain. Main thread only.
   */
  private fun applyVolume() {
    val graph = PlaybackService.graph ?: return
    applyVolumeTo(graph.activeVoice, queue.activeTrack)
    // The idle voice carries the incoming track during a fade, and two tracks
    // rarely share a replay gain. Setting both from the active track — correct
    // while only one voice was ever audible — would apply the outgoing track's
    // correction to the incoming one for the whole overlap, which is the error
    // replay gain exists to remove.
    applyVolumeTo(graph.idleVoice, incomingTrack)
  }

  /** One voice, corrected for the track *that voice* is carrying. */
  private fun applyVolumeTo(voice: AudioGraph.Voice, track: TrackRecord?) {
    val gain = if (track == null) 1.0f else ReplayGain.linearGain(track, replayGain)
    voice.player.volume = userVolume * gain
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

    // `onMain`, like every other player touch — this is the rule stated in the
    // transport section above, and these four lines were the one place that
    // broke it.
    //
    // It survived because of *when* it fails. On the first `setup()` of a
    // process the service does not exist yet (it is started by the
    // `buildAsync` below), so `graph` is null, the block is skipped, and
    // nothing is touched from the wrong thread. Every call after that finds a
    // graph and throws `Player is accessed on the wrong thread` — which broke
    // the idempotency the comment below promises, and meant only the first
    // probe of an app launch could run.
    onMain {
      PlaybackService.graph?.let { graph ->
        graph.voiceA.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
        graph.voiceB.player.setHandleAudioBecomingNoisy(pauseOnBecomingNoisy)
      }
    }

    // Idempotent, as the contract in src/AudioEngine.ts requires: a second call
    // reconfigures rather than restarting, because tearing the session down
    // mid-playback is audible.
    if (controllerFuture != null) return

    val token = SessionToken(context, ComponentName(context, PlaybackService::class.java))
    controllerFuture = MediaController.Builder(context, token).buildAsync()
  }

  /**
   * Fetch protected artwork through the same certificate-aware transport as
   * audio. Media3 has no artwork-header field, so the URL is never handed to
   * its image loader when headers are required; the completed bytes replace the
   * now-playing item's metadata instead.
   */
  private fun requestProtectedArtwork(track: TrackRecord, player: ExoPlayer) {
    val artworkUri = track.artworkUri
    val headers = track.artworkHeaders
    val token = ++artworkRequestToken
    if (artworkUri.isNullOrEmpty() || headers.isNullOrEmpty()) return

    val request = try {
      Request.Builder()
        .url(artworkUri)
        .apply { headers.forEach { (name, value) -> header(name, value) } }
        .build()
    } catch (_: IllegalArgumentException) {
      return
    }

    PlaybackService.clientCertificateTransport.audioCallFactory.newCall(request).enqueue(object : Callback {
      override fun onFailure(call: Call, e: IOException) = Unit

      override fun onResponse(call: Call, response: Response) {
        val artwork = response.use {
          if (!it.isSuccessful) return
          it.body?.bytes()
        } ?: return
        if (artwork.isEmpty()) return

        onMain {
          // A response can finish after a skip, queue replacement, or voice
          // swap. Replacing metadata is safe only for the exact active request.
          if (
            token != artworkRequestToken ||
            queue.activeTrack !== track ||
            PlaybackService.graph?.activeVoice?.player !== player ||
            player.currentMediaItem?.mediaId != track.id
          ) return@onMain
          player.replaceMediaItem(player.currentMediaItemIndex, track.toNowPlayingMediaItem(artwork))
        }
      }
    })
  }

  private fun loadActiveTrack(positionMs: Long = 0L, play: Boolean = true) = onMain {
    val graph = PlaybackService.graph ?: return@onMain
    val track = queue.activeTrack ?: return@onMain
    val player = graph.activeVoice.player
    player.setMediaItem(track.toNowPlayingMediaItem(), positionMs)
    player.prepare()
    requestProtectedArtwork(track, player)
    // The active track changed, so its replay gain did too. Set before anything
    // is audible rather than after: a track arriving at the wrong loudness and
    // being corrected a moment later is exactly what the feature is meant to
    // prevent.
    applyVolume()
    if (play) player.play()
  }

  // MARK: - Advancing, and the overlap
  //
  // Every advance is the engine's decision. Media3 is told not to advance by
  // itself (`setPauseAtEndOfMediaItems`), each voice holds one track, and what
  // follows it is chosen here — cut or fade, honouring repeat.

  private var transitioning = false
  private var incomingTrack: TrackRecord? = null

  /**
   * Which transition a scheduled crossover belongs to.
   *
   * The crossover is a delayed runnable and cannot be unposted from everywhere
   * that cancels a fade, so it checks that the transition it was scheduled for
   * is still the current one. A bare boolean would let a *new* fade's flag
   * satisfy an *old* fade's runnable, which is the same identity mistake as
   * advancing on the wrong voice.
   */
  private var transitionToken = 0

  private fun maybeBeginTransition() {
    if (transitioning) return
    val graph = PlaybackService.graph ?: return
    val player = graph.activeVoice.player
    if (!player.isPlaying) return
    val fade = queue.transitionDuration(userInitiated = false)
    val duration = player.duration
    if (duration == C.TIME_UNSET || duration <= 0) return
    if (!shouldBeginTransition(player.currentPosition / 1000.0, duration / 1000.0, fade)) return
    beginTransition(fade)
  }

  /**
   * Start the overlap: the next track begins on the idle voice while this one
   * is still audible, and the pair cross at the midpoint.
   */
  private fun beginTransition(durationSec: Double) {
    val graph = PlaybackService.graph ?: return
    val nextIndex = queue.nextIndex ?: return
    val next = queue.tracks.getOrNull(nextIndex) ?: return

    transitioning = true
    transitionToken += 1
    val token = transitionToken
    incomingTrack = next

    val incoming = graph.idleVoice
    val outgoing = graph.activeVoice
    TrackHeaders.register(next.uri, next.headers)
    incoming.player.setMediaItem(next.toNowPlayingMediaItem(), 0L)
    incoming.player.prepare()
    // Before the fade begins rather than at the crossover: a track arriving at
    // the wrong loudness and being corrected halfway through the overlap is
    // audible in exactly the way replay gain exists to prevent.
    applyVolumeTo(incoming, next)
    graph.ramp(incoming, 1f, durationSec, AudioGraph.FadeCurve.EQUAL_POWER)
    graph.ramp(outgoing, 0f, durationSec, AudioGraph.FadeCurve.EQUAL_POWER)
    incoming.player.play()

    val listened = listenedSeconds()
    val halfMillis = (durationSec / 2.0 * 1000).toLong()

    // Halfway through is when the incoming track becomes the one being heard,
    // so that is when it becomes the one being reported.
    main.postDelayed({
      if (token != transitionToken) return@postDelayed
      graph.swapVoices()
      queue.set(queue.tracks, nextIndex)
      requestProtectedArtwork(next, incoming.player)
      incomingTrack = null
      transitioning = false
      // The incoming track has been audible since the fade began, half a fade
      // ago, so it starts with that much already listened rather than at zero.
      listenedAccumulatedMillis = halfMillis
      listeningSinceMillis = if (anyVoicePlaying()) System.currentTimeMillis() else 0L
      applyVolume()
      sendEvent(
        "onTrackChange",
        mapOf("index" to nextIndex, "id" to next.id, "previousListenedSec" to listened),
      )
    }, halfMillis)

    // The outgoing voice stops at the *end* of the fade, not at the crossover.
    // Stopping it at the midpoint cuts its own fade-out dead at the halfway
    // gain — equal power puts that at 0.707, so the track would drop abruptly
    // from about three-quarters volume instead of fading away. It also strands
    // the ramp: the gain never reaches zero, and this voice is the *incoming*
    // one next time, which would then start audible at 0.707 rather than
    // rising from silence.
    main.postDelayed({
      if (token != transitionToken) return@postDelayed
      outgoing.player.stop()
    }, (durationSec * 1000).toLong())
  }

  /**
   * Next and previous, shared by the JS surface and the media session.
   *
   * Both spellings reach the same code because they are the same intent: the
   * host asking for another track. Routing the session's buttons somewhere
   * else is how a lock screen and an app end up disagreeing about what
   * "next" means.
   */
  private fun skipToNextTrack() = onMain {
    // A skip is `userInitiated`, so `transitionDuration` gives zero and the
    // change is a cut: a fade is for a track that ended, and eight seconds of
    // politeness after a button press reads as lag.
    cancelTransition()
    // `skipNextIndex`, not `nextIndex`: repeat `one` repeats a track that
    // *ended*, and a pressed next button is a request to leave it.
    queue.skipNextIndex?.let { advanceTo(it, listenedSeconds()) }
  }

  private fun skipToPreviousTrack() = onMain {
    val player = PlaybackService.graph?.activeVoice?.player ?: return@onMain
    cancelTransition()
    if (player.currentPosition > PREVIOUS_RESTARTS_AFTER_MS || queue.activeIndex == 0) {
      player.seekTo(0L)
    } else {
      advanceTo(queue.activeIndex - 1, listenedSeconds())
    }
  }

  /** Abandon a fade in progress and put both voices back where they were. */
  private fun cancelTransition() = onMain {
    if (!transitioning) return@onMain
    transitioning = false
    transitionToken += 1
    incomingTrack = null
    val graph = PlaybackService.graph ?: return@onMain
    graph.idleVoice.player.stop()
    graph.ramp(graph.idleVoice, 0f, 0.0, AudioGraph.FadeCurve.LINEAR)
    graph.ramp(graph.activeVoice, 1f, 0.0, AudioGraph.FadeCurve.LINEAR)
  }

  /**
   * The active track reached its end without a fade having taken over.
   *
   * Asks the queue for what follows rather than adding one, so repeat is
   * honoured in the one place it has to be: `one` returns the same index and
   * the track starts again, `all` wraps instead of finishing.
   */
  private fun handleTrackFinished() {
    if (transitioning) return
    val listened = listenedSeconds()
    val next = queue.nextIndex ?: return
    advanceTo(next, listened)
  }

  /** Make `index` the active track and start it, reporting what came before. */
  private fun advanceTo(index: Int, previousListenedSec: Double?) {
    val track = queue.tracks.getOrNull(index) ?: return
    queue.set(queue.tracks, index)
    resetListened()
    loadActiveTrack()
    sendEvent(
      "onTrackChange",
      mapOf("index" to index, "id" to track.id, "previousListenedSec" to previousListenedSec),
    )
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

    /**
     * Whether it is time to start fading into the next track.
     *
     * Pure, and separated out for the same reason as its Swift counterpart:
     * this is the one piece worth reading on its own, and everything around it
     * is a clock. Kept identical to `PlaybackEngine.shouldBeginTransition`.
     */
    fun shouldBeginTransition(
      positionSec: Double, durationSec: Double, transitionSec: Double,
    ): Boolean {
      if (transitionSec <= 0.0 || durationSec <= 0.0) return false
      return positionSec >= durationSec - transitionSec
    }

    /**
     * How far into a track "previous" restarts it rather than going back one.
     * Matches what Media3's own `seekToPrevious` does, and what every other
     * player on the device does, so the car's button behaves as expected.
     */
    private const val PREVIOUS_RESTARTS_AFTER_MS = 3000L

    /**
     * How often the engine looks at the playhead. Fast enough that a crossfade
     * starts within a frame of its mark, cheap enough to leave running. Matches
     * the 0.25s `PlaybackEngine` ticks at on iOS.
     */
    private const val TICK_INTERVAL_MS = 250L
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
  @Field var playable: TrackRecord? = null
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
 * A node of the browse tree. Recursive, which Expo's record converter handles,
 * and which the iOS side does not yet declare — the tree arrives whole either
 * way, so the shape is dictated by `BrowseNode` in src/types.ts rather than by
 * either platform.
 */
class BrowseNodeRecord : Record {
  @Field var id: String = ""
  @Field var title: String = ""
  @Field var subtitle: String? = null
  @Field var artworkUri: String? = null
  @Field var children: List<BrowseNodeRecord>? = null
  @Field var playable: TrackRecord? = null
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
 * A track as Media3 sees it.
 *
 * The cache key is the host's `MediaId`, not the URI. Subsonic and Jellyfin both
 * hand out URLs carrying a token that rotates, so keying the cache on the URI
 * would re-download the same audio every session and the LRU would fill with
 * duplicates of one album.
 */
@UnstableApi
fun TrackRecord.toMediaItem(): MediaItem = MediaItem.Builder()
  .setMediaId(id)
  .setUri(Uri.parse(uri))
  .setCustomCacheKey(id)
  .setMediaMetadata(
    MediaMetadata.Builder()
      .setTitle(title)
      .setArtist(artist)
      .setAlbumTitle(album)
      .setArtworkUri(artworkUri?.let { Uri.parse(it) })
      .setIsBrowsable(false)
      .setIsPlayable(true)
      .build()
  )
  .build()

/**
 * The playback-only media item. Protected artwork deliberately has no URI:
 * Media3 cannot attach request headers to an artwork URI, and handing it one
 * would cause a second, unauthenticated fetch. Browse items keep using
 * [toMediaItem], so their artwork behavior is unchanged.
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
