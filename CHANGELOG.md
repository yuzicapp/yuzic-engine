# Changelog

All notable changes to yuzic-engine are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

Semver here is a promise about the **JavaScript API** — the methods on
`YuzicEngine`, the event vocabulary, and the exported types. Native
implementation detail may change in a patch release when the observable
behaviour does not.

## [1.1.0]

### Added

- **`clearBrowseTree()` in the JavaScript API.** Both native modules have had
  it; the facade never exposed it. Call it when the library stops being the
  listener's to show, at sign-out especially, because on Android it also
  deletes the copy below.

### Fixed

- **Android: a car could not play anything.** Media3 passes a controller's
  selection on only if the controller holds `COMMAND_SET_MEDIA_ITEM` and
  `COMMAND_PREPARE`, and the session never granted them, so every selection in
  Android Auto and Android Automotive was dropped before it reached the engine,
  with nothing logged. They are granted now, `onSetMediaItems` resolves the
  car's ids against the tree (a track chosen in an album queues the album from
  that track, as on iOS), and the tracks go into the engine's own queue.
- **Android: a car with the app closed had no library and no player.** A car
  starts the media service without starting the host's JavaScript, and the
  playback controller lived in the Expo module, which only exists with it. The
  controller is now `EngineCore`, owned by the service, and the module is a
  bridge to it: a car's selection plays, next and previous work, and tracks
  advance and crossfade with no JavaScript running. The last browse tree is
  kept across process death, encrypted with a key in the Android Keystore and
  excluded from backups, so a car arriving at a dead process still shows the
  library.
- **Android: a host that attached while a car was playing showed a play
  button.** State is sent on a change, and the controller now outlives any one
  host, so attaching sends the current state once.

## [1.0.17]

### Fixed

- **Android: a car that opened the app before it had a library never showed
  it.** 1.0.15 announced a new browse tree with `notifyChildrenChanged`, but
  Media3's default `onSubscribe` first asks `onGetItem` for the parent and
  refuses the subscription unless it is a browsable item. Before the host set
  a tree, `onGetItem("root")` returned an error, so the car was never
  subscribed and the announcement reached nobody. The root is now answered
  with the same empty stand-in `onGetLibraryRoot` serves. Checked on an
  Android Automotive emulator: a tree set with the car's media app open on the
  empty library now appears within a second; on 1.0.16 it never did.

No JavaScript API change.

## [1.0.16]

### Fixed

- **iOS: a track picked in CarPlay showed the previous one while it
  opened.** A car selection is `setQueue` and `play`, and nothing was
  published until the new track's reader was open, so for about two seconds
  CarPlay and the lock screen showed the track before, paused, over the new
  one's audio starting. The ordinary advance had the same gap when nothing was
  preloaded, with the finished track's clock running on past its end. Both now
  publish the new track at once, from the top with the host's length.
- **iOS: a skip was published with the old track's position and length.** The
  outgoing reader and playback stayed attached until the new track began. They
  are dropped before the lock screen is told.
- **iOS: a callback from a playback that was already gone could report
  playing.** Each playback callback checks it belongs to the current
  playback with `===`, which is true when both are nil, so a first-buffer
  callback from a released track set `.playing` while the next track was
  still opening, with nothing loaded and the audio graph stopped. Two nils no
  longer match.
- **iOS: buffering was drawn as paused.** `playbackState` is now `.playing`
  while buffering, with the rate at zero, so the car shows pause rather than a
  play button that would open the track again.

No JavaScript API change.

## [1.0.15]

### Fixed

- **Android Automotive: the app was missing from the car's media app.** The
  car's launcher treats an app with its own launcher activity, which every
  host has, as an ordinary app unless its media service opts in with
  `androidx.car.app.launchable`. Without it the launcher logs `No opt-in info
  found` and `Skipping MBS ... non media template app`, at debug level only.
  The service now opts in, and the library manifest also declares
  `com.android.automotive` beside the Android Auto key, as Google's Automotive
  checklist asks. Both merge into the host without a prebuild. It still does
  not require `android.hardware.type.automotive`, because that would stop a
  phone build installing on phones.
- **Android: a car that opened the app before the host set a browse tree
  showed an error.** The empty stand-in root was served, but asking for its
  children returned `RESULT_ERROR_BAD_VALUE`, which Android Automotive shows as
  "isn't working right now". It is now an empty list. The stand-in also had a
  different id (`yuzic:root`) from the real root (`root`), so a car that
  connected early stayed subscribed to an id the tree never contained. Both
  are `root` now, as on iOS.
