import Foundation
import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif

/**
 What the lock screen, the Control Centre and the car are told.

 Split in two on purpose: `NowPlayingInfo` builds the dictionary and is pure, so
 the interesting decisions can be tested; `NowPlayingCenter` is the thin part
 that hands it to a system singleton and cannot be tested without an app.

 The single most important line in this file is `playbackState`. yuzic's current
 player leaves it implicit, and CarPlay shows "paused" over playing audio on the
 first track of a session — a bug patched downstream in a fork of that library
 rather than fixed. An engine that owns the session should never make anyone do
 that, so the state is stated outright on every change. See docs/architecture.md
 §4.
 */
public struct NowPlayingInfo {

  public struct Snapshot {
    public let title: String
    public let artist: String?
    public let album: String?
    public let durationSec: Double
    public let positionSec: Double
    public let isPlaying: Bool
    /// Waiting for audio it means to play: a track still opening, or a stall.
    /// The clock stands still, but the intent is playing, not paused.
    public let isBuffering: Bool
    public let rate: Double
    /// Live radio: no finish line, so no duration and no scrubber.
    public let isLive: Bool

    public init(
      title: String, artist: String? = nil, album: String? = nil,
      durationSec: Double = 0, positionSec: Double = 0,
      isPlaying: Bool = false, isBuffering: Bool = false,
      rate: Double = 1.0, isLive: Bool = false
    ) {
      self.title = title
      self.artist = artist
      self.album = album
      self.durationSec = durationSec
      self.positionSec = positionSec
      self.isPlaying = isPlaying
      self.isBuffering = isBuffering
      self.rate = rate
      self.isLive = isLive
    }
  }

  /**
   The dictionary iOS reads.

   Three things here are easy to get subtly wrong and unpleasant to debug:

   - **`elapsedPlaybackTime` is a fix point, not a clock.** iOS extrapolates
     from it using the rate, so this only needs updating on seeks and state
     changes — pushing it every tick makes the lock-screen timer stutter as it
     is repeatedly yanked back to a value that is already stale.
   - **The rate must be zero when paused.** Left at 1.0, iOS keeps advancing the
     displayed time over audio that is not playing.
   - **A live stream gets no duration.** Supplying one draws a scrubber that
     lies about a stream with no end, and lets the user drag it.
   */
  public static func build(from snapshot: Snapshot) -> [String: Any] {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: snapshot.title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.positionSec,
      MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPlaying ? snapshot.rate : 0.0,
    ]

    if let artist = snapshot.artist, !artist.isEmpty {
      info[MPMediaItemPropertyArtist] = artist
    }
    if let album = snapshot.album, !album.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = album
    }

    if snapshot.isLive {
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
    } else if snapshot.durationSec > 0 {
      info[MPMediaItemPropertyPlaybackDuration] = snapshot.durationSec
    }

    return info
  }

  /**
   The state the car and the lock screen draw their button from.

   Buffering counts as playing. The rate is already zero, so the clock stops,
   but a track picked in the car and still opening is one the listener asked
   to hear. Drawn as paused, it put a play button over it, and pressing that
   opened the track again.
   */
  public static func playbackState(for snapshot: Snapshot) -> MPNowPlayingPlaybackState {
    snapshot.isPlaying || snapshot.isBuffering ? .playing : .paused
  }
}

/// The commands to advertise. A control that is offered but does nothing is
/// worse than one that is absent, so this list is what the engine can actually
/// honour rather than everything the framework has.
public struct RemoteCommandHandlers {
  public var play: (() -> Void)?
  public var pause: (() -> Void)?
  public var next: (() -> Void)?
  public var previous: (() -> Void)?
  public var seek: ((Double) -> Void)?
  public var stop: (() -> Void)?

  public init() {}
}

/**
 What to do with the lock screen's cover when a new track arrives.

 Pulled out as a decision because it is the part worth testing — the rest is
 `MPNowPlayingInfoCenter`, which needs a real app — and because getting it
 wrong is not visibly a bug. The failure mode is the *previous* track's cover
 sitting under the new track's title, which reads as artwork that loaded fine.
 */
/// An ephemeral artwork request. Headers belong to the request, not the URL:
/// embedding Basic credentials in a URL leaks them into logs and queue state.
public struct ArtworkRequest: Equatable {
  public let uri: String
  public let headers: [String: String]

  public init(uri: String, headers: [String: String] = [:]) {
    self.uri = uri
    self.headers = headers
  }
}

public enum ArtworkAction: Equatable {
  /// Same request as the outgoing track. Leave it; refetching would flicker.
  case keep
  /// Fetch this. Whatever is showing stays up until it arrives.
  case load(ArtworkRequest)
  /// This track has no cover. The old one has to go, or it becomes a lie.
  case clear
}

public func artworkAction(
  for uri: String?, headers: [String: String] = [:], currentlyLoaded loaded: ArtworkRequest?
) -> ArtworkAction {
  guard let uri, !uri.isEmpty else { return .clear }
  let request = ArtworkRequest(uri: uri, headers: headers)
  return request == loaded ? .keep : .load(request)
}

public final class NowPlayingCenter {

  private let center = MPNowPlayingInfoCenter.default()
  private let commands = MPRemoteCommandCenter.shared()
  private var artworkRequest: ArtworkRequest?
  private var handlers = RemoteCommandHandlers()

