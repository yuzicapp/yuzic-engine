import XCTest
@testable import YuzicEngineCore

/// A fetcher over an in-memory blob that counts what was asked for. Stands in
/// for the network so these tests are deterministic and fast.
///
/// Locked throughout, because read-ahead fetches from its own queue: a source
/// with a duration has two threads reaching this object, and an unguarded
/// `fetched.append` between them is a crash the suite would report as a
/// mysterious flake rather than as the race it is.
final class FakeFetcher: ByteFetcher, @unchecked Sendable {
  let blob: Data
  private let lock = NSLock()
  private var fetchedRanges: [Range<Int64>] = []
  var fetched: [Range<Int64>] {
    lock.lock(); defer { lock.unlock() }
    return fetchedRanges
  }
  /// Set to fail the next fetch, to exercise the error path.
  var failNext: Bool {
    get { lock.lock(); defer { lock.unlock() }; return failNextValue }
    set { lock.lock(); failNextValue = newValue; lock.unlock() }
  }
  private var failNextValue = false
  /// Blocks every fetch until signalled, so a test can hold read-ahead still
  /// and look at it mid-flight.
  var gate: DispatchSemaphore?

  /// Filled through a pointer rather than `Data`'s subscript. The read-ahead
  /// tests need fixtures of a few megabytes to have anything to read ahead
  /// *into*, and per-byte subscripting on `Data` takes seconds at that size —
  /// which is how a suite stops being run.
  init(bytes: Int) {
    var data = Data(count: bytes)
    data.withUnsafeMutableBytes { raw in
      guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
      for index in 0..<bytes { base[index] = UInt8(index % 251) }
    }
    blob = data
  }

  func contentLength() throws -> Int64 { Int64(blob.count) }

  func fetch(_ range: Range<Int64>) throws -> Data {
    lock.lock()
    if failNextValue {
      failNextValue = false
      lock.unlock()
      throw ByteSourceError.fetchFailed("injected")
    }
    fetchedRanges.append(range)
    lock.unlock()

    gate?.wait()

    let end = min(Int(range.upperBound), blob.count)
    guard Int(range.lowerBound) < end else { return Data() }
    return blob.subdata(in: Int(range.lowerBound)..<end)
  }

  var bytesFetched: Int64 { fetched.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) } }
}

final class CachedByteSourceTests: XCTestCase {

  private func makeSource(bytes: Int = 1_000_000, window: Int64 = 64 * 1024)
    -> (CachedByteSource, FakeFetcher) {
    let fetcher = FakeFetcher(bytes: bytes)
    return (CachedByteSource(fetcher: fetcher, windowBytes: window), fetcher)
  }

  func testReadsReturnTheRightBytes() throws {
    let (source, fetcher) = makeSource()
    let data = try source.read(offset: 1000, count: 256)
    XCTAssertEqual(data, fetcher.blob.subdata(in: 1000..<1256))
  }

  func testSizeIsReportedInFullBeforeAnythingIsFetched() throws {
    let (source, _) = makeSource(bytes: 1_000_000)
    // The lie the whole design rests on: the parser is told the file is whole
    // so that a seek to the end is an ordinary read.
    XCTAssertEqual(try source.totalBytes(), 1_000_000)
    XCTAssertEqual(source.availableBytes(from: 0), 0)
  }