- **Android: a browse tree set after the car connected did not appear** until
  the driver left the app and came back. `setBrowseTree` and
  `clearBrowseTree` now tell connected cars the root's children changed.

No JavaScript API change.

## [1.0.14]

### Fixed

- **Android: a track that once received a non-audio response stayed
  unplayable after the server recovered.** Every stream goes through the disk
  cache, keyed on the track, and the cache kept whatever body came back, so a
  captive portal's login page or a proxy's error page served as 200 was stored
  as that track's audio. Retrying built a fresh URL onto the same key and read
  the stored page without a request. A parsing or decoding failure now evicts
  the failed track's cached bytes before the error is reported, so the host's
  retry reaches the network. Network failures leave the cache alone, since the
  cached bytes are what makes offline replay work. No JavaScript API change.
  iOS is not affected; see §12 of `docs/architecture.md`.

## [1.0.13]

### Fixed

- **Tracks cut out part-way through and the player moved on as though they had
  finished.** Two independent faults with one symptom, and neither threw
  anything: this engine reports a finished track when a read comes back empty,
  so anything that empties a read early is indistinguishable from an ending.

  *The disk cache was keyed on the track.* A `MediaId` names a track, but what
  the cache holds is a byte stream, and a track has as many of those as the
  server has ways to send it — quality being the obvious one, a server-side
  transcoder change and a library rescan that rewrites tags being the two that
  keep the id stable while every byte after the tag moves. Ranges filled at one
  length survived a write at another, and reads asked for a range without
  saying at what length, so windows from one stream were decoded as another.
  The cache is keyed on the stream now. Entries written before this are deleted
  at first launch rather than adopted: a pre-fix entry records whichever stream
  wrote last against ranges that may have come from several, so adopting one
  carries the fault through the upgrade into exactly the tracks that were
  already breaking. It costs one refetch.

  *And the reader stopped at a guess.* `kExtAudioFileProperty_FileLengthFrames`
  is a frame count where the container carries a packet table and an
  extrapolation from the opening bitrate where it does not. Every read was
  clamped to it, so a VBR MP3 with no Xing header and a dense opening ran out
  of music before it ran out of file. The clamp is there to keep encoder
  padding from being decoded as trailing silence, which looked like a reason it
  could not be touched — but a container that can state its priming and
  remainder is the same set whose length is counted, so the clamp now applies
  exactly where it always did useful work and nowhere else. Gapless playback is
  byte-for-byte unchanged.

- **Seeking past the guessed length ended the track.** The same number bounded
  seeks, so dragging to 2:50 of a track the parser had guessed was 2:40 long
  landed at 2:40 and finished it.

- **A truncated track no longer advances silently on either platform.** iOS
  already refused to advance when playback ended short of the host's declared
  duration, but excluded the ranged transport on the grounds that its end
  "really is the end" — true of the bytes, and irrelevant to a reader that
  stopped before reaching them. It now asks the reader for a second opinion
  instead. Android had no such check at all; it re-prepares at the second
  reached, up to three times, before reporting the failure in the same words
  iOS uses.

### Changed

- **iOS sources compile for the simulator again.** `CFLAC` force-included its
  config through a path relative to the package root, which `swift build`
  resolves and `xcodebuild` does not, so an iOS-destination build failed on the
  first target in the graph and never reached the rest. Because `swift test`
  builds for the host, that left every `#if os(iOS)` branch — the audio-session
  interruption, route-change and media-services-reset handlers among them —
  compiled by nothing. No API change; it is a build-configuration fix recorded
  here because of what it was hiding.

## [1.0.12]

### Added

- **iOS: the engine now says when it has run out of audio.** Every playback
  fault handled so far threw something. A range request that is merely slow —
  up to the eight-second read timeout — does not: it returns, late, having
  succeeded. So the retry ladder never ran, `onReadStalled` never fired, and
  nothing was counted or logged, while the two seconds of scheduled PCM
  drained, the node rendered silence and the engine went on reporting
  `playing`. That is the dropout still reported over the network after every
  other fix, on WiFi as well as cellular.

  `TrackPlayback` now raises an underrun from the buffer completion that takes
  the scheduled depth to zero with the track neither finished nor stopped. The
  engine counts and logs every one (`[yuzic-engine] audio underran …`, with the
  position, the track and the running count, and the length of the gap when it
  ends) and shows `buffering` for any that outlasts a quarter of a second —
  short droughts that the decode thread serves immediately are real but
  inaudible, and drawing them would flash a spinner over music that never
  stopped. The ordinary drain at the end of a track and the flush a stop fires
  both reach zero depth legitimately and are excluded.

  No JavaScript API change: the underrun surfaces through the existing
  `buffering` state, so hosts need no update and the platforms stay at parity.

