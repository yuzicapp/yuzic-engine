package dev.yuzic.engine

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

/**
 * Android's playback controller: the queue, the two voices, every advance and
 * crossfade, the progress clock, and what the host is told about all of it.
 *
 * It lived in [YuzicEngineModule], which only exists while the host's
 * JavaScript does, and that was the one thing it could not afford. A car
 * starts [PlaybackService] on its own, Android Auto when the phone connects
 * and Android Automotive when the driver opens the media app, and neither
 * starts the host's JavaScript. With the controller inside the module, a car
 * with no app open had a library it could show and no one to play it: a
 * selection reached a service that had no queue, no advance and no voice
 * logic of its own. So the controller is the service's now, one per process
 * like the graph and the queue, and the module is a bridge to it. iOS has had
 * this shape all along, because there the engine is native to begin with.
 *
 * Every public function is safe from any thread, as the module's async
 * functions were: player work hops to the main thread, where ExoPlayer lives.
 * Events go to [PlaybackService.eventSink], which is null while no host is
 * listening, and the controller carries on regardless.
 */
@UnstableApi
internal class EngineCore {

  private val queue get() = PlaybackService.queue

  /**
   * Identifies the current now-playing artwork request. Network callbacks can
   * arrive after a skip, so only the request belonging to the current player
   * and track may update the session metadata.
   *
   * Main-thread confined: reads and increments happen in [onMain] or a main
   * handler callback.
   */
  private var artworkRequestToken = 0L

  /** To the host when one is listening; nowhere otherwise. */
  private fun sendEvent(name: String, body: Map<String, Any?>) {
    PlaybackService.eventSink?.invoke(name, body)
  }

  private val main = Handler(Looper.getMainLooper())

