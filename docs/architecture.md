# Architecture

Thirteen sections: twelve decisions, each with the reason it went that way, and a record of where the two platforms still disagree. The later ones came out
of measurement rather than design, which is why they read differently. Anything that contradicts one of these is either a mistake or
a decision to revisit here first.

## 1. A graph, not a queue player

Every React Native audio library wraps a queue player — `AVQueuePlayer` on iOS,
ExoPlayer used as a whole on Android. You get URL playback, buffering and
platform integration nearly free, and you get exactly one output with nowhere
to insert anything. That is a fine trade until you want two of the things yuzic
wants:

- **Crossfade** is two sources overlapping with volume ramps. One output cannot
  overlap with itself.
- **A working equalizer** needs a processing stage between decode and output.
  yuzic has shipped an equalizer *interface* for a while with nothing behind it,
  because there was nowhere to put it.

So: `AVAudioEngine` on iOS, with `AVAudioPlayerNode`s into an `AVAudioMixerNode`
and `AVAudioUnitEQ` in the chain. Media3 on Android, with custom
`AudioProcessor`s and a second player instance for the overlap.

The cost is real and lands almost entirely on iOS — see §2.

## 2. The graph plays files, so remote audio is fetched to disk first

`AVAudioEngine` plays buffers and files. It does not play URLs. That is the bill
for §1, and the obvious response — "then we need a whole streaming stack" —
overstates it, because **yuzic already caches everything to disk**: a 1GB LRU
with a two-track preload window.

Once audio is landing on disk anyway, "stream it" and "cache it" stop being two
problems. The engine fetches to the cache and plays from the cache, for local
and remote alike. One path, and the buffering policy is ours: how much before
we start, how far ahead we read, what a seek past the buffer does.

### Not `AVAudioFile` — a random-access byte provider

The obvious reading of "plays files" is `AVAudioFile`, and that does not work
on a file still being written. Two blockers, both in its own header:

- `length` is computed once at open and never re-derived, so a partial file
  reports a partial length and `scheduleSegment` honours it and stops early.
- Reading past the current end is a **short read, not an error** — you get
  `frameLength == 0`, indistinguishable from real end-of-file. There is no
  "would block" signal, so the only recovery is closing and reopening on every
  underrun, re-paying the parse each time.

So the reader is the callback-based Core Audio file layer instead:

```
sparse disk cache + ranged URLSession
        ↓  AudioFile_ReadProc / AudioFile_GetSizeProc  (blocking, own thread)
AudioFileOpenWithCallbacks
        ↓  ExtAudioFileWrapAudioFileID
ExtAudioFileSeek / ExtAudioFileRead → AVAudioPCMBuffer
        ↓  scheduleBuffer
AVAudioPlayerNode → EQ → mixer → output
```

`AudioFile_ReadProc` is random-access — it is handed an offset, not a cursor —
and `GetSizeProc` answers with the full size from `Content-Length`. So the
parser believes the file is whole from the first frame, and **a seek past the
fetched region stops being a special case**: Core Audio asks for bytes at the
target, the read proc issues a ranged GET and blocks until they land. Identical
code path to a local file.

The read proc has no async form, so all reads run on a dedicated producer
thread keeping a few seconds of PCM queued ahead. A stalled network read then
costs buffer-ahead, not a dropout — provided seeking can abandon an in-flight
blocking read promptly, which is the part to get right.

What this genuinely costs:

- Range requests, so a seek past the fetched region doesn't wait for the whole
  file.
- A start threshold — begin playing at N seconds buffered, not at complete.
- Care with long content. A three-hour DJ set must not have to land entirely
  before it plays.
- **Non-faststart M4A**: when `moov` sits at the tail, the parser's first read
  is near the end of the file. Confirmed by the spike — with only the first 30%
  of an ALAC file present, **the open fails outright**, two of its first ten
  reads being past the fetched region. WAV and FLAC in the same test open
  cleanly and report the correct full duration.

  So the cache **fetches the tail before the head for MP4-family files** —
  roughly the last 64KB. Cheap, because the read proc is random-access already:
  a prefetch heuristic, not a redesign. But it must not be forgotten, or ALAC
  and AAC will refuse to start until the whole file has landed.

Android could have kept the simpler road here: Media3's `SimpleCache` and
`CacheDataSource` do this already and well. It uses the same fetch-to-cache path
anyway, because two caching models would mean two sets of behaviour to reason
about, and the offline-downloads store has to interoperate with exactly one.

Rejected on the way here: an `AVAssetResourceLoader` delegate (it feeds
`AVPlayer`, and there is no supported route from an `AVURLAsset` to a player
node), and a local HTTP proxy (adds a socket, a background-execution liability
and a port-collision surface, in exchange for nothing the read proc doesn't
give free).

Prior art worth reading before writing any of this: **SFBAudioEngine** (MIT,
so both readable and usable) drives an `AVAudioEngine` graph with its own
decoders and does gapless already.

## 3. The queue lives natively

The host hands over a whole queue and issues commands against it. It never
drives playback track by track.

This is not a style preference. Backgrounded apps have their JavaScript
suspended, and the things that must keep working while it is suspended are
exactly the ones users notice: advancing to the next track, updating the lock
screen, answering a steering-wheel button, keeping the now-playing info honest
for CarPlay. Anything that needs JS awake will eventually not happen, usually in
a car.

The same reasoning applies to the browse tree (§`setBrowseTree`) and the sleep
timer: the car can ask, and the timer can fire, while nothing of ours is running
in JS.

## 4. Explicit now-playing state

`MPNowPlayingInfoCenter.playbackState` is set explicitly on every transition,
not inferred and not left to the framework.

This is the one decision taken directly from a bug. yuzic's current player left
it implicit, and CarPlay showed "paused" while audio was playing on the first
track of a session — fixed downstream by patching the library. An engine that
owns the session should never need that patch to exist.

`.buffering` is stated as `.playing`, with a rate of zero. The listener asked
for audio and it is on its way, so the button is pause and the clock stands
still. Stated as paused, a track picked in the car showed a play button while
it opened, and pressing it opened the track again.

The state is only as good as what it is stated about. A track that is opening
has no reader yet, and for a long time that meant nothing was published until
it had one. A car selection is `setQueue` and `play`, the advance goes through
`startTrack`, and neither said anything, so the lock screen and the car showed
the track before for the length of the open: about two seconds of the wrong
title, paused, over the right song starting. A skip did say the new title, but
with the old track's position and length, because the old reader was still
attached. Now every path publishes the track that was asked for at once, from
the top with the length the host declared, and drops the outgoing reader first.
`PlaybackEngineTests` reads it back through `NowPlayingCenter.lastPublished`.

### When the system takes the audio away

