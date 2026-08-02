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

enum RepeatMode: Int, CaseIterable {
    case off = 0, one = 1, all = 2

    var symbol: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var label: String {
        switch self {
        case .off: "Repetição desligada"
        case .all: "Repetir a fila"
        case .one: "Repetir a faixa"
        }
    }
}

/// One entry of what is queued up, for the list the transport can show.
struct QueueEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let artist: String
    /// True for the item currently sounding.
    let isCurrent: Bool
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

    // Declared here, not only defaulted in the extension below. A member that
    // exists solely as an extension default is dispatched statically: called
    // through `any Player`, it runs the default even when the concrete engine
    // overrides it. That is not a subtlety — it made the volume slider vanish
    // and left shuffle and repeat as buttons that did nothing at all.
    var volume: Double { get }
    var supportsVolume: Bool { get }
    func setVolume(_ value: Double)

    var shuffle: Bool { get }
    func setShuffle(_ on: Bool)

    var repeatMode: RepeatMode { get }
    func setRepeat(_ mode: RepeatMode)

    var queue: [QueueEntry] { get }
    func jump(to entryID: String)
}

extension Player {
    /// Engines without volume control simply pause. ApplicationMusicPlayer
    /// exposes no volume, so a gradual fade is not available there.
    func fadeOutAndPause(over seconds: TimeInterval) { togglePlayPause() }

    /// Defaults rather than requirements: an engine that cannot offer one of
    /// these should say so by omission, and the transport hides the control,
    /// instead of showing a switch that silently does nothing.
    var volume: Double { 1 }
    var supportsVolume: Bool { false }
    func setVolume(_ value: Double) {}

    var shuffle: Bool { false }
    func setShuffle(_ on: Bool) {}

    var repeatMode: RepeatMode { .off }
    func setRepeat(_ mode: RepeatMode) {}

    var queue: [QueueEntry] { [] }
    func jump(to entryID: String) {}
}

extension Player {
    /// True when the recording is lossless but the engine cannot deliver it —
    /// the case worth surfacing rather than hiding.
    var isQualityLimited: Bool {
        (nowPlaying?.offersLossless ?? false) && !ceiling.isLossless
    }
}