### Fixed

- **iOS cut out over the network because nothing fetched ahead.** The cushion
  between a listener and their connection was two seconds of decoded PCM, and
  that was all of it: `CachedByteSource` asked the network for a window only
  once a read had arrived wanting bytes it did not have, and `TrackPlayback`
  stops decoding once it is two seconds ahead, so nothing ever ran in front of
  the decoder. A 256KB window is about two seconds of FLAC — a round trip due
  every two seconds of playback, with two seconds of slack to cover it. Fine at
  the 273ms measured against a real server; no margin at all for a phone at the
  edge of a room. Reported on WiFi as well as cellular, and never on Android,
  where Media3 holds tens of seconds.

  `CachedByteSource` now reads ahead on its own queue, keeping thirty seconds
  of bytes in front of wherever the decoder has reached. A window at a time, so
  a seek lands between iterations rather than waiting out a request nobody
  wants; serialised with the decoder's own reads, because `HTTPByteFetcher`
  holds one in-flight task and a cancel has to reach the right one; sized by
  converting the duration through the file's own average bitrate, so a podcast
  gets seconds rather than the whole episode, and clamped to 8MB so a 96/24
  track cannot pull most of a file the listener may skip; written through to
  the disk cache like any other window. Memory is unchanged — `storage` was
  always allocated to the whole declared length, so early bytes occupy space
  that was reserved anyway.

  Two paths deliberately keep the old behaviour, because read-ahead needs a
  duration to size itself: a **downloaded track**, read from disk where a
  cushion buys nothing, and a stream whose host never said how long it is.
  Both fetch on demand exactly as before, and nothing about offline playback
  changes.

- **iOS: the buffer was half a second only at CD rate.** `bufferFrames` was a
  frame count, 22,050, while `read` returns *source* frames at the file's own
  rate — so the four buffers were 2s at 44.1kHz, 0.92s at 96kHz and 0.46s at
  192kHz. The files with the largest windows to fetch had the least slack to
  fetch them in. It is a duration now, converted per reader.

## [1.0.11]

### Fixed

- **iOS froze at the end of songs.** The automatic advance opened the next
  track's reader inline on the main thread — a length probe and a header
  parse, each a network round trip — so the interface, the lock screen, the
  car and every event to the host stalled for the length of the fetch. It also
  ignored the reader the preload had already opened. The advance, and `play()`
  on a queue with nothing loaded (which a CarPlay selection calls on the main
  thread), now open off it and use the preload when it matches. A pause
  pressed while a track opens is kept, and a queue replaced mid-open no longer
  starts the old track.
- **iOS: a skip inside the crossfade window could land on the wrong track.**
  The ticker kept running over the cut track while the skip opened, and began
  a fade into the track after the one asked for, superseding the skip.
- **iOS: internet radio did not play.** The length probe waited for the whole
  response body, which from a station never ends; it now returns on the
  headers, which also stops it downloading a whole transcode to learn there is
  no length. Tracks marked `continuous` are read by a new stream parser
  instead of the file parser, which waited for the end of the broadcast before
  opening and then stopped at what had arrived. Stations reconnect after a
  dropped connection, and a paused station stops buffering. MP3 and ADTS AAC;
  Ogg stations take the existing path. See docs/architecture.md §10.
- **iOS broke after another app took the audio.** An interruption — a call,
  Siri, an alarm, or an app holding a non-mixable session such as a remote
  desktop or a video — stops the audio engine and discards its buffers.
  `play()` afterwards resumed a player node on that stopped engine, which
  raises rather than failing, and only an interruption ending with
  `.shouldResume` re-activated the session. A route or format change during an
  interruption tried to start the engine into the inactive session, dropped
  the playback and reported a failure, so the next play restarted the song and
  re-opened its stream. Now every path that starts audio (play from the app,
  lock screen, AirPods or car; seek; skip; the automatic advance) reclaims the
  session and graph first, and a torn-down track is rebuilt at its position
  over the same reader, with no re-open and no repeated track change. If
  another app still holds the audio, the engine stays paused with the position
  kept, rather than reporting a playback failure. The module's transport and
  queue functions now run on the main queue, where the engine's notification
  handlers already run.