A call, Siri, an alarm, another app with a non-mixable session, a voice memo,
AirPods switching to their microphone, a car connecting: each either
interrupts the session or changes the route or format, and every one of them
stops `AVAudioEngine` and discards the buffers scheduled on it. Nothing tells
the nodes, and `AVAudioPlayerNode.play()` on a stopped engine raises an
Objective-C exception rather than returning an error.

So the engine does not try to resume what it had. When the audio is taken it
holds the active track's position (`pendingRestart`) and releases the
playback. Whatever next starts audio — the interruption ending with
`.shouldResume`, or play from the app, the lock screen, AirPods or the car; a
seek; a skip; the automatic advance — first reclaims the session and the
graph (`reclaimAudioIfNeeded`), then rebuilds the playback at that position
over the same reader. Same second, same stream, no second track-change event,
and `.buffering` until a buffer is really scheduled.

Two rules follow from what actually happens on a phone:

- **No end may be assumed.** An app that holds a non-mixable session often
  never sends `.ended`, or sends it without `.shouldResume`. Recovery hangs off
  the next play, not off the notification.
- **Audio still taken is not a broken track.** If the session cannot be
  re-activated — a call still in progress — the engine stays paused with the
  position kept and emits no failure. A failure event would have the host retry
  or drop a track that is fine; pressing play again once the other app lets go
  works.

A route or format change while *playing* is picked straight back up; while
paused, including during an interruption, it is left for the next play. That
second case used to start the engine into an inactive session, fail, drop the
playback and report a failure. `InterruptionRecoveryTests` drives all of this
through `interruptionBegan`, `interruptionEnded(shouldResume:)` and the
configuration-change handler with the graph stopped the way the system stops
it; the notifications themselves cannot be posted from a Mac test.

## 5. Expo Modules, not Nitro

The perf argument for Nitro does not apply here: **nothing high-frequency
crosses this bridge.** Audio never does — it goes disk → decoder → graph →
output, entirely native. Commands are user-initiated and rare. Progress is
emitted about once a second.

What *is* large is the integration surface: background audio mode, the CarPlay
entitlement and scene delegate, the Android foreground service, the
notification channel, the Android Auto declaration. That is config-plugin work,
and the Expo Modules API is markedly better at it. yuzic is an Expo app with a
dev client already.

The cost: consumers pull in `expo-modules-core`. Acceptable, because this is
for yuzic. If it were aimed at broad adoption the answer would flip to Nitro or
plain Turbo Modules — worth revisiting only if that goal changes.

## 6. Crossfade rules are the engine's, not the host's

Four behaviours are fixed in `PlaybackQueue.transitionDuration` rather than
exposed as settings, because each one is a bug and not a preference when it
goes the other way:

- **A `continuous` track never fades.** Live radio has no known finish line to
  start a fade before.
- **`followsPrevious` hard-cuts.** A track mastered to run out of the one
  before it — an album segue, a continuous mix — sounds worse crossfaded than
  joined, because the overlap doubles. The host supplies this flag; it already
  knows album and track numbers, which beats digging encoder delay and padding
  out of LAME tags or `iTunSMPB`.
- **A manual skip is immediate.** A fade is for a track that ended. Eight
  seconds of politeness after pressing next reads as lag.
- **The fade is clamped to half the shorter track.**

And one that is not about sound at all: **the faded-out portion counts toward
the outgoing track's listened time**, reported as `previousListenedSec` on
`trackChange`. Without it, position never approaches duration, and a host
scrobbling at "half the track or four minutes" silently stops scrobbling
anything once a long crossfade is switched on. `trackChange` fires at the
crossover midpoint so it lines up with what is actually being heard.

## 7. Replay gain comes from tags, and respects peak

Computing loudness on device means decoding a whole track before it can play:
bad on battery, impossible on first listen. Both of yuzic's backends already
carry the figures — Navidrome through the OpenSubsonic extension, Jellyfin as
normalization gain — so the engine reads tags and never measures.

Two details that get missed and make normalisation sound worse than none:

- **Peak-aware clamping.** Positive gain on a hot master clips. Total gain is
  held below full scale using `replayGainPeak`. Quieter than asked for beats
  distorted.
- **Untagged tracks are their own case.** `replayGainDb` absent means "no
  information", which is not 0 dB. A library where half the tracks are adjusted
  and half are not sounds *more* uneven than one where none are, so untagged
  material gets its own configurable pre-amp.

`auto` mode picks album for a queue that is one album — keeping the interlude
that is meant to be quiet quiet — and track otherwise. Most players make this
one global choice and are therefore wrong half the time.

## 8. Fixed sample rate by default, and it excludes crossfade

The graph runs at 48kHz and converts into it: that is what iOS hardware most
often runs natively, so the common case is a no-op rather than a resample.

**Correction to an earlier version of this document.** It claimed overlapping
sources must share a sample rate. That is wrong: Apple's own guidance is to
connect each player node to the mixer *at its own track's rate* and let
`AVAudioMixerNode` do the conversion — it sums once and converts once, which is
cheaper than converting per node. So crossfading 44.1kHz into 96kHz is fine.

The real collision is with the **hardware** rate. `setPreferredSampleRate` is
what bit-perfect output requires, and changing it fires
`AVAudioEngineConfigurationChangeNotification`, which stops the engine and
clears every scheduled buffer. Mid-fade that is a guaranteed audible break.

> **Matching the hardware rate to the source can only happen at a track start
> with nothing fading.** It is not compatible with a crossfade in progress.

So `match-source` still clears crossfade and says so, but for the accurate
reason. Two consequences for the graph:

- A connection's format cannot be changed while the engine runs, so the pool of
  player nodes is reconnected at the incoming track's rate during the *preload*
  window — never the node that is currently playing.
- The mixer's conversion quality is not adjustable. If mixer SRC disappoints on
  96→48, convert at decode time with `AVAudioConverter`, which does expose
  quality, algorithm and dither.

Register for the configuration-change notification regardless and rebuild from
the current decode position: it fires on every AirPods, CarPlay and dock
transition, not only on rate changes of our own making.

Also worth knowing before choosing it — iOS hardware commonly runs at 48kHz and
Bluetooth imposes its own rate regardless, so bit-perfect only means anything
over wired output or a USB DAC.

## 9. Core Audio does not cover the formats, and its FLAC seeking is broken

Two findings that change what has to be built, both from the research spike.

**Ogg has no Core Audio container.** FLAC and Opus decode natively from iOS 11
(`kAudioFormatFLAC`, `kAudioFormatOpus`), and raw `.flac` opens fine. But the
`AudioFileTypeID` list has no Ogg member, so **Opus-in-Ogg — which is what a
`.opus` file off a Subsonic server is — will not open at all**, and Ogg Vorbis
is unsupported at any version. Those need bundled decoders (libogg, libvorbis,
libopus) and a second, parallel code path. Budget for it rather than finding it
late.

