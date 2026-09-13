import AVFoundation

/**
 The playback graph.

 Two player nodes, not one. That is the whole reason this project exists rather
 than a wrapper around `AVQueuePlayer`: a crossfade is two sources overlapping,
 and one output cannot overlap with itself. The nodes alternate — while `a` is
 playing, `b` is the one being prepared, and they swap at every transition — so
 a fade is a volume ramp on each of a pair that are both already running.

    playerA ─┐
             ├─▶ eq ─▶ mainMixer ─▶ output
    playerB ─┘

 The EQ sits after the mixer rather than per-player so a crossfade does not run
 two copies of the filter chain, and so changing the curve mid-fade cannot make
 the two halves sound different from each other.
 */
public final class AudioGraph {

  /// A source and the gain node it is faded with. Gain is separate from the
  /// player's own `volume` so a crossfade ramp and the user's volume setting
  /// cannot overwrite one another.
  public struct Voice {
    public let id: Int
    public let player: AVAudioPlayerNode
    public let gain: AVAudioMixerNode
  }

  /**
   `var`, not `let`, and that is the whole point of `rebuildAfterReset`.

   An `AVAudioEngine` survives a route change — `handleConfigurationChange`
   restarts the same object — but it does not survive the media server
   restarting. Then every audio object this class holds is invalid and the only
   remedy is new ones.
   */
  private var engine: AVAudioEngine
  private var eq: AVAudioUnitEQ

  /**
   Whether the equalizer is currently out of the chain.
   
   Exposed for tests. Bypassing is an efficiency property, not an audible one:
   a parametric EQ with every band at 0dB sounds identical to no EQ at all, so
   comparing rendered audio cannot tell the two apart — which is exactly how
   `testEqualizerIsBypassedWhenFlat` came to be named for something it could
   not observe. This is the only thing that distinguishes them.
   */
  public var isEqualizerBypassed: Bool { eq.bypass }
  private var speed: AVAudioUnitTimePitch
  private var fadeTimers: [Int: Timer] = [:]

  /// The rate this graph was built at, kept so it can be built again the same
  /// way. Only `rebuildAfterReset` needs it, and it has nowhere else to get it.
  private let configuredSampleRate: Double

  /**
   The settings a rebuild has to put back, held as values rather than read off
   the nodes.

   Reading them back would mean asking objects the media server has already
   invalidated what they were set to, which is the one question they cannot be
   trusted to answer. Holding the model means the new nodes are configured from
   what the user chose, not from the wreckage of the old ones.
   */
  private var appliedEqualizerBands: [(frequency: Float, gainDb: Float, q: Float)] = []
  private var appliedSpeed: Float = 1.0
  public private(set) var voiceA: Voice
  public private(set) var voiceB: Voice

  /// Which voice is currently the foreground one. The other is the one being
  /// prepared, or fading out.
  public private(set) var activeIsA = true

  public var activeVoice: Voice { activeIsA ? voiceA : voiceB }
  public var idleVoice: Voice { activeIsA ? voiceB : voiceA }

  /**
   The rate the EQ and mixer run at, in `fixed` mode.

   48kHz because that is what iOS hardware most often runs at natively, so the
   common case is a no-op rather than a resample.

   Note what this is *not*: it is not a requirement that both sources share it.
   Apple's guidance is to connect each player node at its own track's rate and
   let `AVAudioMixerNode` convert — it sums once and converts once, which is
   cheaper than converting per node — so a 44.1kHz track can crossfade into a
   96kHz one. What cannot happen mid-fade is changing the *hardware* rate; see
   `reconnectIdleVoice`.
   */
  public static let fixedSampleRate: Double = 48_000

  /// Everything a graph is made of. Exists so the assembly below can be run
  /// twice — once at init, once when the media server has invalidated the
  /// first set — without either copy of it drifting from the other.
  private struct Parts {
    let engine: AVAudioEngine
    let eq: AVAudioUnitEQ
    let speed: AVAudioUnitTimePitch
    let voiceA: Voice
    let voiceB: Voice
  }

