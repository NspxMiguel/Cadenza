import Foundation
import Observation

/// Chooses which engine plays, and remembers the choice.
///
/// Two exist for one reason: WebKit is capped at lossy AAC, native MusicKit is
/// not. MusicKit needs an entitlement that only a paid membership can provide,
/// so the app cannot know at build time which is available — it probes at
/// launch and routes accordingly.
@MainActor
@Observable
final class Playback {
    static let shared = Playback()

    enum Preference: String, CaseIterable {
        case automatic, lossless, compatible

        var label: String {
            switch self {
            case .automatic: "Automático"
            case .lossless: "Lossless (MusicKit nativo)"
            case .compatible: "Compatível (WebKit)"
            }
        }
    }

    var preference: Preference = .automatic {
        didSet {
            UserDefaults.standard.set(preference.rawValue, forKey: Self.key)
            // Choosing lossless is the moment the user has asked for it, so
            // this is where prompting for access belongs.
            if preference == .lossless, !losslessAvailable {
                Task {
                    losslessAvailable = await MusicKitEngine.shared.probe()
                    losslessDiagnosis = MusicKitEngine.shared.unavailableReason
                    applyPreference()
                }
            } else {
                applyPreference()
            }
        }
    }

    private static let key = "cadenza.engine.preference"

    private(set) var active: any Player = WebKitEngine.shared
    private(set) var losslessAvailable = false
    private(set) var losslessDiagnosis: String?

    var usingLossless: Bool { active is MusicKitEngine }

    /// What the user just asked for, shown while the engine is still fetching.
    ///
    /// Queueing a track takes seconds: the page has to resolve it, request a
    /// licence and buffer. Until the engine reports back there was nothing on
    /// screen at all, so a click looked like it had done nothing and the app
    /// looked broken when it was merely working.
    private(set) var pending: NowPlaying?

    /// The track to display: whatever is actually playing, or what was asked
    /// for while that is still being arranged.
    var displayed: NowPlaying? { active.nowPlaying ?? pending }

    var isPreparing: Bool { active.nowPlaying == nil && pending != nil }

    /// Starts a track within its surroundings, so the queue holds the rest of
    /// the album or playlist and skipping forward has somewhere to go.
    func play(_ item: Item, within siblings: [Item]) {
        // A local file has no catalog behind it and plays through a different
        // engine entirely, so the routing decision happens before anything is
        // queued.
        if item.playable?.type == LocalRoute.payloadType {
            playLocal(item, within: siblings)
            return
        }

        let ids = siblings.compactMap { $0.playable?.id }
        guard let id = item.playable?.id, let index = ids.firstIndex(of: id), ids.count > 1
        else {
            play(item)
            return
        }
        showPending(item)
        Task {
            if let engine = active as? WebKitEngine {
                try? await engine.play(ids: ids, startingAt: index)
            } else {
                try? await active.play(id: id, kind: "songs")
            }
            try? await Task.sleep(for: .seconds(30))
            if active.nowPlaying != nil { pending = nil }
        }
    }

    /// Shown when the same request is made repeatedly while one is in flight.
    /// Clicking again cannot make WebKit resolve a licence any faster, and the
    /// honest thing is to say so — along with the one thing that would.
    private(set) var hint: String?
    private var recentRequests: [Date] = []

    private func noteRequest() {
        let now = Date()
        recentRequests.append(now)
        recentRequests.removeAll { now.timeIntervalSince($0) > 6 }

        if recentRequests.count >= 3, isPreparing {
            hint = "O app está carregando — clicar de novo não acelera. "
                + "Para início instantâneo e lossless, compile com a sua conta em Ajustes."
            Task {
                try? await Task.sleep(for: .seconds(8))
                hint = nil
            }
        }
    }

    private func showPending(_ item: Item) {
        noteRequest()
        guard let payload = item.playable else { return }
        pending = NowPlaying(
            trackID: payload.id,
            title: item.title ?? "",
            artist: item.subtitle ?? item.addition ?? "",
            artworkURL: item.image?.url(size: 256),
            duration: Double(item.durationMs ?? 0) / 1000)
    }