  /**
   * Where a failed track's cached bytes are dropped. `Cache.removeResource` is
   * `@WorkerThread`, and a player error arrives on main. One thread, so an
   * eviction and the error it precedes can never be reordered against another.
   */
  private val cacheWorker = Executors.newSingleThreadExecutor()

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
      val report = {
        sendEvent(
          "onError",
          mapOf(
            "code" to "PLAYBACK_FAILED",
            "message" to (error.message ?: error.errorCodeName),
          ),
        )
      }
      val key = if (failureMeansBadBytes(error.errorCode)) failingCacheKey() else null
      if (key == null) {
        report()
        return
      }
      // Evicted *before* the host hears about it, because hearing about it is
      // what makes the host retry, and a retry that reaches the cache first
      // reads the same bad body again. See `failureMeansBadBytes`.
      cacheWorker.execute {
        try {
          PlaybackService.graph?.evict(key)
        } catch (_: Exception) {
          // A failed eviction leaves the track as it was before this existed.
          // Not a reason to swallow the error the host needs to hear.
        }
        report()
      }
    }
  }

  /**
   * The cache key of the voice that has just failed. Main thread only.
   *
   * The listener is shared by both voices, and `onPlayerError` does not say
   * which one raised it; the player that did is the one holding an error.
   * The key is the item's custom cache key, which `toMediaItem` sets to the
   * `MediaId` — the same key `evict` takes.
   */
  private fun failingCacheKey(): String? {
    val graph = PlaybackService.graph ?: return null
    val failed = listOf(graph.voiceA.player, graph.voiceB.player)
      .firstOrNull { it.playerError != null } ?: return null
    val item = failed.currentMediaItem ?: return null
    return item.localConfiguration?.customCacheKey ?: item.mediaId
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

  /** Tell a car that is already showing the library to read it again. */
  private fun browseTreeChanged() = onMain {
    PlaybackService.onBrowseTreeChanged?.invoke()
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
   * Which track the truncation retries below belong to, and how many are left.
   *
   * Keyed on the track rather than cleared by whoever starts one, because
   * every path that loads a track would then have to remember to clear it and
   * one of them eventually would not. The id answers the question directly:
   * a different track is a different budget.
   */
  private var truncationRetriesFor: String? = null
  private var truncationRetries = 0

  /**
   * Whether an `ended` that just arrived landed a long way short of the song.
   *
   * The iOS engine has had this check since a transcoded stream was found
   * ending tracks part-way through with nothing thrown anywhere, and Android
   * had no equivalent at all — `handleTrackFinished` advanced on any
   * `STATE_ENDED`, whatever it meant. Media3 is more robust than the iOS
   * reader here and the fault is rarer, but it is not absent: a progressive
   * response that stops early, or one served with a `Content-Length` shorter
   * than the audio, reaches `ExoPlayer` as an input that ran out, and an input
   * that ran out *is* the end of the media as far as the player is concerned.
   * The queue then advances and the listener hears a song skip itself.
   *
   * Measured against the host's `durationSec` and nothing else, which is where
   * this deliberately parts company with the Swift version. There the reader's
   * own length is consulted as a second opinion on the ranged transport, since
   * it comes from a container the reader parsed. Media3 has no counterpart:
   * `player.duration` for a VBR MP3 with no Xing header is extrapolated from
   * the first frame's bitrate by `ConstantBitrateSeeker`, so it is a guess of
   * exactly the kind this check exists to disbelieve, and corroborating one
   * guess with another proves nothing. The host's metadata is the one fact
   * here that did not come out of the bytes.
   *
   * Main thread only — it reads the player.
   */
  private fun endedShortOfItsLength(player: ExoPlayer): Boolean {
    val track = queue.activeTrack ?: return false
    // A broadcast has no length to fall short of, and its `durationSec` is
    // whatever the host happened to send.
    if (track.continuous) return false
    val declared = track.durationSec ?: return false
    if (declared <= 0.0) return false
    val position = player.currentPosition.coerceAtLeast(0) / 1000.0
    return position < declared - TRUNCATION_TOLERANCE_SEC
  }

  /**
   * The active track reached its end without a fade having taken over.
   *
   * Asks the queue for what follows rather than adding one, so repeat is
   * honoured in the one place it has to be: `one` returns the same index and
   * the track starts again, `all` wraps instead of finishing.
   *
   * Unless it did not actually end — see [endedShortOfItsLength]. An end that
   * arrived a long way before the end of the song is answered by preparing the
   * same track again at the second it stopped, which on this platform is what
   * reconnecting means: `loadActiveTrack` sets the media item afresh, so the
   * data source opens a new request rather than resuming a response that has
   * already finished. Bounded, because a server that keeps handing back the
   * same short encode would otherwise be asked forever.
   */
  private fun handleTrackFinished() {
    if (transitioning) return

    val player = PlaybackService.graph?.activeVoice?.player
    if (player != null && endedShortOfItsLength(player)) {
      val track = queue.activeTrack
      if (truncationRetriesFor != track?.id) {
        truncationRetriesFor = track?.id
        truncationRetries = 0
      }
      if (truncationRetries < MAX_TRUNCATION_RETRIES) {
        truncationRetries += 1
        loadActiveTrack(positionMs = player.currentPosition.coerceAtLeast(0))
        return
      }
      // Out of retries, and advancing now would be the silent skip this check
      // exists to stop. Said out loud instead, the same way iOS says it.
      val title = track?.title ?: "this track"
      // Paused rather than left to sit with `playWhenReady` still true, so
      // nothing resumes on the next route change and the host's transport
      // controls describe something real.
      //
      // The state event is deliberately *not* forced alongside it. Media3 is
      // in `STATE_ENDED` and `emitStateIfChanged` suppresses "ended" while a
      // next track exists, so a host watching `onStateChange` alone learns
      // less here than an iOS host does, which goes to `paused`. That is a
      // genuine divergence and it belongs in §13 of `docs/architecture.md`
      // rather than in a literal written at this call site: `Tools/parity.py`
      // reads the state vocabulary from emission sites, and a word introduced
      // here rather than in `stateName` reads to it as a state only one
      // platform has. The error below is what a host acts on either way.
      player.pause()
      sendEvent(
        "onError",
        mapOf(
          "code" to "PLAYBACK_FAILED",
          "message" to "$title stopped before it ended",
        ),
      )
      return
    }

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

  // MARK: - What the module and the service ask for
  //
  // The bodies of what were the module's async functions, unchanged but for
  // where they live. The comments that explain them stayed with them.

  fun setProgressInterval(ms: Long) {
    progressIntervalMs = ms.coerceAtLeast(100)
  }

  fun startObservingOnMain() = onMain { startObserving() }

  /**
   * A host has just started listening: tell it the state now.
   *
   * States are sent on a change, and the observation outlives any one host,
   * so a host that attached while a car was already playing heard nothing
   * until the next change and drew a play button over music that was
   * playing. Forgetting the last state sent makes the next check a change.
   */
  fun hostAttached() = onMain {
    lastState = null
    emitStateIfChanged()
  }

  /**
   * The service is going, and its graph with it. This outlives both, so it
   * lets go of the players now; otherwise it would go on believing it was
   * observing, and never attach to the next service's graph.
   */
  fun serviceStopping() = onMain { stopObserving() }

  /**
   * The host went away. Its events stop and its pending artwork is dropped;
   * the sleep timer and the queue's headers go with it, as they always did.
   */
  fun detachHost() {
    onMain {
      artworkRequestToken += 1
      stopObserving()
    }
    sleepTimer.cancel()
    TrackHeaders.clear()
  }

  fun setHandleAudioBecomingNoisy(pause: Boolean) = onMain {
    PlaybackService.graph?.let { graph ->
      graph.voiceA.player.setHandleAudioBecomingNoisy(pause)
      graph.voiceB.player.setHandleAudioBecomingNoisy(pause)
    }
  }

  fun setQueue(tracks: List<TrackRecord>, startIndex: Int) {
    queue.set(tracks, startIndex)
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

  /**
   * A queue a car chose, loaded the way the host's `setQueue` loads one.
   *
   * This is where a selection in Android Auto or Android Automotive arrives,
   * by way of the session's `setMediaItems`, whether or not the host is
   * running. It is `setQueue`, plus starting the observation the advance
   * depends on, because with no host there was nobody to call `setup` and
   * nothing else would start it, plus zeroing the listened time, because the
   * track being left is being replaced rather than advanced from. The session
   * calls `play` next, the same way a host would. A host that is running
   * hears about it through the same queue and track events as any queue.
   */
  fun setQueueFromController(tracks: List<TrackRecord>, startIndex: Int, positionMs: Long) {
    onMain { startObserving() }
    queue.set(tracks, startIndex)
    tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
    cancelTransition()
    onMain { resetListened() }
    loadActiveTrack(positionMs = positionMs.coerceAtLeast(0L), play = false)
    commandsMayHaveChanged()
    sendEvent("onQueueChange", emptyMap<String, Any?>())
    queue.activeTrack?.let { active ->
      sendEvent(
        "onTrackChange",
        mapOf("index" to queue.activeIndex, "id" to active.id, "previousListenedSec" to null),
      )
    }
  }

  fun append(tracks: List<TrackRecord>) {
    queue.append(tracks)
    tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
    // No player call. The voice holds only the track being played, so
    // appending changes what happens *next* and nothing that is happening.
    // Which is exactly why the session has to be told: "next" may have gone
    // from impossible to possible and nothing else will mention it.
    commandsMayHaveChanged()
    sendEvent("onQueueChange", emptyMap<String, Any?>())
  }

  val activeIndex: Int get() = queue.activeIndex

  fun insertAt(index: Int, tracks: List<TrackRecord>) {
    if (tracks.isEmpty()) return
    val at = index.coerceIn(0, queue.tracks.size)
    queue.insert(tracks, at)
    tracks.forEach { TrackHeaders.register(it.uri, it.headers) }
    commandsMayHaveChanged()
    sendEvent("onQueueChange", emptyMap<String, Any?>())
  }

  fun removeAt(index: Int) {
    if (index !in queue.tracks.indices) return
    queue.remove(index)
    commandsMayHaveChanged()
    sendEvent("onQueueChange", emptyMap<String, Any?>())
  }

  fun move(from: Int, to: Int) {
    if (from !in queue.tracks.indices) return
    val destination = to.coerceIn(0, queue.tracks.size - 1)
    if (from == destination) return
    queue.move(from, destination)
    commandsMayHaveChanged()
    sendEvent("onQueueChange", emptyMap<String, Any?>())
  }

  fun clearQueue() {
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

  fun queueAsMaps(): List<Map<String, Any?>> = queue.tracks.map { it.toMap() }

  fun setRepeatMode(mode: String) {
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
  fun play() = onPlayer {
    if (it.playbackState == Player.STATE_IDLE) it.prepare()
    it.play()
  }

  fun pause() = onPlayer { it.pause() }

  fun stop() = onPlayer { it.stop() }

  fun seekTo(positionSec: Double) = onPlayer { it.seekTo((positionSec * 1000).toLong()) }

  fun skipToNext() = skipToNextTrack()

  // Media3's own "previous" rewinds to the head of the current track first
  // when far enough in, which is the platform convention and what the car's
  // button is expected to do. Deliberately not overridden to always change
  // track: that would be this engine disagreeing with every other player on
  // the device.
  fun skipToPrevious() = skipToPreviousTrack()

  fun skipToIndex(index: Int) = onMain {
    if (index in queue.tracks.indices) {
      cancelTransition()
      advanceTo(index, listenedSeconds())
    }
  }

  // Both voices, for the same reason the equalizer sets both: during a
  // crossfade the pair is audible together, and a speed applied to one of
  // them would be heard as the two drifting apart.
  fun setSpeed(speed: Double) {
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
  fun setVolume(volume: Double) {
    userVolume = volume.coerceIn(0.0, 1.0).toFloat()
    onMain { applyVolume() }
  }

  fun sleepAfter(seconds: Double) = sleepTimer.schedule(seconds)

  fun cancelSleep() = sleepTimer.cancel()

  fun currentStateName(): String = readPlayer("idle") { stateName(it) }

  /**
   * Asked rather than waited for — the same reason as iOS. A screen mounting
   * mid-track would otherwise show zero until the next tick.
   */
  fun progress(): Map<String, Double> =
    readPlayer(mapOf("positionSec" to 0.0, "durationSec" to 0.0, "bufferedSec" to 0.0)) {
      mapOf(
        "positionSec" to it.currentPosition.coerceAtLeast(0) / 1000.0,
        // Media3 says TIME_UNSET for a duration it does not know yet, and for
        // a live stream. The contract says 0 there, not a negative sentinel
        // leaking into a progress bar.
        "durationSec" to it.duration.let { ms -> if (ms == C.TIME_UNSET) 0.0 else ms / 1000.0 },
        // Absolute, on the same timeline as the position — matching iOS, and
        // for the reason it gives: a buffering bar is drawn against the same
        // scale as the progress bar. Media3's `bufferedPosition` is already
        // absolute, so this is the raw figure rather than a difference.
        "bufferedSec" to it.bufferedPosition.coerceAtLeast(0) / 1000.0,
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
  fun setReplayGain(settings: ReplayGainSettings) {
    replayGain = settings
    onMain { applyVolume() }
  }

  fun setCrossfade(options: CrossfadeRecord?) {
    queue.crossfade = options
  }

  fun setSampleRateMode(mode: String) {
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

  fun setBrowseTree(context: Context?, title: String, nodes: List<FlatBrowseNodeRecord>) {
    PlaybackService.browseTreeGeneration.incrementAndGet()
    PlaybackService.browseRoot = buildBrowseTree(title, nodes)
    browseTreeChanged()
    // Kept for a car that starts the service with no JavaScript running.
    // After the tree is live, so a slow write never holds up the car.
    context?.let(BrowseTreeStore::forContext)?.save(title, nodes)
  }

  fun clearBrowseTree(context: Context?) {
    PlaybackService.browseTreeGeneration.incrementAndGet()
    PlaybackService.browseRoot = null
    browseTreeChanged()
    // A cleared tree has to stay cleared across a restart too, or a car
    // would bring back a library the host took away, a signed-out one
    // included.
    context?.let(BrowseTreeStore::forContext)?.clear()
  }

  companion object {
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

    /**
     * How far short of the track's real length an `ended` may land before it is
     * disbelieved. `PlaybackEngine.truncationToleranceSec`, to the second.
     *
     * Five is past anything an honest ending can disagree by — encoder padding
     * is fractions of a second and the tag a host reads is rounded to whole
     * ones — and far short of the shortfall a truncation produces, which is
     * the rest of the song.
     */
    private const val TRUNCATION_TOLERANCE_SEC = 5.0

    /**
     * How many times a track that stopped short is prepared again before it is
     * reported. `PlaybackEngine.maxStreamReconnects`, for the same reason it is
     * three there: enough to ride out a server having a bad moment, few enough
     * that one that is simply broken is named rather than retried forever.
     */
    private const val MAX_TRUNCATION_RETRIES = 3
  }
}
