import Foundation
import Observation

/// Preferences that change what the catalog sends back.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// The language the catalog answers in.
    ///
    /// Distinct from the language of the *music*: a Lied's sung text and a
    /// score's tempo markings belong to the work, not to the interface, and
    /// translating them would misrepresent what the composer wrote. This
    /// governs titles, section names and editorial notes.
    enum Language: String, CaseIterable, Identifiable {
        case automatic, ptBR, enUS, enGB, deDE, frFR, esES, itIT, jaJP

        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic: "Automático (pelo país da conta)"
            case .ptBR: "Português (Brasil)"
            case .enUS: "English (US)"
            case .enGB: "English (UK)"
            case .deDE: "Deutsch"
            case .frFR: "Français"
            case .esES: "Español"
            case .itIT: "Italiano"
            case .jaJP: "日本語"
            }
        }

        /// The value Apple expects on the `l` query parameter.
        var code: String? {
            switch self {
            case .automatic: nil
            case .ptBR: "pt-BR"
            case .enUS: "en-US"
            case .enGB: "en-GB"
            case .deDE: "de-DE"
            case .frFR: "fr-FR"
            case .esES: "es-ES"
            case .itIT: "it-IT"
            case .jaJP: "ja-JP"
            }
        }
    }

    var language: Language {
        didSet {
            guard language != oldValue else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.languageKey)
            // Cached screens hold the previous language, so they are no longer
            // an answer to the question being asked.
            Task { await ScreenCache.shared.clear() }
        }
    }

    nonisolated static let languageKey = "cadenza.language"

    /// Readable from any context. `locale(for:)` runs inside the API actor, and
    /// reaching for the main actor from there aborts the process rather than
    /// waiting — the language setting crashed the app on its first request.
    nonisolated static var storedLanguageCode: String? {
        guard let raw = UserDefaults.standard.string(forKey: languageKey),
              let language = Language(rawValue: raw) else { return nil }
        return language.code
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
        language = Language(rawValue: raw) ?? .automatic
    }
}