## [1.0.10]

### Fixed

- **Android started playing every queue it was given.** `setQueue` loaded the
  active track with `play = true`, so a queue the host meant to leave paused —
  one restored on a cold launch, or reloaded by toggling shuffle while paused —
  began sounding with nothing pressed. The contract says `setQueue` does not
  start playback, and iOS already kept it. Android now loads without playing;
  a host that wants sound calls `play`, which the serial async-function queue
  delivers after the load. Nothing is paused either, so a `play` already given
  is kept. Android Auto selections are unaffected: they never reach `setQueue`.

## [1.0.9]

### Fixed

- **1.0.6, 1.0.7 and 1.0.8 do not compile for iOS.** `setup()` assigned
  `reconfigureAudioSession` through `self.engine` before the block that
  creates the engine, so the optional was never unwrapped and the module
  failed to build in any host app. Written as `engine?.` it would have
  compiled and been worse: on the first `setup()` there is no engine yet, so
  the hook would install nothing, and a media services reset would leave a
  player that cannot make sound — the fault 1.0.6 was released to fix. The
  hook is now installed after the engine exists, on every `setup()`.

  CI did not catch it because `swift test` compiles only `ios/Core` through
  `Package.swift`; the module file is compiled by a host app's build, and no
  check runs one for iOS.

## [1.0.8]

### Fixed

- On Android, **`setup()` resolved before the engine existed**, so the first
  commands the host sent went nowhere. `configureAudioSession` starts the
  service by binding a `MediaController`, and `buildAsync` returns at once —
  the service is created later, in `PlaybackService.onCreate`, which is where
  the `AudioGraph` comes from. Nothing waited for that.

  The host reads `setup` resolving as "ready" and releases every command
  queued behind it. Those reached `PlaybackService.graph?.` and were
  optional-chained into silence, and `startObserving` had returned early for
  the same reason, so no state or progress events flowed either. The result
  is a player that looks entirely healthy and does nothing — which is why
  restarting appears to fix it.

  `setup` now waits for the controller, bounded, on Expo's module queue rather
  than the main thread. With readiness meaning what it claims, the swallow
  below it becomes a throw: `onPlayer`, `setRepeatMode`, `setSpeed` and
  `clearQueue` raise `EngineNotSetUpException` — the same error iOS raises
  from `requireEngine`, worded identically — instead of doing nothing. Getters
  keep their fallbacks, which is the split iOS makes too.

  Verified on an emulator: a cold launch of a standalone build binds
  `PlaybackService`, runs JS, and raises no exception and no ANR.

## [1.0.7]

### Added

- **Cover art on the car's browse rows**, on iOS. `BrowseNode.artworkUri` had
  been carried across the bridge since the browse tree existed and was read by
  nothing: the CarPlay scene delegate built every row with a title, a subtitle
  and an accessory, and never an image. A library that shows covers everywhere
  else showed a column of blank squares in the car.

  `BrowseNode` gains `artworkHeaders`, alongside the `artworkUri` it already
  had, so a header-authenticated server — a Plex behind a Basic-auth proxy —
  answers with a cover rather than a 401. Headers rather than a signed URL
  because a browse tree is held for the life of the process and pushed to the
  car in advance; a credential baked into a URL outlives the session that
  issued it.

  `BrowseArtworkLoader` keeps what it has fetched and collapses concurrent asks
  for the same image into one request. CarPlay rebuilds a template on every
  push and every root change, so a list of fifty albums would otherwise be
  fifty requests per navigation, over a phone connection, while someone is
  driving.

  **Android carries the field but cannot use it.** A browse row's cover there
  goes through Media3, which takes a URI on `MediaMetadata` and fetches it
  itself with no hook for a request header, so thumbnails render for an
  ordinary server and not for a header-authenticated one. Declared in
  `Tools/parity.py` rather than left to be discovered.

### Changed

- `Tools/parity.py` compares record *fields* against a declared gap list as
  well as whole methods. The browse-artwork header is a difference in one field
  of one record on a method both platforms implement, which the method-level
  check could only report as an undifferentiated signature mismatch.

## [1.0.6]

Two ways a track could stop playing with nothing reported anywhere. Both are
iOS-only and both are native implementation detail: no change to the
JavaScript API, the event vocabulary or the exported types.

### Fixed

