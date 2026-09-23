import ExpoModulesCore
import AVFoundation

// No `import YuzicEngineCore` here, and that is not an oversight. The podspec
// compiles `ios/Core` and this file into a single module, so the core types are
// already in scope; SwiftPM is the odd one out, splitting Core into its own
// target so `swift test` can build the logic without an app. Importing it would
// be correct for the package and wrong for every real build.

/**
 A command arrived before `setup` built the engine.

 Worth an error rather than a shrug. Every command below used to be
 `self.engine?.doThing()`, and optional chaining on a nil engine is a silent
 no-op — the call crosses the bridge, resolves successfully, and nothing
 happens. That produced a bug where the app opened on a cold launch, showed
 the track and sat paused: `setup` was still claiming the audio session while
 the restored queue issued `setQueue` and `play`, and both vanished.

 The host now serialises its calls behind `setup`, so this should never be
 raised. That is exactly why it should exist and say so: if it is ever seen,
 the ordering guarantee has broken and the alternative is silence.
 */
internal final class EngineNotSetUpException: Exception {
  override var reason: String {
    "the engine is not set up — call setup() and wait for it before any command"
  }
}

/**
 The Expo module surface — the thin part. Everything of substance lives in
 `AudioGraph`, `Queue` and the cache; this file only translates.

 Expo Modules rather than Nitro because nothing high-frequency crosses this
 bridge: audio never does, commands are rare, and progress is emitted about
 once a second. What is large is the *integration* surface — background audio
 mode, the CarPlay entitlement and scene, the Android foreground service and
 notification channel — and that is config-plugin work, which is where the
 Expo Modules API is markedly better. See docs/architecture.md.
 */
public final class YuzicEngineModule: Module {

  private var graph: AudioGraph?
  private var engine: PlaybackEngine?
  private var sleepTimer: SleepTimer?
  private var cache: DiskCache?
  /// Held so a certificate set before `setup` still reaches the factory, and
  /// so one set after it can be handed to a factory that already exists.
  private var factory: HTTPTrackReaderFactory?
  private var clientCertificate: ClientCertificate?
  /// The API-request path for the same certificate. Not optional and not tied
  /// to `setup`: the app has to log in before there is anything to play, so
  /// this has to work before the engine is set up at all.
  private let certificateHTTP = ClientCertificateHTTP()
  /**
   A car selection that arrived before `setup`, played once the engine exists.

   A car can launch the app into its CarPlay scene alone. The host starts its
   JavaScript for that, pushes the tree it has, and calls `setup`, and a driver
   who taps a row in between would otherwise get a now-playing screen that
   never starts. Main queue only, like the engine.
   */
  private var pendingCarSelection: (tracks: [Track], index: Int)?

  /**
   The engine, or a named failure.

   Used by every *command*. Getters keep their defaults on purpose: "nothing
   is playing" is a truthful answer before setup, and a progress poll that
   throws during launch would be noise rather than signal.
   */
  private func requireEngine() throws -> PlaybackEngine {
    guard let engine else { throw EngineNotSetUpException() }
    return engine
  }

