import XCTest
@testable import YuzicEngineCore

/**
 Fetching before the decoder asks.

 The engine fetched purely on demand: `ensure` went to the network only for
 bytes a read had already arrived wanting, and `TrackPlayback` stops decoding
 once it is a couple of seconds ahead — so nothing ever ran ahead of the
 decoder. The whole cushion between a listener and their network was those two
 seconds of PCM, against a 256KB window that is about two seconds of FLAC. A
 round trip was due roughly every two seconds of playback, with two seconds to
 cover it, and a link having a bad minute produced exactly what was reported:
 the music stopping and coming back, at no particular point, over the network
 only, with nothing failing anywhere. `docs/architecture.md` §12 has the long
 version.

 These are about the fetch policy rather than the audio: that read-ahead runs,
 stays within its bounds, follows a seek, does not duplicate a window the
 decoder has already pulled, and stops when told.

 Read-ahead needs a duration to size itself — see `CachedByteSource.durationSec`
 — so a source built without one behaves exactly as it always did, which is
 what `CachedByteSourceTests` continues to check.
 */
final class ReadAheadTests: XCTestCase {

  /// 60s of "1MB/s audio" — 8 Mbps, roughly a hi-res lossless stream, chosen
  /// so a second is a megabyte and the arithmetic in these tests is legible.
  private static let seconds = 60.0
  private static let bytesPerSecond = 1_000_000

  private func makeSource(
    seconds: Double = ReadAheadTests.seconds,
    window: Int64 = 256 * 1024,
    duration: Double? = ReadAheadTests.seconds
  ) -> (CachedByteSource, FakeFetcher) {
    let fetcher = FakeFetcher(bytes: Int(seconds) * Self.bytesPerSecond)
    let source = CachedByteSource(
      fetcher: fetcher, windowBytes: window, durationSec: duration
    )
    return (source, fetcher)
  }

  /// Read-ahead runs on its own queue, so what it has done is a moving target.
  private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /// Let whatever is in flight land. There is no condition to wait on: these
  /// assertions are about where read-ahead *stopped*, which needs it stopped.
  private func quiesce(_ seconds: TimeInterval = 1) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /**
   One small read pulls the window ahead of it in behind.

   The behaviour the engine did not have. Before this, reading 512 bytes
   fetched one 256KB window and stopped, and the next window was not asked for
   until the decoder had consumed its way to the end of this one — which is
   when a listener can least afford to wait for it.
   */
  func testAReadPullsTheRegionAheadOfItInBehind() throws {
    let (source, _) = makeSource()
    _ = try source.read(offset: 0, count: 512)

    // The cap is `maxReadAheadBytes` here: 30s of this fixture is 30MB, well
    // past the ceiling, so 8MB is the figure to expect.
    settle { source.availableBytes(from: 0) >= CachedByteSource.maxReadAheadBytes }
    XCTAssertGreaterThanOrEqual(
      source.availableBytes(from: 0), CachedByteSource.maxReadAheadBytes,
      "a read should leave the region ahead of it fetched, not just its own window"
    )
  }

  /**
   And stops there.

   Read-ahead that ran to the end of the file would be a download, not a
   cushion: it would spend a listener's cellular data on a track they may skip
   in five seconds, and on a long album track it would hold the whole file.
   */
  func testReadAheadStopsAtItsBound() throws {
    let (source, fetcher) = makeSource()
    _ = try source.read(offset: 0, count: 512)

    settle { source.availableBytes(from: 0) >= CachedByteSource.maxReadAheadBytes }
    quiesce()

    let fetched = fetcher.bytesFetched
    // Plus a couple of windows: the bound is where read-ahead stops *asking*,
    // and the window it is inside when it gets there is fetched whole.
    XCTAssertLessThanOrEqual(
      fetched, CachedByteSource.maxReadAheadBytes + 512 * 1024,
      "read-ahead overran its bound — fetched \(fetched) bytes"
    )
    XCTAssertLessThan(fetched, Int64(Int(Self.seconds) * Self.bytesPerSecond),
                      "read-ahead fetched the whole file, which is a download")
  }

  /**
   A low-bitrate track gets seconds, not megabytes.

   The bound is a duration converted through the file's own average rate, so a
   podcast at a tenth the bitrate should fetch about a tenth as much for the
   same thirty seconds — rather than a flat byte figure that is a cushion for
   one and most of the file for the other.
   */
  func testTheBoundFollowsTheBitrateRatherThanAFlatSize() throws {
    // 600s of 100KB/s: 30s of read-ahead is 3MB, inside both clamps.
    let fetcher = FakeFetcher(bytes: 600 * 100_000)
    let source = CachedByteSource(fetcher: fetcher, windowBytes: 256 * 1024, durationSec: 600)

    _ = try source.read(offset: 0, count: 512)
    let expected = Int64(100_000 * CachedByteSource.readAheadSeconds)
    settle { source.availableBytes(from: 0) >= expected }
    quiesce()

    XCTAssertGreaterThanOrEqual(source.availableBytes(from: 0), expected)
    XCTAssertLessThan(fetcher.bytesFetched, expected + 512 * 1024,
                      "thirty seconds of a 100KB/s track is about 3MB, not the ceiling")
  }