- On iOS, **a media services reset left the player dead but looking healthy**:
  a track sitting there showing paused, with transport controls that did
  nothing, until the app was force-quit. Most often after a Bluetooth handover
  or in a car.

  `mediaserverd` is a separate process and it restarts — under memory
  pressure, on a route handover. Apple's contract is that every audio object
  the process holds is invalid afterwards: the engine, the player nodes, the
  units, *and* the audio session category the host set once at setup.
  `AVAudioSession.mediaServicesWereResetNotification` was not observed, so none
  of it was put back. This was the fourth of the four ways iOS takes audio
  away, and the only one with no handling at all.

  `AudioGraph.rebuildAfterReset` now discards the graph and assembles a new
  one — a restart in place, which is all a route change needs, does not survive
  this — re-applying the listener's equalizer curve and playback speed from the
  settings rather than reading them off units that can no longer be asked. The
  engine reclaims the session first, keeps the open reader, and comes back
  paused at the position reached rather than resuming: a reset is a crash the
  audio system just had, and starting music out of whatever output iOS settles
  on afterwards is a guess.

- On iOS, a **transcoded stream that broke mid-track** could end the song
  silently and advance the queue. The listener heard a track stop part-way
  through — often around the same point in the same song — and the next one
  begin, over the network only, with no error and no buffering spinner.

  This is the last route by which a broken stream reached the listener as a
  skip, and it survived the earlier fixes because it does not look like a
  failure anywhere along its length. `TrackPlayback` treats a read that returns
  no frames and no error as the genuine end of the file, which is the only
  thing it can conclude from there — and a dead transcode produces exactly
  that: `StreamingByteSource` is marked finished by its producer,
  `totalBytes()` drops from the estimate to the bytes that arrived, and the
  next read comes back empty at what is now the end of the file by every
  measure the reader has. So `onEndOfTrack` fired rather than `onReadFailed`,
  and the retry ladder, the stall signal and the stream reconnection were all
  stepped over.

  An end of file that lands more than five seconds short of the length the host
  declared is no longer believed on the sequential transport. It is picked back
  up with `timeOffset` like any other lost stream, and reported as a failure if
  it cannot be. The ranged transport, live radio, and tracks whose length the
  host never stated are untouched.

## [1.0.3]

### Fixed

