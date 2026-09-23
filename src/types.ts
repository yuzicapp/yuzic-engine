/**
 * The vocabulary the engine and its host agree on.
 *
 * Deliberately not modelled on any existing React Native player: those all
 * describe a queue player, and this is a graph. The differences that matter
 * show up here — `followsPrevious`, `continuous`, the replay-gain pair, and
 * the fact that a track carries its own request headers.
 */

/** Stable identity for a track, chosen by the host. Opaque to the engine. */
export type MediaId = string;

export interface Track {
  id: MediaId;
  /**
   * `file://` for something already on disk, `http(s)://` for anything else.
   * A remote URI is fetched into the cache and played from there — see
   * docs/architecture.md; the graph plays files, never sockets.
   */
  uri: string;
  title: string;
  artist?: string;
  album?: string;
  /** Shown on the lock screen and in the car. Remote or local. */
  artworkUri?: string;
  /**
   * Sent only while fetching `artworkUri`. Keep credentials out of the URL and
   * out of persisted host state; the engine owns this ephemeral request.
   */
  artworkHeaders?: Record<string, string>;
  /**
   * Seconds, when the host already knows it. The engine will discover the real
   * duration on decode; this is what the lock screen shows before then, and
   * what a progress bar can size itself against without waiting.
   */
  durationSec?: number;
  /**
   * Sent with the fetch. Some servers authenticate a stream by header rather
   * than by signing the URL, and a player that can only take a URL forces
   * those into query strings, where they end up in logs.
   */
  headers?: Record<string, string>;
  /**
   * This track was mastered to run directly out of the one before it — an
   * album segue, a continuous mix. The engine hard-cuts instead of fading,
   * because a crossfade across a deliberate segue doubles the overlap and
   * sounds worse than the seam it is hiding.
   *
   * The host sets this; it knows album and track numbers already, which is a
   * far better signal than digging encoder delay and padding out of LAME tags
   * or `iTunSMPB`.
   */
  followsPrevious?: boolean;
  /**
   * Track (or album) loudness in dB relative to reference, from the server's
   * tags. Absent means "no information" — which is not the same as 0 dB, and
   * the engine treats the two differently: see `ReplayGainOptions.untaggedPreampDb`.
   */
  replayGainDb?: number;
  /**
   * Sample peak, 1.0 being full scale, from the same tags. Used to hold gain
   * below clipping: applying a positive replay-gain figure to an already-hot
   * master is how loudness normalisation ends up making tracks sound worse.
   */
  replayGainPeak?: number;
  /**
   * A stream with no meaningful end: live radio, and anything else where the
   * next track is not a thing that exists. Suppresses crossfade, gapless
   * preparation and end-of-track prediction — all three assume a finish line.
   */
  continuous?: boolean;
  /**
   * How to pick a stream back up after it breaks, when the server offered no
   * byte ranges and so the lost bytes cannot simply be asked for again. The
   * engine requests the track anew with this query parameter set to the
   * second reached, replacing any value already in the URL.
   *
   * Absent means `{ queryParam: 'timeOffset' }`, which is Subsonic's (and so
   * Navidrome's) spelling. That default is kept for compatibility, and it is
   * the wrong one for any other server: a parameter the server ignores
   * restarts the track from the top while the reported position carries on.
   * Pass `{ queryParam: null }` to turn reconnection off, so a broken stream
   * is reported as an `error` event instead.
   *
   * iOS only. Android reopens the same URL at the position reached and lets
   * Media3 find its way there, so it sends no parameter and reads nothing
   * here.
   */
  seekReconnect?: { queryParam: string | null };
}

export type RepeatMode = 'off' | 'one' | 'all';

/**
 * What the engine is doing. `buffering` is distinct from `paused` because the
 * UI should say different things: one is waiting on the network, the other is
 * waiting on the user.
 *
 * There is deliberately no `error` here. Neither platform has ever sent one:
 * a failure arrives as an `error` *event*, which carries a code and a message
 * a state name could not, and the state that follows is whatever the engine
 * is actually in afterwards. A member no producer emits is a member every
 * consumer still has to handle, so it is not declared.
 */
export type PlaybackState =
  | 'idle'
  | 'buffering'
  | 'playing'
  | 'paused'
  | 'ended';

export interface Progress {
  positionSec: number;
  /** 0 until the decoder knows, and for anything `continuous`. */
  durationSec: number;
  /**
   * How far the cache holds contiguous audio, on the *same timeline as
   * `positionSec`* — not a distance ahead of the playhead.
   *
   * A track playing at 4s with ten seconds fetched ahead reports 14, so a
   * buffering bar can be drawn against the same scale as the progress bar with
   * no arithmetic on the host's part. Measured from the playhead instead, the
   * figure would sit at the wrong end of that bar.
   */
  bufferedSec: number;
}

/**
 * Off by default.
 *
 * Three behaviours here are not configurable because getting them wrong is
 * always a bug, never a preference:
 *
 * - The fade is clamped to `min(durationSec, shorterTrack / 2)`. An eight
 *   second fade across a three second interlude is nonsense.
 * - The faded-out portion still counts toward the outgoing track's listened
 *   time. Without this, a long crossfade silently stops the host ever
 *   reaching a scrobble threshold, because position never approaches duration.
 * - Now-playing switches at the crossover midpoint. At fade start the lock
 *   screen names a track you can barely hear yet; at fade end it lags what you
 *   are hearing.
 */
export interface CrossfadeOptions {
  durationSec: number;
  /**
   * `gapless-aware` respects `Track.followsPrevious` and hard-cuts there.
   * `always` fades between everything, segues included — offered because some
   * people genuinely want it for shuffle-everything listening.
   */
  mode: 'always' | 'gapless-aware';
  /**
   * Cut rather than fade when the user pressed next. A fade is for a track
   * that ended; a skip should feel immediate. A short ramp is still applied so
   * the cut does not click. Default true.
   */
  skipIsImmediate?: boolean;
}