  /**
   A seek moves the mark rather than leaving read-ahead behind.

   The mark is set from the end of every read, so the jump is one step. Read-
   ahead crawling forward from the old position would spend the listener's
   bandwidth on audio they have just skipped past, and would arrive at the new
   one last.
   */
  func testReadAheadFollowsASeek() throws {
    let (source, _) = makeSource()
    _ = try source.read(offset: 0, count: 512)
    settle { source.availableBytes(from: 0) >= 1_000_000 }

    let seekTo: Int64 = 40_000_000
    _ = try source.read(offset: seekTo, count: 512)
    settle { source.availableBytes(from: seekTo) >= 4_000_000 }

    XCTAssertGreaterThanOrEqual(
      source.availableBytes(from: seekTo), 4_000_000,
      "read-ahead should have moved to where the decoder went"
    )
  }

  /**
   The same window is not fetched twice.

   Read-ahead and the decoder are two threads wanting overlapping regions, and
   the decoder's read goes first because someone is waiting on it. Whichever
   arrives second has to notice the window landed while it queued — otherwise
   read-ahead quietly doubles a listener's data usage, which is the way this
   feature would be worth removing.
   */
  func testAWindowIsNeverFetchedTwice() throws {
    let (source, fetcher) = makeSource()
    _ = try source.read(offset: 0, count: 512)
    settle { source.availableBytes(from: 0) >= CachedByteSource.maxReadAheadBytes }
    quiesce()

    // Read back across everything read-ahead pulled. The request count is
    // *expected* to grow while this runs — each read moves the mark, and
    // read-ahead keeps its bound ahead of wherever the decoder is, so reading
    // at 4MB legitimately asks for windows out at 12MB. What must not happen
    // is the same window being asked for again.
    for offset in stride(from: Int64(0), to: 4_000_000, by: 100_000) {
      let data = try source.read(offset: offset, count: 4096)
      XCTAssertEqual(data.count, 4096, "a byte already fetched came back short")
    }
    quiesce()

    let ranges = fetcher.fetched
    let unique = Set(ranges.map { "\($0.lowerBound)-\($0.upperBound)" })
    XCTAssertEqual(ranges.count, unique.count,
                   "the same window was requested more than once — read-ahead is duplicating the decoder's work")

    // And nothing overlapped, which a uniqueness check on its own would miss.
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    for (earlier, later) in zip(sorted, sorted.dropFirst()) {
      XCTAssertLessThanOrEqual(earlier.upperBound, later.lowerBound,
                               "\(earlier) and \(later) overlap; those bytes were paid for twice")
    }
  }

  /**
   Cancelling stops it.

   `cancel` is what a seek and a pause both reach, and read-ahead that carried
   on afterwards would hold the one fetch slot against the read that actually
   has someone waiting for it.
   */
  func testCancelStopsReadAhead() throws {
    let (source, fetcher) = makeSource()
    let gate = DispatchSemaphore(value: 0)
    fetcher.gate = gate

    // The foreground read is held in the fetcher; read-ahead queues behind it.
    let firstRead = expectation(description: "first read returned")
    DispatchQueue.global().async {
      _ = try? source.read(offset: 0, count: 512)
      firstRead.fulfill()
    }
    // Release only the foreground window.
    gate.signal()
    wait(for: [firstRead], timeout: 5)

    source.cancel()
    // Everything read-ahead might still be parked on.
    for _ in 0..<40 { gate.signal() }
    quiesce()

    let afterCancel = fetcher.fetched.count
    quiesce()
    XCTAssertEqual(fetcher.fetched.count, afterCancel,
                   "read-ahead kept fetching after the source was cancelled")
  }

  /**
   No duration, no read-ahead.

   There is nothing to convert thirty seconds into, and both ways of guessing
   are worse than not guessing — see `CachedByteSource.durationSec`. This is
   also what keeps every existing fetch-policy test measuring what it was
   written to measure.
   */
  func testASourceWithNoDurationFetchesOnDemandAsBefore() throws {
    let (source, fetcher) = makeSource(duration: nil)
    _ = try source.read(offset: 0, count: 512)
    quiesce()

    XCTAssertEqual(fetcher.fetched.count, 1)
    XCTAssertEqual(fetcher.fetched.first, 0..<(256 * 1024))
  }
}
