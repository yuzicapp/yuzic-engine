# yuzic-engine

An audio playback engine for React Native, built around an audio graph rather
than a single player. Written for [yuzic](https://github.com/yuzicapp/yuzic), a
self-hosted music client, and usable on its own.

Apache-2.0. iOS and Android.

```ts
import { YuzicEngine } from 'yuzic-engine';

await YuzicEngine.setup({ progressIntervalMs: 1000 });
await YuzicEngine.setQueue(tracks, 0);
await YuzicEngine.setCrossfade({ durationSec: 8, mode: 'gapless-aware' });
await YuzicEngine.play();

const off = YuzicEngine.addListener(event => {
  if (event.type === 'progress') draw(event.progress);
});
```

## Why a graph

Two tracks have to be audible at once for a crossfade, and an equalizer has to
sit somewhere in the signal path. Neither is expressible against an API that
plays one URL at a time — you can fade a single output down and back up, but
the join is a hole rather than an overlap.

So the engine keeps **two voices**, each a player node feeding its own gain,
summed into a mixer, through an EQ, to the output. A crossfade is the window
where both are running and their gains are moving in opposite directions. A
gapless join is the same machinery with a zero-length fade. Everything else —
replay gain, speed, the equalizer — is a node in a graph that already exists.

The cost is that the unglamorous work is yours: audio sessions, interruptions,
route changes, decoding, caching, and the lock screen. Most of this repository
is that work, and
[`docs/architecture.md`](https://github.com/yuzicapp/yuzic-engine/blob/main/docs/architecture.md)
explains the ten decisions it rests on.

## What it does

**Queue, natively.** Set, append, insert, remove, move, clear; skip to next,
previous or an index; read it back. The queue lives in native code because
backgrounded JavaScript is suspended and the lock screen, the notification and
the car have to keep working anyway.

**Transport.** Play, pause, stop, seek, volume, speed (0.25×–4×), repeat
(off / one / all).

**Crossfade.** Configurable duration, with two modes: `gapless-aware` hard-cuts
where a track is marked as following the previous one, so a segued album is not
faded through its own joins; `always` fades everything. A user-initiated skip
always cuts, because a fade after a button press reads as lag.

**DSP.** A ten-band equalizer, bypassed entirely when flat, and replay gain with
album/track/auto modes and clipping protection.

**Sources.** Local files, and HTTP streaming with auth in query parameters or
headers. Mutual TLS can import a PKCS#12 identity in memory and presents the
same identity for ordinary server API requests and Media3/Core Audio streaming.
Remote audio is fetched through a byte source with an on-device LRU
cache keyed by media id — not by URL, because Subsonic and Jellyfin hand out
URLs carrying a token that rotates, and keying on those re-downloads the same
audio every session.

**Platform integration.** Background playback, lock-screen and notification
controls with artwork, CarPlay, Android Auto and Android Automotive browse
trees, audio focus, interruptions, route changes, becoming-noisy, and a sleep
timer that fades rather than cuts.

**Events.** State changes, track changes with the time actually listened,
progress, queue changes, and errors.

## Formats

Core Audio and Media3 between them cover MP3, AAC/M4A, ALAC, FLAC and WAV. Two
that they do not, and this engine decodes itself:

| | iOS | Android |
| --- | --- | --- |
| Ogg Vorbis | libvorbis, vendored | Media3 |
| Ogg Opus | libopus, vendored | Media3 |

iOS has no decoder for either — an `.ogg` or `.opus` cannot be opened by Core
Audio at all, so the failure is total rather than a quality loss. For a
self-hosted library stored in one of them that is the difference between working
and not, so libogg, libvorbis, libopus and libopusfile are vendored under
`ios/Vendor` (BSD-3, see NOTICE) and decoded through the same cache and ranged
requests as everything else. The decoder is chosen by reading the codec out of
the identification packet in the first Ogg page, not by file extension — a
stream URL does not have one.

## Platform state

Derived from the modules rather than remembered, because this section has been
wrong before by asserting a parity that had stopped being true hours earlier.

| | iOS | Android |
| --- | --- | --- |
| Playback, queue, transport | yes | yes |
| Crossfade | yes | yes |
| Equalizer, replay gain | yes | yes |
| Lock screen, car | yes | yes |
| Disk cache | yes | yes |
| Mutual TLS for API and audio | yes | yes |
| Cache management | yes | all but `configureCache` |

Android has always cached — `SimpleCache` sits in the data source chain, keyed
by the host's `MediaId` so a rotating Subsonic or Jellyfin token does not
re-download the same album. It was the *management* API that was missing, and
only `configureCache` still is: Media3's evictor takes its limit as a
constructor argument, so changing it needs either a second `SimpleCache` over
one directory (documented as corrupting the index) or releasing the live one
mid-track.

A method a platform lacks rejects with its own name and that platform's —
`setSpeed() is not implemented on android` — rather than arriving as
`undefined` and failing as a type error somewhere unrelated.

## Using it

An Expo module. Add it to `plugins` in `app.json` so its config plugin can run:
it declares background audio and the CarPlay scene, and without it the CarPlay
screen never appears and nothing logs to say why.

```json
{ "expo": { "plugins": ["yuzic-engine"] } }
```

Two things the plugin cannot do for you:

1. **The `com.apple.developer.carplay-audio` entitlement is granted by Apple per
   app**, on request. Until it is, none of the CarPlay support appears in a car.
   The plugin deliberately does not fabricate the entitlement, because that
   trades a clear message for a signing failure.
2. **If your project commits its `ios/` directory**, the plugin's Info.plist
   changes only land on a prebuild.

To try CarPlay without a car: Xcode's Simulator has **I/O → External Displays →
CarPlay**, which needs the entitlement the same way a head unit does.

On Android the car declarations are in the library's own manifest, so they
merge into your app without a prebuild: the Android Auto key for a phone, and
for Android Automotive in the car both its own key and the opt-in on the media
service that puts the app in the car's media app. What the engine leaves to you
is `<uses-feature android:name="android.hardware.type.automotive"
android:required="true" />`, which Play expects on a build meant for cars and
which makes a phone build uninstallable on phones.

To try Android without a car: Android Auto's Desktop Head Unit needs a real
phone, and Play will not install Android Auto on an emulator. An Android
Automotive emulator image works: install the app and pick it from the media
app's source list.

## Building and testing

```sh
npm install
npm run typecheck    # both tsconfigs — see below
npm test             # the TypeScript side
swift test           # the iOS core: 390 tests, no Xcode project, no app
```

`ios/Core` is a SwiftPM target as well as part of the pod, which is what lets
the engine's logic be built and run on any Mac with no app around it. The
bridge in `ios/YuzicEngineModule.swift` is podspec-only and is therefore
compiled by an app build and nothing else — worth knowing before trusting a
green `swift test` on a change to it.

`npm run typecheck` runs `tsconfig.json` *and* `tsconfig.build.json`. The second
is the one `prepare` uses when this package is installed from git, and it once
diverged far enough that the package could not be installed at all while every
local check passed.

`Tools/mutate.py` breaks one real behaviour at a time and checks that a test
notices. It exists because a test suite can be green and vacuous — one of these
was named for the crossfade and could not observe the crossfade curve.

`Tools/parity.py` compares the two native modules by **signature**, not by
name, and exits non-zero when they disagree:

```sh
python3 Tools/parity.py
```

A name-only diff — which is what this repository used to recommend — is silent
about the failure that actually happened: a `setBrowseTree` present on both
platforms whose arity differed, arriving at a call site as a type error
somewhere unrelated. This resolves each `Record` parameter to its *field shape*
before comparing, so the platforms are free to name the same wire type
differently (`BrowseNodeRecord` and `FlatBrowseNodeRecord` are the same six
fields) without that reading as a mismatch. Deliberate gaps are declared in
`KNOWN_GAPS` with the reason; a gap that gets closed is reported as a stale
entry, so the list cannot quietly become a record of what used to be true.

## Contributing

See
[CONTRIBUTING.md](https://github.com/yuzicapp/yuzic-engine/blob/main/CONTRIBUTING.md),
which covers the one rule about where code may come from.
