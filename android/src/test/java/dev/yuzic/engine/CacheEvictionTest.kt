package dev.yuzic.engine

import androidx.media3.common.PlaybackException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CacheEvictionTest {
  @Test
  fun aBodyNoExtractorRecognisesIsEvicted() {
    // The captive-portal case: an HTML page served as the stream.
    assertTrue(failureMeansBadBytes(PlaybackException.ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED))
  }

  @Test
  fun aBrokenOrUndecodableBodyIsEvicted() {
    assertTrue(failureMeansBadBytes(PlaybackException.ERROR_CODE_PARSING_CONTAINER_MALFORMED))
    assertTrue(failureMeansBadBytes(PlaybackException.ERROR_CODE_DECODING_FAILED))
  }

  @Test
  fun aNetworkFailureKeepsTheCachedBytes() {
    // They are what lets a track played once play again offline.
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED))
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT))
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS))
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_IO_UNSPECIFIED))
  }

  @Test
  fun aDeviceThatCannotDecodeKeepsTheCachedBytes() {
    // The next attempt would fetch the same bytes into the same failure.
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_DECODER_INIT_FAILED))
    assertFalse(failureMeansBadBytes(PlaybackException.ERROR_CODE_DECODING_FORMAT_UNSUPPORTED))
  }
}
