package dev.yuzic.engine

import android.content.Context
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.annotation.WorkerThread
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import okhttp3.Call
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sinh

/**
 * The playback graph.
 *
 * Two players, not one. That is the whole reason this project exists rather
 * than a wrapper around a queue player: a crossfade is two sources overlapping,
 * and one output cannot overlap with itself. The voices alternate — while `a` is
 * playing, `b` is the one being prepared, and they swap at every transition — so
 * a fade is a gain ramp on each of a pair that are both already running.
 *
 *     playerA ─▶ eqA ─▶ fadeA ─┐
 *                              ├─▶ platform mixer ─▶ output
 *     playerB ─▶ eqB ─▶ fadeB ─┘
 *
 * **This is where Android's shape differs from iOS's and cannot be made to
 * match.** On iOS the EQ sits after `AVAudioMixerNode`, so a crossfade runs one
 * filter chain and the two halves of a fade are provably identical. Android has
 * no insertion point below an `ExoPlayer`'s own `AudioSink`: the next stage down
 * is AudioFlinger, which is not ours. So each voice carries its own copy of the
 * chain and `setEqualizer` writes the same coefficients to both. The cost is a
 * second filter cascade for the duration of a fade, and the obligation — met in
 * [setEqualizer] — never to update one voice's curve without the other.
 */
@UnstableApi
class AudioGraph(private val context: Context, private val httpCallFactory: Call.Factory) {

  /**
   * A player and the two processors spliced into its output. Fade gain is kept
   * separate from [ExoPlayer.setVolume] so a crossfade ramp and the user's
   * volume setting cannot overwrite one another — the same reason iOS gives each
   * voice its own gain node rather than driving the player's own volume.
   */
  class Voice(
    val player: ExoPlayer,
    val equalizer: EqualizerAudioProcessor,
    val fade: FadeAudioProcessor,
  )

  val voiceA: Voice
  val voiceB: Voice

  /**
   * Which voice is currently the foreground one. The other is the one being
   * prepared, or fading out.
   */
  var activeIsA = true
    private set

  val activeVoice: Voice get() = if (activeIsA) voiceA else voiceB
  val idleVoice: Voice get() = if (activeIsA) voiceB else voiceA

  private var cache: SimpleCache? = null
  private var cacheMaxBytes: Long = DEFAULT_CACHE_BYTES

  init {
    voiceA = buildVoice()
    voiceB = buildVoice()
    // Full scale on the active voice; the idle one starts silent so that a
    // preloaded track cannot be heard before its fade is asked for.
    voiceA.fade.setGainImmediately(1f)
    voiceB.fade.setGainImmediately(0f)
  }

  // MARK: - Construction

  private fun buildVoice(): Voice {
    val equalizer = EqualizerAudioProcessor()
    val fade = FadeAudioProcessor()

    val renderersFactory = object : DefaultRenderersFactory(context) {
      override fun buildAudioSink(
        context: Context,
        enableFloatOutput: Boolean,
        enableAudioTrackPlaybackParameters: Boolean,
      ): AudioSink =
        DefaultAudioSink.Builder(context)
          // Order matters and is the same as the iOS graph reads top to bottom:
          // equalise first, then apply the fade, so a fade-out attenuates the
          // equalised signal rather than the filters re-lifting a faded one.
          .setAudioProcessors(arrayOf<AudioProcessor>(equalizer, fade))
          // Float output and offload are both mutually exclusive with a
          // processor chain — Media3 silently drops the chain rather than
          // erroring, which would look like "the equalizer does nothing on some
          // devices". Opted out explicitly so the trade is visible here.
          .setEnableFloatOutput(false)
          .build()
    }

    val player = ExoPlayer.Builder(context, renderersFactory)
      .setMediaSourceFactory(DefaultMediaSourceFactory(cacheDataSourceFactory()))
      // Media3 takes the partial wake lock itself, but only if asked; without
      // this, playback dies when the CPU sleeps with the screen off.
      .setWakeMode(C.WAKE_MODE_NETWORK)
      .setHandleAudioBecomingNoisy(true)
      .build()

    // Never advance on its own. Each voice holds exactly one track and the
    // engine decides what follows it, because a crossfade needs the idle voice
    // playing track N+1 while this one is still playing N — a player that
    // advanced by itself would reach N+1 twice. Belt and braces given the
    // single-item timeline, and deliberately so: this is the lever that stops
    // Media3 doing behind the engine's back what `handleTrackFinished`'s
    // identity check stops it doing in front.
    player.setPauseAtEndOfMediaItems(true)

    return Voice(player, equalizer, fade)
  }