- On iOS, a track entered by **crossfade** could keep reporting `buffering`
  for its whole length while the audio played normally. The lock screen drew
  dimmed transport controls and a play glyph over playing music, with the
  progress bar advancing correctly beside them (yuzicapp/yuzic#212).

  `continueTransition` was the one path that starts a track without stating
  `state`. At the crossover it is usually `.playing` already, so the omission
  was invisible almost every time — but the outgoing track's last seconds are
  exactly where the fade begins *and* where a patchy connection stalls, and
  `onReadStalled` sets `.buffering`. That stall belongs to a playback the
  crossover then stops and discards, and nothing could ever clear it:
  `onReadResumed` fires on the outgoing playback and guards on it still being
  the active one, which it no longer is.

  `publishNowPlaying` maps `.buffering` to a published playback rate of `0`,
  which is what dims iOS's transport, while `positionSec` is set from the real
  playhead on the same dictionary and keeps the bar moving. The mapping was
  never wrong; which state reached it was. The same stale state also blocked
  `preloadNextIfIdle`, so the track after that one was never prefetched.

  Android derives its state from Media3's player rather than tracking it, so
  it was never affected.

## [1.0.2]

### Fixed

- On Android, the lock screen, notification and car display kept showing the
  **previous track** after a crossfade. `EnginePlayer` is a `ForwardingPlayer`
  around one of the two voices, and it overrode only the getters describing
  *where playback is* — position, duration, state — leaving everything
  describing *what is loaded* to the wrapped player. That was correct while
  `swapVoices()` was never called, and the comment above it said so. Giving
  Android engine-driven advances made the crossfade swap for the first time,
  so after an odd number of fades the wrapped player was the *idle* voice,
  still holding the track it last played. The metadata, timeline and media-item
  getters now follow the active voice like the rest.

  Verified on device across a crossfade: the session metadata moves with the
  audio, where before the outgoing track's title persisted indefinitely.

## [1.0.1]

Test and tooling only; no change to the engine's behaviour or its API.

### Fixed

- `StreamReconnectTests.testReconnectionGivesUpAfterItsBudget` failed about
  three runs in four. It injected a fixed number of read failures and asserted
  the engine had seen every one, which it had not: `onReadFailed` hops to the
  main queue and only then checks `activePlayback === playback`, so a failure
  arriving while a reconnection is swapping the playback out finds a different
  object and returns. That drop is correct — a failure belongs to the playback
  that raised it — so the test was wrong rather than the engine, and it now
  injects until the budget is actually spent.
- `Tools/mutate.py` had been unusable since the repository moved: `ROOT` was an
  absolute path to a checkout that no longer exists, so it died on its first
  file read. Derived from `__file__` now. With it running again, all nine
  mutations are caught and none survive.

## [1.0.0]

First published release. The engine has been in production use in
[yuzic](https://github.com/yuzicapp/yuzic) across iOS and Android before this
point; 1.0.0 marks the API being committed to rather than the code being new.

### Added

- **Two-voice audio graph** with crossfade (`gapless-aware` and `always`
  modes), where a gapless join is the same machinery with a zero-length fade.
- **Native queue** — set, append, insert, remove, move, clear, and skip to
  next/previous/index. It lives in native code because backgrounded JavaScript
  is suspended while the lock screen, notification and car still have to work.
- **Transport** — play, pause, stop, seek, volume, speed (0.25×–4×), and
  repeat (off / one / all).
- **DSP** — a ten-band equalizer, bypassed entirely when flat, and replay gain
  with album/track/auto modes and clipping protection.
- **Sources** — local files and HTTP streaming, with auth by query parameter
  or header, and an on-device LRU cache keyed by media id rather than URL
  (Subsonic and Jellyfin rotate tokens through the URL, so keying on it
  re-downloads the same audio every session).
- **Vorbis and Opus decoding** on iOS, which Core Audio cannot open at all,
  via vendored libogg/libvorbis/libopus.
- **Mutual TLS** on both platforms — import a PKCS#12 identity in memory and
  present it for both ordinary API requests and audio streaming. Both halves
  are required: a certificate on only the audio transport is unreachable,
  because the login that precedes every track is the request an mTLS server
  refuses first.
- **Platform integration** — background playback, lock-screen and notification
  controls with artwork, CarPlay and Android Auto browse trees, audio focus,
  interruptions, route changes, becoming-noisy, and a sleep timer that fades
  rather than cuts.
- **Events** — state changes, track changes carrying the time actually
  listened, progress, queue changes, and errors.

### Fixed

- **A seek no longer ends the stream it is seeking within.**
  `StreamingByteSource.cancel()` stopped its producer, which for the HTTP
  producer cancels the task and invalidates the session — irreversible — while
  `resume()` only cleared a flag and nothing restarted it. Since every seek
  cancels and resumes the source being decoded from, the first seek ended a
  transcoded stream for good and every read afterwards timed out: silence, and
  then a track that ended itself. The contract on `ByteSource` is exactly
  "unblocks any waiting read", so stopping the producer was always more than
  `cancel()` was asked to do; teardown belongs to `deinit`. Streamed audio
  only — a downloaded file never takes this path, and Android has no
  equivalent because Media3 owns that transport.
- **An estimated length is no longer mistaken for the end of a track.** For a
  sequential source `totalBytes()` is `duration × bitrate` until the stream
  ends, and `AudioFileReader` turned an empty read at that figure into a clean
  end-of-file, which the engine follows by advancing the queue. A new
  `isFinished` on `ByteSource` says whether a reported length is a fact or a
  guess, and only a fact may mean end-of-file. Ranged sources report `true` by
  default, so that transport is unchanged.

### Known gaps

- `configureCache` is **absent on Android**, deliberately rather than stubbed,
  so it rejects by name at the bridge. Media3's evictor takes its cache limit
  as a constructor argument, so honouring a new one means either a second
  `SimpleCache` over one directory (which corrupts the index) or releasing the
  live one mid-track. `Tools/parity.py` declares it; every other method agrees
  across the two platforms by signature and event vocabulary.

[Unreleased]: https://github.com/yuzicapp/yuzic-engine/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.17...v1.1.0
[1.0.17]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.16...v1.0.17
[1.0.16]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.15...v1.0.16
[1.0.15]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.14...v1.0.15
[1.0.14]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.13...v1.0.14
[1.0.13]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.12...v1.0.13
[1.0.12]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.11...v1.0.12
[1.0.11]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.10...v1.0.11
[1.0.2]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/yuzicapp/yuzic-engine/releases/tag/v1.0.0
