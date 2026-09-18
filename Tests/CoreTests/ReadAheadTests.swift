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

 The fixtures are sized in bytes-per-second so the arithmetic is legible, and
 kept to a few megabytes: big enough that thirty seconds of read-ahead is a
 real distance, small enough that the suite stays quick.
 */
final class ReadAheadTests: XCTestCase {

  private static let window: Int64 = 256 * 1024

  /// A blob of `seconds × bytesPerSecond`, told it lasts `duration`.
  private func makeSource(
    seconds: Int,
    bytesPerSecond: Int,
    duration: Double?
  ) -> (CachedByteSource, FakeFetcher) {
    let fetcher = FakeFetcher(bytes: seconds * bytesPerSecond)
    let source = CachedByteSource(
      fetcher: fetcher, windowBytes: Self.window, durationSec: duration
    )
    return (source, fetcher)
  }

  /// 60s at 200KB/s — a 12MB file, and thirty seconds of read-ahead is 6MB,
  /// inside both clamps so the derived figure is what is being measured.
  private func ordinarySource() -> (CachedByteSource, FakeFetcher) {
    makeSource(seconds: 60, bytesPerSecond: 200_000, duration: 60)
  }
  private static let ordinaryReadAhead: Int64 = 200_000 * 30

  /// Read-ahead runs on its own queue, so what it has done is a moving target.
  private func settle(timeout: TimeInterval = 5, until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /// Let whatever is in flight land. There is no condition to wait on: these
  /// assertions are about where read-ahead *stopped*, which needs it stopped.
  private func quiesce(_ seconds: TimeInterval = 0.5) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
  }