> **Status: half built, and the prediction held exactly.** It was found late
> anyway — by a listener, as one album of a real library showing "Unable to
> play track" while everything around it played.
>
> `TrackReader` is the parallel path, and `VorbisFileReader` is the first
> thing on it: libogg and libvorbis are vendored under `ios/Vendor` and the
> factory picks a decoder by reading the codec name out of the first Ogg page.
> Not by extension — a stream URL has none — and not by container either,
> since Opus and FLAC also live in Ogg behind the same `OggS`.
>
> **Opus is still not decoded.** A `.opus` file is transcoded by the server
> instead, which works and is not what Original quality is for. libopus is the
> same shape of job as libvorbis was, now that the seam and the two-build-system
> vendoring both exist.

**Apple's FLAC and MP3 decoders ignore the seek structures in the file.** They
decode from byte zero instead of using FLAC's `SEEKTABLE` or MP3's Xing/LAME
TOC, so seek cost is linear in distance. Measured on a 75-minute file, seeking
to the midpoint:

| format | local | over network |
| --- | --- | --- |
| WAV | 0.0005 s | 0.007 s |
| ALAC | 0.0011 s | 0.015 s |
| MP3 | 0.196 s | 9.2 s |
| **FLAC** | **0.753 s** | **30.2 s** |

`FLAC__stream_decoder_seek_absolute()` does the same seek in ~0.015 s. For a
self-hosted FLAC library — which is exactly yuzic's audience — that is the
difference between a working scrubber and an unusable one, and it applies to
any design sitting on Apple's decoder.

The mitigation is the same bundled libFLAC that Ogg support already argues for,
leaving Core Audio to handle MP3, AAC/M4A, ALAC and WAV.

**Reproduced, and it is worse than slow seeking.** The spike in
[`spikes/ios-reader`](../spikes/ios-reader) measured this on macOS 26 with a
20-minute file. Seek cost is linear in distance, as reported — but the useful
measurement was not time, it was *which bytes the decoder asks for*:

| format | bytes requested to play from 90% in | range touched |
| --- | --- | --- |
| WAV | 16 KB | 186050–186066 KB |
| **FLAC** | **279,985 KB — 177% of the file** | **13–142,331 KB** |
| ALAC | 36 KB | 143151–143188 KB |

Apple's FLAC decoder reads from the start of the file to the seek point, some
regions more than once. **So random access buys nothing for FLAC.** Over a
network, seeking near the end of a track would fetch the whole track first.
This is not a performance footnote — it defeats the ranged-fetch design in §2
outright, for the format this app's audience mostly holds.

libFLAC is therefore **architectural, not an optimisation**. Core Audio keeps
MP3, AAC/M4A, ALAC and WAV, where seeking is targeted.

**Done.** `ios/Core/FLACFileReader.swift` decodes raw FLAC with the vendored
libFLAC, and `HTTPTrackReaderFactory` routes to it on the `fLaC` magic — the
same byte-sniff the Ogg codecs get, because a Subsonic stream URL says nothing
about what it will send. Measured on the 46MB 24-bit file that prompted it:

| | Core Audio | libFLAC |
| --- | --- | --- |
| forward-only source (a transcoded stream) | **cannot even open** — `openFailed(-40)`, seeks backwards on the first read | decodes 237.7s, 100%, zero seeks |
| seek to 90% in | 177% of the file | **1.1%** of the file, via its SEEKTABLE |

The forward-only column is what made yuzic#213: a lossless track's *first*
cellular play hits a cold transcode, which Navidrome answers `200` with no
length, so the engine correctly takes the sequential transport — where Core
Audio's backward seeks are unservable. The same track played fine on a second
attempt, once the server had cached the transcode and could answer `206`.

Two properties of the decoder are worth keeping in mind when changing this:
libFLAC is given **no seek/tell/length callbacks at all** when the source is
sequential (reporting `UNSUPPORTED` is a fact about the stream; reporting an
*error* would make it treat the file as broken), and it hands back signed
integers **in the file's own bit depth**, so the float conversion must scale by
that depth rather than a fixed one — the track in question is 24-bit, where
16-bit scaling overflows by 256x.

FLAC-in-Ogg is still not claimed: `oggCodec` answers nil for it and the raw
signature check does not match, so it reaches Core Audio exactly as before.

## 10. Transcoded streams are a second transport, not a variation

Measured, not assumed — see `spikes/ios-reader`. Against a real Navidrome, a
direct stream answers `206` with `accept-ranges: bytes` and a full
`content-range`. The same track requested with `maxBitRate` and `format`
answers `200`, `accept-ranges: none`, **and no content-length at all**, because
the server is producing bytes as it sends them.

Everything in §2 rests on two things a transcoded stream refuses to provide: a
known total size, and random access. `GetSizeProc` has nothing truthful to
answer, and an offset does not address a stable resource.

Subsonic's own seek mechanism for this case is `timeOffset` — re-request the
stream starting *n* seconds in, confirmed working on the demo server. That is a
fresh byte stream per seek, not a window into one file.

So there are two transports:

| | direct | transcoded |
| --- | --- | --- |
| ranges | yes | no, explicitly refused |
| length up front | yes | no |
| seeking | byte range | re-request with `timeOffset` |

**And the app chooses between them without meaning to.** yuzic sends
`format`/`maxBitRate` for every quality except Original, and that setting is
per-network — so the same track is randomly accessible on WiFi at Original and
forward-only on cellular at 192kbps. Neither the reader nor the cache may
assume which one it has.

What this does not change: the callback reader, the cache, the range
bookkeeping, and everything the spike proved are all still right for the direct
path, which is the one that carries lossless playback and offline downloads.

What it adds, now built as `StreamingByteSource`:

- **Length-unknown, append-only.** Every byte that arrives is kept, so seeking
  backwards or anywhere already received is ordinary random access; only a read
  ahead of the write head waits, which is the normal case for a reader running
  slightly ahead of a download.
- **`GetSizeProc` answers an estimate** until the stream ends, then the true
  size. It has to answer *something* — the parser asks before any bytes arrive.
  `duration × bitrate` is what the host knows. Erring high is deliberate:
  reading past the real end returns nothing, which the parser treats as
  end-of-file, whereas under-reporting truncates the track.

  **Nothing may treat that estimate as the end of the audio.** `isFinished`
  says whether the reported length is a fact or a guess, and it is false until
  the producer's own `onFinish` fires. `AudioFileReader.readProc` reads it
  before turning an empty read into `kAudioFileEndOfFileError`: at an estimated
  length an empty read means only that the bytes have not arrived, and the
  engine advances the queue on an end-of-file. That is the difference between a
  track that stalls and one that ends itself early — which is exactly the shape
  of the 320 kbps fault recorded on `assumedBitrate`, where a 3:21 FLAC was
  read as 58 seconds. Erring high protects against it; refusing to trust the
  estimate at all is what makes it structural rather than a matter of margin.