  /**
   * The disk cache.
   *
   * Media3 hands this over almost free — `SimpleCache` does sparse ranged
   * caching, LRU eviction and a seek into an unfetched region already, and does
   * them well. **iOS cannot do the same at any price**: Core Audio has no
   * caching data source, which is why the iOS side has to carry a hand-written
   * `AudioFile_ReadProc` over a sparse cache of its own (docs/architecture.md
   * §2). The two platforms genuinely differ here, and it is the one place in
   * this engine where Android's implementation is a fraction of iOS's.
   *
   * What that section asks for and this still honours is *one* cache model: the
   * offline-downloads store writes into this same `SimpleCache` through Media3's
   * `DownloadManager`, so a downloaded track and a streamed-then-cached track
   * are the same bytes under the same evictor, and there is one set of
   * behaviours to reason about rather than two.
   */
  private fun cacheDataSourceFactory(): DataSource.Factory {
    val cache = requireCache()

    // DefaultDataSource wraps the upstream so `file://` for offline downloads
    // resolves through exactly the same chain as `https://`. One path, as §2
    // asks for.
    val network = DefaultDataSource.Factory(context, OkHttpDataSource.Factory(httpCallFactory))

    // Headers are attached here, per request, rather than on the OkHttp client.
    // They are a property of the track (see `Track.headers`) because some
    // servers authenticate a stream by header rather than by signing the URL;
    // a client-level interceptor would send one track's credentials with the
    // next track's fetch.
    val resolving = androidx.media3.datasource.ResolvingDataSource.Factory(network) { spec ->
      val headers = TrackHeaders.forUri(spec.uri.toString())
      if (headers.isEmpty()) spec else spec.withAdditionalHeaders(headers)
    }

    return CacheDataSource.Factory()
      .setCache(cache)
      .setUpstreamDataSourceFactory(resolving)
      // A cache write failure must degrade to plain streaming, not to silence.
      // A full or unwritable disk is a common state on a phone and it is not a
      // reason to stop playing music.
      .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
  }

  private fun requireCache(): SimpleCache {
    cache?.let { return it }
    // SimpleCache is documented as one instance per directory per process, and
    // a second one over the same folder corrupts the index rather than failing
    // loudly. Both voices therefore share this.
    val created = SimpleCache(
      File(context.cacheDir, CACHE_DIRECTORY_NAME),
      LeastRecentlyUsedCacheEvictor(cacheMaxBytes),
      StandaloneDatabaseProvider(context),
    )
    cache = created
    return created
  }

  // MARK: - Cache

  /**
   * What the cache currently holds.
   *
   * Reads the field rather than `requireCache()`: with no cache built yet
   * nothing has been cached, and zeros are the true answer. Creating one to
   * report on it would be building the thing in order to measure it.
   */
  fun cacheStats(): Stats {
    val existing = cache ?: return Stats(usedBytes = 0, maxBytes = cacheMaxBytes, entryCount = 0)
    return Stats(
      usedBytes = existing.cacheSpace,
      maxBytes = cacheMaxBytes,
      entryCount = existing.keys.size,
    )
  }

  data class Stats(val usedBytes: Long, val maxBytes: Long, val entryCount: Int)

  /**
   * Drop everything cached. Worker thread only — `removeResource` is annotated
   * `@WorkerThread`, and it walks the index and the filesystem for every key.
   */
  @WorkerThread
  fun clearCache() {
    val existing = cache ?: return
    // Copied before iterating: `removeResource` mutates the set this came from.
    for (key in existing.keys.toList()) existing.removeResource(key)
  }

  /**
   * Drop one track's cached audio, by the host's `MediaId`.
   *
   * That is the key because `toNowPlayingMediaItem` sets it as the custom cache key — so
   * this takes the same id the host uses everywhere else, and does not need a
   * URI that may since have rotated its token.
   */
  @WorkerThread
  fun evict(id: String) {
    cache?.removeResource(id)
  }

