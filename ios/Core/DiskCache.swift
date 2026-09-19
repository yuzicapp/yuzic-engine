import Foundation

/**
 Audio kept on disk between tracks, and between launches.

 Everything cached before this was per-track and in memory: a `CachedByteSource`
 held the ranges it had fetched for as long as the track was playing, and they
 went when it did. Replaying a track re-downloaded it, and an "offline
 download" had nowhere to live. This is the store those become possible on.

 **Keyed by the host's `MediaId`, never by URL.** Subsonic and Jellyfin both
 hand out stream URLs carrying a token that rotates, so a URL key would miss on
 every session and fill the cache with duplicates of the same album. The
 Android side already keys its Media3 cache this way and says so; this is the
 same decision on the same reasoning.

 **A `MediaId` names a track, though, and an entry holds a byte *stream*.**
 Those are not the same thing, and taking them for the same thing is what made
 tracks stop part-way through. yuzic sends `format`/`maxBitRate` for every
 quality except Original and that setting is *per-network*, so one id is a
 lossless file on WiFi and a 192kbps transcode on cellular — different bytes,
 different length, and until this was fixed the same entry. `write` replaced
 the entry's `totalBytes` with whatever the current stream declared and carried
 the ranges recorded from the previous one straight over, so `read` would then
 hand a window of the mp3 to a decode of the FLAC. That garbage decodes to a
 zero-frame read, `AudioFileReader` turns a zero-frame read into nil, and
 `TrackPlayback` reads nil as the end of the track. What the listener gets is a
 clean ending in the middle of a song and the queue moving on, with nothing
 failing anywhere and nothing to see in a log — the worst shape a fault in this
 engine takes, and the one §12 of the architecture doc is a list of.

 So an entry is filed under the id **and the length the server declared for
 that stream**, and the length is therefore immutable for the life of an entry
 — see `CacheKey`. Two encodings of one track are two entries, kept side by
 side, because the alternative is a cache that empties itself every time the
 listener walks out of the house.

 **Entries are sparse, and honest about it.** A track played halfway is
 half-fetched, and the ranges that arrived are worth keeping — but a file with
 holes cannot say which parts are real, so each entry carries a sidecar
 recording exactly what it holds. Without that, resuming would either
 re-download everything or serve silence out of a hole, and the second is worse
 because it sounds like a corrupt file.

 **Eviction takes whole entries.** Freeing space by dropping *ranges* would
 leave files that are technically valid and practically useless — a track with
 its middle removed still costs a request per gap. Least-recently-used, whole
 entries, until the budget is met. `evict(_:)` is the exception and takes every
 encoding of one id, because it answers a host that has deleted the track and
 leaving one quality behind would be the cache saying it freed space it did
 not.

 Not thread-safe by itself; `CachedByteSource` serialises access to a given
 entry, and the lock here covers the index the two share.
 */
public final class DiskCache {

  public struct Stats: Equatable {
    public let usedBytes: Int64
    public let maxBytes: Int64
    public let entryCount: Int
  }

  /**
   What one cached byte stream is filed under.

   The id alone was the key, and the class comment above says what that cost.
   The second half is the length the server stated for this particular stream
   — `Content-Range`'s total on the ranged transport, which is the only path
   that caches — used here as the stream's fingerprint rather than as a size.

   **Why the length and not something better.** The candidates were the URL,
   an HTTP validator, and this. The URL is out for the reason the class
   comment gives and for a worse one: the parts of it that identify an
   encoding sit in the same query string as credentials that rotate per
   session, so any rule for reading one risks reading the other, and getting
   that wrong produces a cache that silently stops hitting rather than a
   cache that is wrong — quiet, and nobody would report it. An `ETag` or
   `Last-Modified` would be the textbook answer, and is worth having later,
   but it would have to be carried out of `HTTPByteFetcher`'s length probe
   and plumbed through `ByteFetcher`, which is a wider change than the fault
   needs. The declared length is already in hand on every path, at the moment
   the first window is written, with no parsing and nothing to get wrong.

   **What it separates, and what it does not.** Two qualities of the same
   track differ in length by a factor, so it separates those, which is the
   reported fault. A server that re-encodes its library, or a file re-tagged
   by a rescan, changes the length too, so it separates those — and those are
   the cases the previous key could not even be asked about, because the
   entry simply absorbed the new length and kept the old bytes. What it
   cannot separate is two different streams that happen to be exactly the
   same number of bytes long. Within one library that means the file did not
   change, which is the answer we want. Across two libraries it would mean
   two servers issuing the same id for two different tracks of identical
   size, which the engine cannot see at all — `MediaId` is the host's
   statement of identity and namespacing it across servers is the host's job.
   Worth knowing about rather than worth guarding here.
   */
  struct CacheKey: Hashable, Comparable {
    let id: MediaId
    let streamBytes: Int64