  /// What was last handed to the system, or nil after `clear`. Kept so the
  /// engine's publishing can be tested without an app to read it back from.
  public private(set) var lastPublished: NowPlayingInfo.Snapshot?

  public init() {}

  public func update(
    _ snapshot: NowPlayingInfo.Snapshot, artworkUri: String? = nil, artworkHeaders: [String: String] = [:]
  ) {
    var info = NowPlayingInfo.build(from: snapshot)

    // Keep whatever artwork is already loaded rather than blanking it while a
    // new image is fetched — the lock screen flickering to grey between tracks
    // is worse than a stale cover for a moment.
    if let existing = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] {
      info[MPMediaItemPropertyArtwork] = existing
    }
    center.nowPlayingInfo = info
    lastPublished = snapshot

    // Stated, never inferred. This is the CarPlay bug.
    center.playbackState = NowPlayingInfo.playbackState(for: snapshot)

    switch artworkAction(for: artworkUri, headers: artworkHeaders, currentlyLoaded: artworkRequest) {
    case .keep:
      break
    case .load(let request):
      artworkRequest = request
      loadArtwork(request)
    case .clear:
      artworkRequest = nil
      setArtwork(nil)
    }
  }

  /// Put an image on the lock screen, or take one off. Main-thread only,
  /// because `nowPlayingInfo` is read on it.
  private func setArtwork(_ artwork: MPMediaItemArtwork?) {
    let apply = {
      var info = self.center.nowPlayingInfo ?? [:]
      if let artwork {
        info[MPMediaItemPropertyArtwork] = artwork
      } else {
        info.removeValue(forKey: MPMediaItemPropertyArtwork)
      }
      self.center.nowPlayingInfo = info
    }
    if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
  }

  public func clear() {
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
    artworkRequest = nil
    lastPublished = nil
  }

  private func loadArtwork(_ artwork: ArtworkRequest) {
    // UIKit-only. The package also builds for macOS so the logic above can be
    // tested by `swift test` without an app, and cover art is the one part of
    // this that genuinely cannot come along.
    #if canImport(UIKit)
    guard let url = URL(string: artwork.uri) else { setArtwork(nil); return }

    // A short timeout because this is decorative. The default is 60 seconds,
    // and a server that hangs would otherwise leave the outgoing track's cover
    // on the lock screen for a minute of the new one.
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    artwork.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

    URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
      guard let self else { return }
      // A later track (or a refreshed credential) already won the race;
      // whatever came back is not wanted, and clearing here would wipe the
      // newer track's cover.
      guard self.artworkRequest == artwork else { return }

      guard let data, let image = UIImage(data: data) else {
        // No art for this track — a 404, a timeout, or a body that is not an
        // image. Clearing matters: the previous track's cover is still up, and
        // leaving it means the lock screen shows one album while playing
        // another. Wrong art is worse than none, because it looks correct.
        self.setArtwork(nil)
        return
      }

      let mediaArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
      self.setArtwork(mediaArtwork)
    }.resume()
    #endif
  }

  // MARK: - Remote commands

  public func setCommands(_ enabled: [RemoteCommand], handlers: RemoteCommandHandlers) {
    self.handlers = handlers
    // Targets accumulate: reconfiguring without removing the old ones means a
    // single press firing every handler ever registered.
    removeAllTargets()

    let wanted = Set(enabled)

    commands.playCommand.isEnabled = wanted.contains(.playPause)
    commands.pauseCommand.isEnabled = wanted.contains(.playPause)
    commands.togglePlayPauseCommand.isEnabled = wanted.contains(.playPause)
    commands.nextTrackCommand.isEnabled = wanted.contains(.next)
    commands.previousTrackCommand.isEnabled = wanted.contains(.previous)
    commands.changePlaybackPositionCommand.isEnabled = wanted.contains(.seek)
    commands.stopCommand.isEnabled = wanted.contains(.stop)

    commands.playCommand.addTarget { [weak self] _ in
      self?.handlers.play?(); return .success
    }
    commands.pauseCommand.addTarget { [weak self] _ in
      self?.handlers.pause?(); return .success
    }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in
      // The car and the headphone button send this one rather than a specific
      // play or pause, so the engine's own state decides which it means.
      if self?.center.playbackState == .playing { self?.handlers.pause?() }
      else { self?.handlers.play?() }
      return .success
    }
    commands.nextTrackCommand.addTarget { [weak self] _ in
      self?.handlers.next?(); return .success
    }
    commands.previousTrackCommand.addTarget { [weak self] _ in
      self?.handlers.previous?(); return .success
    }
    commands.stopCommand.addTarget { [weak self] _ in
      self?.handlers.stop?(); return .success
    }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.handlers.seek?(event.positionTime)
      return .success
    }
  }

  private func removeAllTargets() {
    commands.playCommand.removeTarget(nil)
    commands.pauseCommand.removeTarget(nil)
    commands.togglePlayPauseCommand.removeTarget(nil)
    commands.nextTrackCommand.removeTarget(nil)
    commands.previousTrackCommand.removeTarget(nil)
    commands.stopCommand.removeTarget(nil)
    commands.changePlaybackPositionCommand.removeTarget(nil)
  }
}

/// Which remote controls to advertise.
public enum RemoteCommand: String, Hashable {
  case playPause
  case next
  case previous
  case seek
  case stop
}
