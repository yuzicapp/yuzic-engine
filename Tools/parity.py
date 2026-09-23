#!/usr/bin/env python3
"""Compare the two native modules by signature, not just by name.

The check this replaces compared names only:

    grep -o 'AsyncFunction("[a-z]*"' <each module> | sort | comm -23 ios android

That is half the surface. A `setBrowseTree` once shipped whose name matched on
both platforms and whose arity did not, and a name-only diff is silent about
exactly that — the method is present on both sides, so nothing is reported,
and the failure arrives at a call site as a type error somewhere unrelated.

Exit status is 0 when the two modules agree and 1 when they do not, so this
can gate a change rather than be read and forgotten.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IOS = ROOT / "ios" / "YuzicEngineModule.swift"
ANDROID = ROOT / "android/src/main/java/dev/yuzic/engine/YuzicEngineModule.kt"
# Android's surface is split: the media session lives in the service, and it
# sends events too. Reading only the module reported `onRemoteCommand` as never
# sent on both platforms, when in fact Android sends it from here and iOS is
# the one that does not.
ANDROID_EXTRA = [
    ROOT / "android/src/main/java/dev/yuzic/engine/PlaybackService.kt",
    # The playback controller moved out of the module so it runs without the
    # host's JavaScript, and most of the events are sent from there now.
    ROOT / "android/src/main/java/dev/yuzic/engine/EngineCore.kt",
]

# Differences that are deliberate. Listing one here is a claim that the gap is
# known and documented — not a way to quieten the check. Anything absent from
# this list fails, which is the point: an undocumented divergence should be
# loud, and a documented one should not cost you a red run forever.
KNOWN_GAPS = {
    # Media3's evictor takes its cache limit as a constructor argument, so
    # changing it needs either a second SimpleCache over one directory (which
    # corrupts the index) or releasing the live one mid-track. Deliberately
    # absent rather than stubbed, so it rejects by name at the bridge.
    "configureCache": "android",
}

# Record fields one platform carries and the other cannot, keyed by the field
# name. Same rule as KNOWN_GAPS: listing one is a claim that the difference is
# understood and written down, not a way to quieten the check.
#
# A field-level gap rather than a whole method, because the method itself works
# on both platforms — it is one argument of one record that has nowhere to go.
KNOWN_FIELD_GAPS: dict[str, str] = {
    # iOS restarts a stream that broke with no byte ranges by asking the
    # server for it again from a time offset in the query. Android reopens
    # the same URL at the position reached and lets Media3 get there, so
    # there is nothing on that side for the parameter to name.
    "seekReconnect": "android",
}

# Events one platform declares and deliberately never sends. Same rule as
# KNOWN_GAPS: listing one is a claim that the difference is understood, not a
# way to quieten the check.
KNOWN_EVENT_GAPS = {
    # iOS answers lock-screen and car commands inside the engine —
    # `wireRemoteCommands` maps each MPRemoteCommand straight onto a transport
    # call — so there is nothing to ask the host about. Android's media session
    # forwards custom actions it cannot answer alone, which is what this event
    # is for. The name stays in both `Events(...)` lists because the TypeScript
    # union is shared.
    "onRemoteCommand": "ios",
}

# String-union values one platform deliberately does not recognise, keyed by
# (union, value). Same rule again: a claim that the difference is understood.
KNOWN_VALUE_GAPS: dict[tuple[str, str], str] = {
    # CarPlay draws every list as rows with artwork, so iOS reads no layout at
    # all. See `BrowseNode.layout` and BrowseTree.swift.
    ("BrowseLayout", "list"): "ios",
    ("BrowseLayout", "grid"): "ios",
    # Android tests for `gapless-aware` and treats every other mode as
    # `always`, so the word itself never appears. Handled, not ignored.
    ("mode", "always"): "android",
}

# Unions the host never sends. `PlaybackState` travels the other way and is
# compared as the state vocabulary below.
OUTPUT_ONLY_UNIONS = {"PlaybackState"}

# Swift and Kotlin spell the same wire types differently. Normalise both onto a
# single vocabulary so that `[TrackRecord]` and `List<TrackRecord>` compare
# equal — they are the same thing to the bridge, and a diff that reported them
# as a mismatch would be noise that trains you to ignore it.
CANON = [
    (re.compile(r"\bBoolean\b"), "Bool"),
    (re.compile(r"\bList<([^>]+)>"), r"[\1]"),
    (re.compile(r"\bMap<\s*([^,]+),\s*([^>]+)>"), r"[\1:\2]"),
    (re.compile(r"\bMutableList<([^>]+)>"), r"[\1]"),
]


def canonical(t: str) -> str:
    t = t.strip()
    # Swift writes `[String: Any]`; Kotlin `Map<String, Any>`. Drop the spaces
    # so the two land on the same string after the rewrites below.
    t = re.sub(r"\s+", "", t)
    for pattern, repl in CANON:
        prev = None
        while prev != t:  # nested generics need more than one pass
            prev = t
            t = pattern.sub(repl, t)
    return t


def split_params(raw: str) -> list[str]:
    """Split a parameter list on commas that are not inside brackets."""
    out, depth, current = [], 0, ""
    for ch in raw:
        if ch in "[<(":
            depth += 1
        elif ch in "]>)":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        out.append(current)
    # Each entry is `label: Type`; the label is a local name and differs freely
    # between platforms (`fromIndex` vs `from`), so only the type is compared.
    types = []
    for p in out:
        p = p.strip()
        types.append(canonical(p.split(":", 1)[1]) if ":" in p else canonical(p))
    return types


PARAM_LIKE = re.compile(r"^\s*\w+\s*:\s*[\w\[\]<>,.:?\s]+$")

# `@Field var id: String = ""` on both platforms.
FIELD = re.compile(r"@Field\s+var\s+(\w+)\s*:\s*([\w\[\]<>,.:?\s]+?)\s*(?:=|$)", re.M)
# Swift `struct X: Record {`, Kotlin `class X : Record {`.
RECORD = re.compile(r"(?:struct|class)\s+(\w+)\s*:\s*Record\s*\{")


def parse_records(text: str) -> dict[str, tuple[tuple[str, str], ...]]:
    """Map each Record type to its field shape.

    The two platforms are free to name the same wire shape differently —
    `BrowseNodeRecord` on iOS is `FlatBrowseNodeRecord` on Android — and
    comparing the names would report that as a mismatch. What crosses the
    bridge is the fields, so that is what gets compared.
    """
    records = {}
    for m in RECORD.finditer(text):
        name, start = m.group(1), m.end()
        depth, i = 1, start
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[start : i - 1]
        records[name] = tuple(
            sorted((f, canonical(t)) for f, t in FIELD.findall(body))
        )
    return records


def without_known_field_gaps(types: list[str]) -> list[str]:
    """Drop the fields declared in KNOWN_FIELD_GAPS before comparing.

    Removed from *both* sides rather than added to the one that lacks it: the
    comparison then says "these agree apart from a difference that is written
    down", and a second, undeclared field difference in the same record still
    fails. Adding it to the poorer side instead would have hidden that.

    The separator has to go with the field or the shapes stop parsing as
    shapes — a record rendered `{a:X,b:Y}` with `a` removed is `{b:Y}`, not
    `{,b:Y}`, and a comparison against a literal string notices the difference.
    """
    if not KNOWN_FIELD_GAPS:
        return types
    names = "|".join(re.escape(f) for f in KNOWN_FIELD_GAPS)
    # Field with the comma after it, then field with the comma before it (the
    # last in a record has no comma after), then a record of nothing else.
    patterns = [
        re.compile(rf"\b(?:{names}):[^,}}]+,"),
        re.compile(rf",\b(?:{names}):[^,}}]+"),
        re.compile(rf"\{{(?:{names}):[^,}}]+\}}"),
    ]
    out = []
    for t in types:
        t = patterns[0].sub("", t)
        t = patterns[1].sub("", t)
        t = patterns[2].sub("{}", t)
        out.append(t)
    return out


def resolve(types: list[str], records: dict) -> list[str]:
    """Replace a Record type name with its field shape, so that two platforms
    naming the same shape differently compare equal."""
    out = []
    for t in types:
        inner = t[1:-1] if t.startswith("[") and t.endswith("]") else t
        bare = inner.rstrip("?")
        if bare in records:
            shape = "{" + ",".join(f"{f}:{ty}" for f, ty in records[bare]) + "}"
            out.append(t.replace(bare, shape))
        else:
            out.append(t)
    return out


def parse_ios(text: str) -> dict[str, list[str]]:
    """`AsyncFunction("name") { (a: T, b: U?) in` — parens, or none for no args."""
    found = {}
    for m in re.finditer(r'AsyncFunction\("(\w+)"\)\s*\{([^\n]*)', text):
        name, rest = m.group(1), m.group(2)
        paren = re.match(r"\s*\(([^)]*)\)", rest)
        if paren:
            inner = paren.group(1).strip()
            # `() -> Int in` is a no-argument function with a return type.
            found[name] = [] if not inner else split_params(inner)
        else:
            found[name] = []
    return found


def parse_android(text: str) -> dict[str, list[str]]:
    """`AsyncFunction("name") { a: T, b: U? ->` — arrow ends the list.

    A no-argument function may carry its whole body inline
    (`{ onPlayer { it.play() } }`) and has no arrow at all, so the absence of
    one means zero parameters rather than an unparsed signature.
    """
    found = {}
    for m in re.finditer(r'AsyncFunction\("(\w+)"\)\s*\{([^\n]*)', text):
        name, rest = m.group(1), m.group(2)
        if "->" not in rest:
            found[name] = []
            continue
        head = rest.split("->", 1)[0]
        # A nested lambda's arrow is not this function's parameter list. Real
        # parameter lists are `label: Type` pairs and contain no braces.
        if "{" in head or not all(
            PARAM_LIKE.match(p) for p in head.split(",") if p.strip()
        ):
            found[name] = []
            continue
        found[name] = split_params(head)
    return found


# ── Events ───────────────────────────────────────────────────────────────────
#
# Signatures were never the whole surface. Everything this engine sends the host
# travels as an event, and the tool was blind to all of it — which is how iOS
# came to raise a stall signal that nothing listened to while Android emitted
# `buffering` for the same stall, how iOS forwarded `ended` twice, and how
# `progressIntervalMs` was honoured on one platform and ignored on the other.
# None of that changes a method signature.
#
# What can be checked statically is the vocabulary: the names declared in
# `Events(...)`, and the state strings each platform can actually put on the
# wire. Emission *sites* and their conditions cannot be, and the report says so
# rather than implying a clean run means the platforms behave alike.

EVENTS = re.compile(r'Events\(([^)]*)\)')
# Both spellings: the modules call `sendEvent("onX", …)`, and Android's service
# reaches the same bridge through `eventSink?.invoke("onX", …)`. Matching only
# the first reported Android's remote-command event as never sent.
SENT_EVENT = re.compile(r'(?:sendEvent|invoke)\(\s*"(on[A-Za-z]+)"')
STATE_LITERAL = re.compile(r'"state"\s*(?:to|:)\s*"([a-z]+)"|"([a-z]+)"\s*(?://.*)?$')


def parse_events(text: str) -> tuple[set[str], set[str]]:
    """Declared event names, and the ones some line actually sends."""
    declared: set[str] = set()
    match = EVENTS.search(text)
    if match:
        declared = {piece.strip().strip('"') for piece in match.group(1).split(",")}
        declared.discard("")
    return declared, set(SENT_EVENT.findall(text))


def parse_states(text: str) -> set[str]:
    """The state strings this platform can put on the wire.

    Read from the `state` payloads it builds, which is the only place the two
    platforms have to agree in a way a host can see.
    """
    found: set[str] = set()
    for line in text.splitlines():
        if '"state"' not in line:
            continue
        for quoted in re.findall(r'"([a-z]+)"', line):
            if quoted != "state":
                found.add(quoted)
    return found


# ── String-union values ──────────────────────────────────────────────────────
#
# A value the TypeScript union offers and a platform never reads is the same
# failure as a missing method, one level down: the host sends it, the bridge
# accepts it, and the native side drops it. iOS once took `skipForward` and
# `skipBackward` from `setCommands` and discarded them by name while Android
# honoured both, and nothing here could see it because the method signature
# was `[String]` on both sides.
#
# Checked by vocabulary: each value has to appear on each platform as a string
# literal, or as a case of a Swift `String` enum, whose raw value is its name
# unless it says otherwise. Comments are stripped first so that a value only
# mentioned in prose does not count. This cannot prove the value is handled
# well, only that the platform has a word for it.

TS_SOURCES = [ROOT / "src" / "types.ts", ROOT / "src" / "AudioEngine.ts"]
IOS_SOURCES = ROOT / "ios"
ANDROID_SOURCES = ROOT / "android" / "src" / "main"

NAMED_UNION = re.compile(r"export type (\w+)\s*=\s*((?:\s*\|?\s*'[^']*')+)\s*;")
INLINE_UNION = re.compile(r"(\w+)\??\s*:\s*('[^']*'(?:\s*\|\s*'[^']*')+)")
STRING_ENUM = re.compile(r"enum\s+\w+\s*:\s*String[^{]*\{")


def parse_unions(text: str) -> dict[str, list[str]]:
    """Every string-literal union in the TypeScript API.

    Named unions by their type name, and inline ones (`mode: 'a' | 'b'`) by
    the field that declares them.
    """
    unions: dict[str, list[str]] = {}
    for m in NAMED_UNION.finditer(text):
        unions[m.group(1)] = re.findall(r"'([^']*)'", m.group(2))
    for m in INLINE_UNION.finditer(text):
        unions.setdefault(m.group(1), re.findall(r"'([^']*)'", m.group(2)))
    return {n: v for n, v in unions.items() if n not in OUTPUT_ONLY_UNIONS}


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"(?m)(^|\s)//.*$", r"\1", text)


def vocabulary(text: str) -> tuple[str, set[str]]:
    """The code with comments removed, and the raw values of its String enums."""
    code = strip_comments(text)
    cases: set[str] = set()
    for m in STRING_ENUM.finditer(code):
        depth, i = 1, m.end()
        while i < len(code) and depth:
            depth += {"{": 1, "}": -1}.get(code[i], 0)
            i += 1
        for line in re.findall(r"\bcase\s+([^\n]+)", code[m.end() : i]):
            for part in line.split(","):
                named = re.match(r"\s*`?(\w+)`?\s*(?:=\s*\"([^\"]*)\")?", part)
                if named:
                    cases.add(named.group(2) or named.group(1))
    return code, cases


def platform_vocabulary(root: Path, suffix: str) -> tuple[str, set[str]]:
    texts = [
        p.read_text(encoding="utf-8")
        for p in sorted(root.rglob(f"*{suffix}"))
        if "Vendor" not in p.parts
    ]
    return vocabulary("\n".join(texts))


def android_icon_names() -> set[str]:
    """Android spells a browse icon as a drawable, `yuzic_car_<icon>`, and
    builds the resource name from the value rather than quoting it."""
    drawables = ANDROID_SOURCES / "res" / "drawable"
    return {p.stem[len("yuzic_car_"):] for p in drawables.glob("yuzic_car_*.xml")}


def union_problems() -> tuple[list[str], list[tuple[str, str]]]:
    """Values a platform has no word for, and KNOWN_VALUE_GAPS entries that no
    longer describe anything."""
    unions = parse_unions("\n".join(p.read_text(encoding="utf-8") for p in TS_SOURCES))
    ios_code, ios_cases = platform_vocabulary(IOS_SOURCES, ".swift")
    android_code, android_cases = platform_vocabulary(ANDROID_SOURCES, ".kt")
    android_cases |= android_icon_names()

    problems: list[str] = []
    missing: set[tuple[str, str]] = set()
    for union, values in sorted(unions.items()):
        for value in values:
            for side, code, cases in (
                ("ios", ios_code, ios_cases),
                ("android", android_code, android_cases),
            ):
                if f'"{value}"' in code or value in cases:
                    continue
                missing.add((union, value))
                if KNOWN_VALUE_GAPS.get((union, value)) != side:
                    problems.append(f"{union} '{value}' is never read on {side}")
    stale = sorted(set(KNOWN_VALUE_GAPS) - missing)
    return problems, stale


def main() -> int:
    ios_text, android_text = IOS.read_text(), ANDROID.read_text()
    ios_records = parse_records(ios_text)
    android_records = parse_records(android_text)

    ios = {n: resolve(p, ios_records) for n, p in parse_ios(ios_text).items()}
    android = {
        n: resolve(p, android_records) for n, p in parse_android(android_text).items()
    }

    ios_only = sorted(
        n for n in set(ios) - set(android) if KNOWN_GAPS.get(n) != "android"
    )
    android_only = sorted(
        n for n in set(android) - set(ios) if KNOWN_GAPS.get(n) != "ios"
    )
    mismatched = sorted(
        n for n in set(ios) & set(android)
        if without_known_field_gaps(ios[n]) != without_known_field_gaps(android[n])
    )
    android_all = android_text + "\n".join(
        path.read_text() for path in ANDROID_EXTRA if path.exists()
    )
    ios_declared, ios_sent = parse_events(ios_text)
    android_declared, android_sent = parse_events(android_all)
    ios_states = parse_states(ios_text)
    android_states = parse_states(android_all)

    event_problems: list[str] = []
    if ios_declared != android_declared:
        event_problems.append(
            f"declared events differ — only iOS: {sorted(ios_declared - android_declared)}, "
            f"only Android: {sorted(android_declared - ios_declared)}"
        )
    for side, key, declared, sent in (
        ("iOS", "ios", ios_declared, ios_sent),
        ("Android", "android", android_declared, android_sent),
    ):
        never = sorted(
            name for name in declared - sent
            if KNOWN_EVENT_GAPS.get(name) != key
        )
        if never:
            event_problems.append(
                f"{side} declares {never} and never sends them — a host waiting on "
                "one of those waits forever"
            )
        undeclared = sorted(sent - declared)
        if undeclared:
            event_problems.append(f"{side} sends undeclared events: {undeclared}")
    if ios_states != android_states:
        event_problems.append(
            f"state vocabularies differ — only iOS: {sorted(ios_states - android_states)}, "
            f"only Android: {sorted(android_states - ios_states)}"
        )

    known = sorted(
        n
        for n, side in KNOWN_GAPS.items()
        if (side == "android" and n in ios and n not in android)
        or (side == "ios" and n in android and n not in ios)
    )
    # A gap that has been closed should stop being listed as known, or the list
    # slowly becomes a record of what used to be true.
    stale = sorted(set(KNOWN_GAPS) - set(known))
    value_problems, stale_values = union_problems()

    print(f"iOS: {len(ios)} methods   Android: {len(android)} methods\n")

    if known:
        print("Known gaps (declared in KNOWN_GAPS):")
        for n in known:
            print(f"  {n} — absent on {KNOWN_GAPS[n]}")
        print()
    if KNOWN_FIELD_GAPS:
        print("Known field gaps (declared in KNOWN_FIELD_GAPS):")
        for field, side in sorted(KNOWN_FIELD_GAPS.items()):
            print(f"  {field} — carried on the bridge, unusable on {side}")
        print()
    if stale:
        print("KNOWN_GAPS lists differences that no longer exist — remove them:")
        for n in stale:
            print(f"  {n}")
        print()

    if stale_values:
        print("KNOWN_VALUE_GAPS lists values both platforms now read. Remove them:")
        for union, value in stale_values:
            print(f"  {union} '{value}'")
        print()
    if value_problems:
        print("String-union values the TypeScript API offers and a platform drops:")
        for problem in value_problems:
            print(f"  {problem}")
        print()

    if ios_only:
        print("Only on iOS:")
        for n in ios_only:
            print(f"  {n}({', '.join(ios[n])})")
        print()
    if android_only:
        print("Only on Android:")
        for n in android_only:
            print(f"  {n}({', '.join(android[n])})")
        print()
    if mismatched:
        print("Signature mismatch — the name matches and the arguments do not:")
        for n in mismatched:
            print(f"  {n}")
            print(f"    ios     ({', '.join(ios[n])})")
            print(f"    android ({', '.join(android[n])})")
        print()

    if event_problems:
        print("Events:")
        for problem in event_problems:
            print(f"  {problem}")
        print()

    if not (
        ios_only or android_only or mismatched or stale or event_problems
        or value_problems or stale_values
    ):
        print(
            "Signatures, event vocabulary and union values agree, apart from the "
            "declared gaps above."
        )
        print(
            "Note: this compares names, types and vocabulary. It cannot compare "
            "*when* an event is sent, so it says nothing about the two platforms "
            "behaving alike — the divergences recorded in docs/architecture.md are "
            "invisible here by construction."
        )
        return 0

    return 1


if __name__ == "__main__":
    sys.exit(main())