  // MARK: - Lifecycle

  fun release() {
    voiceA.player.release()
    voiceB.player.release()
    cache?.release()
    cache = null
  }

  /** Swap which voice is foreground. Called at the crossover point. */
  fun swapVoices() {
    activeIsA = !activeIsA
  }

  // MARK: - Equalizer

  /**
   * An untouched EQ costs nothing: with every band flat the cascade
   * short-circuits to a straight copy.
   *
   * Note what this is *not* doing — it is not toggling `AudioProcessor.isActive`.
   * Media3 only re-reads that when the sink is reconfigured, so a processor that
   * declares itself inactive stays out of the chain until the next format
   * change, and enabling the EQ mid-track would appear to do nothing. iOS's
   * `eq.bypass` takes effect on the next buffer; here the bypass has to live one
   * level down, inside the processor.
   */
  fun setEqualizer(bands: List<Band>) {
    // Written to both voices unconditionally. During a crossfade both are live,
    // and a curve applied to one of them would make the two halves of the fade
    // audibly different from each other.
    voiceA.equalizer.setBands(bands)
    voiceB.equalizer.setBands(bands)
  }

  data class Band(val frequencyHz: Float, val gainDb: Float, val q: Float)

  // MARK: - Gain

  /**
   * Ramp a voice's gain over `durationSec`.
   *
   * Driven by the sample clock inside [FadeAudioProcessor] rather than by a
   * `Handler` or a `ValueAnimator`, for the same reason iOS drives it from the
   * audio thread: the app is backgrounded during most crossfades, Doze throttles
   * timers, and a fade that stutters because the main looper was asleep is worse
   * than no fade. Counting frames cannot be throttled.
   */
  fun ramp(voice: Voice, target: Float, durationSec: Double, curve: FadeCurve) {
    if (durationSec <= 0.0) {
      voice.fade.setGainImmediately(target)
    } else {
      voice.fade.rampTo(target, durationSec, curve)
    }
  }

  /**
   * The shape a fade follows. Chosen per call, because the right answer differs.
   *
   * There is deliberately no default. A fade between two sources and a fade of
   * one source to silence want opposite curves, and making either the default
   * makes the other caller quietly wrong — which is exactly what happened on
   * iOS, where the sleep timer silently inherited the crossfade's curve.
   */
  enum class FadeCurve {
    /**
     * Two uncorrelated sources overlapping. `rising² + falling² == 1` at every
     * point, so the pair sums to constant power and the crossover does not dip.
     * Linear ramps here sum to about 0.5 amplitude in the middle, which is
     * audibly a hole.
     *
     * Safe on this platform for a reason worth writing down, because the
     * comment that used to sit in [FadeAudioProcessor] argued the opposite:
     * equal power cannot clip here, since each voice owns a separate
     * `DefaultAudioSink` and the two never sum inside a processor. They meet in
     * the system mixer, which has its own headroom.
     */
    EQUAL_POWER,

    /**
     * One source going somewhere on its own. Nothing sums with it, so constant
     * power is meaningless — and equal power is actively wrong here: its
     * fade-out is still at 0.707 halfway through, holding almost full volume
     * and then collapsing. For the sleep timer that is "still loud, still loud,
     * gone" rather than a fade to sleep.
     */
    LINEAR,
  }

