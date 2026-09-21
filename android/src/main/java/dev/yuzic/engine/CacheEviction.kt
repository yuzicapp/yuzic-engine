package dev.yuzic.engine

import androidx.media3.common.PlaybackException

/**
 * Whether a playback failure says the bytes themselves were wrong, so the
 * cached copy of them has to go before anything tries again.
 *
 * Every stream goes through the disk cache (`AudioGraph.cacheDataSourceFactory`),
 * and the cache keeps whatever body came back. A server that answers a stream
 * request with something that is not audio (a captive portal's login page, a
 * reverse proxy's error page, a JSON error, all served as 200) has that body
 * written under the track's `MediaId`. From then on every attempt at the track
 * reads the cached page instead of the network: the host's retry builds a fresh
 * URL, but the key is the id, so the fresh URL lands on the same entry. The
 * track stays unplayable after the network is fine again, until the evictor
 * gets round to it or someone clears the whole cache. Seen on a device against
 * a server that had been fixed: no stream request reached it at all until the
 * cache was cleared, and then the track played at once.
 *
 * Only parsing and decoding failures count. A network failure says nothing
 * about the cached bytes, and those bytes are what lets a track that was played
 * once play again offline, so throwing them away on a dropped connection would
 * trade a transient fault for a lasting one. Decoder *initialisation* and
 * capability errors are left alone for the same reason: they are about the
 * device, and the next attempt would fetch identical bytes into the same
 * failure.
 */
internal fun failureMeansBadBytes(errorCode: Int): Boolean = when (errorCode) {
  // What a non-audio body produces: no extractor recognises it at all.
  PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED,
  // Recognised by its first bytes and broken after them, which is what a
  // truncated or spliced body looks like.
  PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED,
  // Parsed, then undecodable part-way.
  PlaybackException.ERROR_CODE_DECODING_FAILED -> true
  else -> false
}
