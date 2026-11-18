package dev.yuzic.engine;

import static org.junit.Assert.*;
import java.io.DataInputStream;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import org.junit.Assume;
import org.junit.Test;

public class NativeAlacDecoderTest {
  private DataInputStream resource(String name) {
    return new DataInputStream(getClass().getResourceAsStream("/alac/" + name));
  }

  @Test public void readsTheMedia3CookieAndRejectsUnsupportedConfigurations() throws Exception {
    byte[] cookie = new byte[24];
    try (DataInputStream input = resource("16bit-2ch.packets")) { input.readFully(cookie); }
    NativeAlacDecoder.Config config = new NativeAlacDecoder.Config(cookie);
    assertEquals(2, config.channels);
    assertEquals(44100, config.sampleRate);
    assertEquals(4096 * 2 * 2, config.maxOutputBytes);
    assertThrows(IllegalArgumentException.class, () -> new NativeAlacDecoder.Config(new byte[23]));
    for (int index : new int[] {0, 4, 5, 8, 9, 20}) {
      byte[] bad = cookie.clone();
      bad[index] = (byte) 255;
      assertThrows(IllegalArgumentException.class, () -> new NativeAlacDecoder.Config(bad));
    }
  }

  @Test public void jniDecodesSeeksAndClosesWithoutChangingSamples() throws Exception {
    // Regular Android JVM tests do not load device .so files. This same test is
    // also run on the host with the native library built for its architecture.
    Assume.assumeTrue("Run with the host JNI library on java.library.path", NativeAlacDecoder.AVAILABLE);
    for (String name : new String[] {"16bit-1ch", "16bit-2ch", "24bit-1ch", "24bit-2ch"}) {
      byte[] cookie = new byte[24];
      ArrayList<byte[]> packets = new ArrayList<>();
      try (DataInputStream input = resource(name + ".packets")) {
        input.readFully(cookie);
        for (int size; (size = input.readInt()) != -1;) {
          byte[] packet = new byte[size];
          input.readFully(packet);
          packets.add(packet);
        }
      }
      byte[] reference;
      try (DataInputStream input = resource(name + ".pcm")) { reference = input.readAllBytes(); }
      NativeAlacDecoder decoder = new NativeAlacDecoder(new NativeAlacDecoder.Config(cookie));
      try {
        ByteBuffer pcm = ByteBuffer.allocateDirect(decoder.config.maxOutputBytes);
        int offset = 0;
        ArrayList<byte[]> decoded = new ArrayList<>();
        for (byte[] packet : packets) {
          // Exercise nonzero input positions: JNI must receive remaining bytes.
          ByteBuffer input = ByteBuffer.allocateDirect(packet.length + 7);
          input.position(7); input.put(packet); input.flip(); input.position(7);
          int size = decoder.decode(input, pcm);
          byte[] output = new byte[size];
          pcm.position(0); pcm.get(output); pcm.clear();
          assertArrayEquals(Arrays.copyOfRange(reference, offset, offset + size), output);
          offset += size;
          decoded.add(output);
        }
        assertEquals(reference.length, offset);
        for (int index : new int[] {packets.size()-1, 0}) {
          decoder.flush();
          ByteBuffer input = ByteBuffer.allocateDirect(packets.get(index).length);
          input.put(packets.get(index)); input.flip();
          int size = decoder.decode(input, pcm);
          byte[] output = new byte[size]; pcm.position(0); pcm.get(output); pcm.clear();
          assertArrayEquals(decoded.get(index), output);
        }
        assertThrows(IllegalArgumentException.class,
            () -> decoder.decode(ByteBuffer.wrap(packets.get(0)), pcm));
      } finally { decoder.close(); }
      decoder.close();
      assertThrows(IllegalStateException.class,
          () -> decoder.decode(ByteBuffer.allocateDirect(8), ByteBuffer.allocateDirect(8)));
    }
  }
}