  /**
   One small read pulls the region ahead of it in behind.

   The behaviour the engine did not have. Before this, reading 512 bytes
   fetched one 256KB window and stopped, and the next window was not asked for
   until the decoder had consumed its way to the end of this one — which is
   when a listener can least afford to wait for it.
   */
  func testAReadPullsTheRegionAheadOfItInBehind() throws {
    let (source, _) = ordinarySource()
    _ = try source.read(offset: 0, count: 512)

    settle { source.availableBytes(from: 0) >= Self.ordinaryReadAhead }
    XCTAssertGreaterThanOrEqual(
      source.availableBytes(from: 0), Self.ordinaryReadAhead,
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
    let (source, fetcher) = ordinarySource()
    _ = try source.read(offset: 0, count: 512)

    settle { source.availableBytes(from: 0) >= Self.ordinaryReadAhead }
    quiesce()

    let fetched = fetcher.bytesFetched
    // Plus a window: the bound is where read-ahead stops *asking*, and the
    // window it is inside when it gets there is fetched whole.
    XCTAssertLessThanOrEqual(
      fetched, Self.ordinaryReadAhead + Self.window,
      "read-ahead overran its bound — fetched \(fetched) bytes"
    )
    XCTAssertLessThan(fetched, Int64(60 * 200_000),
                      "read-ahead fetched the whole file, which is a download")
  }

  /**
   The ceiling holds on a high-bitrate track.

   Thirty seconds of 96/24 lossless is around eleven megabytes, which is most
   of an album track — so the duration-derived figure is clamped. 20s at
   500KB/s asks for 15MB and must be held to `maxReadAheadBytes`.
   */
  func testTheCeilingHoldsOnAHighBitrateTrack() throws {
    let (source, fetcher) = makeSource(seconds: 20, bytesPerSecond: 500_000, duration: 20)
    _ = try source.read(offset: 0, count: 512)

    settle { source.availableBytes(from: 0) >= CachedByteSource.maxReadAheadBytes }
    quiesce()

    XCTAssertGreaterThanOrEqual(source.availableBytes(from: 0),
                                CachedByteSource.maxReadAheadBytes)
    XCTAssertLessThanOrEqual(
      fetcher.bytesFetched, CachedByteSource.maxReadAheadBytes + Self.window,
      "the clamp did not hold: fetched \(fetcher.bytesFetched)"
    )
  }

  /**
   A low-bitrate track gets seconds, not megabytes.

   The bound is a duration converted through the file's own average rate, so a
   podcast at a tenth the bitrate fetches about a tenth as much for the same
   thirty seconds — rather than a flat byte figure that is a cushion for one
   and most of the file for the other.
   */
  func testTheBoundFollowsTheBitrateRatherThanAFlatSize() throws {
    // 600s at 20KB/s: thirty seconds is 600KB, above the floor and far below
    // both the ceiling and what the same thirty seconds costs at lossless.
    let (source, fetcher) = makeSource(seconds: 600, bytesPerSecond: 20_000, duration: 600)
    _ = try source.read(offset: 0, count: 512)

    let expected = Int64(20_000 * 30)
    settle { source.availableBytes(from: 0) >= expected }
    quiesce()

    XCTAssertGreaterThanOrEqual(source.availableBytes(from: 0), expected)
    XCTAssertLessThan(
      fetcher.bytesFetched, CachedByteSource.maxReadAheadBytes,
      "a 20KB/s track pulled a lossless track's worth of read-ahead"
    )
  }

  /**
   A seek moves the mark rather than leaving read-ahead behind.

   The mark is set from the end of every read, so the jump is one step. Read-
   ahead crawling forward from the old position would spend the listener's
   bandwidth on audio they have just skipped past, and would arrive at the new
   one last.
   */
  func testReadAheadFollowsASeek() throws {
    let (source, _) = ordinarySource()
    _ = try source.read(offset: 0, count: 512)
    settle { source.availableBytes(from: 0) >= Self.window * 2 }

    // Past everything the first pass could have reached.
    let seekTo: Int64 = 8_000_000
    _ = try source.read(offset: seekTo, count: 512)
    settle { source.availableBytes(from: seekTo) >= Self.window * 4 }

    XCTAssertGreaterThanOrEqual(
      source.availableBytes(from: seekTo), Self.window * 4,
      "read-ahead should have moved to where the decoder went"
    )
  }

  /**
   The same bytes are never fetched twice.

   Read-ahead and the decoder are two threads wanting overlapping regions, and
   the decoder's read goes first because someone is waiting on it. Whichever
   arrives second has to notice the window landed while it queued — otherwise
   read-ahead quietly doubles a listener's data usage, which is the way this
   feature would be worth removing.
   */
  func testAWindowIsNeverFetchedTwice() throws {
    let (source, fetcher) = ordinarySource()
    _ = try source.read(offset: 0, count: 512)
    settle { source.availableBytes(from: 0) >= Self.ordinaryReadAhead }
    quiesce()

    // Read back across what read-ahead pulled. The request count is *expected*
    // to grow while this runs — each read moves the mark, and read-ahead keeps
    // its bound ahead of wherever the decoder is. What must not happen is the
    // same bytes being asked for again.
    for offset in stride(from: Int64(0), to: 4_000_000, by: 100_000) {
      let data = try source.read(offset: offset, count: 4096)
      XCTAssertEqual(data.count, 4096, "a byte already fetched came back short")
    }
    quiesce()

    let sorted = fetcher.fetched.sorted { $0.lowerBound < $1.lowerBound }
    for (earlier, later) in zip(sorted, sorted.dropFirst()) {
      XCTAssertLessThanOrEqual(
        earlier.upperBound, later.lowerBound,
        "\(earlier) and \(later) overlap — those bytes were paid for twice"
      )
    }
  }

  /**
   Cancelling stops it.

   `cancel` is what a seek and a pause both reach, and read-ahead that carried
   on afterwards would hold the one fetch slot against the read that actually
   has someone waiting for it.
   */
  func testCancelStopsReadAhead() throws {
    let (source, fetcher) = ordinarySource()
    let gate = DispatchSemaphore(value: 0)
    fetcher.gate = gate

    // Read-ahead is only scheduled once the foreground read returns, so one
    // signal releases that read and nothing else.
    let firstRead = expectation(description: "first read returned")
    DispatchQueue.global().async {
      _ = try? source.read(offset: 0, count: 512)
      firstRead.fulfill()
    }
    gate.signal()
    wait(for: [firstRead], timeout: 5)

    source.cancel()
    // Release anything read-ahead is parked on, so it can notice and stop
    // rather than simply stay blocked — which would pass this test for the
    // wrong reason.
    for _ in 0..<64 { gate.signal() }
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
    let (source, fetcher) = makeSource(seconds: 60, bytesPerSecond: 200_000, duration: nil)
    _ = try source.read(offset: 0, count: 512)
    quiesce()

    XCTAssertEqual(fetcher.fetched.count, 1)
    XCTAssertEqual(fetcher.fetched.first, 0..<Self.window)
  }
}
