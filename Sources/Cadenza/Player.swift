import Foundation

/// What an engine can actually deliver. Made explicit because it is the whole
/// reason this protocol exists: WebKit is capped at lossy AAC, while native
/// MusicKit reaches lossless and Spatial Audio. The UI can show the ceiling
/// honestly instead of implying a quality the engine cannot produce.
enum AudioCeiling: String {
    case lossyAAC = "256 kbps AAC"
    case lossless = "Lossless"
    case losslessSpatial = "Lossless + Spatial"

    var isLossless: Bool { self != .lossyAAC }
}

enum PlaybackStatus: Equatable {
    case idle, loading, playing, paused
}

struct NowPlaying: Equatable {
    var trackID: String
    var title: String
    var artist: String
    var artworkURL: URL?
    var duration: TimeInterval
    /// From the catalog's `audioTraits` — what the recording *offers*, which is
    /// not necessarily what the current engine can deliver.
    var offersLossless: Bool = false
}

/// The seam that keeps the engine decision reversible.
///
/// Everything above this line — browsing, the queue, the UI, media keys — is
/// written against this protocol, so swapping a WebKit engine for a native
/// MusicKit one changes an implementation and nothing else.
@MainActor
protocol Player: AnyObject {
    var status: PlaybackStatus { get }
    var nowPlaying: NowPlaying? { get }
    var position: TimeInterval { get }

    /// The best this engine can do, regardless of what the recording offers.
    var ceiling: AudioCeiling { get }

    func play(trackID: String) async throws
    /// `kind` is the catalog's own vocabulary — `songs`, `albums`, `playlists`.
    func play(id: String, kind: String) async throws
    func togglePlayPause()
    func seek(to position: TimeInterval)
    func skipForward()
    func skipBackward()
    func stop()

    /// Eases to silence before pausing, for the sleep timer.
    func fadeOutAndPause(over seconds: TimeInterval)
}

extension Player {
    /// Engines without volume control simply pause. ApplicationMusicPlayer
    /// exposes no volume, so a gradual fade is not available there.
    func fadeOutAndPause(over seconds: TimeInterval) { togglePlayPause() }
}

extension Player {
    /// True when the recording is lossless but the engine cannot deliver it —
    /// the case worth surfacing rather than hiding.
    var isQualityLimited: Bool {
        (nowPlaying?.offersLossless ?? false) && !ceiling.isLossless
    }
}