/** One band of the equalizer. Frequencies in Hz, gain in dB. */
export interface EqBand {
  frequencyHz: number;
  gainDb: number;
  /** Bandwidth in octaves. Defaults to a sensible value per band. */
  q?: number;
}

/**
 * `album` preserves the dynamics within a record — the quiet interlude that is
 * meant to be quiet stays quiet. `track` levels everything, which is what you
 * want on shuffle and not what you want on an album.
 *
 * `auto` is the recommended setting and picks per queue: album mode when the
 * queue is one album, track mode otherwise. Most players make this a global
 * choice and are therefore wrong half the time.
 */
export type ReplayGainMode = 'off' | 'track' | 'album' | 'auto';

export interface ReplayGainOptions {
  mode: ReplayGainMode;
  /** Applied on top of the tag figure, for people who want it all louder. */
  preampDb?: number;
  /**
   * Applied to tracks with no tags at all. Left at 0 by default: a library
   * where half the tracks are adjusted and half are not sounds *more* uneven
   * than one where none are, so this exists to let a user match the two.
   */
  untaggedPreampDb?: number;
  /**
   * Hold total gain below clipping using `Track.replayGainPeak`, at the cost
   * of not fully reaching the target loudness on hot masters. Default true —
   * quieter than asked for beats distorted.
   */
  preventClipping?: boolean;
}

/**
 * `fixed` runs the graph at one rate and converts everything into it.
 * `match-source` reconfigures the audio session per track to play at the
 * source's own rate.
 *
 * These are not equally capable, and the reason is structural: overlapping
 * sources must share a rate, and changing the session rate requires stopping
 * the engine. **`match-source` therefore disables crossfade**, and only takes
 * effect at a real track boundary. The engine enforces that rather than
 * letting the two settings quietly fight.
 *
 * Worth knowing before choosing: iOS hardware commonly runs at 48kHz and
 * Bluetooth imposes its own rate regardless, so `match-source` is only
 * meaningful over wired output or a USB DAC.
 */
export type SampleRateMode = 'fixed' | 'match-source';

/**
 * There is no preload count. One was declared here and neither platform read
 * it. The engine prepares the next track in the queue on its own, which is
 * the one a crossfade or a gapless join needs.
 */
export interface CacheOptions {
  maxBytes: number;
}

export interface CacheStats {
  usedBytes: number;
  maxBytes: number;
  entryCount: number;
}

/** A node in the CarPlay / Android Auto browse tree. */
export interface BrowseNode {
  id: string;
  title: string;
  subtitle?: string;
  artworkUri?: string;
  /**
   * Sent only while fetching `artworkUri`, exactly as `Track.artworkHeaders`
   * is for the now-playing cover.
   *
   * Without it a header-authenticated server — a Plex behind a Basic-auth
   * proxy, a Navidrome reached through one — answers 401 for every browse
   * thumbnail, and the car shows a list of blank squares while the same album
   * displays its cover perfectly on the now-playing screen. Keep credentials
   * out of the URL: a browse tree is held in memory for the life of the
   * process and pushed to the car, so a signed URL in it outlives the session
   * that signed it.
   */
  artworkHeaders?: Record<string, string>;
  /** Present for a branch; absent or empty for a leaf that plays. */
  children?: BrowseNode[];
  /** For a leaf: what to play. */
  playable?: Track;
  /**
   * How a branch draws its children. `grid` suits covers (albums, playlists),
   * `list` suits tracks. Android Auto and Automotive honour it; CarPlay draws
   * every list as rows with artwork, which is what it does best. Absent means
   * `list`.
   */
  layout?: BrowseLayout;
  /**
   * The icon for a top-level entry, which the car shows as a tab. Ignored
   * below the top level.
   */
  icon?: BrowseIcon;
  /**
   * A row that does something rather than opening or playing one thing.
   * `shuffle` plays every track beside it in random order, which is the one
   * thing a driver most wants from an album or a playlist and cannot build by
   * hand while moving. It needs no `playable` and no `children`.
   */
  action?: BrowseAction;
}

export type BrowseLayout = 'list' | 'grid';

export type BrowseIcon =
  | 'recent'
  | 'favorites'
  | 'albums'
  | 'artists'
  | 'playlists'
  | 'downloads'
  | 'radio'
  | 'library';

export type BrowseAction = 'shuffle';

/**
 * The codes an `error` event carries, and every one either platform sends.
 *
 * `PLAYBACK_FAILED`: a track could not be opened or stopped short, and the
 * message says which. `CROSSFADE_DISABLED`: crossfade was switched off because
 * `setSampleRateMode('match-source')` cannot coexist with it.
 */
export type EngineErrorCode = 'PLAYBACK_FAILED' | 'CROSSFADE_DISABLED';

export type EngineEvent =
  | { type: 'stateChange'; state: PlaybackState }
  /**
   * Fired at the crossover midpoint when crossfading, so it lines up with
   * what the listener is actually hearing. `previousListenedSec` is the
   * outgoing track's played time *including* its fade-out, which is what a
   * scrobble threshold has to be measured against.
   */
  | { type: 'trackChange'; index: number; id: MediaId | null; previousListenedSec?: number }
  | { type: 'progress'; progress: Progress }
  | { type: 'queueChange' }
  | { type: 'error'; code: EngineErrorCode; message: string; id?: MediaId }
  /**
   * A remote command the engine could not handle alone — the car asked for
   * something from the browse tree, say. The host answers by driving the
   * ordinary API.
   */
  | { type: 'remoteCommand'; command: string; payload?: unknown };