    /// Switches to the local engine and plays a file from disk.
    ///
    /// Local playback is not a preference the user sets — it is dictated by
    /// what was clicked, so it overrides the engine choice for as long as a
    /// local track is playing and hands control back the moment a catalog
    /// track is.
    private func playLocal(_ item: Item, within siblings: [Item]) {
        guard let id = item.playable?.id,
              let track = LocalLibrary.shared.track(id: id) else { return }

        let neighbours = siblings
            .filter { $0.playable?.type == LocalRoute.payloadType }
            .compactMap { $0.playable?.id }
            .compactMap { LocalLibrary.shared.track(id: $0) }

        if !(active is LocalEngine) {
            active.stop()
            active = LocalEngine.shared
        }
        pending = nil
        LocalEngine.shared.play(local: track, within: neighbours)
    }

    /// Starts a track, showing it immediately from what the catalog already
    /// told us rather than waiting for the engine to echo it back.
    func play(_ item: Item) {
        if item.playable?.type == LocalRoute.payloadType {
            playLocal(item, within: [item])
            return
        }
        guard item.playable != nil else { return }
        // Coming back from a local file: the streaming engine has to be the
        // active one again before anything is queued on it.
        if active is LocalEngine {
            active.stop()
            applyPreference(force: true)
        }
        showPending(item)
        let payload = item.playable!
        Task {
            try? await active.play(id: payload.id, kind: payload.type)
            // Give the engine a moment to take over the display.
            try? await Task.sleep(for: .seconds(30))
            if active.nowPlaying != nil { pending = nil }
        }
    }

    /// Same, for a whole album or playlist, where only a name is known upfront.
    func play(context: Payload, title: String, artwork: URL? = nil) {
        pending = NowPlaying(trackID: context.id, title: title,
                             artist: "", artworkURL: artwork, duration: 0)
        Task {
            try? await active.play(id: context.id, kind: context.type)
            try? await Task.sleep(for: .seconds(30))
            if active.nowPlaying != nil { pending = nil }
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.key),
           let saved = Preference(rawValue: raw) {
            preference = saved
        }
    }

    /// Boots WebKit unconditionally — it is also the login surface — then finds
    /// out whether this build can reach native MusicKit.
    func start() async {
        WebKitEngine.shared.start()
        await Favourites.shared.loadIfNeeded()
        await AppSettings.shared.loadStorefrontLanguages()

        // Quiet at launch: asking here would prompt for Apple Music access every
        // time the app opens, to test a capability most builds cannot use.
        losslessAvailable = await MusicKitEngine.shared.probeQuietly()
        losslessDiagnosis = MusicKitEngine.shared.unavailableReason
        applyPreference()

        let note = "[playback] lossless disponível: \(losslessAvailable)"
            + (losslessDiagnosis.map { " — \($0)" } ?? "")
        FileHandle.standardError.write(Data((note + "\n").utf8))
    }

    // MARK: Sleep timer

    private(set) var sleepDeadline: Date?
    private var sleepTask: Task<Void, Never>?

    func scheduleSleep(after interval: TimeInterval) {
        cancelSleep()
        sleepDeadline = Date().addingTimeInterval(interval)
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.active.fadeOutAndPause(over: 20)
                self?.sleepDeadline = nil
            }
        }
    }

    func cancelSleep() {
        sleepTask?.cancel()
        sleepTask = nil
        sleepDeadline = nil
    }

    private func applyPreference(force: Bool = false) {
        let wantsLossless = switch preference {
        case .automatic: losslessAvailable
        case .lossless: losslessAvailable
        case .compatible: false
        }

        let next: any Player = wantsLossless ? MusicKitEngine.shared : WebKitEngine.shared
        // `force` exists for the return from local playback: the engine that
        // should be active is the one already named here, so nothing differs
        // and the ordinary check would decline to switch back.
        if !force, type(of: next) == type(of: active) { return }
        active.stop()
        active = next
    }
}
