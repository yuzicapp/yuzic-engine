package dev.yuzic.engine;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** JNI owns one decoder per Media3 voice. Config parsing never calls native code. */
final class NativeAlacDecoder implements AutoCloseable {
  static final boolean AVAILABLE;
  static {
    boolean loaded;
    try { System.loadLibrary("yuzic_alac"); loaded = true; }
    catch (UnsatisfiedLinkError error) {
      loaded = false;
      // System.err also reaches logcat, and remains usable in plain JVM tests.
      System.err.println("YuzicAlac: native library could not be loaded: " + error);
    }
    AVAILABLE = loaded;
  }

  static final class Config {
    final byte[] cookie;
    final int channels;
    final int sampleRate;
    final int maxOutputBytes;

    Config(byte[] cookie) {
      if (cookie.length != 24) throw new IllegalArgumentException("Expected a 24-byte ALAC config");
      ByteBuffer data = ByteBuffer.wrap(cookie).order(ByteOrder.BIG_ENDIAN);
      int frames = data.getInt(0), depth = cookie[5] & 255;
      channels = cookie[9] & 255;
      sampleRate = data.getInt(20);
      if (frames < 1 || frames > 65536 || cookie[4] != 0 || channels < 1 || channels > 8
          || (depth != 16 && depth != 20 && depth != 24 && depth != 32)
          || (cookie[8] & 255) > 31 || sampleRate < 1 || sampleRate > 768000) {
        throw new IllegalArgumentException("Unsupported ALAC configuration");
      }
      this.cookie = cookie.clone();
      maxOutputBytes = frames * channels * 2;
    }
  }

  final Config config;
  private long handle;

  NativeAlacDecoder(Config config) {
    this.config = config;
    handle = create(config.cookie);
    if (handle == 0) throw new IllegalArgumentException("Cannot initialize ALAC decoder");
  }

  int decode(ByteBuffer input, ByteBuffer output) {
    if (handle == 0) throw new IllegalStateException("ALAC decoder is closed");
    return decode(handle, input, input.position(), input.remaining(), output, output.capacity());
  }

  void flush() {
    if (handle == 0) throw new IllegalStateException("ALAC decoder is closed");
    flush(handle);
  }

  @Override public void close() {
    if (handle != 0) { destroy(handle); handle = 0; }
  }

  private static native long create(byte[] config);
  private static native int decode(long handle, ByteBuffer input, int offset, int size,
                                   ByteBuffer output, int capacity);
  private static native void destroy(long handle);
  private static native void flush(long handle);
}