  func testSmallReadsShareOneWindowedFetch() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    // A parser asks for a few bytes at a time; a request per read would be
    // thousands of round trips per track.
    for offset in stride(from: Int64(0), to: 8192, by: 512) {
      _ = try source.read(offset: offset, count: 512)
    }
    XCTAssertEqual(fetcher.fetched.count, 1)
    XCTAssertEqual(fetcher.fetched.first, 0..<65536)
  }

  func testFetchesAreWindowAligned() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 70_000, count: 16)
    // Rounded down to the window boundary rather than starting at the read.
    XCTAssertEqual(fetcher.fetched.first?.lowerBound, 65536)
  }

  func testSeekingForwardDoesNotFetchTheSkippedRegion() throws {
    let (source, fetcher) = makeSource(bytes: 1_000_000, window: 64 * 1024)
    _ = try source.read(offset: 0, count: 128)
    _ = try source.read(offset: 900_000, count: 128)

    // The point of random access: jumping to the end costs one window, not the
    // 900KB in between. This is precisely what Apple's FLAC decoder does *not*
    // do, which is why FLAC needs libFLAC rather than Core Audio.
    XCTAssertEqual(fetcher.bytesFetched, 128 * 1024)
    XCTAssertFalse(fetcher.fetched.contains { $0.lowerBound > 100_000 && $0.upperBound < 800_000 })
  }

  func testAlreadyPresentBytesAreNotRefetched() throws {
    let (source, fetcher) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 0, count: 1024)
    let afterFirst = fetcher.fetched.count
    _ = try source.read(offset: 0, count: 1024)
    _ = try source.read(offset: 2048, count: 1024)
    XCTAssertEqual(fetcher.fetched.count, afterFirst)
  }

  func testReadPastTheEndReturnsEmptyRatherThanFailing() throws {
    let (source, _) = makeSource(bytes: 4096)
    XCTAssertTrue(try source.read(offset: 4096, count: 128).isEmpty)
    // A read that straddles the end is truncated, which Core Audio treats as
    // end-of-file rather than an error.
    XCTAssertEqual(try source.read(offset: 4000, count: 500).count, 96)
  }

  func testTailPrefetchGrabsTheEndFirst() throws {
    let (source, fetcher) = makeSource(bytes: 1_000_000, window: 64 * 1024)
    try source.prefetchTail(bytes: 128 * 1024)

    // Without this an ALAC or AAC file will not open at all until the whole
    // thing has landed: moov sits at the tail of a non-faststart file, and the
    // spike watched the open fail with two of its first ten reads past the
    // fetched region.
    XCTAssertGreaterThan(source.availableBytes(from: 1_000_000 - 128 * 1024), 0)
    XCTAssertTrue(fetcher.fetched.allSatisfy { $0.lowerBound >= 800_000 })
  }

  func testCancellingUnblocksAReadInsteadOfHanging() throws {
    let (source, _) = makeSource()
    source.cancel()
    XCTAssertThrowsError(try source.read(offset: 0, count: 128)) { error in
      XCTAssertEqual(error as? ByteSourceError, .cancelled)
    }
    // And a cancelled source can be put back to work, since a seek cancels the
    // in-flight read and then immediately wants a new one.
    source.resume()
    XCTAssertEqual(try source.read(offset: 0, count: 128).count, 128)
  }

  func testAFailedFetchSurfacesRatherThanSpinning() throws {
    let (source, fetcher) = makeSource()
    fetcher.failNext = true
    XCTAssertThrowsError(try source.read(offset: 0, count: 128))
  }

  func testAvailableBytesTracksWhatLanded() throws {
    let (source, _) = makeSource(window: 64 * 1024)
    _ = try source.read(offset: 0, count: 16)
    XCTAssertEqual(source.availableBytes(from: 0), 65536)
    XCTAssertEqual(source.availableBytes(from: 65536), 0)
  }

  /**
   The case a seek actually hits: the cancel arrives while a window fetch is
   already in flight.

   `testCancellingUnblocksAReadInsteadOfHanging` covers the easy half, where
   the flag is already set when the read begins. This is the half that matters
   — someone scrubbing the progress bar cancels a read that is *waiting on the
   network*, and if the cancel is only observed between fetches, the seek waits
   out the HTTP timeout before the first sample of the new position is asked
   for. The bound has to come from the cancel, not from the request.
   */
  func testCancellingUnblocksAReadAlreadyWaitingOnAFetch() {
    let fetcher = BlockingFetcher(bytes: 1_000_000)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: 64 * 1024)

    let finished = XCTestExpectation(description: "read returns")
    DispatchQueue.global().async {
      do {
        _ = try source.read(offset: 0, count: 128)
        XCTFail("read returned bytes it never fetched")
      } catch {
        XCTAssertEqual(error as? ByteSourceError, .cancelled)
      }
      finished.fulfill()
    }

    XCTAssertEqual(fetcher.entered.wait(timeout: .now() + 2), .success, "fetch never started")
    source.cancel()

    // Two seconds is generous for something that should take microseconds, and
    // still far below the 30s HTTP timeout that is the bound when the cancel
    // does not reach the fetcher.
    XCTAssertEqual(XCTWaiter().wait(for: [finished], timeout: 2), .completed)
  }
}