  /**
   Caches (which iOS may delete under pressure) rather than Documents.

   Audio here is re-fetchable by definition — it came from a server and the id
   that keyed it will fetch it again. Putting it in Documents would back it up
   to iCloud and count against the user's storage forever, for bytes the app
   can always get back. Offline *downloads* are a different feature with
   different expectations, and they belong somewhere else when they arrive.
   */
  private static func defaultCacheDirectory() -> URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("yuzic-engine/audio", isDirectory: true)
  }

  public func definition() -> ModuleDefinition {
    Name("YuzicEngine")

    Events("onStateChange", "onTrackChange", "onProgress", "onQueueChange", "onError", "onRemoteCommand")

    // MARK: lifecycle

    AsyncFunction("setup") { (options: SetupOptions?) in
      let pauseOnNoisy = options?.pauseOnBecomingNoisy ?? true
      try self.configureAudioSession(pauseOnBecomingNoisy: pauseOnNoisy)

      if self.engine == nil {
        let graph = AudioGraph()
        try graph.start()
        // A cache that cannot be created is not a reason to refuse to play —
        // the engine worked without one until now, and falls back to that.
        let cache = try? DiskCache(directory: Self.defaultCacheDirectory())
        self.cache = cache
        // Carried into the factory rather than re-sent by the app: the
        // certificate can be set before `setup` as easily as after, and a
        // caller should not have to know which order it happened in.
        let factory = HTTPTrackReaderFactory(
          cache: cache, clientCertificate: self.clientCertificate
        )
        self.factory = factory
        let engine = PlaybackEngine(graph: graph, factory: factory)
        engine.onEvent = { [weak self] event in self?.forward(event) }
        // Honoured rather than ignored — Android has always applied it, and a
        // host asking for 1Hz was getting 4Hz of bridge traffic here. Floored
        // the same way Android floors it.
        engine.progressIntervalSec =
          Double(max(100, options?.progressIntervalMs ?? 1000)) / 1000.0
        self.graph = graph
        self.engine = engine
        self.sleepTimer = SleepTimer { [weak self] fade in
          // Fade rather than cut: music stopping mid-bar is what wakes people,
          // which is the opposite of the point.
          guard let self, let graph = self.graph else { return }
          // Linear, not equal power. Nothing sums with this — it is one track
          // going to silence — and equal power would still be at 0.707 halfway
          // through, so the fade would hold almost full volume and then
          // collapse. That is the opposite of a fade to sleep.
          graph.fade(graph.activeVoice, to: 0, over: fade, curve: .linear) { self.engine?.pause() }
        }
      }

      // The session is configured once, above — and a media services reset
      // clears it. The engine cannot know what category this host wants, so
      // it asks for the same call again rather than guessing one. Installed
      // after the engine exists, and on every setup, so a setup that changes
      // `pauseOnBecomingNoisy` re-arms the hook with the new value.
      self.engine?.reconfigureAudioSession = { [weak self] in
        try self?.configureAudioSession(pauseOnBecomingNoisy: pauseOnNoisy)
      }

      // What the car's "Up Next" reads, and how a row in it jumps. Read on
      // main when the driver opens it, which is where the engine lives.
      CarPlayCoordinator.shared.setQueueSource({ [weak self] in
        let queue = self?.engine?.queue
        return CarPlayCoordinator.QueueSnapshot(tracks: queue?.tracks ?? [], activeIndex: queue?.activeIndex ?? 0)
      }, skip: { [weak self] index in
        try? self?.engine?.skipTo(index: index)
      })

      DispatchQueue.main.async { [weak self] in
        guard let self, let engine = self.engine, let pending = self.pendingCarSelection else { return }
        self.pendingCarSelection = nil
        self.playCarSelection(pending.tracks, at: pending.index, on: engine)
      }
    }

    AsyncFunction("teardown") {
      // Optional on purpose, unlike the commands: tearing down something that
      // was never set up is a no-op, not a failure. A host cleaning up after a
      // failed launch should not be handed an error for tidying.
      self.engine?.stop()
      self.engine = nil
      CarPlayCoordinator.shared.setQueueSource(nil, skip: nil)
      CarPlayCoordinator.shared.setNowPlaying(nil)
      self.graph?.stop()
      self.graph = nil
      self.sleepTimer?.cancel()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: queue
    //
    // Everything that reads or moves the engine runs on the main queue. The
    // engine is driven from main by everything else that touches it — the
    // ticker, the lock screen and car commands, and the system's interruption,
    // route and media-reset notifications — and Expo's default is a background
    // queue of its own, so a play from JavaScript could race an interruption
    // handler over the same playback and graph.
    //
    // The queue lives here, natively, and not in JavaScript. Backgrounded JS is
    // suspended, and the next track still has to start, the lock screen still
    // has to update, and the car still has to answer its buttons.

    AsyncFunction("setQueue") { (tracks: [TrackRecord], startIndex: Int?) in
      try self.requireEngine().setQueue(tracks.map(\.asTrack), startIndex: startIndex ?? 0)
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("append") { (tracks: [TrackRecord]) in
      try self.requireEngine().queue.append(tracks.map(\.asTrack))
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("getActiveIndex") { () -> Int in
      self.engine?.queue.activeIndex ?? 0
    }.runOnQueue(.main)

    // Queue editing. Declared in `src/AudioEngine.ts` since the beginning and
    // implemented by nothing until now, which is what was standing between the
    // host and deleting its current player — yuzic edits its queue through
    // every one of these.
    //
    // None of them touch playback. Editing a list and changing what is playing
    // are different actions, and the queue's own index adjustments exist to
    // keep the second from happening as a side effect of the first.

    AsyncFunction("insertAt") { (index: Int, tracks: [TrackRecord]) in
      try self.requireEngine().queue.insert(tracks.map(\.asTrack), at: index)
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("removeAt") { (index: Int) in
      try self.requireEngine().queue.remove(at: index)
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("move") { (fromIndex: Int, toIndex: Int) in
      try self.requireEngine().queue.move(from: fromIndex, to: toIndex)
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("clearQueue") {
      try self.requireEngine().queue.clear()
      self.sendEvent("onQueueChange", [:])
    }.runOnQueue(.main)

    AsyncFunction("getQueue") { () -> [[String: Any]] in
      (self.engine?.queue.tracks ?? []).map(\.asRecordDictionary)
    }.runOnQueue(.main)

    AsyncFunction("setRepeatMode") { (mode: String) in
      try self.requireEngine().queue.repeatMode = RepeatMode(rawValue: mode) ?? .off
    }.runOnQueue(.main)

    // MARK: transport

    AsyncFunction("getState") { () -> String in
      self.engine?.state.rawValue ?? PlaybackEngine.PlaybackState.idle.rawValue
    }.runOnQueue(.main)

    /**
     Asked rather than waited for.

     Progress arrives as an event on a timer, which is no use to a screen that
     has just mounted mid-track — it would show zero until the next tick.
     */
    AsyncFunction("getProgress") { () -> [String: Any] in
      let progress = self.engine?.progress ?? (positionSec: 0, durationSec: 0, bufferedSec: 0)
      return [
        "positionSec": progress.positionSec,
        "durationSec": progress.durationSec,
        "bufferedSec": progress.bufferedSec,
      ]
    }.runOnQueue(.main)

    AsyncFunction("play") { try self.requireEngine().play() }.runOnQueue(.main)
    AsyncFunction("pause") { try self.requireEngine().pause() }.runOnQueue(.main)
    AsyncFunction("stop") { try self.requireEngine().stop() }.runOnQueue(.main)
    AsyncFunction("seekTo") { (positionSec: Double) in try self.requireEngine().seek(toSeconds: positionSec) }.runOnQueue(.main)
    AsyncFunction("skipToNext") { try self.requireEngine().skipToNext() }.runOnQueue(.main)
    AsyncFunction("skipToPrevious") { try self.requireEngine().skipToPrevious() }.runOnQueue(.main)
    AsyncFunction("skipToIndex") { (index: Int) in try self.requireEngine().skipTo(index: index) }.runOnQueue(.main)
    AsyncFunction("setVolume") { (volume: Double) in
      // Through the engine, not onto the gain node. Writing `outputVolume`
      // here put user volume on the same node the crossfade ramps, so it was
      // discarded by the next fade and, after a skip taken mid-fade, wrote to
      // a voice nothing would touch again until the following track.
      try self.requireEngine().volume = Float(volume)
    }.runOnQueue(.main)

    AsyncFunction("setSpeed") { (speed: Double) in
      self.graph?.setSpeed(Float(speed))
    }.runOnQueue(.main)

    // MARK: cache
    //
    // These four were declared in src/AudioEngine.ts and existed nowhere, so
    // calling one failed with "function not found" — which the comment there
    // described as throwing rather than quietly doing nothing, and preferred
    // to a method that lies. They do something now.

    /**
     Present a client certificate to servers that ask for one.

     `pkcs12Base64` is the file the person imported, base64'd because that is
     what crosses the bridge; nil clears it. The password decrypts the blob and
     is not stored here — the app holds both in the system keychain and hands
     them over on each setup.

     Throws on a blob that will not decrypt, rather than accepting it and
     failing later at the first request. A certificate that cannot be read is
     something the person can fix while they are still looking at the screen
     they imported it on, and reporting it there is the difference between a
     typo in a password and "the server is unreachable".
     */
    AsyncFunction("setClientCertificate") { (pkcs12Base64: String?, password: String?) in
      guard let pkcs12Base64, !pkcs12Base64.isEmpty else {
        self.clientCertificate = nil
        self.factory?.setClientCertificate(nil)
        self.certificateHTTP.setClientCertificate(nil)
        return
      }
      guard let blob = Data(base64Encoded: pkcs12Base64) else {
        throw ClientCertificateError.notBase64
      }
      let certificate = try ClientCertificate(pkcs12: blob, password: password ?? "")
      self.clientCertificate = certificate
      self.factory?.setClientCertificate(certificate)
      // The API requests need the same identity as the audio stream. A
      // certificate given to only the factory authenticates playback for a
      // server the app cannot log into, which is no use to anyone: the login
      // fails first and no track is ever requested.
      self.certificateHTTP.setClientCertificate(certificate)
    }

    /**
     Perform an HTTP request with the client certificate attached.

     Here rather than in the app because JavaScript's `fetch` has no way to
     present a client identity — this is the only path from JS to a mutual-TLS
     server. The app routes its server API calls through this exactly when a
     certificate is set, and uses `fetch` otherwise.

     Bodies are base64 in both directions: a response may be artwork as easily
     as JSON, and base64 is what survives arbitrary bytes over the bridge.
     */
    AsyncFunction("clientCertificateRequest") { (options: ClientCertificateRequestRecord) -> [String: Any] in
      let result = try await self.certificateHTTP.request(
        url: options.url,
        method: options.method,
        headers: options.headers,
        bodyBase64: options.bodyBase64,
        timeoutMs: options.timeoutMs
      )
      return [
        "status": result.status,
        "headers": result.headers,
        "bodyBase64": result.bodyBase64,
      ]
    }

    AsyncFunction("configureCache") { (options: CacheOptionsRecord) in
      self.cache?.configure(maxBytes: Int64(options.maxBytes))
    }

    AsyncFunction("clearCache") {
      self.cache?.clear()
    }

    AsyncFunction("cacheStats") { () -> [String: Any] in
      let stats = self.cache?.stats()
      return [
        "usedBytes": stats?.usedBytes ?? 0,
        "maxBytes": stats?.maxBytes ?? 0,
        "entryCount": stats?.entryCount ?? 0,
      ]
    }

    AsyncFunction("evict") { (id: String) in
      self.cache?.evict(id)
    }

    // MARK: sleep timer

    AsyncFunction("sleepAfter") { (seconds: Double) in self.sleepTimer?.schedule(after: seconds) }.runOnQueue(.main)
    AsyncFunction("cancelSleep") { self.sleepTimer?.cancel() }.runOnQueue(.main)

    // MARK: the reasons this exists

    AsyncFunction("setEqualizer") { (bands: [EqBandRecord]) in
      self.graph?.setEqualizer(bands: bands.map {
        (frequency: Float($0.frequencyHz), gainDb: Float($0.gainDb), q: Float($0.q ?? 1.0))
      })
    }.runOnQueue(.main)

    /**
     Loudness normalisation, from the host's tags.

     The engine never measures loudness itself: measuring means decoding a
     whole track before it can play, which is the thing this player exists not
     to do. The figures are already in the files.
     */
    AsyncFunction("setReplayGain") { (options: ReplayGainRecord) in
      try self.requireEngine().replayGain = options.asSettings
    }.runOnQueue(.main)

    AsyncFunction("setCrossfade") { (options: CrossfadeRecord?) in
      try self.requireEngine().queue.crossfade = options?.asSettings
    }.runOnQueue(.main)

    /**
     Hand the car its browse tree.

     Pushed down in advance rather than served on demand, because the car asks
     when the app's JavaScript is asleep — someone starts driving, the phone
     connects, and there is no runtime awake to answer. A tree that has to be
     fetched from JS is a tree that is sometimes empty at exactly the wrong
     moment.
     */
    AsyncFunction("setBrowseTree") { (title: String, nodes: [BrowseNodeRecord]) in
      let tree = BrowseTree.build(title: title, from: nodes.map(\.asFlatNode))
      CarPlayCoordinator.shared.setRoot(tree)
      CarPlayCoordinator.shared.setPlayHandler { [weak self] tracks, index in
        guard let self else { return }
        // Played natively rather than round-tripped through JS, for the same
        // reason the tree is: nothing may be listening. The host finds out
        // afterwards through the ordinary track-change event.
        guard let engine = self.engine else {
          // Before `setup`: held, and played the moment it finishes. The
          // latest tap wins, which is what the driver last asked for.
          NSLog("[yuzic-engine] CarPlay selection held until the engine is set up")
          self.pendingCarSelection = (tracks, index)
          return
        }
        self.playCarSelection(tracks, at: index, on: engine)
      }
    }

    /**
     Which remote controls to advertise.

     Not a fixed property of the engine: a podcast wants skip-forward rather
     than next-track, and a live stream should not draw a scrubber over
     something with no end.
     */
    AsyncFunction("setCommands") { (commands: [String]) in
      // An unrecognised name is dropped rather than defaulted. Advertising a
      // control the host never asked for is how a car ends up with a button
      // that does nothing.
      try self.requireEngine().remoteCommands = commands.compactMap { RemoteCommand(rawValue: $0) }
    }.runOnQueue(.main)

    AsyncFunction("clearBrowseTree") {
      CarPlayCoordinator.shared.setRoot(nil)
      CarPlayCoordinator.shared.setPlayHandler(nil)
    }

    AsyncFunction("setSampleRateMode") { (mode: String) in
      // Enforced rather than merely recorded. Overlapping sources may differ in
      // rate — the mixer converts — but the *hardware* rate cannot change
      // mid-fade without stopping the engine and discarding every scheduled
      // buffer, so bit-perfect output and a crossfade in progress cannot
      // coexist. Resolved here rather than left as two settings that fight.
      let resolved = SampleRateMode(rawValue: mode) ?? .fixed
      let engine = try self.requireEngine()
      if resolved == .matchSource, engine.queue.crossfade != nil {
        engine.queue.crossfade = nil
        self.sendEvent("onError", [
          "code": "CROSSFADE_DISABLED",
          "message": "Crossfade turned off: the hardware sample rate cannot change mid-fade.",
        ])
      }
      engine.queue.sampleRateMode = resolved
    }.runOnQueue(.main)
  }

  private func playCarSelection(_ tracks: [Track], at index: Int, on engine: PlaybackEngine) {
    engine.setQueue(tracks, startIndex: index)
    try? engine.play()
    sendEvent("onQueueChange", [:])
  }

  /// Engine events, translated for JavaScript. One place, so the event names
  /// and payload shapes cannot drift between here and the TypeScript types.
  private func forward(_ event: PlaybackEngine.Event) {
    switch event {
    case .stateChanged(let state):
      sendEvent("onStateChange", ["state": state.rawValue])
    case .trackChanged(let index, let id, let listened):
      // The car marks the row of what is playing, whoever started it.
      CarPlayCoordinator.shared.setNowPlaying(id)
      var payload: [String: Any] = ["index": index]
      if let id { payload["id"] = id }
      if let listened { payload["previousListenedSec"] = listened }
      sendEvent("onTrackChange", payload)
    case .progress(let position, let duration, let buffered):
      sendEvent("onProgress", [
        "positionSec": position, "durationSec": duration, "bufferedSec": buffered,
      ])
    case .ended:
      // Deliberately not forwarded. `finish()` sets `state = .ended` first,
      // whose `didSet` already sent `onStateChange: ended` through the case
      // above — so forwarding this as well told the host the queue had
      // finished twice. The engine keeps the distinct event because "the queue
      // ran out" and "the state is now ended" are different statements
      // internally; on the wire there is only the one state.
      break
    case .failed(let message):
      sendEvent("onError", ["code": "PLAYBACK_FAILED", "message": message])
    }
  }

  /**
   `.playback` with `.longFormAudio`: the category that keeps playing when the
   screen locks and the routing policy that tells the system this is music
   rather than a game or a call.
   */
  private func configureAudioSession(pauseOnBecomingNoisy: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
    try session.setActive(true)
  }
}

// MARK: - Records
//
// Shapes crossing the bridge. Kept flat and optional-tolerant: a host that
// omits a field means "no information", which is not the same as a zero — the
// replay-gain pair is exactly that distinction.

struct SetupOptions: Record {
  @Field var progressIntervalMs: Int = 1000
  @Field var pauseOnBecomingNoisy: Bool = true
}

struct TrackRecord: Record {
  @Field var id: String = ""
  @Field var uri: String = ""
  @Field var title: String = ""
  @Field var artist: String?
  @Field var album: String?
  @Field var artworkUri: String?
  @Field var artworkHeaders: [String: String]?
  @Field var durationSec: Double?
  @Field var headers: [String: String]?
  @Field var followsPrevious: Bool = false
  @Field var replayGainDb: Double?
  @Field var replayGainPeak: Double?
  @Field var continuous: Bool = false
  /// Absent means the default parameter; present with a nil `queryParam`
  /// means none. See `Track.seekReconnect` in src/types.ts.
  @Field var seekReconnect: SeekReconnectRecord?
}

struct SeekReconnectRecord: Record {
  @Field var queryParam: String?
}

/**
 One browse node, flat.

 Flat because a `Record` cannot contain itself — `@Field` has no way to
 describe recursion — so the tree crosses the bridge as a list with parent
 references and is rebuilt on this side.
 */
struct BrowseNodeRecord: Record {
  @Field var id: String = ""
  @Field var parentId: String?
  @Field var title: String = ""
  @Field var subtitle: String?
  @Field var artworkUri: String?
  /// Sent only while fetching `artworkUri` — see `BrowseNode.artworkHeaders`.
  @Field var artworkHeaders: [String: String] = [:]
  @Field var playable: TrackRecord?
  /// Carried for Android Auto, which can draw a grid. CarPlay draws rows.
  @Field var layout: String?
  @Field var icon: String?
  @Field var action: String?
}

struct EqBandRecord: Record {
  @Field var frequencyHz: Double = 0
  @Field var gainDb: Double = 0
  @Field var q: Double?
}

struct ClientCertificateRequestRecord: Record {
  @Field var url: String = ""
  @Field var method: String = "GET"
  @Field var headers: [String: String] = [:]
  /// Base64 because a request body may be arbitrary bytes. Nil for a GET.
  @Field var bodyBase64: String?
  /// Mirrors the app's own per-request ceiling; the native side must not
  /// outlive the timeout JavaScript believes it set.
  @Field var timeoutMs: Int = 30_000
}

struct CacheOptionsRecord: Record {
  @Field var maxBytes: Double = Double(DiskCache.defaultMaxBytes)
}

struct ReplayGainRecord: Record {
  @Field var mode: String = "off"
  @Field var preampDb: Double = 0
  @Field var untaggedPreampDb: Double = 0
  @Field var preventClipping: Bool = true
}

struct CrossfadeRecord: Record {
  @Field var durationSec: Double = 0
  @Field var mode: String = "gapless-aware"
  @Field var skipIsImmediate: Bool = true
}


// MARK: - Domain → bridge
//
// Only `getQueue` needs this direction: everything else the host learns comes
// through an event, and events carry figures rather than tracks. Hand-built
// rather than made `Codable`, so that the keys here and the `Track` fields in
// src/types.ts are visibly the same list and drift is a visible diff.

extension Track {
  var asRecordDictionary: [String: Any] {
    var out: [String: Any] = [
      "id": id,
      "uri": uri,
      "title": title,
      "followsPrevious": followsPrevious,
      "continuous": continuous,
    ]
    // Absent rather than null: `durationSec` missing means the host never knew,
    // and a JSON null would arrive as 0 and be believed.
    if let artist { out["artist"] = artist }
    if let album { out["album"] = album }
    if let artworkUri { out["artworkUri"] = artworkUri }
    if !artworkHeaders.isEmpty { out["artworkHeaders"] = artworkHeaders }
    if let durationSec { out["durationSec"] = durationSec }
    if !headers.isEmpty { out["headers"] = headers }
    if let replayGainDb { out["replayGainDb"] = replayGainDb }
    if let replayGainPeak { out["replayGainPeak"] = replayGainPeak }
    // Only when it differs from the default, so an ordinary queue reads back
    // exactly as it was set.
    if seekReconnectParam != Track.defaultSeekReconnectParam {
      let param: Any = seekReconnectParam ?? NSNull()
      out["seekReconnect"] = ["queryParam": param]
    }
    return out
  }
}

// MARK: - Bridge → domain
//
// The conversion happens here and nowhere else. Below this line everything is
// plain Swift that `swift test` can build without ExpoModulesCore — which is
// the only reason the queue rules have tests at all.

extension TrackRecord {
  var asTrack: Track {
    Track(
      id: id,
      uri: uri,
      title: title,
      artist: artist,
      album: album,
      artworkUri: artworkUri,
      artworkHeaders: artworkHeaders ?? [:],
      durationSec: durationSec,
      headers: headers ?? [:],
      followsPrevious: followsPrevious,
      replayGainDb: replayGainDb,
      replayGainPeak: replayGainPeak,
      continuous: continuous,
      seekReconnectParam: seekReconnect.map { $0.queryParam } ?? Track.defaultSeekReconnectParam
    )
  }
}

extension BrowseNodeRecord {
  var asFlatNode: BrowseTree.FlatNode {
    BrowseTree.FlatNode(
      id: id,
      parentId: parentId,
      title: title,
      subtitle: subtitle,
      artworkUri: artworkUri,
      artworkHeaders: artworkHeaders,
      playable: playable?.asTrack,
      icon: icon.flatMap(BrowseIcon.init(rawValue:)),
      action: action.flatMap(BrowseAction.init(rawValue:))
    )
  }
}

extension ReplayGainRecord {
  var asSettings: ReplayGainSettings {
    ReplayGainSettings(
      // An unrecognised mode means off rather than a guess: silently applying
      // an adjustment nobody asked for is worse than applying none.
      mode: ReplayGainMode(rawValue: mode) ?? .off,
      preampDb: preampDb,
      untaggedPreampDb: untaggedPreampDb,
      preventClipping: preventClipping
    )
  }
}

extension CrossfadeRecord {
  var asSettings: CrossfadeSettings {
    CrossfadeSettings(
      durationSec: durationSec,
      // An unrecognised mode falls back to the safer of the two: fading
      // through a deliberate segue is the outcome people notice and dislike.
      mode: CrossfadeMode(rawValue: mode) ?? .gaplessAware,
      skipIsImmediate: skipIsImmediate
    )
  }
}

/// Raised before the certificate layer is reached, for input that could not
/// have been a PKCS#12 in the first place.
enum ClientCertificateError: Error, LocalizedError {
  case notBase64

  var errorDescription: String? {
    switch self {
    case .notBase64: return "The certificate could not be decoded."
    }
  }
}