- **`cancel()` unblocks reads; it does not stop the stream.** The `ByteSource`
  contract is exactly "unblocks any waiting read" — a seek needs the decode
  thread off the condition variable so the reader can be repositioned, and for
  the ranged transport nothing more can be meant, since a cancelled range is
  simply reissued. This source has one producer, started once, and stopping it
  is irreversible: `HTTPStreamProducer.stop()` cancels the task and invalidates
  the session, while `resume()` only clears a flag and `startIfNeeded`'s
  `started` guard never resets. Stopping the producer in `cancel()` therefore
  ended the transcode on the first seek, and every read afterwards waited out
  `readWaitTimeoutSec` and threw — silence, then a track that ended itself.
  Reported as a seek near the end of a track playing nothing and the next seek
  skipping on; the same track downloaded was unaffected, because a local file
  never takes this path. Teardown belongs to `deinit`, which already does it,
  and letting the download run through a seek is better anyway: the buffer
  keeps filling while the reader is repositioned.

  **Neither fault has an Android counterpart, structurally.** Both live in the
  hand-written byte source that exists only because Core Audio has no caching
  data source (§2). Media3 owns the transport on Android: `seekTo` goes
  straight to ExoPlayer, `CacheDataSource` does its own ranged refetching and
  reconnection, and there is no `cancel`/`resume` pair and no producer to stop.
  Nor is there a length estimate to mistake for an ending — Media3 reports
  `TIME_UNSET` for a duration it does not know and the bridge answers `0`
  rather than guessing. This is the one place where Android's implementation
  being a fraction of iOS's is an advantage.

- **A forward seek past the write head is a reconnection, not a read.**
  `streamURL(base:timeOffsetSeconds:)` builds the new request; the layer above
  replaces the source and reopens the reader, because the new stream's byte
  offsets have nothing to do with the old one's. Deliberately not smuggled into
  the source, which would make a seek look cheap when it costs a round trip and
  a rebuffer.

  That layer above went unwritten for as long as this paragraph described it —
  `streamURL` had no callers at all — and its absence is what made a broken
  transcode fatal. `TrackPlayback`'s retry ladder re-reads, which recovers a
  ranged source because the same bytes can be asked for again; on a stream the
  producer has stopped and reading again waits on nothing. The ladder spent its
  whole budget on a fault it could not fix. `PlaybackEngine.reconnectStream`
  is the missing layer: on a read failure over a sequential source it asks the
  server for the track again from the second reached, up to
  `maxStreamReconnects` times per outage, with the position carried across by
  `TrackPlayback.start(atFrame:readerOrigin:)` — the reopened stream's own
  frame zero is that offset into the track, and only keeping the two apart
  stops a reconnection throwing the progress bar back to 0:00.

That last cost is accepted rather than hidden. Someone who set a bitrate cap
chose it, and a slower seek is the honest consequence — better than quietly
pulling the lossless original over cellular to make seeking feel nicer.

**Measured since: the cost is smaller than this paragraph assumes.** 333ms to
first sample on the transcoded path against 273ms on a ranged one — a
reconnection, a fresh stream and a rebuffer, for about sixty milliseconds. The
trade-off stands, but "slower seek" overstates what a user would notice; see
open question 3.

`AudioFileReader` takes a `ByteSource` rather than either concrete type, so it
does not know or care which transport it is reading.

The alternative — always source the cache from `/rest/download`, which is the
raw file and seekable — trades a user's deliberate bandwidth choice for
seekability, and on cellular that is not ours to make.

### Live streams are a third transport

Internet radio has neither a length nor an end, and both transports above lean
on at least one. Measured against a real station (a 302 chain to a chunked
`audio/mpeg` that ignores `Range`):

- **The length probe never returned.** It waited for the whole response body,
  which from a server that ignores `Range` is everything — here, a broadcast.
  It ran into its wall-clock deadline and threw, so no station opened at all.
  It now reads the status and headers and abandons the body, which also stops
  it downloading an entire transcode just to learn there is no length.
- **The file parser waits for an end.** Over `StreamingByteSource`,
  `AudioFileOpenWithCallbacks` read the last 128 bytes of the guessed size
  (an ID3v1 check) and waited out a full read timeout, then scanned packets to
  the write head and waited out another: 24 seconds to open. The frame count it
  settled on was what had arrived by then, and `read` stops there, so the
  station ended itself shortly after it started.
- **Every byte was kept**, which a transcode needs for backward seeks and a
  broadcast never uses: 58MB an hour at 128 kbps.

So a track the host marks `continuous` is read by `LiveStreamReader`, over
`AudioFileStream` — Core Audio's push parser, which is handed bytes in order
and yields packets as they complete — and `AudioConverter`. Bytes are dropped
once parsed. It covers MP3 and ADTS AAC, which is nearly every Icecast and
Shoutcast station; Ogg is handed back to the file path and its own decoders.

Two behaviours are deliberate. A connection whose bytes go unread past a cap —
a paused station — is dropped and reopened on the next read, so resuming
plays the station as it is now, and a paused station costs no bandwidth. And a
dropped connection is reopened by the reader itself: `reconnectStream` skips
continuous tracks because a `timeOffset` into a broadcast means nothing, and
for a station the same URL again is the whole recovery.

**The host has to say so.** Nothing in the bytes or the headers distinguishes a
station from a transcode reliably, so `continuous` is the host's statement. A
station the host does not mark goes down the file path and fails as above.

## 11. The car is served natively, from a tree pushed down in advance

CarPlay asks for its list at the worst possible moment. The phone connects as
someone starts driving; the app has been backgrounded for hours, and its
JavaScript is suspended. A browse tree that has to be fetched from JS is a tree
that is sometimes empty exactly then, and the failure looks to the driver like
an app with an empty library.

So the host pushes the tree down whenever it likes, and the native side answers
alone — including playing the selection, which never round-trips either. The
host learns what happened afterwards, through the ordinary track-change event.

**Everything that decides anything is kept out of CarPlay's types.**
`BrowseTree` and `CarPlayCoordinator` import Foundation and nothing else, so
`swift test` reaches them on any Mac with no car and no phone. The scene
delegate is left with drawing. This is the same split as `NowPlayingInfo` and
`NowPlayingCenter`, for the same reason: the interesting decisions here are not
about templates.

The decisions worth stating:

- **A track chosen inside an album queues the album and starts there**, rather
  than playing one track and stopping. The album is the context the driver
  believes they are in, and they cannot pick a follow-up while moving.
- **Over-long lists truncate rather than throw.** CarPlay refuses a list past
  its limit outright; a car showing the first hundred albums is usable, a car
  showing an error is not.
- **Orphaned nodes are dropped, not promoted.** A half-loaded library should
  show less, not show a flat pile of tracks where albums were expected.
- **Duplicate ids keep the first.** Selection resolves by id, so the
  alternative is a car playing something other than what it displayed.