  public init(sampleRate: Double = AudioGraph.fixedSampleRate) {
    configuredSampleRate = sampleRate
    let parts = AudioGraph.assemble(sampleRate: sampleRate)
    engine = parts.engine
    eq = parts.eq
    speed = parts.speed
    voiceA = parts.voiceA
    voiceB = parts.voiceB
  }

  private static func assemble(sampleRate: Double) -> Parts {
    let engine = AVAudioEngine()
    let eq: AVAudioUnitEQ
    let speed: AVAudioUnitTimePitch
    let voiceA: Voice
    let voiceB: Voice

    eq = AVAudioUnitEQ(numberOfBands: 10)
    eq.globalGain = 0

    // TimePitch rather than Varispeed: varispeed resamples, so speeding a
    // podcast up raises the voice to a chipmunk. Pitch preservation is the
    // whole point of a speed control, and it is what costs the CPU here.
    speed = AVAudioUnitTimePitch()
    speed.rate = 1.0

    voiceA = Voice(id: 0, player: AVAudioPlayerNode(), gain: AVAudioMixerNode())
    voiceB = Voice(id: 1, player: AVAudioPlayerNode(), gain: AVAudioMixerNode())

    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

    // Attach before connecting, always: connecting a node the engine does not
    // hold yet fails at run time with a bare assertion about `_nodes`, and
    // nothing about that message points at the ordering.
    engine.attach(eq)
    engine.attach(speed)
    for voice in [voiceA, voiceB] {
      engine.attach(voice.player)
      engine.attach(voice.gain)
    }

    // The two voices meet at the main mixer, not at the EQ. An AVAudioUnitEQ
    // has a single input bus, so connecting both gains to it does not sum them
    // — the second connection replaces the first, and one voice goes silent.
    // Summing is a mixer's job; the mixer is also the one node here that takes
    // any number of inputs.
    //
    //   playerA → gainA ─┐
    //                    ├→ mainMixer → eq → speed → output
    //   playerB → gainB ─┘
    //
    // EQ after the mixer, so a crossfade runs one filter chain rather than two
    // and a curve change mid-fade cannot make the halves differ.
    //
    // Speed last, and shared, for the same reason one step further on: two
    // voices stretched by separate units could drift apart mid-fade, which is
    // the one place it would be unmistakable. Putting it *after* the EQ also
    // leaves the filters looking at audio at its natural rate — the band
    // frequencies were chosen against the recording, not against the speed
    // someone happens to be listening at.
    for voice in [voiceA, voiceB] {
      engine.connect(voice.player, to: voice.gain, format: format)
      engine.connect(voice.gain, to: engine.mainMixerNode, format: format)
      voice.gain.outputVolume = 0
    }
    engine.connect(engine.mainMixerNode, to: eq, format: format)
    engine.connect(eq, to: speed, format: format)
    engine.connect(speed, to: engine.outputNode, format: format)

    // Full scale on the active voice; the fade is done on the per-voice gain.
    voiceA.gain.outputVolume = 1

    return Parts(engine: engine, eq: eq, speed: speed, voiceA: voiceA, voiceB: voiceB)
  }

  public func start() throws {
    guard !engine.isRunning else { return }
    engine.prepare()
    try engine.start()
  }

  public func stop() {
    engine.stop()
  }

  /**
   Rebuild after the system pulled the rug out.

   `AVAudioEngineConfigurationChangeNotification` fires on every route change —
   AirPods connecting, CarPlay, a dock — and it stops the engine and discards
   every scheduled buffer. The caller has to reschedule from the current decode
   position afterwards; there is no way to recover the buffers that were in
   flight.
   */
  public func handleConfigurationChange() throws {
    try start()
  }

