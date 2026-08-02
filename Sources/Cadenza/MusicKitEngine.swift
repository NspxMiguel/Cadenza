import Foundation
import MusicKit
import Observation

/// Playback through native MusicKit — the only path that reaches Lossless and
/// Spatial Audio.
///
/// It requires the MusicKit entitlement, which in turn requires a paid Apple
/// Developer membership: a free personal team cannot register a Mac as a device,
/// so it never gets a macOS provisioning profile, so no entitlement is honoured.
/// Without it, catalog requests fail with `developerTokenRequestFailed`.
///
/// So this engine probes before it is offered, and the app falls back to WebKit
/// when the probe fails. Nothing above the `Player` protocol changes either way.
@MainActor
@Observable
final class MusicKitEngine: Player {
    static let shared = MusicKitEngine()

    private(set) var status: PlaybackStatus = .idle
    private(set) var nowPlaying: NowPlaying?
    private(set) var position: TimeInterval = 0

    /// Reported honestly: what the device actually delivers depends on the
    /// user's Apple Music quality settings, but native MusicKit is not the
    /// bottleneck the way WebKit is.
    let ceiling: AudioCeiling = .losslessSpatial

    private var ticker: Timer?
    private var player: ApplicationMusicPlayer { .shared }

    // MARK: Availability

    private(set) var isAvailable = false
    private(set) var unavailableReason: String?

    /// Attempts one real catalog request. Anything less would not distinguish a
    /// missing entitlement from a missing subscription.
    func probe() async -> Bool {
        guard await MusicAuthorization.request() == .authorized else {
            unavailableReason = "Acesso ao Apple Music não autorizado."
            isAvailable = false
            return false
        }

        do {
            let subscription = try await MusicSubscription.current
            guard subscription.canPlayCatalogContent else {
                unavailableReason = "Assinatura do Apple Music sem acesso ao catálogo."
                isAvailable = false
                return false
            }

            // The request that fails without the entitlement.
            var request = MusicCatalogResourceRequest<Song>(
                matching: \.id, equalTo: MusicItemID("1651971451"))
            request.limit = 1
            _ = try await request.response()

            isAvailable = true
            unavailableReason = nil
            return true
        } catch {
            isAvailable = false
            unavailableReason = Self.explain(error)
            return false
        }
    }

    private static func explain(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("developerToken") {
            return "Este build não tem a entitlement MusicKit. "
                + "Ela exige o Apple Developer Program (US$ 99/ano) — "
                + "veja docs/lossless.md para compilar com a sua conta."
        }
        return error.localizedDescription
    }

    // MARK: Playback

    func play(trackID: String) async throws {
        try await play(id: trackID, kind: "songs")
    }

    func play(id: String, kind: String) async throws {
        status = .loading
        switch kind {
        case "albums":
            let albums = try await MusicCatalogResourceRequest<Album>(
                matching: \.id, equalTo: MusicItemID(id)).response()
            guard let album = albums.items.first else { throw PlaybackError.notFound }
            player.queue = ApplicationMusicPlayer.Queue(for: [album])
        case "playlists":
            let lists = try await MusicCatalogResourceRequest<Playlist>(
                matching: \.id, equalTo: MusicItemID(id)).response()
            guard let list = lists.items.first else { throw PlaybackError.notFound }
            player.queue = ApplicationMusicPlayer.Queue(for: [list])
        default:
            let songs = try await MusicCatalogResourceRequest<Song>(
                matching: \.id, equalTo: MusicItemID(id)).response()
            guard let song = songs.items.first else { throw PlaybackError.notFound }
            player.queue = ApplicationMusicPlayer.Queue(for: [song])
        }

        try await Self.beginPlayback()
        startTicking()
    }

    /// MusicKit predates strict concurrency: `ApplicationMusicPlayer` is not
    /// Sendable, so awaiting its methods from the main actor reads as sending a
    /// non-Sendable value across isolation. Reaching the shared instance from a
    /// nonisolated context sidesteps that without weakening the whole target.
    private nonisolated static func beginPlayback() async throws {
        let player = ApplicationMusicPlayer.shared
        try await player.prepareToPlay()
        try await player.play()
    }

    // Same reason: reached inside the body rather than captured.
    func togglePlayPause() {
        let isPlaying = player.state.playbackStatus == .playing
        if isPlaying {
            player.pause()
        } else {
            Task { try? await Self.beginPlayback() }
        }
    }

    func seek(to position: TimeInterval) { player.playbackTime = position }

    func skipForward() {
        Task { try? await Self.skip(forward: true) }
    }

    func skipBackward() {
        Task { try? await Self.skip(forward: false) }
    }

    private nonisolated static func skip(forward: Bool) async throws {
        let player = ApplicationMusicPlayer.shared
        if forward {
            try await player.skipToNextEntry()
        } else {
            try await player.skipToPreviousEntry()
        }
    }

    func stop() {
        player.stop()
        ticker?.invalidate()
        ticker = nil
        status = .idle
        nowPlaying = nil
        position = 0
    }

    // MARK: State

    private func startTicking() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        sample()
    }

    private func sample() {
        position = player.playbackTime
        status = switch player.state.playbackStatus {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .idle
        default: .loading
        }

        guard let entry = player.queue.currentEntry else {
            nowPlaying = nil
            return
        }

        var duration: TimeInterval = 0
        var artwork: URL?
        if case let .song(song) = entry.item {
            duration = song.duration ?? 0
            artwork = song.artwork?.url(width: 512, height: 512)
        }

        nowPlaying = NowPlaying(
            trackID: entry.item.map { String(describing: $0.id) } ?? "",
            title: entry.title,
            artist: entry.subtitle ?? "",
            artworkURL: artwork,
            duration: duration,
            offersLossless: true)
    }
}

enum PlaybackError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: "Item não encontrado no catálogo."
        }
    }
}