- **A tree arriving after the car connects rebuilds the root template.**
  Otherwise the driver has to back out and re-enter to refresh an empty list.

**The tree crosses the bridge flat**, with parent references, because an Expo
`Record` cannot contain itself. Hosts never see that: the facade flattens, the
native side rebuilds, and both sides pin the same rules in tests, so a
disagreement cannot quietly become a car that displays one album and plays
another.

Two things outside the engine's reach. The `com.apple.developer.carplay-audio`
entitlement is granted by Apple per app; until it is, none of this appears in a
car and nothing logs to say why. And yuzic commits its `ios/` directory, so the
config plugin's Info.plist scene entry lands only on a prebuild.

Android has two cars, and they read different declarations. Android Auto,
projected from a phone, looks for `com.google.android.gms.car.application`.
Android Automotive, the OS in the car, wants `com.android.automotive`, and its
launcher also treats an app with a launcher activity of its own as an
ordinary app unless the media service opts in with
`androidx.car.app.launchable`. With only the Auto key, the app installed and
ran on an Automotive car and was left out of its media app. The launcher
logged `No opt-in info found` and `Skipping MBS ... non media template app`,
both at debug level, and nothing else. All three are in the library manifest
now and `carManifest.test.ts` pins them. The one declaration left to the host
is requiring `android.hardware.type.automotive`, because that has to be on a
car build and must not be on a phone build.

The Android service follows the same two rules as CarPlay about time. A car
that asks before there is a tree gets an empty root with empty children,
never an error, because Automotive draws an error as "isn't working right
now". And a tree that arrives later is announced with `notifyChildrenChanged`
on the root. The stand-in root and the real one share the id `root` for that
reason: a car stays subscribed to the id it was first given.

## 12. How this engine fails

Not a design decision — a record. The serious defects here have kept arriving in
the same shape, and it is worth naming because it is not the shape most review
looks for. Nothing below threw. Nothing below failed a test suite. Seven of the
thirteen are code that ran, returned, and accomplished nothing. Two are the same
idea one level up: one where what accomplished nothing was the handover, one
where it was the API boundary. The tenth is a step further out again — code that
was correct, and a *test* that ran, passed, and proved nothing, because it
exercised a different decoder from the one the fault lived in. The eleventh is
further out still, and is the only one that is not about code at all: a fault
nothing was watching, because the path it took was the one where everything
succeeded.

The twelfth and thirteenth are the inversion, and arrived together in the same
symptom. They are not code that accomplished nothing: they are code that
accomplished *something plausible and wrong*, and returned a value that cannot
be told from the right one. That shape is worse, because the tests that catch
the first eleven all ask whether the work happened.

**A guard that guards nothing.** `remoteCommandsEnabled` re-registered the lock
screen's targets only when the value changed. Correct in isolation; the previous
library's teardown calls `removeTarget(nil)`, which clears every target while
leaving the flag alone, so the one call that would have restored them was the
one the guard skipped. The controls were greyed out on every device.

**A function with no callers.** `handleConfigurationChange` was written, was
correct, committed, shipped, and never invoked. `streamURL` was the same shape
and lasted longer: the reconnection it exists for was described in §5 as
something "the layer above" did, and that layer was never built — so the
document read as though the feature existed. A design note written in the
present tense is not evidence that anything calls it.

**A stub that accepts and discards.** `setCrossfade` on Android took its
argument, stored it, and no code read it. The API was complete and the feature
did not exist.

**A curve inherited by the wrong caller.** The sleep timer's fade-out went
through the crossfade's ramp and got its equal-power curve. Right for two
uncorrelated sources overlapping; wrong for one source going to silence alone,
where it holds loud and then drops. `FadeCurve` is now a required argument with
no default, so the question has to be answered at every call site.

**A command greyed out before it can be sent.** Overriding `seekToNext` is
useless if `getAvailableCommands` reports there is nowhere to go: the controller
never sends the command and the override never runs. The button was not being
ignored — it was disabled before it could be pressed.

**A control advertised from state the announcing object cannot see.** Since the
Android model port each voice holds exactly one track, so
`getAvailableCommands` answers `COMMAND_SEEK_TO_NEXT` from `queue.nextIndex`
rather than from the player's timeline — a timeline of one can never report
that a next exists. But `ForwardingPlayer` passes listener registration
straight through and keeps no record, so nothing could raise
`onAvailableCommandsChanged` on the session's behalf. ExoPlayer announces its
own commands when its timeline changes; ours can change when nothing about the
player does. Appending behind the last track turns "next" from impossible into
possible, and the player has no reason to mention it.

The distinguishing detail is that it was *intermittent*, and that is the
property that let it survive. During ordinary playback, unrelated player events
fire often enough that the set is usually re-read within seconds — so it reaches
a user as "sometimes the next button doesn't work", with no pattern they can
see. Measured on device, the same probe on the same build gave one run that
recovered at eleven seconds and one that was still greyed at thirty. A control
that is wrong every time gets reported; a control that is wrong sometimes gets
lived with.

It is worth distinguishing from *a command greyed out before it can be sent*
above, which looks identical from outside. There, the advertised value was
wrong. Here, the value is right and nothing announces that it changed. Both
produce a dead button and the fix is in a different place for each — which is
why the thing that settled it was decoding the session's `actions` bitmask
rather than looking at the button: bit 16 present and bit 32 absent said the
override was running and the queue genuinely had nowhere to go, which was the
correct answer to a question that had been asked of a one-track queue.

The same blindness produces the opposite fault, and review caught that where the
device run had not: `setQueue(emptyList())` takes the queue from n tracks to
none while calling no player method at all, because `loadActiveTrack` returns
early when there is no active track. Nothing is announced, and the session goes
on advertising a next that is no longer there — lit when it should be greyed,
where the original was greyed when it should be lit. One blindness, both signs.

**A state announcing an event that has not happened.** The engine went to
`.playing` when play was requested rather than when the first buffer was
scheduled, so a track that never buffered showed as playing at 0:00 forever.

**A change that is whole where it was tested and partial where it was sent.**
The Android crossfade was built, wired and verified on a device by one author,
then handed over as a set of hunks transcribed by hand and vouched for as
complete. The hunk calling `maybeBeginTransition` was not among them. The
receiving copy therefore had the entire overlap implementation and nothing that
would ever run it — and it would have compiled, reviewed clean, and never once
faded. Nothing was wrong with the code; the defect existed only in the copy, and
only between two machines.

**A feature complete on one side of an API that nothing on the other side
feeds.** The engine implements replay gain properly — per-track gain, a preamp
for untagged tracks, a clipping guard using `replayGainPeak`, a floor. It is
tested and it is correct. No host populates `replayGainDb` or `replayGainPeak`,
so every track takes the untagged branch and every track gets the same
multiplier. The feature cannot be observed to work or to fail, because nothing
exercises the part that varies.