/// Blocks inside `fetch` until cancelled, the way a real ranged GET blocks on
/// the network. Signals `entered` so a test can cancel at the exact moment a
/// fetch is outstanding.
private final class BlockingFetcher: ByteFetcher, @unchecked Sendable {
  let bytes: Int
  let entered = DispatchSemaphore(value: 0)
  private let released = DispatchSemaphore(value: 0)

  init(bytes: Int) { self.bytes = bytes }

  func contentLength() throws -> Int64 { Int64(bytes) }

  func fetch(_ range: Range<Int64>) throws -> Data {
    entered.signal()
    // Waits effectively forever unless `cancel()` releases it — a fetch that
    // returned on its own would not test anything.
    released.wait()
    throw ByteSourceError.cancelled
  }

  func cancel() { released.signal() }
}

/// The point of the disk cache, from the reader's side: a second play does not
/// go back to the network.
final class CachedByteSourceDiskTests: XCTestCase {

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("yuzic-source-cache-\(UUID().uuidString)")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  func testASecondSourceOverTheSameIdServesFromDisk() throws {
    let cache = try DiskCache(directory: directory)

    let first = FakeFetcher(bytes: 500_000)
    let warm = CachedByteSource(fetcher: first, windowBytes: 64 * 1024, cache: cache, cacheId: "track-1")
    _ = try warm.read(offset: 0, count: 1024)
    XCTAssertGreaterThan(first.fetched.count, 0, "the first play has to fetch something")

    // A new source, a new fetcher, same id — a later session playing the same
    // track. Nothing should reach the network.
    let second = FakeFetcher(bytes: 500_000)
    let cold = CachedByteSource(fetcher: second, windowBytes: 64 * 1024, cache: cache, cacheId: "track-1")
    let data = try cold.read(offset: 0, count: 1024)

    XCTAssertEqual(data, first.blob.subdata(in: 0..<1024))
    XCTAssertTrue(second.fetched.isEmpty, "went to the network for bytes it had on disk")
  }

  func testADifferentIdDoesNotShareBytes() throws {
    let cache = try DiskCache(directory: directory)

    let one = FakeFetcher(bytes: 200_000)
    let a = CachedByteSource(fetcher: one, windowBytes: 64 * 1024, cache: cache, cacheId: "track-a")
    _ = try a.read(offset: 0, count: 512)

    let two = FakeFetcher(bytes: 200_000)
    let b = CachedByteSource(fetcher: two, windowBytes: 64 * 1024, cache: cache, cacheId: "track-b")
    _ = try b.read(offset: 0, count: 512)

    XCTAssertFalse(two.fetched.isEmpty, "track-b was served track-a's audio")
  }

  func testWithoutACacheNothingIsWrittenAnywhere() throws {
    let fetcher = FakeFetcher(bytes: 100_000)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: 64 * 1024)
    _ = try source.read(offset: 0, count: 512)
    // The pre-cache behaviour still has to work: hosts that never configure a
    // cache, and every other test in this file, run through this path.
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testEvictingSendsTheNextReadBackToTheNetwork() throws {
    let cache = try DiskCache(directory: directory)
    let first = FakeFetcher(bytes: 200_000)
    let warm = CachedByteSource(fetcher: first, windowBytes: 64 * 1024, cache: cache, cacheId: "track-1")
    _ = try warm.read(offset: 0, count: 512)

    cache.evict("track-1")

    let second = FakeFetcher(bytes: 200_000)
    let cold = CachedByteSource(fetcher: second, windowBytes: 64 * 1024, cache: cache, cacheId: "track-1")
    _ = try cold.read(offset: 0, count: 512)
    XCTAssertFalse(second.fetched.isEmpty, "evict did not actually remove the audio")
  }
}