  /**
   Build the whole graph again, because the one it had is rubble.

   `AVAudioSession.mediaServicesWereResetNotification` means `mediaserverd`
   restarted. That is not a route change and `handleConfigurationChange` is not
   enough for it: Apple's contract is that **every** audio object the process
   holds is invalid afterwards — the engine, the player nodes, the mixers, the
   units — and the only remedy is to throw them away and make new ones. An
   engine restarted in place after a reset either refuses to start or runs
   producing nothing, which is why the symptom is a player that looks entirely
   healthy and makes no sound.

   The voices are new objects when this returns, so every `Voice` the caller
   was holding is stale. Whoever calls this has to re-read `activeVoice` and
   build its playback again — the same requirement `handleConfigurationChange`
   already imposes for a different reason, which is why `PlaybackEngine` has
   somewhere to put it.

   `activeIsA` is deliberately preserved. Which of a pair is foreground is this
   class's own bookkeeping and has nothing to do with the media server;
   resetting it here would swap the graph under a crossfade that is still
   running upstairs.
   */
  public func rebuildAfterReset() throws {
    for timer in fadeTimers.values { timer.invalidate() }
    fadeTimers.removeAll()

    // Not `stop()`. The old engine is invalid, and messaging it is exactly
    // what the notification is warning about; letting ARC drop it is the whole
    // of the teardown available.
    let parts = AudioGraph.assemble(sampleRate: configuredSampleRate)
    engine = parts.engine
    eq = parts.eq
    speed = parts.speed
    voiceA = parts.voiceA
    voiceB = parts.voiceB

    // Assembly puts full scale on A, which is only right if A is foreground.
    voiceA.gain.outputVolume = activeIsA ? 1 : 0
    voiceB.gain.outputVolume = activeIsA ? 0 : 1

    // The user's settings survive the media server; the nodes carrying them
    // did not. Re-applied from the values rather than copied off the old
    // units, which cannot be asked.
    setSpeed(appliedSpeed)
    setEqualizer(bands: appliedEqualizerBands)

    try start()
  }

  /// Swap which voice is foreground. Called at the crossover point.
  public func swapVoices() {
    activeIsA.toggle()
  }

