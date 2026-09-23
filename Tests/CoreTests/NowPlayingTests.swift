import XCTest
import MediaPlayer
@testable import YuzicEngineCore

/**
 The dictionary iOS reads off the lock screen.

 Testable because building it is separated from handing it to a system
 singleton — the singleton needs an app, the decisions do not, and the decisions
 are where this goes wrong.
 */
final class NowPlayingTests: XCTestCase {

  private func snapshot(
    isPlaying: Bool = true, isBuffering: Bool = false,
    durationSec: Double = 240, positionSec: Double = 30,
    rate: Double = 1.0, isLive: Bool = false, artist: String? = "Boards of Canada"
  ) -> NowPlayingInfo.Snapshot {
    .init(
      title: "Roygbiv", artist: artist, album: "Music Has the Right to Children",
      durationSec: durationSec, positionSec: positionSec,
      isPlaying: isPlaying, isBuffering: isBuffering, rate: rate, isLive: isLive)
  }

  // MARK: - The lock screen's fix point

  /**
   The bug: a paused lock screen showing an *earlier* time than the playing
   one did a moment before — 1:29 against 1:34, reported from a real build.

   `elapsedPlaybackTime` is a fix point iOS extrapolates from at the playback
   rate, and the engine deliberately does not re-send it every tick because
   that makes the timer stutter. But the engine's position comes from rendered
   frames, which stop advancing during a buffering stall while the wall clock
   does not, so the lock screen drifts ahead of the audio. Pausing publishes
   the truth and the number jumps back.
   */
  private let epoch = Date(timeIntervalSince1970: 1_000_000)

  func testNoRepublishWhileTheScreenAgreesWithTheAudio() {
    // Published 10s ago at 30s, and the audio really is at 40s.
    XCTAssertFalse(PlaybackEngine.shouldRepublish(
      actual: 40, published: 30, publishedAt: epoch, now: epoch.addingTimeInterval(10)
    ))
  }

  func testRepublishWhenTheScreenHasRunAhead() {
    // A five-second stall: the screen would be showing 40s, the audio is at 35.
    XCTAssertTrue(PlaybackEngine.shouldRepublish(
      actual: 35, published: 30, publishedAt: epoch, now: epoch.addingTimeInterval(10)
    ))
  }

  /// Symmetric, though drift is one-sided in practice — rendered frames fall
  /// behind wall clock and never run ahead of it.
  func testRepublishWhenTheScreenHasFallenBehind() {
    XCTAssertTrue(PlaybackEngine.shouldRepublish(
      actual: 45, published: 30, publishedAt: epoch, now: epoch.addingTimeInterval(10)
    ))
  }

  /// Under the threshold nothing is sent, or the timer stutters — which is
  /// the problem the sparse publishing exists to avoid.
  func testSmallDriftIsLeftAlone() {
    XCTAssertFalse(PlaybackEngine.shouldRepublish(
      actual: 39.5, published: 30, publishedAt: epoch, now: epoch.addingTimeInterval(10)
    ))
  }

  /// Nothing published yet: send one.
  func testRepublishWhenThereIsNoFixPoint() {
    XCTAssertTrue(PlaybackEngine.shouldRepublish(
      actual: 10, published: nil, publishedAt: nil, now: epoch
    ))
  }

  // MARK: - Artwork

  /**
   The lock screen showing the wrong album.

   `update` deliberately keeps the outgoing track's cover while a new one
   loads, so the screen does not flicker to grey between tracks. That is right
   while something is on its way and wrong the moment nothing is — a track with
   no art would otherwise keep the previous track's cover indefinitely, which
   does not look like a bug. It looks like art that loaded.
   */
  func testATrackWithNoArtworkClearsTheOldCover() {
    XCTAssertEqual(artworkAction(for: nil, currentlyLoaded: ArtworkRequest(uri: "https://a/1.jpg")), .clear)
  }

  /// An empty string is a missing cover, not a URL to fetch.
  func testAnEmptyUriIsTreatedAsNoArtwork() {
    XCTAssertEqual(artworkAction(for: "", currentlyLoaded: ArtworkRequest(uri: "https://a/1.jpg")), .clear)
  }

  func testANewCoverIsLoaded() {
    XCTAssertEqual(
      artworkAction(for: "https://a/2.jpg", currentlyLoaded: ArtworkRequest(uri: "https://a/1.jpg")),
      .load(ArtworkRequest(uri: "https://a/2.jpg"))
    )
  }

  /**
   The same cover twice is left alone.

   Two tracks off one album share an artwork URL, and refetching would replace
   the image with an identical one — a visible flicker on the lock screen at
   every track change within an album, which is the common case.
   */
  func testTheSameCoverIsKeptRatherThanRefetched() {
    XCTAssertEqual(
      artworkAction(for: "https://a/1.jpg", currentlyLoaded: ArtworkRequest(uri: "https://a/1.jpg")),
      .keep
    )
  }

