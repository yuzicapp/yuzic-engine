import XCTest
@testable import YuzicEngineCore

/**
 The disk cache.

 A cache is only useful if it is honest, so most of what follows is about the
 ways it could lie: claiming a range it does not hold, serving bytes from a
 hole, keeping a sidecar whose audio has gone, reporting space it has not
 actually freed, or — the one that took longest to find — answering with bytes
 that really are cached and really are under that id and are nonetheless the
 wrong audio. A cache that merely *usually* works produces bugs that look like
 corrupt audio, which is the hardest kind to trace back to here.
 */
final class DiskCacheTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-cache-tests-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private func makeCache(maxBytes: Int64 = 1_000_000) throws -> DiskCache {
    try DiskCache(directory: directory, maxBytes: maxBytes)
  }

  private func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
    Data((0..<count).map { UInt8(($0 &+ Int(seed)) % 251) })
  }

  // MARK: - Holding what it says it holds

  func testReadsBackWhatWasWritten() throws {
    let cache = try makeCache()
    let payload = bytes(512)
    cache.write("t1", offset: 0, data: payload, totalBytes: 2048)
    XCTAssertEqual(cache.read("t1", range: 0..<512, totalBytes: 2048), payload)
  }

  func testServesASubrangeOfWhatItHolds() throws {
    let cache = try makeCache()
    let payload = bytes(512)
    cache.write("t1", offset: 0, data: payload, totalBytes: 2048)
    XCTAssertEqual(cache.read("t1", range: 100..<200, totalBytes: 2048),
                   payload.subdata(in: 100..<200))
  }

  func testRefusesARangeItOnlyPartlyHolds() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(512), totalBytes: 2048)
    // The second half was never fetched. Serving zeroes here is the failure
    // that sounds like a corrupt file rather than a cache miss.
    XCTAssertNil(cache.read("t1", range: 0..<1024, totalBytes: 2048))
  }

  func testRefusesAcrossAHole() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(256), totalBytes: 2048)
    cache.write("t1", offset: 1024, data: bytes(256, seed: 9), totalBytes: 2048)
    XCTAssertNil(cache.read("t1", range: 0..<1280, totalBytes: 2048))
    // But either side on its own is fine.
    XCTAssertNotNil(cache.read("t1", range: 0..<256, totalBytes: 2048))
    XCTAssertNotNil(cache.read("t1", range: 1024..<1280, totalBytes: 2048))
  }

  func testWritingEitherSideOfAHoleClosesIt() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(256), totalBytes: 2048)
    cache.write("t1", offset: 512, data: bytes(256), totalBytes: 2048)
    XCTAssertNil(cache.read("t1", range: 0..<768, totalBytes: 2048))
    cache.write("t1", offset: 256, data: bytes(256), totalBytes: 2048)
    XCTAssertNotNil(cache.read("t1", range: 0..<768, totalBytes: 2048))
  }

  /**
   A write that fails is not recorded as a write that happened.

   The file is truncated to its full size the moment the entry is created, so
   the bytes a failed write did not deliver are not missing — they are zeros,
   and they are exactly as long as the real ones. The index used to record the
   range as present regardless, and `read` only rejects a *short* read, never a
   zeroed one. The parser was then handed silence, and because the sidecar is
   persisted the entry survived a restart: a track broken forever, looking like
   a corrupt library rather than a disk that had filled up.

   Forced with `RLIMIT_FSIZE`, which is what a full disk looks like from inside
   a process — the open succeeds and the write returns EFBIG. `SIGXFSZ` is
   ignored first, or exceeding the limit kills the test runner instead of
   returning an error.
   */
  func testAFailedWriteIsNotRecordedAsPresent() throws {
    let cache = try makeCache()

    // A successful write first, so the entry and its file exist.
    cache.write("track", offset: 0, data: bytes(64), totalBytes: 40_000)
    XCTAssertNotNil(cache.read("track", range: 0..<64, totalBytes: 40_000),
                    "setup failed: the good write did not land")

    let previous = signal(SIGXFSZ, SIG_IGN)
    var limits = rlimit()
    getrlimit(RLIMIT_FSIZE, &limits)
    let originalLimit = limits.rlim_cur
    defer {
      limits.rlim_cur = originalLimit
      setrlimit(RLIMIT_FSIZE, &limits)
      signal(SIGXFSZ, previous)
    }

    // Anything written past 4KB now fails at the write, not at the open.
    limits.rlim_cur = 4096
    guard setrlimit(RLIMIT_FSIZE, &limits) == 0 else {
      throw XCTSkip("could not lower RLIMIT_FSIZE on this machine")
    }

    cache.write("track", offset: 20_000, data: bytes(64, seed: 9), totalBytes: 40_000)

    XCTAssertNil(cache.read("track", range: 20_000..<20_064, totalBytes: 40_000),
                 "the cache recorded a range it never managed to write — a later read "
                 + "would be served zeros as though they were audio")
  }

  func testAMissIsNilRatherThanEmpty() throws {
    let cache = try makeCache()
    XCTAssertNil(cache.read("never-seen", range: 0..<10, totalBytes: 2048))
    XCTAssertNil(cache.ranges(for: "never-seen", totalBytes: 2048))
  }

  /// A stream with no declared length has no identity to be filed under, so
  /// there is no entry it can safely share with anything. Storing it under a
  /// length of zero would make one entry that every length-less stream wrote
  /// into, which is the fault below with extra steps.
  func testAStreamWithNoDeclaredLengthIsNotStoredAtAll() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(128), totalBytes: 0)
    XCTAssertEqual(cache.stats().entryCount, 0)
    XCTAssertNil(cache.read("t1", range: 0..<128, totalBytes: 0))
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(left.isEmpty, "left behind: \(left)")
  }

  // MARK: - One id, two byte streams

  /**
   The fault this key was changed for.

   yuzic sends `format`/`maxBitRate` for every quality except Original and the
   setting is per-network, so one `MediaId` is a lossless file on WiFi and a
   transcode on cellular. The entry used to take the new stream's length and
   keep the old stream's ranges, so the second play was handed the first
   play's bytes for any window the first play had already fetched — which
   decodes to nothing, which `AudioFileReader` reports as a zero-frame read,
   which `TrackPlayback` reads as the end of the track. A song stopping in the
   middle with a clean ending and no error anywhere.

   Written the way the bug happened: the second stream's write comes first,
   and *then* the first stream asks for a window it never fetched.
   */
  func testAStreamOfADifferentLengthIsNeverServedTheOtherOnesBytes() throws {
    let cache = try makeCache()

    // The cellular play: a 192kbps transcode, most of a megabyte.
    cache.write("same-track", offset: 0, data: bytes(512, seed: 7), totalBytes: 800_000)
    XCTAssertNotNil(cache.read("same-track", range: 0..<512, totalBytes: 800_000),
                    "setup failed: the transcode's own window did not land")

    // Back on WiFi at Original: the same id, a lossless file, nothing of it
    // fetched yet. This has to miss.
    XCTAssertNil(cache.read("same-track", range: 0..<512, totalBytes: 9_000_000),
                 "served one encoding's bytes into a decode of another — the track "
                 + "would stop part-way through and the queue would move on")
    XCTAssertNil(cache.ranges(for: "same-track", totalBytes: 9_000_000))
  }

  /// And the ranges do not leak the other way either: filling the lossless
  /// entry must not make the transcode's entry claim to hold anything more
  /// than the one window it actually fetched.
  func testFillingOneEncodingDoesNotExtendTheOther() throws {
    let cache = try makeCache()
    cache.write("same-track", offset: 0, data: bytes(512, seed: 7), totalBytes: 800_000)
    cache.write("same-track", offset: 0, data: bytes(4096), totalBytes: 9_000_000)

    XCTAssertEqual(cache.ranges(for: "same-track", totalBytes: 800_000)?.present.ranges, [0..<512])
    XCTAssertEqual(cache.ranges(for: "same-track", totalBytes: 9_000_000)?.present.ranges, [0..<4096])
    XCTAssertNil(cache.read("same-track", range: 512..<4096, totalBytes: 800_000))
  }

  /**
   Both encodings are kept, rather than the newer one replacing the older.

   The cheaper fix was to throw the entry away whenever the length changed,
   and it would have closed the fault just as well. It was not taken because
   the quality setting is *per-network*: a listener who walks out of the house
   and back in would empty and refill their cache on every trip, which is a
   cache that costs bandwidth instead of saving it. Two entries, and the
   ordinary LRU decides which survives when space runs short.
   */
  func testBothEncodingsSurviveSideBySide() throws {
    let cache = try makeCache()
    let transcode = bytes(512, seed: 7)
    let lossless = bytes(512)

    cache.write("same-track", offset: 0, data: transcode, totalBytes: 800_000)
    cache.write("same-track", offset: 0, data: lossless, totalBytes: 9_000_000)

    XCTAssertEqual(cache.read("same-track", range: 0..<512, totalBytes: 800_000), transcode)
    XCTAssertEqual(cache.read("same-track", range: 0..<512, totalBytes: 9_000_000), lossless)
    XCTAssertEqual(cache.stats().entryCount, 2)
  }

  /// `evict` answers a host that deleted a track, so it has to take the track
  /// — every encoding of it. Leaving one quality behind is the cache saying it
  /// freed space it did not.
  func testEvictingATrackTakesEveryEncodingOfIt() throws {
    let cache = try makeCache()
    cache.write("gone", offset: 0, data: bytes(128), totalBytes: 800_000)
    cache.write("gone", offset: 0, data: bytes(128), totalBytes: 9_000_000)
    cache.write("kept", offset: 0, data: bytes(128), totalBytes: 800_000)

    cache.evict("gone")

    XCTAssertNil(cache.read("gone", range: 0..<128, totalBytes: 800_000))
    XCTAssertNil(cache.read("gone", range: 0..<128, totalBytes: 9_000_000))
    XCTAssertNotNil(cache.read("kept", range: 0..<128, totalBytes: 800_000))
    XCTAssertEqual(cache.stats().entryCount, 1)
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(left.count, 2, "left behind: \(left)")
  }

  // MARK: - Surviving a relaunch

  func testRangesSurviveReopening() throws {
    let first = try makeCache()
    first.write("t1", offset: 128, data: bytes(256), totalBytes: 4096)

    // A new instance over the same directory is what a relaunch looks like.
    let second = try makeCache()
    let held = second.ranges(for: "t1", totalBytes: 4096)
    XCTAssertEqual(held?.total, 4096)
    XCTAssertEqual(held?.present.ranges, [128..<384])
    XCTAssertNotNil(second.read("t1", range: 128..<384, totalBytes: 4096))
  }

  func testBothEncodingsSurviveReopeningSeparately() throws {
    let first = try makeCache()
    first.write("t1", offset: 0, data: bytes(256, seed: 3), totalBytes: 4096)
    first.write("t1", offset: 0, data: bytes(256), totalBytes: 80_000)

    // The pair has to come back as a pair: a naming scheme that could not tell
    // them apart on disk would have one silently overwrite the other's file
    // while the index went on describing both.
    let second = try makeCache()
    XCTAssertEqual(second.stats().entryCount, 2)
    XCTAssertEqual(second.read("t1", range: 0..<256, totalBytes: 4096), bytes(256, seed: 3))
    XCTAssertEqual(second.read("t1", range: 0..<256, totalBytes: 80_000), bytes(256))
  }

  func testASidecarWithoutItsAudioIsDiscarded() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(128), totalBytes: 128)
    // Half-deleted pairs happen: a purge interrupted, a crash mid-write. The
    // index must not report bytes that cannot be read.
    let audio = directory.appendingPathComponent("t1-128.audio")
    XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path),
                  "setup failed: the audio is not where the naming scheme says it is")
    try FileManager.default.removeItem(at: audio)

    let reopened = try makeCache()
    XCTAssertNil(reopened.ranges(for: "t1", totalBytes: 128))
    XCTAssertEqual(reopened.stats().entryCount, 0)
  }

  // MARK: - The caches that already exist

  /// A sidecar in the scheme that shipped before the key carried a length:
  /// named after the id alone, and recording whatever `totalBytes` was written
  /// last.
  private func writePreFixEntry(id: String, totalBytes: Int64, ranges: [Int64], audio: Data) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try audio.write(to: directory.appendingPathComponent("\(id).audio"))
    let pairs: [String] = ranges.map { String($0) }
    let flat = pairs.joined(separator: ",")
    let sidecar = "{\"totalBytes\":\(totalBytes),\"ranges\":[\(flat)],\"lastUsed\":1}"
    try Data(sidecar.utf8).write(to: directory.appendingPathComponent("\(id).json"))
  }

  /**
   An entry written before the fix is not adopted, at any length.

   This is the half of the fix that decides whether it reaches anybody. The
   entries already on people's phones are the ones the fault was reported
   against — a pre-fix entry records one length against ranges that may have
   come from several encodings, and nothing on the outside can say which bytes
   came from which. Trusting it at its recorded length would carry the bug
   through the upgrade and into exactly the tracks that were already breaking.
   */
  func testAnEntryFromBeforeTheFixIsNotTrusted() throws {
    try writePreFixEntry(id: "t1", totalBytes: 2048, ranges: [0, 512], audio: bytes(512))

    let cache = try makeCache()

    XCTAssertNil(cache.ranges(for: "t1", totalBytes: 2048))
    XCTAssertNil(cache.read("t1", range: 0..<512, totalBytes: 2048),
                 "adopted an entry whose bytes cannot be attributed to any one stream")
    XCTAssertEqual(cache.stats().entryCount, 0)
  }

  /// And it is cleared out rather than left to sit there. An unreadable entry
  /// that still occupies disk is the cache holding storage it will never use
  /// and never reports — `stats` counts the index, and the index no longer
  /// knows about it.
  func testAnEntryFromBeforeTheFixIsDeletedFromDisk() throws {
    try writePreFixEntry(id: "t1", totalBytes: 2048, ranges: [0, 512], audio: bytes(512))
    try writePreFixEntry(id: "t2", totalBytes: 4096, ranges: [0, 256], audio: bytes(256))

    _ = try makeCache()

    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(left.isEmpty, "the old cache was left on disk unreachable: \(left)")
  }

  /// The migration must not take the new entries with it. A cache opened twice
  /// — which is every relaunch after the first — has to keep what the first
  /// run wrote.
  func testTheMigrationLeavesCurrentEntriesAlone() throws {
    try writePreFixEntry(id: "old", totalBytes: 2048, ranges: [0, 512], audio: bytes(512))
    let first = try makeCache()
    first.write("new", offset: 0, data: bytes(256), totalBytes: 4096)

    let second = try makeCache()
    XCTAssertEqual(second.stats().entryCount, 1)
    XCTAssertNotNil(second.read("new", range: 0..<256, totalBytes: 4096))
    XCTAssertNil(second.read("old", range: 0..<512, totalBytes: 2048))
  }

  /// The filename and the sidecar both state the length, and an entry is only
  /// loaded when they agree. They can disagree only if something outside this
  /// class has been in the directory, and an entry of unclear provenance is
  /// precisely what must not reach a decoder.
  func testASidecarThatContradictsItsOwnFilenameIsDiscarded() throws {
    let cache = try makeCache()
    cache.write("t1", offset: 0, data: bytes(256), totalBytes: 4096)

    let sidecar = directory.appendingPathComponent("t1-4096.json")
    try Data("{\"totalBytes\":9999,\"ranges\":[0,256],\"lastUsed\":1}".utf8).write(to: sidecar)

    let reopened = try makeCache()
    XCTAssertEqual(reopened.stats().entryCount, 0)
    XCTAssertNil(reopened.read("t1", range: 0..<256, totalBytes: 4096))
    XCTAssertNil(reopened.read("t1", range: 0..<256, totalBytes: 9999))
  }

  // MARK: - Eviction

  func testEvictingOneTrackLeavesTheOthers() throws {
    let cache = try makeCache()
    cache.write("keep", offset: 0, data: bytes(128), totalBytes: 128)
    cache.write("drop", offset: 0, data: bytes(128), totalBytes: 128)

    cache.evict("drop")
    XCTAssertNil(cache.read("drop", range: 0..<128, totalBytes: 128))
    XCTAssertNotNil(cache.read("keep", range: 0..<128, totalBytes: 128))
    XCTAssertEqual(cache.stats().entryCount, 1)
  }

  func testClearRemovesEverythingIncludingTheFiles() throws {
    let cache = try makeCache()
    cache.write("a", offset: 0, data: bytes(128), totalBytes: 128)
    cache.write("b", offset: 0, data: bytes(128), totalBytes: 128)

    cache.clear()
    XCTAssertEqual(cache.stats().entryCount, 0)
    XCTAssertEqual(cache.stats().usedBytes, 0)
    // Reporting freed space while leaving the bytes on disk is the specific
    // dishonesty worth a test: the user asked for their storage back.
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(left.isEmpty, "left behind: \(left)")
  }

  func testExceedingTheBudgetEvictsTheLeastRecentlyUsed() throws {
    let cache = try makeCache(maxBytes: 300)
    cache.write("old", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)
    cache.write("new", offset: 0, data: bytes(200), totalBytes: 200)

    // 400 bytes against a 300 budget: the older one goes.
    XCTAssertNil(cache.read("old", range: 0..<200, totalBytes: 200))
    XCTAssertNotNil(cache.read("new", range: 0..<200, totalBytes: 200))
  }

  /**
   Reading refreshes recency, so it is *used* rather than *written* that
   decides. Needs three entries to show it: with two, the one being read is
   still older than the one being written, and both policies would evict the
   same thing.

   Without this, a track on repeat would be evicted while it played.
   */
  func testReadingSomethingKeepsItAliveAheadOfSomethingOlder() throws {
    let cache = try makeCache(maxBytes: 500)
    cache.write("a", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)
    cache.write("b", offset: 0, data: bytes(200), totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)

    // `a` is the oldest by write time, and now the newest by use.
    _ = cache.read("a", range: 0..<200, totalBytes: 200)
    Thread.sleep(forTimeInterval: 0.01)

    // 600 bytes against 500: exactly one has to go, and it should be `b`.
    cache.write("c", offset: 0, data: bytes(200), totalBytes: 200)

    XCTAssertNotNil(cache.read("a", range: 0..<200, totalBytes: 200),
                    "reading it should have saved it")
    XCTAssertNil(cache.read("b", range: 0..<200, totalBytes: 200),
                 "b was the least recently used")
    XCTAssertNotNil(cache.read("c", range: 0..<200, totalBytes: 200))
  }

  func testLoweringTheBudgetEvictsImmediately() throws {
    let cache = try makeCache(maxBytes: 1_000_000)
    cache.write("a", offset: 0, data: bytes(400), totalBytes: 400)
    XCTAssertEqual(cache.stats().usedBytes, 400)

    cache.configure(maxBytes: 100)
    XCTAssertEqual(cache.stats().usedBytes, 0)
    XCTAssertEqual(cache.stats().maxBytes, 100)
  }

  // MARK: - Stats

  func testStatsCountOnlyBytesActuallyHeld() throws {
    let cache = try makeCache()
    // A ten-megabyte track with one kilobyte fetched is one kilobyte of cache,
    // not ten megabytes — the file is sparse and the holes cost nothing.
    cache.write("t1", offset: 0, data: bytes(1024), totalBytes: 10_000_000)
    XCTAssertEqual(cache.stats().usedBytes, 1024)
    XCTAssertEqual(cache.stats().entryCount, 1)
  }

  func testIdsThatLookLikePathsDoNotEscapeTheDirectory() throws {
    let cache = try makeCache()
    cache.write("../../etc/passwd", offset: 0, data: bytes(16), totalBytes: 16)
    XCTAssertNotNil(cache.read("../../etc/passwd", range: 0..<16, totalBytes: 16))
    // Whatever it was named, it landed here and nowhere else.
    let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertEqual(left.count, 2)
  }

  /// An id with a `-` in it — Jellyfin's are UUIDs, so this is the common case
  /// rather than a contrived one. The separator between the id and the length
  /// has to survive it, or a whole server's worth of tracks would be filed
  /// under a mangled id and then fail to come back after a relaunch.
  func testAnIdContainingTheSeparatorStillRoundTrips() throws {
    let id = "8f14e45f-ceea-467a-9575-0b3a10c1f2d1"
    let first = try makeCache()
    first.write(id, offset: 0, data: bytes(256), totalBytes: 4096)

    let second = try makeCache()
    XCTAssertEqual(second.stats().entryCount, 1)
    XCTAssertEqual(second.read(id, range: 0..<256, totalBytes: 4096), bytes(256))
  }
}