  /**
   Point a voice at a new source rate, ready for the track about to start on it.

   A connection's format cannot be changed while the engine is running, so the
   caller must pass a voice that is not currently playing. Reconnecting a live
   one would glitch, which is the whole reason the swap happens on a pair
   rather than on a single node being reconfigured in place.

   Getting this wrong is audible. `AudioFileReader.outputFormat` is built at
   the file's native rate, so the buffers reaching `scheduleBuffer` carry the
   file's frames — and a node connected at some other rate consumes them *as
   if* they were its own. A 44.1kHz track on a 48kHz connection plays 8.8%
   fast and about 1.5 semitones sharp. Nothing resamples it back: the mixer
   converts what the node hands it, and the node has already decided those
   samples are 48kHz ones.

   The reported position is wrong by the same ratio and for the same reason —
   `playerTime.sampleTime` advances in the connection's frames while
   `AudioFileReader.sampleRate` reports the file's, and `PlaybackEngine
   .progress` divides one by the other — so the progress bar runs ahead, the
   track appears to end early, and `shouldBeginTransition` starts the
   crossfade before it should.
   */
  public func reconnect(_ voice: Voice, toSourceRate rate: Double) {
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }
    engine.disconnectNodeOutput(voice.player)
    engine.connect(voice.player, to: voice.gain, format: format)
  }

  /// `reconnect`, for the preload window before a crossfade.
  public func reconnectIdleVoice(toSourceRate rate: Double) {
    reconnect(idleVoice, toSourceRate: rate)
  }

  // MARK: - Equalizer

  /**
   An untouched EQ costs nothing: with every band flat the unit is bypassed
   outright rather than left in the chain multiplying by one.
   */
  /**
   Playback rate, with pitch held.

   Bypassed at 1.0 rather than left in the chain doing nothing. A TimePitch
   unit is the most expensive node here and it is not free when it is idle, so
   the overwhelmingly common case — nobody has touched the speed control —
   should not pay for the feature.

   Clamped to what a listener could plausibly want. `AVAudioUnitTimePitch`
   accepts 1/32 to 32, and every value near those ends is unintelligible; a
   host asking for one has a bug, and honouring it faithfully would only make
   that bug harder to see.
   */
  public func setSpeed(_ rate: Float) {
    let clamped = min(max(rate, 0.25), 4.0)
    appliedSpeed = clamped
    speed.rate = clamped
    speed.bypass = clamped == 1.0
  }

  public var currentSpeed: Float { speed.rate }

  public func setEqualizer(bands: [(frequency: Float, gainDb: Float, q: Float)]) {
    appliedEqualizerBands = bands
    guard !bands.isEmpty, bands.contains(where: { $0.gainDb != 0 }) else {
      eq.bypass = true
      return
    }
    eq.bypass = false
    for (index, band) in bands.prefix(eq.bands.count).enumerated() {
      let target = eq.bands[index]
      target.filterType = .parametric
      target.frequency = band.frequency
      target.gain = band.gainDb
      target.bandwidth = band.q
      target.bypass = false
    }
    // Any band the caller did not supply is neutralised rather than left
    // holding whatever the previous curve put there.
    for index in bands.count..<eq.bands.count {
      eq.bands[index].bypass = true
    }
  }

  /**
   Set a voice's per-track loudness adjustment.

   Applied to the *player* rather than the voice's gain node, which is the only
   reason replay gain and crossfade can coexist: a fade ramps `gain
   .outputVolume` from 0 to 1 and back, and anything else written there is
   overwritten by the next ramp. Two separate multiplications in the same
   signal path, neither able to clobber the other.
   */
  public func setTrackGain(_ voice: Voice, to gain: Float) {
    voice.player.volume = gain
  }

  // MARK: - Gain and fades

  /**
   Move a voice's gain toward `target` over `duration`, in steps.

   `AVAudioMixerNode` has no ramp of its own, so the fade is stepped. Two
   choices worth stating:

   **Equal power, not linear.** Two linear ramps crossing at their midpoint sum
   to about 0.5 of full amplitude, and the crossover is audibly a dip. Taking
   the square root of the linear position keeps the summed power roughly
   constant, which is what makes a crossfade sound like one sound becoming
   another rather than one dipping and another rising.

   **Stepped on a timer, and the step is coarse.** A sample-accurate ramp would
   need a render callback; at ~50 steps a second the granularity is inaudible
   for a fade measured in seconds. If that ever proves wrong, the fix is a
   custom `AVAudioSourceNode` rather than a faster timer.
   */
  /**
   The shape a fade follows. Chosen per call, because the right answer differs.

   There is deliberately no default. A fade between two sources and a fade of
   one source to silence want opposite curves, and making either the default
   makes the other caller quietly wrong.
   */
  public enum FadeCurve {
    /// Two uncorrelated sources overlapping. `rising² + falling² == 1` at every
    /// point, so the pair sums to constant power and the crossover does not
    /// dip. Linear ramps here sum to about 0.5 amplitude in the middle, which
    /// is audibly a hole.
    case equalPower

    /// One source going somewhere on its own. Nothing sums with it, so
    /// constant power is meaningless — and equal power is actively wrong here:
    /// its fade-out is still at 0.707 halfway through, holding almost full
    /// volume and then collapsing. For the sleep timer that is "still loud,
    /// still loud, gone" rather than a fade to sleep.
    case linear
  }

  /**
   The gain a fade should be at, a fraction `position` of the way through.

   Pure, and separated out because the curve is the part worth testing while
   the rest is a timer. It is also the part that was wrong once: the falling
   branch read `1 - sqrt(1 - (1 - position))`, whose inner `1 - (1 - position)`
   collapses to `position`, making it `1 - sqrt(position)` — and once
   interpolated between start and target that inverted the fade-out, so the
   outgoing track rose from silence and was cut off at full volume instead of
   fading away.
   */
  public static func fadeVolume(
    from start: Float, to target: Float, position: Float, curve: FadeCurve
  ) -> Float {
    let p = max(0, min(1, position))
    switch curve {
    case .equalPower:
      return target > start
        ? start + (target - start) * sqrt(p)
        : target + (start - target) * sqrt(1 - p)
    case .linear:
      return start + (target - start) * p
    }
  }

  public func fade(_ voice: Voice, to target: Float, over duration: TimeInterval,
            curve: FadeCurve, completion: (() -> Void)? = nil) {
    // A fade can be started from the decode queue — end-of-track is discovered
    // there — and `RunLoop` is not thread-safe. Scheduling a timer on the main
    // run loop from another thread is the kind of race that works in testing
    // and fails once, in a car.
    guard Thread.isMainThread else {
      DispatchQueue.main.async { [weak self] in
        self?.fade(voice, to: target, over: duration, curve: curve, completion: completion)
      }
      return
    }

    fadeTimers[voice.id]?.invalidate()

    guard duration > 0.01 else {
      voice.gain.outputVolume = target
      completion?()
      return
    }

    let start = voice.gain.outputVolume
    let startedAt = CACurrentMediaTime()
    let interval = 0.02

    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
      let elapsed = CACurrentMediaTime() - startedAt
      let position = Float(min(1.0, elapsed / duration))
      voice.gain.outputVolume = AudioGraph.fadeVolume(
        from: start, to: target, position: position, curve: curve)

      if position >= 1 {
        voice.gain.outputVolume = target
        timer.invalidate()
        self?.fadeTimers[voice.id] = nil
        completion?()
      }
    }
    fadeTimers[voice.id] = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  /**
   Cut a voice immediately.

   This used to run a 15ms fade to avoid a click, which was solving a problem
   the mixer already solves: `AVAudioMixerNode` glides volume changes rather
   than stepping them — measurable, and measured, in
   `testGainIsHonoured`. A 15ms fade at 20ms steps was never more than one step
   anyway.

   What the fade did add was a dependency on a running run loop, which meant a
   cut silently never completed anywhere one was not spinning. Setting the
   value is both simpler and more reliable.
   */
  public func cut(_ voice: Voice, to target: Float) {
    fadeTimers[voice.id]?.invalidate()
    fadeTimers[voice.id] = nil
    voice.gain.outputVolume = target
  }

  // MARK: - Offline rendering
  //
  // Lets the whole graph be rendered without audio hardware, which is what
  // makes it testable at all: the alternative is a device and a pair of ears.

  public func startOffline(sampleRate: Double = AudioGraph.fixedSampleRate,
                    maximumFrameCount: AVAudioFrameCount = 4096) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    engine.stop()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maximumFrameCount)
    engine.prepare()
    try engine.start()
  }

  /// Render `frames` frames and hand back what came out.
  public func renderOffline(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    guard let format = engine.manualRenderingFormat as AVAudioFormat?,
          let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
      throw NSError(domain: "AudioGraph", code: -1)
    }
    var rendered: AVAudioFrameCount = 0
    while rendered < frames {
      let chunk = min(engine.manualRenderingMaximumFrameCount, frames - rendered)
      guard let slice = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
      let status = try engine.renderOffline(chunk, to: slice)
      guard status == .success || status == .insufficientDataFromInputNode else { break }
      if slice.frameLength == 0 { break }
      output.append(slice)
      rendered += slice.frameLength
    }
    return output
  }
}

private extension AVAudioPCMBuffer {
  /// Concatenate, for accumulating offline render output.
  func append(_ other: AVAudioPCMBuffer) {
    guard let dst = floatChannelData, let src = other.floatChannelData else { return }
    let room = frameCapacity - frameLength
    let count = min(room, other.frameLength)
    guard count > 0 else { return }
    for channel in 0..<Int(format.channelCount) {
      memcpy(dst[channel] + Int(frameLength), src[channel], Int(count) * MemoryLayout<Float>.size)
    }
    frameLength += count
  }
}