This one was found by trying to test it: the check for whether an incoming
track's gain was applied correctly during a crossfade could not be constructed,
because no two tracks could be made to differ. A green result there would have
meant nothing at all. It is the same shape as a function with no callers, moved
out to the boundary between two codebases — where it is harder to see, because
each side is complete and only the join is empty.

**A fix verified on the wrong parser.** The tenth, and the one that took four
attempts to land. A stalled network read was being reported as the end of the
file, so tracks cut off part-way through and the engine advanced — heard as
songs skipping themselves. `AudioFileReader.readProc` was fixed to answer a
failed read with `kAudioFilePositionError` rather than `kAudioFileEndOfFileError`,
and the fix was proven against a WAV fixture. WAV's parser is a header and a
block of samples: an error has nowhere to go but up. **Core Audio's FLAC parser
absorbs it** and returns `noErr` with zero frames, which `read` cannot
distinguish from a file that ended — so the fault survived, unchanged, in the
only format it had ever been reported in. Lossless is what people stream over
cellular; WAV is what the test happened to use.

The same swallow existed twice more, in `VorbisFileReader` and
`OpusFileReader`, where `try? source.read(...)` returned 0 to a C callback that
reads 0 as end of stream. Four places, one lesson: **a callback that cannot
throw will lose the difference between "could not read" and "finished" unless
something is written to carry it across** — and proving that on one decoder
proves nothing about the next. Each reader now records the reason on the way
down and raises it on the way back up.

Testing the same stall across four containers then found two more divergences
that had been sitting behind the same assumption:

- **The retry ladder was retrying a reader that could not recover.**
  `TrackPlayback` retries a failed read for thirty-three seconds, against the
  *same* reader, and Core Audio's FLAC parser latches after a failed read —
  stuck at 40,960 frames of 220,500, and never moving again once the source
  came back. So a stall the connection recovered from still ended the track.
  A seek back to position yielded exactly one more buffer and stopped; the
  latch is in the `AudioFile` parser, not the `ExtAudioFile` cursor, so
  recovery has to rebuild both. ALAC and AAC did not latch but lost audio —
  half a second and two tenths — which is quieter and just as wrong.
- **A cancelled read is not an ending on every parser.** WAV and FLAC pass
  `kAudioFileEndOfFileError` up as zero frames. MP4 reports it as a hard
  error, so a deliberate seek on an ALAC or AAC track surfaced as a decode
  failure.

The tests are a matrix now — WAV, FLAC, ALAC, AAC × four properties, failures
naming the format — and it is verified by mutation rather than by going green:
remove the failure carry and it produces eight failures, of which **zero are
WAV**. That is the entire point restated. **MP3 is the standing gap**: Core
Audio decodes it and will not encode it, so no fixture can be built in process,
and MP3 is what every transcoded stream is. Anyone who finds a way to get a
small MP3 fixture into the suite should add it to the matrix.

**A fault on the path where nothing goes wrong.** The eleventh, and the one
left over after all the rest. Every fault above was eventually caught by asking
what some piece of code *did*. This one had no code to ask about. A range
request that is merely slow — anything up to `HTTPByteFetcher.defaultTimeout`,
which is eight seconds — does not throw, does not time out and does not fail.
It returns, late, with the bytes. So the retry ladder never ran, `onReadStalled`
never fired, `reconnectStream` was never reached, and every instrument added in
the course of fixing the ten above sat on paths that were not taken. Meanwhile
`TrackPlayback`'s two seconds of scheduled PCM drained, the node rendered
silence, the rendered position stopped advancing, and the engine went on
reporting `.playing`. The account the engine gave of that minute was that it
played normally, and the listener heard the music stop and come back.

Reported, after everything else had been fixed, as "it's been better than
before, but it still cuts out" — which is the description of a fault that has
lost its neighbours and is now audible on its own.

`onUnderrun` is the instrument: raised from the buffer completion that takes
the scheduled depth to zero with the track neither finished nor stopped, which
is the moment the node has nothing left to render. Counted and logged on every
occurrence, because the count is the measurement; drawn as `.buffering` only
once it outlasts `PlaybackEngine.underrunGraceSec`, because a depth that
touches zero and is served again a few milliseconds later is a gap nobody heard
and a spinner nobody should see. The two exclusions are the whole of the
subtlety — the ordinary drain at the end of a track and the flush `stop()`
fires reach zero legitimately, and a check written against the depth alone
would report a dropout on every track anyone ever finished.

**The instrument came first, and then the cause it was built to measure.**
The cushion was two seconds of PCM and nothing else. `TrackPlayback` schedules
four buffers and stops; `CachedByteSource.ensure` fetched a window only once a
read had arrived wanting bytes it did not have. So nothing in the engine ever
ran ahead of the decoder, and a 256KB window is about two seconds of FLAC — a
round trip due every two seconds of playback, with two seconds to cover it.
At the 273ms measured against a real server that is comfortable. It has no
margin at all for a link having a bad minute, which is what a phone on WiFi at
the edge of a room is.

Two things were wrong underneath that, and both are now fixed.

**The cushion was in the wrong place.** PCM is the expensive way to hold audio
— two seconds of 96kHz stereo float32 is about 1.5MB, and it buys two seconds.
The compressed bytes are the cheap way, and `storage` is already allocated to
the whole declared length of the file, so bytes fetched early cost *nothing*
beyond bandwidth. `CachedByteSource` now runs a read-ahead pass on its own
queue that keeps `readAheadSeconds` — thirty, the order Media3 holds on
Android, where none of this was ever reported — of bytes ahead of wherever the
decoder has reached. A window at a time, so a seek lands between iterations;
behind the same one-fetch-at-a-time lock as the foreground read, because
`HTTPByteFetcher` keeps a single in-flight task and a cancel has to reach the
right one; bounded by a duration converted through the file's own average
bitrate, so a podcast gets seconds rather than the whole episode; and written
through to `DiskCache` like any other window.

**And it shrank as the audio got better.** `bufferFrames` was 22,050 — half a
second at 44.1kHz and at no other rate, because `read` returns source frames
and `outputFormat` is built from `native.mSampleRate`. At 96kHz the four
buffers were 0.92s in total and at 192kHz 0.46s, so the files with the largest
windows to fetch had the least slack to fetch them in. It is a duration now,
converted per reader.

What remains of the PCM depth is what it should always have been: cover for
decode jitter, not for the network.

**And one thing that looked like it followed, and did not.** Read-ahead makes
`bufferedSec` mean something for a stream — it reported a sawtooth between zero
and one window before — so `preloadAfterBufferedSec` was raised from 2 to 8 on
the reasoning that two seconds had become a bar anything clears. It had, *for a
stream with a duration*. Read-ahead needs one to size itself, and two paths
deliberately have none: a downloaded track, read from disk where a cushion buys
nothing, and a stream whose host never gave a length. Those still top out
around 2.2s, so the raised gate could never open for them — which turned
gapless off for every downloaded album, silently, because declining to preload
is a legal state that reports no fault. Four tests caught it, nothing else
would have, and the number is back at 2.