  companion object {
    /**
     * The gain a fade should be at, a fraction `position` of the way through.
     *
     * Pure, and separated out for the same reason as its Swift counterpart: the
     * curve is the part worth testing while the rest is a clock. It is also the
     * part that was wrong once — the iOS falling branch read
     * `1 - sqrt(1 - (1 - position))`, whose inner `1 - (1 - position)` collapses
     * to `position`, inverting the fade-out so the outgoing track rose from
     * silence and was cut off at full volume. Kept identical to
     * `AudioGraph.fadeVolume` in `ios/Core/AudioGraph.swift`, so a change to one
     * reads as an omission in the other.
     */
    fun fadeVolume(start: Float, target: Float, position: Float, curve: FadeCurve): Float {
      val p = position.coerceIn(0f, 1f)
      return when (curve) {
        FadeCurve.EQUAL_POWER ->
          if (target > start) start + (target - start) * kotlin.math.sqrt(p)
          else target + (start - target) * kotlin.math.sqrt(1f - p)
        FadeCurve.LINEAR -> start + (target - start) * p
      }
    }

    /**
     * The rate the graph is *expected* to run at in `fixed` mode.
     *
     * Android differs from iOS here in a way worth naming: there is no
     * equivalent of `setPreferredSampleRate`, and `AudioTrack` resamples in the
     * HAL whatever we hand it. So this is not enforced by reconfiguring
     * hardware — the processors below run at whatever rate the decoder produces
     * and recompute their coefficients when it changes. 48kHz is kept as the
     * documented target because it is what the platform mixer runs at on
     * essentially every device shipped in the last decade, so the common case is
     * still a no-op.
     */
    const val FIXED_SAMPLE_RATE = 48_000

    const val CACHE_DIRECTORY_NAME = "yuzic-engine-audio"

    /** 1GB, matching what yuzic already uses. Overridden by `configureCache`. */
    const val DEFAULT_CACHE_BYTES = 1_024L * 1_024L * 1_024L
  }
}

/**
 * Per-track request headers, looked up by URI at fetch time.
 *
 * A registry rather than something carried on the `MediaItem` because the
 * `DataSpec` that reaches the data source has been through the cache and the
 * extractor and no longer knows which `MediaItem` it came from. Keyed by URI,
 * which is the one thing that does survive the trip.
 */
object TrackHeaders {
  private val byUri = java.util.concurrent.ConcurrentHashMap<String, Map<String, String>>()

  fun register(uri: String, headers: Map<String, String>?) {
    if (headers.isNullOrEmpty()) byUri.remove(uri) else byUri[uri] = headers
  }

  fun forUri(uri: String): Map<String, String> = byUri[uri] ?: emptyMap()

  fun clear() = byUri.clear()
}

/**
 * The equalizer, as a cascade of RBJ peaking biquads — one per band, per channel.
 *
 * **Why this and not `android.media.audiofx.Equalizer`.** The platform effect is
 * genuinely cheaper (it runs in the HAL, sometimes on DSP silicon) and it was
 * the first thing considered. It loses on four counts, and the first is fatal:
 *
 * 1. It binds to an *audio session id*, and this graph has two players and so
 *    two sessions. Sharing one id between them forces both onto a single
 *    `AudioTrack` configuration, which is precisely the overlap the two-player
 *    arrangement exists to allow; giving them one effect each means two
 *    independently-scheduled HAL effects that are not guaranteed to apply on the
 *    same frame, so a crossfade could be heard through two different curves.
 * 2. Its bands are *device-defined*. `getNumberOfBands()`, the centre
 *    frequencies and the dB range all come from the implementation, so the same
 *    `EqBand[]` produces a visibly different curve on different handsets. The
 *    contract in `src/types.ts` is frequency, gain and Q — figures the platform
 *    equalizer cannot be asked to honour, only approximated against whatever
 *    fixed bands it happens to expose.
 * 3. It is optional. Plenty of devices have no effect implementation and the
 *    constructor throws `UnsupportedOperationException`, so the feature would be
 *    present on some phones and absent on others with nothing the host could do.
 * 4. Attaching to the global output mix (session 0) applies the curve to *other
 *    apps'* audio, which is not a thing a library should do to a user.
 *
 * The price paid: a few percent of a core, and no float output or audio offload
 * on the voice (see the sink builder). Worth it for a curve that is the same
 * everywhere and the same on both sides of a fade.
 */
@UnstableApi
class EqualizerAudioProcessor : BaseAudioProcessor() {

  private class Biquad {
    var b0 = 1.0; var b1 = 0.0; var b2 = 0.0; var a1 = 0.0; var a2 = 0.0
    // Direct Form I state, per channel. Two of each, because a biquad needs the
    // previous two inputs and outputs.
    lateinit var x1: DoubleArray
    lateinit var x2: DoubleArray
    lateinit var y1: DoubleArray
    lateinit var y2: DoubleArray

    fun allocate(channels: Int) {
      x1 = DoubleArray(channels); x2 = DoubleArray(channels)
      y1 = DoubleArray(channels); y2 = DoubleArray(channels)
    }

    fun reset() {
      x1.fill(0.0); x2.fill(0.0); y1.fill(0.0); y2.fill(0.0)
    }