  func testTheFirstCoverIsLoadedWhenNothingIsShowing() {
    XCTAssertEqual(artworkAction(for: "https://a/1.jpg", currentlyLoaded: nil), .load(ArtworkRequest(uri: "https://a/1.jpg")))
  }

  func testChangedArtworkHeadersReloadTheSameUri() {
    XCTAssertEqual(
      artworkAction(
        for: "https://a/1.jpg", headers: ["Authorization": "Basic fresh"],
        currentlyLoaded: ArtworkRequest(uri: "https://a/1.jpg", headers: ["Authorization": "Basic stale"])
      ),
      .load(ArtworkRequest(uri: "https://a/1.jpg", headers: ["Authorization": "Basic fresh"]))
    )
  }

  /// Nothing showing and nothing to show is not a clear-and-redraw.
  func testNoArtworkAndNothingLoadedStillClears() {
    XCTAssertEqual(artworkAction(for: nil, currentlyLoaded: nil), .clear)
  }

  func testCarriesTheMetadata() {
    let info = NowPlayingInfo.build(from: snapshot())
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Roygbiv")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Boards of Canada")
    XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Music Has the Right to Children")
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 240)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 30)
  }

  func testRateIsZeroWhenPaused() {
    let paused = NowPlayingInfo.build(from: snapshot(isPlaying: false))
    // Left at 1.0 while paused, iOS keeps advancing the displayed time over
    // audio that is not playing — the clock runs away from the music.
    XCTAssertEqual(paused[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)

    let playing = NowPlayingInfo.build(from: snapshot(isPlaying: true))
    XCTAssertEqual(playing[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
  }

  func testPlaybackSpeedIsReportedAsTheRate() {
    // Someone listening to a podcast at 1.5× should see the lock-screen timer
    // run at 1.5×, which is what iOS extrapolates from this.
    let info = NowPlayingInfo.build(from: snapshot(rate: 1.5))
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.5)
  }

  func testALiveStreamHasNoDurationAndSaysSo() {
    let info = NowPlayingInfo.build(from: snapshot(durationSec: 0, isLive: true))
    // A duration on a stream with no end draws a scrubber that lies, and lets
    // the user drag it somewhere that does not exist.
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
    XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, true)
  }

  func testAnUnknownDurationIsOmittedRatherThanSentAsZero() {
    let info = NowPlayingInfo.build(from: snapshot(durationSec: 0))
    // Zero would draw a scrubber pinned at the end for the whole track.
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
  }

  func testEmptyMetadataIsOmittedRatherThanSentBlank() {
    let info = NowPlayingInfo.build(from: snapshot(artist: ""))
    // An empty string renders as a blank line under the title; absent renders
    // as nothing, which is what "we do not know" should look like.
    XCTAssertNil(info[MPMediaItemPropertyArtist])
  }

  func testPositionIsCarriedExactlyForSeeking() {
    let info = NowPlayingInfo.build(from: snapshot(positionSec: 123.456))
    // iOS extrapolates from this fix point using the rate, so it has to be the
    // real position at the moment of the update rather than a rounded one.
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 123.456)
  }

  func testBufferingIsDrawnAsPlayingWithTheClockStopped() {
    // A track picked in the car and still opening. Drawn as paused, the car
    // put a play button over it, and pressing that opened it again.
    let opening = snapshot(isPlaying: false, isBuffering: true)
    XCTAssertEqual(NowPlayingInfo.playbackState(for: opening), .playing)
    let info = NowPlayingInfo.build(from: opening)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0,
                   "nothing is playing yet, so the clock must not run")
  }

  func testPausedIsDrawnAsPaused() {
    XCTAssertEqual(NowPlayingInfo.playbackState(for: snapshot(isPlaying: false)), .paused)
    XCTAssertEqual(NowPlayingInfo.playbackState(for: snapshot(isPlaying: true)), .playing)
  }

  // MARK: skip forward and back

  func testTheSkipCommandsAreRecognisedByName() {
    // `setCommands` drops a name it does not recognise, which is how these two
    // were silently ignored on iOS while Android honoured them.
    XCTAssertEqual(RemoteCommand(rawValue: "skipForward"), .skipForward)
    XCTAssertEqual(RemoteCommand(rawValue: "skipBackward"), .skipBackward)
  }

  func testASkipMovesByTheInterval() {
    XCTAssertEqual(NowPlayingInfo.skipTarget(from: 30, by: 15, durationSec: 200), 45)
    XCTAssertEqual(NowPlayingInfo.skipTarget(from: 30, by: -5, durationSec: 200), 25)
  }

  func testASkipIsClampedToTheTrack() {
    XCTAssertEqual(NowPlayingInfo.skipTarget(from: 2, by: -5, durationSec: 200), 0)
    XCTAssertEqual(NowPlayingInfo.skipTarget(from: 195, by: 15, durationSec: 200), 200)
  }

  func testAnUnknownDurationOnlyClampsAtZero() {
    XCTAssertEqual(NowPlayingInfo.skipTarget(from: 195, by: 15, durationSec: 0), 210)
  }
}
