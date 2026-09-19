// swift-tools-version: 5.9
import PackageDescription

/**
 A SwiftPM package over the *core* of the iOS side — the model, the queue rules
 and the graph. Not the Expo module, which needs `ExpoModulesCore` and a React
 Native toolchain to build at all.

 The point is that the logic worth testing can be compiled and run by
 `swift test` on any Mac, with no Xcode project, no pod install and no app. The
 bridge stays in `ios/YuzicEngineModule.swift` and converts at the edge; the
 podspec picks up both directories, so this package existing costs the real
 build nothing.

 Written after both platforms' code had been reviewed but never compiled, which
 is a state worth not staying in.
 */
let package = Package(
  name: "YuzicEngineCore",
  platforms: [.iOS(.v15), .macOS(.v12)],
  products: [
    .library(name: "YuzicEngineCore", targets: ["YuzicEngineCore"]),
  ],
  targets: [
    /**
     Xiph's decoders, vendored. One target per library.

     iOS has no Vorbis or Opus decoder, so an `.ogg` or `.opus` cannot be
     opened by Core Audio at all — the failure is total rather than a quality
     loss.

     libFLAC is here for the opposite reason: Core Audio *does* decode FLAC,
     just not in a way this engine can stream. Its parser reads from the start
     of the file to the seek point — measured at 177% of the file to play from
     90% in — and it seeks backwards whenever it likes, which a forward-only
     transcoded stream cannot serve. See docs/architecture.md §10.

     Separate targets rather than one, because libvorbis and libopus both
     define `mdct_lookup` in a header called `mdct.h`. A single target shares
     one header search path across every source in it, which puts both in
     scope and fails to compile. Keeping each library's internal headers to
     itself is the only arrangement that works; the podspec mirrors it with a
     subspec each.

     They are SwiftPM targets at all so `swift test` can reach the decoders. A
     decoder only the app build compiles is one no test can exercise.
     */
    .target(
      name: "COgg",
      path: "ios/Vendor/ogg",
      sources: ["src"],
      publicHeadersPath: "include"
    ),
    .target(
      name: "CVorbis",
      dependencies: ["COgg"],
      path: "ios/Vendor/vorbis",
      sources: ["lib"],
      publicHeadersPath: "include",
      // libvorbis reaches its own `modes/` and `books/` relative to `lib`.
      cSettings: [.headerSearchPath("lib")]
    ),
    .target(
      name: "CFLAC",
      path: "ios/Vendor/flac",
      // `deduplication/` holds fragments that `lpc.c`, `fixed.c` and
      // `bitreader.c` **textually `#include`** inside a function body — they
      // are not translation units and have no standalone declarations.
      // SwiftPM compiles every .c under `sources` by default and fails on them
      // with "unknown type name 'lag'", which reads like a broken vendor drop
      // rather than what it is.
      exclude: ["src/deduplication"],
      sources: ["src"],
      publicHeadersPath: "include",
      cSettings: [
        // libFLAC's sources reach their internal headers as
        // "private/bitreader.h" and "protected/stream_decoder.h", relative to
        // the directory `src/libFLAC` had upstream — which is `src` here.
        .headerSearchPath("src"),
        // And its public ones as <FLAC/format.h>.
        .headerSearchPath("include"),
        // And the forced config by bare name, found through this target's own
        // directory — the same way opus reaches its public headers below.
        //
        // It was spelled as a path from the package root, which `swift build`
        // resolves and `xcodebuild` does not: the two run from different
        // working directories, so an iOS-simulator build died with
        // "'ios/Vendor/flac/yuzic-flac-config.h' file not found" while the
        // macOS test build was fine. That is why nothing compiled the
        // `#if os(iOS)` branches — CFLAC failed first and the build never
        // reached them. `.headerSearchPath` is target-relative and SwiftPM
        // makes it absolute per driver, so a bare `-include` finds the header
        // whichever one is building.
        .headerSearchPath("."),
        // Force-included rather than reached through HAVE_CONFIG_H, for the
        // reason spelled out in `yuzic-flac-config.h` and already learned from
        // libopus: that flag applies to every file in the target, React
        // Native's C++ included, where it changes unrelated headers' branches.
        .unsafeFlags(["-include", "yuzic-flac-config.h"]),
      ]
    ),
    .target(
      name: "COpus",
      dependencies: ["COgg"],
      path: "ios/Vendor/opus",
      sources: ["celt", "silk", "src", "opusfile"],
      publicHeadersPath: "include",
      cSettings: [
        // opus and opusfile include their own public headers by bare name —
        // "opus_types.h", not <opus/opus_types.h> as a consumer would. That is
        // also why opusfile lives in this target rather than its own: a
        // separate module compiles fine but cannot be *imported*, because
        // these search paths apply to building the target and not to whoever
        // imports it, and `opusfile.h` reaches for `opus_multistream.h`.
        .headerSearchPath("include"),
        .headerSearchPath("."),
        .headerSearchPath("celt"),
        .headerSearchPath("silk"),
        .headerSearchPath("silk/float"),
        .headerSearchPath("src"),
        .headerSearchPath("opusfile"),
        // opus's own defines, spelled out rather than reached through
        // HAVE_CONFIG_H — that flag is generic autotools vocabulary, and in
        // the pod it applies to every file in the target including React
        // Native's C++, where it made unrelated headers take a different
        // branch. Kept identical here so both builds compile the same library.
        .define("OPUS_BUILD", to: "1"),
        .define("VAR_ARRAYS", to: "1"),
        .define("HAVE_LRINT", to: "1"),
        .define("HAVE_LRINTF", to: "1"),
        // opusfile fetches nothing itself: `ByteSource` supplies the bytes,
        // with the cache and ranged requests the rest of the engine uses.
        .define("OP_DISABLE_HTTP"),
      ]
    ),
    .target(name: "YuzicEngineCore", dependencies: ["COgg", "CVorbis", "COpus", "CFLAC"], path: "ios/Core"),
    .testTarget(name: "CoreTests", dependencies: ["YuzicEngineCore"], path: "Tests/CoreTests"),
  ]
)
