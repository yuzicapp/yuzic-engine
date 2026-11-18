# Android ALAC decoding

Media3 extracts ALAC packets from MP4/M4A, but Android does not require an ALAC
MediaCodec decoder. `AlacAudioRenderer` is registered before the platform audio
renderer and handles ALAC only. A device advertising ALAC support can still
fail inside `MediaCodecAudioRenderer`; a renderer registered as a fallback
never gets selected in that case. Both voices use their existing sink, so EQ, replay
gain, crossfade, HTTP authentication, ranged requests and caching still apply.

Successful initialization logs `YuzicAlac: Using native FFmpeg ALAC decoder`
with sample rate and channel count. A native library load failure is logged
to stderr/logcat instead of silently dropping the software decoder.

`src/main/cpp` builds FFmpeg **9.0.2**, enabling only the ALAC decoder, libavcodec
and libavutil. No FFmpeg network transport, demuxer, encoder, CLI, GPL or nonfree
components are enabled. CMake fetches the unmodified official source archive,
checks its SHA-256, and builds it separately for each requested Android ABI.
The first native build needs internet access plus a POSIX shell and `make`.
The downloaded source and native objects are cached in the native build directory.
NDK and CMake are selected by the host app; the module requests CMake 3.22.1.
The JNI library uses static libc++ and 16 KiB ELF segment alignment.

For an existing/offline source tree, pass this host Gradle property:

```
-PyuzicEngineFfmpegSource=/absolute/path/to/ffmpeg-9.0.2
```

Keep an override tree unconfigured: FFmpeg is configured out of tree, and will
refuse a source tree containing an in-tree `config.h`. Local source changes are
compiled as supplied; omitting the property always selects the pinned release.

The 24-byte config from Media3 is wrapped in an ALAC atom for FFmpeg. Each
Media3 decoder owns its own native context. Input packets are padded as required
by libavcodec, flush clears codec state on a seek, and release joins the decoder
thread before freeing its native context. Bounds and decode errors reach the
ordinary playback error path. Mono through eight channels and 16/20/24/32-bit
sources decode to interleaved PCM16, the format required by the graph's existing
processors. Higher-depth input is reduced to 16 bits at this output boundary.

Gonic 0.23.0 can report an ALAC M4A as `audio/mp4a-latm`. For the reported file,
a `format=raw` download had the same SHA-256 as the original M4A. This is a
misleading MIME label, not LATM-wrapped ALAC. Media3 sniffs the MP4 container and
selects this renderer from the extracted `audio/alac` sample format. Actual AAC
and LATM playback continue through Media3's platform renderer.

## Verification

The native core builds and tests without an Android SDK:

```
cmake -S android/src/main/cpp -B /tmp/yuzic-alac -DCMAKE_BUILD_TYPE=Release
cmake --build /tmp/yuzic-alac --parallel 2
ctest --test-dir /tmp/yuzic-alac --output-on-failure
python3 Tools/verify_android_alac.py /path/to/test.m4a --build-dir /tmp/yuzic-alac
```

Pass `-DYUZIC_FFMPEG_SOURCE=/path/to/ffmpeg-9.0.2` to CMake and
`--ffmpeg-source /path/to/ffmpeg-9.0.2` to the Python probe to use local sources.
The probe compares every decoded PCM byte with the system FFmpeg CLI; it needs
`ffmpeg` and `ffprobe`. Test fixtures are generated tones, not library music.
Native tests check exact PCM, short final packets, reverse seeks, separate
voices, malformed packets and configuration, and 20/32-bit signed conversion.
`NativeAlacDecoderTest` additionally exercises JNI direct buffers and lifecycle
when a host-built `libyuzic_alac` is on `java.library.path`.

For AddressSanitizer and UndefinedBehaviorSanitizer, configure a separate build
with `-DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'`,
`-DCMAKE_CXX_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'` and
`-DCMAKE_EXE_LINKER_FLAGS='-fsanitize=address,undefined'`. These flags also reach
FFmpeg's configure/build, rather than instrumenting only the wrapper.

Android compilation and JVM tests run through the host app's Gradle wrapper.
A handset/emulator is still needed to verify AudioTrack output and HTTP playback.

## Source and notices

FFmpeg is Copyright (c) 2000-2026 the FFmpeg developers, LGPL-2.1-or-later.
The exact source is https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz
(SHA-256 `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`).
The build and JNI wrapper sources are in `src/main/cpp`; no FFmpeg source is
modified. License texts and the source pointer ship as APK assets under
`yuzic-alac/`. Do not remove them or prohibit replacement of `libyuzic_alac.so`
with a rebuilt version. To rebuild that library, use this CMake project with
the Android NDK toolchain, matching `ANDROID_ABI`, `ANDROID_PLATFORM=android-24`
and `ANDROID_STL=c++_static`; `CMakeLists.txt` records the full FFmpeg configuration.
