# Changelog

All notable changes to yuzic-engine are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
follows [semantic versioning](https://semver.org/spec/v2.0.0.html).

Semver here is a promise about the **JavaScript API** — the methods on
`YuzicEngine`, the event vocabulary, and the exported types. Native
implementation detail may change in a patch release when the observable
behaviour does not.

## [Unreleased]

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

[Unreleased]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.2...HEAD
[1.0.2]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/yuzicapp/yuzic-engine/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/yuzicapp/yuzic-engine/releases/tag/v1.0.0
