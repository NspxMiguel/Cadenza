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

    private func applyPreference() {
        let wantsLossless = switch preference {
        case .automatic: losslessAvailable
        case .lossless: losslessAvailable
        case .compatible: false
        }

        let next: any Player = wantsLossless ? MusicKitEngine.shared : WebKitEngine.shared
        guard type(of: next) != type(of: active) else { return }
        active.stop()
        active = next
    }
}