The general form, and the reason it is written down here rather than quietly
reverted: **a bound raised to suit the path that got faster has to be checked
against the paths that did not.** The old value's stated reason — that the
threshold has to be reachable — outlived the change that appeared to retire it.

**A key that names the wrong thing.** The twelfth. The disk cache was keyed on
`MediaId`, and a `MediaId` names a *track* — but what the cache holds is a byte
stream, and one track has as many of those as the server has ways to send it.
Quality is the obvious one; a transcoder reconfigured server-side and a library
rescan that rewrites tags are the two that do not look like a different stream
at all, since the id is stable across both. `write` replaced the entry's length
and kept the ranges filled at the old one, and `fetchWindow` asked for a range
without saying at what length, so the cache had nothing to check against even
where it wanted to. Windows from one stream were served into a decode of
another. Every layer did its job: the fetch returned bytes, the cache returned
bytes, the decoder was handed bytes. They were simply the wrong bytes, and the
only thing downstream that could tell was the decoder producing zero frames —
which this engine reads as a track ending. The cache persisted after every
window and reloaded with no check beyond the audio file still existing, so a
poisoned entry outlived every restart until eviction. It is keyed on the stream
now, and entries from before the fix are deleted rather than adopted, because
adopting one means trusting a length that records whichever stream wrote last.

**A number that answers two questions.** The thirteenth, and the same symptom
from the other end. `kExtAudioFileProperty_FileLengthFrames` is a frame count
where the container carries a packet table and an extrapolation from the
leading frames' bitrate where it does not, and it does not say which it just
gave you. The reader clamped every read to it, so a VBR MP3 with no Xing header
and a dense opening stopped mid-song and returned nil — a legal value, and the
one that means the track is over.

What makes it worth recording rather than fixing quietly is that the clamp
looked load-bearing. It exists so encoder padding is not decoded as trailing
silence, which is a real guarantee with a real test behind it, and the obvious
reading is that you cannot have both. You can: a container that can state its
priming and remainder is exactly one whose packets have been accounted for, so
"is this length a count" and "is there padding to trim" are the same question
asked twice. The clamp only ever did useful work on the files it now applies
to. On the rest it trimmed nothing and discarded music.

The same number reached the seek bound, so dragging to 2:50 of a track the
parser guessed was 2:40 long landed at 2:40 and ended it — the same fault
wearing a second face, and the one a user would have described as a different
bug entirely.

The common thread through the first eleven is that they are invisible to "does
it return, and is the return value right". What catches them is asking what the
code *did* — which call ran, which caller reached it, what the user then heard.
`Tools/mutate.py` automates one slice of this: break a real behaviour, and see
whether any test notices.

The last two need the question asked the other way round, because the return
value *was* right by every local test available: bytes of the length asked for,
a nil at a frame count the file itself reported. What was wrong was the
premise — which stream those bytes belonged to, which question that number had
answered. Neither is reachable from inside the function that got it wrong, and
that is the argument for the identity being carried in the key and in the
reader's own flag rather than inferred at the point of use.

**A cache that kept exactly what it was given.** The fourteenth, Android only.
Every stream goes through Media3's `SimpleCache`, and the cache stores whatever
body came back. A server that answers a stream request with something that is
not audio, served as 200 (a captive portal's login page, a proxy's error
page, a JSON error), has that page written under the track's `MediaId`. The
host retries with a freshly built URL, but the key is the id, so the retry
lands on the same entry and reads the same page without making a request. The
track is then unplayable after the network is fine again, until the evictor
reaches it or the whole cache is cleared.

Measured against a mock server serving JSON for one track, then fixed: on
1.0.13 the fixed server received no request for that track at all and the host
dropped it as unplayable; with the eviction below it received one and the
track played. iOS does not have this shape. Its disk cache is taken only by a
stream that answers ranged requests with 206 and a length, which a page served
as 200 does not, and an entry is filed under the declared length as well.

The cache did nothing wrong by its own lights: it stored the bytes it was
handed, and returned them. What it could not know is that the bytes were not
the thing it was caching. So the evidence is taken from the one place that can
tell: a parsing or decoding failure evicts the failed track's entry before the
error is reported (`failureMeansBadBytes`), and a network failure does not,
because the cached bytes are what lets a track play again offline.

### The instrument is part of the system

Four times the measurement was the fault and the code was fine, and each nearly
produced a "fix" for a bug that did not exist:

- A **decoder count** that could not distinguish "one track played" from "two
  tracks shared a codec" — it would have read the same either way, so it was
  evidence for neither.
- **`state=NONE(0)`** read as a fault, when nothing had been started yet. An
  absence is not a failure.
- **`actions=661`** read as a regression, when 661 was correct: a one-track
  queue genuinely had nowhere to go.
- A position of **298265 against a duration of 212741** — not a slow track, a
  wrong instrument. A number larger than the total it is measured against is a
  fact about the ruler.

A fifth is in CONTRIBUTING because it is about builds rather than readings: a
bare `lib/` in `.gitignore` kept all of libvorbis out of every commit while
`swift test` and the app build both stayed green, because both were being fed
the working tree. Before believing what a measurement implies, check that it
could have come out differently.

That test — could this have come out differently? — is also what caught the
seventh shape above, and it is worth being precise about how, because it was not
review and it was not a test suite. The hunks arrived with an assertion that
they were complete. An assertion cannot fail. What failed was a mechanical check
on the merged file: every helper named, and for each one, both a definition and
a caller. `maybeBeginTransition` came back defined once and called zero times.
The check took a minute to write, knew nothing about crossfades, and would have
caught the omission whichever hunk had gone missing.

The general form: when you receive work you did not do, verify a property of the
result rather than trusting a claim about the process. "That is every hunk" and
"the tests pass" are both claims about process. "Every function that exists is
reachable" is a property of the artefact in front of you.

## 13. Where the two platforms still disagree

`Tools/parity.py` compares method names, argument types, event names and the
state vocabulary. It cannot compare *when* an event is sent, and that is where
every remaining divergence lives — so a green run says the surfaces match, not
that the platforms behave alike. What follows is the list that check cannot
make, found by reading both implementations against each other rather than by
running anything.

