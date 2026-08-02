import AppKit
import MediaPlayer

/// Publishes the current track to the system and accepts the hardware controls.
///
/// This is the layer the official experience never had on the Mac: media keys,
/// Control Center, the Now Playing widget and AirPods gestures all speak to
/// Cadenza directly instead of to a browser tab.
@MainActor
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private var artworkCache: (url: URL, image: NSImage)?
    private var lastPublished: String?

    private var engine: WebKitEngine { WebKitEngine.shared }

    func activate() {
        let commands = MPRemoteCommandCenter.shared()

        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.engine.status != .playing { self.engine.togglePlayPause() }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.engine.status == .playing { self.engine.togglePlayPause() }
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.engine.togglePlayPause()
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.engine.skipForward()
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.engine.skipBackward()
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent
            else { return .commandFailed }
            self?.engine.seek(to: event.positionTime)
            return .success
        }

        // Poll rather than observe: the engine's state already arrives on a
        // one-second tick from the page, so anything finer would be invented.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    private func publish() {
        let center = MPNowPlayingInfoCenter.default()

        guard let track = engine.nowPlaying else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            lastPublished = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: engine.position,
            MPNowPlayingInfoPropertyPlaybackRate: engine.status == .playing ? 1.0 : 0.0,
        ]

        if let cached = artworkCache, cached.url == track.artworkURL {
            let image = cached.image
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else if let url = track.artworkURL, track.trackID != lastPublished {
            lastPublished = track.trackID
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = NSImage(data: data) else { return }
                await MainActor.run { self?.artworkCache = (url, image) }
            }
        }

        center.nowPlayingInfo = info
        center.playbackState = engine.status == .playing ? .playing : .paused
    }
}
