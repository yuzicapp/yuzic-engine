package dev.yuzic.engine;

import android.os.Handler;
import android.util.Log;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MimeTypes;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.decoder.CryptoConfig;
import androidx.media3.decoder.DecoderException;
import androidx.media3.decoder.DecoderInputBuffer;
import androidx.media3.decoder.SimpleDecoder;
import androidx.media3.decoder.SimpleDecoderOutputBuffer;
import androidx.media3.exoplayer.audio.AudioRendererEventListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DecoderAudioRenderer;
import java.nio.ByteBuffer;

/** Preferred ALAC decoder for MP4, sharing each voice's ordinary PCM sink and processors. */
@UnstableApi
public final class AlacAudioRenderer extends DecoderAudioRenderer<AlacAudioRenderer.Decoder> {
  public AlacAudioRenderer(Handler handler, AudioRendererEventListener listener, AudioSink sink) {
    super(handler, listener, sink);
  }

  @Override public String getName() { return "YuzicAlacAudioRenderer"; }

  @Override protected int supportsFormatInternal(Format format) {
    if (!MimeTypes.AUDIO_ALAC.equals(format.sampleMimeType)) return C.FORMAT_UNSUPPORTED_TYPE;
    if (!NativeAlacDecoder.AVAILABLE) return C.FORMAT_UNSUPPORTED_SUBTYPE;
    if (format.cryptoType != C.CRYPTO_TYPE_NONE) return C.FORMAT_UNSUPPORTED_DRM;
    try {
      NativeAlacDecoder.Config decoder = config(format);
      return sinkSupportsFormat(outputFormat(decoder)) ? C.FORMAT_HANDLED : C.FORMAT_UNSUPPORTED_SUBTYPE;
    } catch (IllegalArgumentException error) {
      return C.FORMAT_UNSUPPORTED_SUBTYPE;
    }
  }

  @Override protected Decoder createDecoder(Format format, CryptoConfig cryptoConfig) throws Failure {
    try {
      Decoder decoder = new Decoder(new NativeAlacDecoder(config(format)), format.maxInputSize);
      Log.i("YuzicAlac", "Using native FFmpeg ALAC decoder: "
          + decoder.packets.config.sampleRate + " Hz, " + decoder.packets.config.channels + " channels");
      return decoder;
    } catch (IllegalArgumentException error) {
      throw new Failure(error);
    }
  }

  @Override protected Format getOutputFormat(Decoder decoder) { return outputFormat(decoder.packets.config); }

  private static NativeAlacDecoder.Config config(Format format) {
    if (format.initializationData.size() != 1) {
      throw new IllegalArgumentException("Missing ALAC configuration");
    }
    return new NativeAlacDecoder.Config(format.initializationData.get(0));
  }

  private static Format outputFormat(NativeAlacDecoder.Config decoder) {
    return new Format.Builder().setSampleMimeType(MimeTypes.AUDIO_RAW)
        .setChannelCount(decoder.channels).setSampleRate(decoder.sampleRate)
        .setPcmEncoding(C.ENCODING_PCM_16BIT).build();
  }

  static final class Failure extends DecoderException {
    Failure(Throwable cause) { super("ALAC decoding failed", cause); }
  }

  static final class Decoder extends SimpleDecoder<DecoderInputBuffer, SimpleDecoderOutputBuffer, Failure> {
    final NativeAlacDecoder packets;

    Decoder(NativeAlacDecoder packets, int maxInputSize) {
      super(new DecoderInputBuffer[8], new SimpleDecoderOutputBuffer[8]);
      this.packets = packets;
      setInitialInputBufferSize(maxInputSize == Format.NO_VALUE ? 16384 : maxInputSize);
    }

    @Override public String getName() { return "yuzic-alac"; }
    @Override protected DecoderInputBuffer createInputBuffer() {
      return new DecoderInputBuffer(DecoderInputBuffer.BUFFER_REPLACEMENT_MODE_DIRECT);
    }
    @Override protected SimpleDecoderOutputBuffer createOutputBuffer() {
      return new SimpleDecoderOutputBuffer(this::releaseOutputBuffer);
    }
    @Override protected Failure createUnexpectedDecodeException(Throwable error) { return new Failure(error); }

    @Override protected Failure decode(DecoderInputBuffer input, SimpleDecoderOutputBuffer output, boolean reset) {
      try {
        if (reset) packets.flush();
        ByteBuffer pcm = output.init(input.timeUs, packets.config.maxOutputBytes);
        int size = packets.decode(input.data, pcm);
        pcm.position(0);
        pcm.limit(size);
        return null;
      } catch (RuntimeException error) {
        return new Failure(error);
      }
    }

    @Override public void release() {
      // SimpleDecoder joins the decode thread before its native state is freed.
      super.release();
      packets.close();
    }
  }
}