Fixed since it was written down: iOS ignored `progressIntervalMs` while
Android honoured it (a host asking for 1Hz got 4Hz on iOS); iOS forwarded both
`stateChanged(.ended)` and `.ended` to the same wire event, so the queue
finishing was announced twice; `play()` did nothing on a player Android had
left in `STATE_IDLE`, the same defect iOS had with a stopped `TrackPlayback`;
`ended` was emitted at every track boundary on Android and is now scoped to the
end of the queue as it is on iOS; the first track of a queue announced itself
on iOS and not on Android, and `setQueue` now sends `onTrackChange` for it;
`skipToNext` under `repeat: one` replayed the track on Android and now advances
as it does on iOS; `PlaybackState = 'error'`, which neither platform ever
emitted, is gone from `src/types.ts`; and Android now imports the same PKCS#12
identity for both the bridge's ordinary API requests and Media3 audio fetches.
The latter uses one synchronized, process-lifetime transport: API calls snapshot
its reused OkHttp client directly, while each voice keeps a stable delegating
`Call.Factory` that snapshots that client when Media3 creates a request. That
indirection matters because `DefaultMediaSourceFactory` captures its data-source
factory when a voice is built; merely replacing a graph field would leave both
existing players presenting the old identity. Clearing swaps to a normal client
for both paths and evicts the removed client's pooled connections without
weakening the platform trust manager or hostname verification.

The Android implementation is compiled and its native unit tests run through a
real Android SDK/NDK host. Behaviour that needs a handset remains called out
below rather than being inferred from compilation.

Still true, and each is a decision rather than an oversight to fix blindly:

- **After a failure iOS reports `paused` and Android `idle`.** Same error, two
  words for the state the player is left in.
- **Android has no retry of its own.** It inherits ExoPlayer's default policy —
  three loader attempts, backoff capped at five seconds — where iOS now retries
  for a wall-clock budget with a visible buffering state. A handover iOS rides
  out still kills the track on Android.
- **A track that stopped short leaves the players in different states.** Both
  platforms now refuse to advance when playback ends before the host's declared
  duration, and both report the same error in the same words. What they leave
  behind differs: iOS moves to `paused`, Android stays in Media3's `ENDED`,
  which `emitStateIfChanged` suppresses, so a host watching state alone sees
  nothing move on Android.

  This one is deliberate and the reason is worth keeping, because it looks like
  an oversight. Writing `"paused"` at the Android veto site would close it in
  one line — and fails `Tools/parity.py`, which reads the state vocabulary from
  emission-site literals and so counts a literal written on one platform as a
  state only that platform has. The check is right to: a state one side can
  reach and the other cannot is exactly the divergence it exists to catch. It
  cannot see that this particular literal would be *closing* a divergence
  rather than opening one, which is the same blind spot §12's eleventh entry
  is about — the tool measures the surface, and the surface is not the
  behaviour. Closing it properly means Android reaching `paused` through the
  path that already emits it, not asserting the word at a new site.

## What is not decided yet

The architecture above is settled. What remains is empirical, and there is a
spike to run before the iOS reader is written. In order, the first two being
go/no-go:

1. ~~Does the FLAC slow-seek defect reproduce?~~ **Done — yes**, on macOS.
   Linear in distance, and it reads 177% of the file to play from 90% in. See
   §9 and `spikes/ios-reader`. Outstanding: confirm on an iOS device, and test
   MP3, which could not be encoded on macOS for lack of an encoder.
2. ~~Does the callback reader decode a partial file?~~ **Done — yes for WAV and
   FLAC**, opening from the head alone with the correct duration reported.
   **No for non-faststart M4A**, which needs its tail; the cache gets a
   tail-first prefetch for MP4-family files.
3. **Seek into an unfetched region**: time-to-first-sample end to end, and
   confirm an in-flight blocking read cancels in bounded time.
   **Half done — cancellation, yes**, once it was built: `cancel` reached only
   as far as a flag `ensure` read between fetches, so a seek waited out the
   request it had arrived during. `ByteFetcher.cancel` now abandons the task,
   and the bound is the cancel rather than the 30s timeout. `TrackPlayback.stop`
   calls through to it, so a discarded playback no longer leaves a thread and a
   request open until the timeout.

   Wiring it turned up a second thing. `PlaybackEngine.seek` builds a new
   `TrackPlayback` over the *same* reader, and `AudioFileReader` is documented
   not thread-safe — so the old producer, still parked in a read, was being
   raced by the new one seeking. That is `stopAndWait`: cancel, wait for the
   producer to unwind on its serial queue, then put the reads back to work.
   Used only at the seek site; everywhere else the reader is discarded and the
   wait would buy nothing.

   ~~Outstanding: time-to-first-sample.~~ **Done, and both transports were
   measured** — which turned out to matter, because the first run measured the
   wrong one and was written up as the other.

   On the simulator against a real Navidrome over the open internet, playing at
   4.4s with 11.1s buffered, seeking to 151.4s:

   | transport | first sample |
   | --- | --- |
   | direct, ranged (`format=raw`) | **273ms** |
   | transcoded, 320k (`timeOffset` reconnect) | **333ms** |

   So a seek far outside anything fetched costs about a round trip either way,
   not a rebuffer — and §10's second transport, which has to throw away its
   stream and reconnect, is only ~60ms worse than a ranged GET. That is a much
   better result for the transcoded path than the design assumed when it called
   the slower seek "the honest consequence" of a bitrate cap.

   **The trap worth recording**: yuzic sends `format`/`maxBitRate` for every
   quality *except* Original, so a probe written against the app's default
   quality silently measures the transcoded path. The engine cannot tell you
   which one you got — both are just a `ByteSource` by then. The smoke test now
   has one row per transport and prints which it is using.

   Measuring it also caught a divergence the tests could not: `bufferedSec` is
   **absolute** — on the same timeline as the position — because that is what a
   buffering bar is drawn against. iOS did that and said so; `src/types.ts`
   documented the opposite, and the Android port had followed the docs. Both
   corrected to match iOS.
4. **Two nodes at 44.1 and 96 crossfaded through the mixer**, on device and
   over Bluetooth. Decide mixer SRC versus `AVAudioConverter` by listening.

   The plain case now runs: two tracks overlapping, the transition started by
   the engine's own tick rather than by being told, with the track change
   landing at the fade's midpoint where §1 says it should. Driven from yuzic's
   smoke test, on the simulator. So the graph does what it was built for — but
   this question is not answered by that. What is still unmeasured is the part
   that motivated it: **differing sample rates**, a **real device**, and
   **Bluetooth**, none of which a simulator playing two 44.1kHz files exercises.
5. **Configuration-change survival**: pull the route mid-crossfade, confirm the
   rebuild resumes at the right frame with nothing repeated or dropped.
6. ~~Against real servers: does `/rest/stream` honour `Range` when
   transcoding?~~ **Done — no.** Direct streams are fully ranged; transcoded
   ones answer `accept-ranges: none` with no length, and seek via `timeOffset`.
   See §10; this needs a second transport, not a tweak.
7. **Thermal and battery** with two hi-res decoders live during a crossfade.

If (2) fails for a given format, that format falls back to fetch-to-complete —
a degradation, not a redesign.