    /** RBJ Audio EQ Cookbook, peaking EQ. Q is read as bandwidth in octaves. */
    fun configure(sampleRate: Int, frequencyHz: Float, gainDb: Float, bandwidthOctaves: Float) {
      val a = 10.0.pow(gainDb / 40.0)
      val w0 = 2.0 * PI * frequencyHz / sampleRate
      val cosW0 = cos(w0)
      val sinW0 = sin(w0)
      val bw = bandwidthOctaves.coerceAtLeast(0.05f).toDouble()
      val alpha = sinW0 * sinh(kotlin.math.ln(2.0) / 2.0 * bw * w0 / sinW0)

      val a0 = 1 + alpha / a
      b0 = (1 + alpha * a) / a0
      b1 = (-2 * cosW0) / a0
      b2 = (1 - alpha * a) / a0
      a1 = (-2 * cosW0) / a0
      a2 = (1 - alpha / a) / a0
    }

    fun process(channel: Int, x: Double): Double {
      val y = b0 * x + b1 * x1[channel] + b2 * x2[channel] - a1 * y1[channel] - a2 * y2[channel]
      x2[channel] = x1[channel]; x1[channel] = x
      y2[channel] = y1[channel]; y1[channel] = y
      return y
    }
  }

  @Volatile
  private var pendingBands: List<AudioGraph.Band>? = null

  private var bands: List<AudioGraph.Band> = emptyList()
  private var filters: List<Biquad> = emptyList()
  private var flat = true

  fun setBands(bands: List<AudioGraph.Band>) {
    // Handed over rather than applied: this is called from the JS thread and the
    // filters are touched by the audio thread. The swap happens in queueInput,
    // between buffers, where there is no half-updated cascade to hear.
    pendingBands = bands
  }

  override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
      throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    }
    rebuildFilters(inputAudioFormat)
    // The EQ neither resamples nor rechannels, so output format is input format.
    return inputAudioFormat
  }

  override fun isActive(): Boolean =
    // Always in the chain once the format is known — see the note on
    // AudioGraph.setEqualizer about why the bypass cannot live here.
    inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET

  private fun rebuildFilters(format: AudioProcessor.AudioFormat) {
    val active = bands.filter { it.gainDb != 0f }
    flat = active.isEmpty()
    filters = active.map { band ->
      Biquad().apply {
        allocate(format.channelCount)
        configure(format.sampleRate, band.frequencyHz, band.gainDb, band.q)
      }
    }
  }

  override fun queueInput(inputBuffer: ByteBuffer) {
    pendingBands?.let {
      bands = it
      pendingBands = null
      if (inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET) rebuildFilters(inputAudioFormat)
    }

    val remaining = inputBuffer.remaining()
    if (remaining == 0) return

    val output = replaceOutputBuffer(remaining)

    if (flat) {
      // The zero-cost path. A user who never opens the EQ pays a memcpy, which
      // is what the chain would have cost anyway getting the buffer to the sink.
      output.put(inputBuffer)
      output.flip()
      return
    }

    val channels = inputAudioFormat.channelCount
    val input = inputBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
    var channel = 0
    while (input.hasRemaining()) {
      var sample = input.get().toDouble()
      for (filter in filters) {
        sample = filter.process(channel, sample)
      }
      // Clip rather than wrap. A cascade with positive gain can exceed full
      // scale on a hot master, and a wrapped Short is a loud click where a
      // clamped one is momentary distortion — the same reasoning as the
      // peak-aware replay-gain clamp.
      output.putShort(sample.coerceIn(-32768.0, 32767.0).toInt().toShort())
      channel = (channel + 1) % channels
    }
    inputBuffer.position(inputBuffer.limit())
    output.flip()
  }

  override fun onFlush() {
    // A seek discards the filter memory. Carrying the previous two samples
    // across a jump in the signal rings the cascade audibly.
    filters.forEach { it.reset() }
  }

  override fun onReset() {
    filters = emptyList()
    bands = emptyList()
    flat = true
  }
}

