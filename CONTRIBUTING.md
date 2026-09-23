# Contributing

## Where code may come from

This engine is Apache-2.0 and everything in it has to be compatible with that.
One rule matters more than the rest:

**Do not read, copy, port, or consult `@rntp/player` v5 source while working on
this project.** That package is proprietary from v5 and its licence carries a
non-competition clause covering exactly this kind of software. Not a grey area,
and not something a rewrite launders.

`react-native-track-player` **v4 and earlier is Apache-2.0**, and that grant is
perpetual for the code published under it. Referencing or lifting from v4 is
legally clean. If you do, attribute it in `NOTICE` and say what changed.

Third-party code that is vendored — currently libogg, libvorbis, libopus and
libopusfile under `ios/Vendor` — goes in unmodified, with its licence file alongside it and an
entry in `NOTICE` naming the version and what was included.

## Verifying a change

The engine has been wrong in the same handful of ways often enough to be worth
listing, because each was found late and none of them threw.

**Say which copy you built.** `swift test` compiles `ios/Core` from the working
tree. An app build compiles whatever is in `node_modules`, which is the
*published* package. Those can differ — a bare `lib/` in `.gitignore` once kept
all of libvorbis out of every commit while both checks stayed green, because
the working tree had the files and the app build was being fed a copy of the
working tree. If a change adds files, check `git ls-files <path> | wc -l`
against what is on disk.

**Check the measurement before believing what it implies.** Four separate times
the instrument was the fault, not the code: a decoder count that could not
distinguish "one track played" from "two tracks shared a codec"; a state read
that returned `NONE` because nothing had been started; a command bitmask read
as a regression when it was a queue with genuinely nowhere to go; a position of
298265 against a duration estimated at 212741, which is not a slow track but a
wrong instrument.

**Ask what the code did, not whether it returned.** The characteristic failure
here is not a crash — it is succeeding at nothing. A guard that guards nothing,
a function with no callers, a stub that records its argument and discards it, a
curve inherited by a caller that wanted a different one, a command greyed out
before it can be sent, a state announcing an event that has not happened, a
whole feature that no caller on the other side of the API ever feeds. Every one
of those passed a test suite.

`Tools/mutate.py` exists for the last of these: it breaks one real behaviour at
a time and reports whether any test notices. A test that survives its own
subject being broken is not a test. Run it when adding one that matters.
All nine mutations are currently caught, with no survivors — which is the
result to preserve, not merely to reproduce. Note that it edits files in place
and restores them afterwards, so do not commit while it is running; a mutated
`PlaybackEngine.swift` looks exactly like an ordinary unstaged change.

`Tools/parity.py` covers the API boundary the same way: it compares the two
native modules by signature rather than by name, because the two have already
drifted once in a way a name diff could not see. Run it after touching either
module. It is mutation-tested itself — dropping a parameter, changing a type,
renaming a method and closing a declared gap are each caught.

**A failure raised against a playback that has since been replaced is
dropped, by design.** `onReadFailed` hops to the main queue and only then
checks `activePlayback === playback`, so a read failure arriving while a
reconnection is swapping the playback out finds a different object and
returns. That is right — a failure belongs to the playback that raised it,
and the reconnection has already answered it — but it means a test cannot
count injected failures and expect the engine to have seen all of them.
`testReconnectionGivesUpAfterItsBudget` did, and flaked three runs in four
until it was made to inject until the budget was actually spent. Two earlier
attempts at that fixed the wrong thing, both aimed at the loop's counting;
the probe that settled it printed one line per reconnection and showed the
failing runs reaching three opens where the passing ones reached four.

Each of those failures is written up with the case it came from in
[§12 of docs/architecture.md](docs/architecture.md#12-how-this-engine-fails).
Worth reading once before a first change here: none of them threw, and none of
them failed a suite.

## Gates

```sh
npm run typecheck    # both tsconfigs — the second is what `prepare` uses
npm test
swift test
python3 Tools/parity.py
```

`.github/workflows/checks.yml` runs those four on every push and pull request
to `main`.

**Android is built by its host, not here.** This module has no Gradle wrapper
and no `settings.gradle`, because an Expo module is compiled by the app that
consumes it — `expoAutolinking.useExpoModules()` in the app's
`android/settings.gradle` is what pulls this directory into a build at all. So
`android/src/test/` runs as `:yuzic-engine:testDebugUnitTest` through the
*app's* `./gradlew`, against whatever commit the app has pinned, and is
reached that way rather than standalone.

CI does this too. Its Android job checks out the app, repoints the app's
`yuzic-engine` dependency at the commit under test, and runs the unit tests
and an assemble through it. That drags the whole app's dependency tree and the
NDK into this repository's CI, which is why it is the slowest job, and it
proves compilation and unit behaviour, not behaviour on a device.
