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

    /// Checks whether native MusicKit is reachable *without* asking for
    /// anything. Requesting authorisation at launch made macOS show the Apple
    /// Music permission dialog on every single start, which is intrusive for a
    /// capability most builds cannot use anyway.
    func probeQuietly() async -> Bool {
        guard MusicAuthorization.currentStatus == .authorized else {
            unavailableReason = "Acesso ao Apple Music ainda não autorizado. "
                + "Escolha Lossless em Ajustes para conceder."
            isAvailable = false
            return false
        }
        return await probe()
    }

    /// Attempts one real catalog request. Anything less would not distinguish a
    /// missing entitlement from a missing subscription. Prompts if needed, so
    /// it runs only when the user has asked for lossless.
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

    // MARK: The rest of a player

    /// Confirmed missing: this engine implemented none of these, so through
    /// `any Player` it ran the protocol's empty defaults. In lossless mode the
    /// shuffle and repeat buttons lit up and changed nothing — the same class
    /// of silent no-op the protocol comment already warns about.
    private(set) var shuffle = false

    func setShuffle(_ on: Bool) {
        shuffle = on
        player.state.shuffleMode = on ? .songs : .off
    }

    private(set) var repeatMode: RepeatMode = .off

    func setRepeat(_ mode: RepeatMode) {
        repeatMode = mode
        player.state.repeatMode = switch mode {
        case .off: MusicPlayer.RepeatMode.none
        case .one: .one
        case .all: .all
        }
    }

    /// ApplicationMusicPlayer shuffles the queue it has, not the one it is
    /// about to get, so the mode is set after the queue is built.
    func play(id: String, kind: String, shuffled: Bool) async throws {
        try await play(id: id, kind: kind)
        setShuffle(shuffled)
    }

    var queue: [QueueEntry] {
        player.queue.entries.map { entry in
            QueueEntry(id: entry.id, title: entry.title,
                       artist: entry.subtitle ?? "",
                       isCurrent: entry.id == player.queue.currentEntry?.id)
        }
    }

    func jump(to entryID: String) {
        guard let entry = player.queue.entries.first(where: { $0.id == entryID })
        else { return }
        player.queue.currentEntry = entry
        Task { try? await Self.beginPlayback() }
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
