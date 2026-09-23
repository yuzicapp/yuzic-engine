import type {
  BrowseNode,
  CacheOptions,
  CacheStats,
  CrossfadeOptions,
  EngineEvent,
  EqBand,
  MediaId,
  PlaybackState,
  Progress,
  RepeatMode,
  ReplayGainOptions,
  SampleRateMode,
  Track,
} from './types';

/**
 * The whole surface.
 *
 * Two rules shaped this, and both are worth stating before the methods:
 *
 * **The queue lives natively.** Not here. When the app is backgrounded, its
 * JavaScript is suspended — but the lock screen still has to advance to the
 * next track, the car still has to answer a steering-wheel button, and the
 * now-playing info still has to update. Anything that needs JS awake to happen
 * will eventually not happen. So the host hands over a whole queue and issues
 * commands against it; it never drives track-by-track.
 *
 * **Playback is a graph, not a player.** Crossfade is two source nodes
 * overlapping into a mixer, and an equalizer is a node in the chain. Neither is
 * expressible against a single-output queue player, which is the wall every
 * existing React Native player runs into. That choice is what `setCrossfade`
 * and `setEqualizer` below rest on, and it is why remote audio is fetched to
 * disk first — see docs/architecture.md.
 */
export interface AudioEngine {
  // ── lifecycle ────────────────────────────────────────────────────────────

  /**
   * Claim the audio session and start the playback service. Idempotent; a
   * second call with different options reconfigures rather than restarting,
   * because tearing the session down mid-playback is audible.
   */
  setup(options?: EngineSetupOptions): Promise<void>;

  /** Release the session and stop the service. */
  teardown(): Promise<void>;

  // ── queue ────────────────────────────────────────────────────────────────

  /** Replace the queue. `startIndex` becomes current; playback does not start. */
  setQueue(tracks: Track[], startIndex?: number): Promise<void>;
  append(tracks: Track[]): Promise<void>;
  /** Insert before `index`. */
  insertAt(index: number, tracks: Track[]): Promise<void>;
  removeAt(index: number): Promise<void>;
  move(fromIndex: number, toIndex: number): Promise<void>;
  clearQueue(): Promise<void>;

  getQueue(): Promise<Track[]>;
  getActiveIndex(): Promise<number>;

  // ── transport ────────────────────────────────────────────────────────────

  play(): Promise<void>;
  pause(): Promise<void>;
  /** Stops and releases the current source; the queue survives. */
  stop(): Promise<void>;
  seekTo(positionSec: number): Promise<void>;
  skipToNext(): Promise<void>;
  skipToPrevious(): Promise<void>;
  skipToIndex(index: number): Promise<void>;

  setVolume(volume: number): Promise<void>;
  setSpeed(speed: number): Promise<void>;
  setRepeatMode(mode: RepeatMode): Promise<void>;

  getState(): Promise<PlaybackState>;
  getProgress(): Promise<Progress>;

  // ── the reasons this exists ──────────────────────────────────────────────

  /** Pass `null` to turn crossfade off. */
  setCrossfade(options: CrossfadeOptions | null): Promise<void>;

  /**
   * Replace the equalizer curve. An empty array is flat — which is not the
   * same as bypassed, and the engine bypasses the node entirely when flat so
   * an untouched EQ costs nothing.
   */
  setEqualizer(bands: EqBand[]): Promise<void>;

  /**
   * Needs `replayGainDb` on the tracks — the engine reads tags and never
   * computes loudness itself, because computing it means decoding a whole
   * track before it can play.
   */
  setReplayGain(options: ReplayGainOptions): Promise<void>;

  /**
   * Turning this to `match-source` disables crossfade, because overlapping
   * sources have to share a sample rate. The engine reports the change rather
   * than letting the two settings silently contradict each other.
   */
  setSampleRateMode(mode: SampleRateMode): Promise<void>;

  // ── cache ────────────────────────────────────────────────────────────────
  //
  // Both platforms, apart from `configureCache` (below). Audio is kept on disk between tracks and between
  // launches, keyed by `MediaId` rather than by URL — stream URLs carry tokens
  // that rotate, so a URL key would miss every session and fill the cache with
  // duplicates of one album.
  //
  // Entries are sparse: a track played halfway is kept halfway, and a later
  // play resumes from whatever arrived rather than starting again. Eviction is
  // least-recently-used and takes whole entries, because a track with its
  // middle dropped still costs a request per gap.
  //
  // Only directly-streamed audio is cached. A transcoded stream is generated
  // per request and its bytes are not the file, so two plays at different
  // bitrates would be different audio under one id.
  //
  // `configureCache` is NOT IMPLEMENTED on Android — and *absent*, not inert.
  // `YuzicEngine.ts` is a straight pass-through with no platform branching, so
  // calling it there throws at the bridge rather than quietly doing nothing.
  //
  // That is the intended behaviour and not a gap to paper over: a method that
  // silently does nothing is the thing this file has refused elsewhere. Media3
  // takes the cache limit as a constructor argument to the evictor, so changing
  // it means a second `SimpleCache` over one directory — documented as
  // corrupting the index — or releasing the live one mid-track. The other three
  // do work on both platforms.