    static func < (lhs: CacheKey, rhs: CacheKey) -> Bool {
      lhs.id == rhs.id ? lhs.streamBytes < rhs.streamBytes : lhs.id < rhs.id
    }
  }

  /// What one cached byte stream knows about itself.
  struct Entry: Codable {
    /// The same number as the key's `streamBytes`, kept here so the sidecar
    /// describes itself rather than relying on its own filename — `loadIndex`
    /// requires the two to agree before it will trust either.
    var totalBytes: Int64
    /// Present ranges, as flat pairs — `ByteRangeSet` is not `Codable` and
    /// giving it a persistence format would tie an in-memory type to a file on
    /// disk that has to survive a version of the app it has never met.
    var ranges: [Int64]
    var lastUsed: Double

    var byteCount: Int64 { present.totalBytes }

    /// The flat pairs, back as the set the rest of the engine speaks in.
    var present: ByteRangeSet {
      var set = ByteRangeSet()
      for pair in stride(from: 0, to: ranges.count - 1, by: 2) {
        set.insert(ranges[pair]..<ranges[pair + 1])
      }
      return set
    }

    mutating func setPresent(_ set: ByteRangeSet) {
      ranges = set.ranges.flatMap { [$0.lowerBound, $0.upperBound] }
    }
  }

  public static let defaultMaxBytes: Int64 = 1_024 * 1_024 * 1_024

  private let directory: URL
  private let lock = NSLock()
  private var index: [CacheKey: Entry] = [:]
  public private(set) var maxBytes: Int64

  public init(directory: URL, maxBytes: Int64 = DiskCache.defaultMaxBytes) throws {
    self.directory = directory
    self.maxBytes = maxBytes
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    loadIndex()
  }

  // MARK: - The contract src/AudioEngine.ts describes

  public func configure(maxBytes: Int64) {
    lock.lock()
    self.maxBytes = max(0, maxBytes)
    lock.unlock()
    evictIfNeeded()
  }

  public func stats() -> Stats {
    lock.lock(); defer { lock.unlock() }
    return Stats(
      usedBytes: index.values.reduce(0) { $0 + $1.byteCount },
      maxBytes: maxBytes,
      entryCount: index.count
    )
  }

  /**
   Drop one track, in every encoding it was cached in.

   Used when a download is deleted, where leaving the audio behind would mean
   the app says it freed space and did not — and since the same track can be
   held twice, once per quality, removing only the copy that happens to match
   some length the caller does not have would be exactly that. The host asked
   about a track, so this answers about a track.
   */
  public func evict(_ id: MediaId) {
    lock.lock()
    let keys = index.keys.filter { $0.id == id }
    for key in keys { index[key] = nil }
    lock.unlock()
    for key in keys { removeFiles(key) }
  }

  public func clear() {
    lock.lock()
    let keys = Array(index.keys)
    index.removeAll()
    lock.unlock()
    for key in keys { removeFiles(key) }
  }

  // MARK: - Reading and writing ranges

  /// What the entry for this stream holds, or nil if there is no such entry.
  /// `totalBytes` is half the key rather than a hint: an entry recorded
  /// against a different length belongs to a different encoding and is not
  /// this caller's to read.
  public func ranges(for id: MediaId, totalBytes: Int64) -> (total: Int64, present: ByteRangeSet)? {
    guard totalBytes > 0 else { return nil }
    lock.lock(); defer { lock.unlock() }
    guard let entry = index[CacheKey(id: id, streamBytes: totalBytes)] else { return nil }
    return (entry.totalBytes, entry.present)
  }