/**
 * The crossfade ramp, applied on the sample clock.
 *
 * A crossfade is a pair of these running against each other: the outgoing voice
 * ramps to 0 while the incoming one ramps to 1, over the duration
 * [PlaybackQueue.transitionDuration] settled on.
 *
 * Counting frames rather than milliseconds is the point. The app is backgrounded
 * during most crossfades and the main looper is being throttled; a `Handler`
 * ramp would step unevenly and a `ValueAnimator` would be paused outright. The
 * only clock that keeps running is the one the audio itself is drawn against.
 */
@UnstableApi
class FadeAudioProcessor : BaseAudioProcessor() {

  // Written from the JS thread, read on the audio thread. Volatile rather than
  // locked: a ramp request is two independent scalars and the worst a torn read
  // could do is start the fade one buffer late, which is inaudible, whereas a
  // lock on the audio thread is a dropout waiting to happen.
  @Volatile private var requestedGain = 1f
  @Volatile private var requestedSeconds = 0.0
  @Volatile private var requestedCurve = AudioGraph.FadeCurve.LINEAR

  // Audio-thread only, from here down.
  private var currentGain = 1f
  private var startGain = 1f
  private var pendingTarget = 1f
  private var framesIntoRamp = 0L
  private var rampFrames = 0L
  private var rampCurve = AudioGraph.FadeCurve.LINEAR

  fun setGainImmediately(gain: Float) {
    requestedSeconds = 0.0
    requestedGain = gain
  }

  fun rampTo(target: Float, durationSec: Double, curve: AudioGraph.FadeCurve) {
    requestedSeconds = durationSec
    requestedCurve = curve
    requestedGain = target
  }

  /** Where the fade has actually got to. The queue reads this to decide when the crossover midpoint has passed. */
  val gain: Float get() = currentGain

  override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
      throw AudioProcessor.UnhandledAudioFormatException(inputAudioFormat)
    }
    return inputAudioFormat
  }

  override fun isActive(): Boolean = inputAudioFormat != AudioProcessor.AudioFormat.NOT_SET

  override fun queueInput(inputBuffer: ByteBuffer) {
    val remaining = inputBuffer.remaining()
    if (remaining == 0) return

    // Pick up a new ramp request at a buffer boundary. Doing it mid-buffer would
    // put a discontinuity inside a block of samples, which is a click.
    val target = requestedGain
    if (target != pendingTarget) {
      pendingTarget = target
      startGain = currentGain
      framesIntoRamp = 0
      rampCurve = requestedCurve
      rampFrames = (requestedSeconds * inputAudioFormat.sampleRate).toLong()
      if (rampFrames == 0L) currentGain = target
    }

    val output = replaceOutputBuffer(remaining)

    if (rampFrames == 0L && currentGain == 1f) {
      // Unity gain and nothing in flight: the overwhelmingly common case, and it
      // must not cost a multiply per sample.
      output.put(inputBuffer)
      output.flip()
      return
    }

    val channels = inputAudioFormat.channelCount
    val input = inputBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
    var channel = 0
    while (input.hasRemaining()) {
      if (channel == 0 && rampFrames > 0) {
        val progress = (framesIntoRamp.toDouble() / rampFrames).coerceIn(0.0, 1.0)
        // The shape is the caller's choice — see [AudioGraph.FadeCurve]. This
        // used to be linear unconditionally, on the grounds that equal power
        // "sums above unity in the middle, which clips": not so here, because
        // each voice has its own audio sink and the two never sum inside a
        // processor.
        currentGain = AudioGraph.fadeVolume(startGain, pendingTarget, progress.toFloat(), rampCurve)
        if (framesIntoRamp >= rampFrames) {
          currentGain = pendingTarget
          rampFrames = 0
        }
        framesIntoRamp++
      }
      val scaled = input.get() * currentGain
      output.putShort(scaled.coerceIn(-32768f, 32767f).toInt().toShort())
      channel = (channel + 1) % channels
    }
    inputBuffer.position(inputBuffer.limit())
    output.flip()
  }

  override fun onFlush() {
    // Deliberately does *not* reset the gain. A seek during a fade-out should
    // land at the volume the fade had reached, not jump back to full scale.
    framesIntoRamp = 0
  }

  override fun onReset() {
    currentGain = 1f
    pendingTarget = 1f
    startGain = 1f
    requestedGain = 1f
    requestedSeconds = 0.0
    rampFrames = 0
    framesIntoRamp = 0
  }
}
