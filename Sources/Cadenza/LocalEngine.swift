import AVFoundation
import Foundation
import Observation

/// Plays files from the disk.
///
/// The third engine, and the only one with no ceiling at all: there is no DRM
/// between the app and the samples, so a FLAC transfer plays at whatever it
/// was encoded at. That makes it the one path in this app where "lossless"
/// costs nothing and needs no membership.
///
/// It implements the same `Player` protocol as the other two, which is the
/// whole reason that protocol exists — the list, the transport, the scrubber
/// and the queue needed no changes to work with local files.
@MainActor
@Observable
final class LocalEngine: Player {
    static let shared = LocalEngine()

    private(set) var status: PlaybackStatus = .idle
    private(set) var nowPlaying: NowPlaying?
    private(set) var position: TimeInterval = 0

    /// Whatever the file is. Nothing here re-encodes or downsamples, so the
    /// only limit is what was imported.
    let ceiling: AudioCeiling = .lossless

    private var player: AVAudioPlayer?
    private var ticker: Timer?

    /// The tracks queued around the one playing, so skipping has somewhere to
    /// go — the same lesson the WebKit engine had to learn.
    private var queueTracks: [LocalTrack] = []
    private var cursor = 0

    // MARK: Playing

    func play(local track: LocalTrack, within siblings: [LocalTrack]) {
        queueTracks = siblings.isEmpty ? [track] : siblings
        cursor = queueTracks.firstIndex(of: track) ?? 0
        start(queueTracks[cursor])
    }

    private func start(_ track: LocalTrack) {
        guard let url = LocalLibrary.shared.url(for: track) else {
            status = .idle
            Diagnostics.log("[local] arquivo não encontrado: \(track.path)")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(volume)
            player.prepareToPlay()
            player.play()
            self.player = player
            status = .playing
            position = 0
            nowPlaying = NowPlaying(
                trackID: track.id,
                title: track.title,
                artist: [track.artist, track.album].filter { !$0.isEmpty }
                    .joined(separator: " — "),
                artworkURL: LocalLibrary.shared.artworkURL(for: track),
                duration: player.duration > 0 ? player.duration : track.duration)
            startTicking()
        } catch {
            status = .idle
            Diagnostics.log("[local] não consegui abrir \(url.lastPathComponent): \(error)")
        }
    }

    /// Required by the protocol and meaningless here: a catalog identifier
    /// names nothing on this disk. Local playback goes through `play(local:)`.
    func play(trackID: String) async throws {
        guard let track = LocalLibrary.shared.track(id: trackID) else { return }
        play(local: track, within: LocalLibrary.shared.tracks)
    }

    func play(id: String, kind: String) async throws { try await play(trackID: id) }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            status = .paused
        } else {
            player.play()
            status = .playing
        }
    }

    func seek(to position: TimeInterval) {
        guard let player else { return }
        player.currentTime = max(0, min(position, player.duration))
        self.position = player.currentTime
    }

    func skipForward() {
        guard !queueTracks.isEmpty else { return }
        cursor = repeatMode == .one ? cursor : cursor + 1
        if cursor >= queueTracks.count {
            guard repeatMode == .all else { stop(); return }
            cursor = 0
        }
        start(queueTracks[cursor])
    }

    func skipBackward() {
        guard !queueTracks.isEmpty else { return }
        // Restart the track first, the way every player does, and only step
        // back when it has barely begun.
        if position > 3 {
            seek(to: 0)
            return
        }
        cursor = cursor > 0 ? cursor - 1 : 0
        start(queueTracks[cursor])
    }

    func stop() {
        player?.stop()
        player = nil
        ticker?.invalidate()
        ticker = nil
        status = .idle
        nowPlaying = nil
        position = 0
    }

    // MARK: The rest of a player

    private(set) var volume: Double = 1
    var supportsVolume: Bool { true }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
    }

    private(set) var shuffle = false

    func setShuffle(_ on: Bool) {
        shuffle = on
        guard on, queueTracks.count > 1 else { return }
        let current = queueTracks[safe: cursor]
        queueTracks.shuffle()
        if let current, let index = queueTracks.firstIndex(of: current) { cursor = index }
    }

    private(set) var repeatMode: RepeatMode = .off

    func setRepeat(_ mode: RepeatMode) { repeatMode = mode }

    var queue: [QueueEntry] {
        queueTracks.enumerated().map { index, track in
            QueueEntry(id: track.id, title: track.title, artist: track.artist,
                       isCurrent: index == cursor)
        }
    }

    func jump(to entryID: String) {
        guard let index = queueTracks.firstIndex(where: { $0.id == entryID }) else { return }
        cursor = index
        start(queueTracks[index])
    }

    func fadeOutAndPause(over seconds: TimeInterval) {
        guard let player else { return }
        player.setVolume(0, fadeDuration: seconds)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            player.pause()
            player.volume = Float(volume)
            status = .paused
        }
    }

    // MARK: Clock

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        guard let player else { return }
        position = player.currentTime
        // AVAudioPlayer reports isPlaying false once it reaches the end, which
        // is the only signal that the track finished.
        if !player.isPlaying, status == .playing {
            if position >= player.duration - 0.5 {
                skipForward()
            } else {
                status = .paused
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