  configureCache(options: CacheOptions): Promise<void>;
  clearCache(): Promise<void>;
  cacheStats(): Promise<CacheStats>;
  /** Drop one track's cached audio — used when a download is deleted. */
  evict(id: MediaId): Promise<void>;

  // ── mutual TLS ───────────────────────────────────────────────────────────
  //
  // A server behind a reverse proxy that asks the client for a certificate.
  // The engine presents it on both transports; without it the handshake ends
  // and every request reads as "cannot connect", with nothing to say that a
  // certificate was ever wanted.
  //
  // `pkcs12Base64` is the imported file, base64'd for the bridge; the password
  // decrypts it and is not retained here. Pass null to stop presenting one.
  // Takes effect for the next network request. A request already in flight may
  // finish on the identity it started with. Rejects immediately when the blob
  // is malformed or the password cannot decrypt it.
  setClientCertificate(pkcs12Base64: string | null, password: string | null): Promise<void>;

  /**
   * **Experimental.** Its shape may change, or it may move out of this
   * package, in a minor release. It is an HTTP client rather than audio, and
   * is here only because the certificate it presents already is.
   *
   * Perform an HTTP request presenting the client certificate set above.
   *
   * Here because JavaScript's `fetch` cannot present a client identity, and a
   * certificate that only reaches the audio transport is unreachable in
   * practice: the app has to log in and list a library before it asks for a
   * track, and those calls are the ones the server refuses first. So the host
   * routes its server API calls through this exactly while a certificate is
   * set, and uses `fetch` otherwise.
   *
   * Not a general networking layer, and deliberately minimal — redirects,
   * cookies and caching are the platform's defaults. Bodies are base64 in both
   * directions because a response is as likely to be artwork as JSON, and
   * base64 is what carries arbitrary bytes over the bridge without a second
   * guess about charset. Response header names arrive lowercased.
   *
   * A non-2xx is returned, not thrown: an HTTP error is an answer, and the
   * callers already read `status`. It rejects only when no answer arrived at
   * all — a failed handshake, a refused connection, a timeout.
   */
  clientCertificateRequest(options: ClientCertificateRequest): Promise<ClientCertificateResponse>;

  // ── platform surfaces ────────────────────────────────────────────────────

  /**
   * The tree CarPlay and Android Auto browse. Handed over whole for the same
   * reason as the queue: the car may ask while JS is asleep.
   */
  setBrowseTree(root: BrowseNode): Promise<void>;
  /**
   * Take the tree away. On Android this also deletes the copy kept for a car
   * that starts the service with no JavaScript running, so call it when the
   * library is no longer the listener's to show, at sign-out most of all.
   */
  clearBrowseTree(): Promise<void>;
  /** Which remote controls to advertise on the lock screen and in the car. */
  setCommands(commands: RemoteCommand[]): Promise<void>;

  // ── sleep timer ──────────────────────────────────────────────────────────

  /** Fades out and pauses after `seconds`. Native so it survives suspension. */
  sleepAfter(seconds: number): Promise<void>;
  cancelSleep(): Promise<void>;

  // ── events ───────────────────────────────────────────────────────────────

  addListener(listener: (event: EngineEvent) => void): () => void;
}

export interface ClientCertificateRequest {
  url: string;
  /** Defaults to `GET` on the native side. */
  method?: string;
  headers?: Record<string, string>;
  /** Base64, because a body may be arbitrary bytes. Omit for a GET. */
  bodyBase64?: string | null;
  /** Ceiling for this request. Defaults to 30s, matching the app's own. */
  timeoutMs?: number;
}

export interface ClientCertificateResponse {
  status: number;
  /** Header names are lowercased — HTTP does not promise a case. */
  headers: Record<string, string>;
  /** Base64, decoded by the caller into text or bytes as it needs. */
  bodyBase64: string;
}

/**
 * Only what both platforms honour. `cache` and `android` used to be declared
 * here and were read by neither native module, so a host that set them got
 * nothing and was not told. The cache is sized with `configureCache` (iOS),
 * and the notification is Media3's own.
 */
export interface EngineSetupOptions {
  /**
   * How often to emit `progress`. The host usually wants ~1Hz for a progress
   * bar; scrubbing wants more. Emitting is cheap, re-rendering is not, so the
   * rate is the host's call.
   */
  progressIntervalMs?: number;
  /** Pause when headphones are unplugged, rather than playing out loud. */
  pauseOnBecomingNoisy?: boolean;
}

/**
 * `skipForward` and `skipBackward` jump 15 seconds forward and 5 back, the
 * same on both platforms: they are Media3's defaults, and iOS uses them too so
 * the same button does the same thing everywhere.
 */
export type RemoteCommand =
  | 'playPause'
  | 'next'
  | 'previous'
  | 'seek'
  | 'skipForward'
  | 'skipBackward'
  | 'stop';