  /**
   Read what is on disk for `range` of the stream of this length, or nil when
   any of it is missing.

   All-or-nothing on purpose: a partial answer would have to describe which
   part, and every caller would then have to handle a case that the fetcher
   above already handles better by simply asking for what it lacks.

   A caller that asks with the wrong length gets nil rather than bytes. That
   is the whole fix for the fault in the class comment, and it is deliberately
   arranged as a miss: a miss costs a request, and the engine is built to pay
   for those, while the alternative costs a track that ends itself in the
   middle.
   */
  public func read(_ id: MediaId, range: Range<Int64>, totalBytes: Int64) -> Data? {
    guard totalBytes > 0 else { return nil }
    let key = CacheKey(id: id, streamBytes: totalBytes)

    lock.lock()
    guard var entry = index[key] else { lock.unlock(); return nil }
    guard entry.present.firstGap(from: range.lowerBound, limit: range.upperBound) == nil else {
      lock.unlock(); return nil
    }
    entry.lastUsed = Date().timeIntervalSince1970
    index[key] = entry
    lock.unlock()

    guard let handle = try? FileHandle(forReadingFrom: dataURL(key)) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: UInt64(range.lowerBound))
    let wanted = Int(range.upperBound - range.lowerBound)
    let data = try? handle.read(upToCount: wanted)
    // A short read means the file and the index disagree, which is a corrupt
    // entry rather than a miss — drop it so the next attempt refetches. This
    // one encoding, not the whole track: the other one is a separate file and
    // has done nothing wrong.
    guard let data, data.count == wanted else { drop(key); return nil }
    return data
  }

  /// Store bytes at `offset`, growing the file as needed. `totalBytes` is the
  /// length the server declared for the stream these bytes came out of, and it
  /// decides which entry they land in.
  public func write(_ id: MediaId, offset: Int64, data: Data, totalBytes: Int64) {
    // A stream with no stated length has no identity here, so there is no
    // entry it can safely be filed under. Nothing reaches this with one — the
    // ranged transport always has a length and the sequential one is not
    // cached — but an entry keyed on zero would be the one entry every
    // length-less stream shared, which is the fault this class was just fixed
    // for.
    guard !data.isEmpty, totalBytes > 0 else { return }

    let key = CacheKey(id: id, streamBytes: totalBytes)
    let url = dataURL(key)
    let manager = FileManager.default

    if !manager.fileExists(atPath: url.path) {
      manager.createFile(atPath: url.path, contents: nil)
      // Sparse: the file is declared full-size up front and the holes cost
      // nothing until written. Growing it per range instead would rewrite the
      // tail every time a gap earlier on was filled.
      if let handle = try? FileHandle(forWritingTo: url) {
        try? handle.truncate(atOffset: UInt64(totalBytes))
        try? handle.close()
      }
    }

    /*
     Every step checked, because the index is a claim about the file.

     These were four `try?`s in a row, and the last of them mattered: the file
     is truncated to full size up front, so a write that fails — a full disk,
     which is the ordinary way this fails on a phone — leaves a correctly-sized
     region of *zeros* where the index then records bytes as present. `read`
     only rejects a short read, not a zeroed one, so the parser is later handed
     silence and the entry survives an app restart. The track is broken until
     something evicts it, and it looks like a corrupt library rather than a
     disk that filled up.

     A cache is allowed to fail to store something. It is not allowed to
     remember storing something it did not.
    */
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    do {
      try handle.seek(toOffset: UInt64(offset))
      try handle.write(contentsOf: data)
      try handle.close()
    } catch {
      try? handle.close()
      return
    }

    lock.lock()
    // There used to be an `entry.totalBytes = totalBytes` here, one line below
    // the lookup, and it was the fault: it accepted a new stream's length onto
    // an entry whose ranges had been recorded against the old one's bytes.
    // There is nothing to assign now — the length is in the key, so an entry
    // found here was filed under this length and an entry not found here is
    // created at it. A range recorded in an entry can only have come from a
    // stream of the entry's own length, which is the invariant the whole file
    // rests on.
    var entry = index[key] ?? Entry(totalBytes: totalBytes, ranges: [], lastUsed: 0)
    var present = entry.present
    present.insert(offset..<(offset + Int64(data.count)))
    entry.setPresent(present)
    entry.lastUsed = Date().timeIntervalSince1970
    index[key] = entry
    lock.unlock()

    persist(key)
    evictIfNeeded()
  }

  // MARK: - Eviction

  private func evictIfNeeded() {
    lock.lock()
    var used = index.values.reduce(Int64(0)) { $0 + $1.byteCount }
    guard used > maxBytes else { lock.unlock(); return }
    // Oldest first. Ties broken by key so eviction is deterministic, which
    // matters only for the tests but costs nothing here.
    let victims = index.sorted {
      $0.value.lastUsed == $1.value.lastUsed ? $0.key < $1.key : $0.value.lastUsed < $1.value.lastUsed
    }
    var dropped: [CacheKey] = []
    for (key, entry) in victims {
      guard used > maxBytes else { break }
      used -= entry.byteCount
      index[key] = nil
      dropped.append(key)
    }
    lock.unlock()

    for key in dropped { removeFiles(key) }
  }

  /// Forget one entry and take its files with it. Never called with `lock`
  /// held — it takes the lock itself.
  private func drop(_ key: CacheKey) {
    lock.lock()
    index[key] = nil
    lock.unlock()
    removeFiles(key)
  }

  private func removeFiles(_ key: CacheKey) {
    try? FileManager.default.removeItem(at: dataURL(key))
    try? FileManager.default.removeItem(at: metaURL(key))
  }

  // MARK: - On-disk layout

  /**
   The separator between the encoded id and the stream length in a filename.

   Safe as one character because `safeName` below emits nothing but letters,
   digits and `%`, so the last `-` in a stem is always this one and never part
   of an id. It doubles as the marker that tells a post-fix file from a
   pre-fix one, which is what `loadIndex` uses to clear the old cache out.
   */
  private static let variantSeparator: Character = "-"

  // Ids come from a server and can contain anything; a percent-encoded name
  // keeps one from escaping the directory or colliding with a sidecar. The
  // fallback is base-36 of an unsigned hash rather than of `hashValue`, which
  // is signed and would put a leading `-` in a name the separator above is
  // parsed out of. Unreachable in practice — percent-encoding a `String`
  // against `.alphanumerics` does not fail — and cheaper to make impossible
  // than to reason about.
  private func safeName(_ id: MediaId) -> String {
    id.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
      ?? String(UInt(bitPattern: id.hashValue), radix: 36)
  }

  private func fileStem(_ key: CacheKey) -> String {
    "\(safeName(key.id))\(Self.variantSeparator)\(key.streamBytes)"
  }

  private func dataURL(_ key: CacheKey) -> URL {
    directory.appendingPathComponent(fileStem(key) + ".audio")
  }

  private func metaURL(_ key: CacheKey) -> URL {
    directory.appendingPathComponent(fileStem(key) + ".json")
  }

  /// `fileStem` in reverse. Nil for anything this version did not write,
  /// which includes every file the pre-fix cache left behind.
  private static func key(fromStem stem: String) -> CacheKey? {
    guard let separator = stem.lastIndex(of: variantSeparator) else { return nil }
    guard let streamBytes = Int64(stem[stem.index(after: separator)...]), streamBytes > 0 else {
      return nil
    }
    guard let id = String(stem[stem.startIndex..<separator]).removingPercentEncoding else {
      return nil
    }
    return CacheKey(id: id, streamBytes: streamBytes)
  }

  private func persist(_ key: CacheKey) {
    lock.lock(); let entry = index[key]; lock.unlock()
    guard let entry, let data = try? JSONEncoder().encode(entry) else { return }
    try? data.write(to: metaURL(key))
  }

  /**
   Rebuild the index from the sidecars, and throw away anything that cannot be
   proved to belong to a known stream.

   **This is where the existing caches on people's phones are dealt with, and
   they are deleted rather than adopted.** A pre-fix entry is named after its
   id alone and records one `totalBytes` — the last one written — against
   ranges that may have been fetched from any number of encodings before it.
   There is no way to tell from the outside which bytes in such a file came
   from which stream, so renaming it into the new scheme would be filing a
   mixture under one of the lengths that went into it and calling it clean.
   That is the bug, preserved through the upgrade, and it would be preserved
   in exactly the entries people have already been listening to. A cache is
   regenerable; the only honest migration is to drop it and pay for the
   refetch once.

   `DiskCache` owns this directory outright, so anything in it that does not
   parse as a current filename is the previous scheme, a half-written pair, or
   something that has no business being here, and all three want removing.
   */
  private func loadIndex() {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return }

    for name in names {
      let url = directory.appendingPathComponent(name)
      guard let key = Self.key(fromStem: (name as NSString).deletingPathExtension) else {
        try? manager.removeItem(at: url)
        continue
      }
      // The audio half is carried by its sidecar, below, and never loaded on
      // its own — a `.audio` whose sidecar has gone describes nothing.
      guard name.hasSuffix(".json") else { continue }

      // The filename and the sidecar both state the length, and the entry is
      // loaded only when they agree. They can disagree only if something
      // outside this class has been in the directory, and an entry of unclear
      // provenance is exactly what must not reach a decoder.
      guard let data = try? Data(contentsOf: url),
            let entry = try? JSONDecoder().decode(Entry.self, from: data),
            entry.totalBytes == key.streamBytes
      else {
        try? manager.removeItem(at: url)
        continue
      }
      // Only trust a sidecar whose audio is still there. A half-deleted pair
      // would otherwise report bytes that cannot be read.
      guard manager.fileExists(atPath: dataURL(key).path) else {
        try? manager.removeItem(at: url)
        continue
      }
      index[key] = entry
    }
  }
}
