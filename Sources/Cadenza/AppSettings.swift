import Foundation
import Observation

/// Preferences that change what the catalog sends back.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// What the storefront itself says it speaks. Fetched once, because Apple
    /// answers this better than a hardcoded table can: a storefront declares its
    /// default language and exactly which others it supports.
    private(set) var storefrontDefault: String?
    private(set) var storefrontSupported: [String] = []

    func loadStorefrontLanguages() async {
        guard storefrontSupported.isEmpty,
              let creds = TokenStore.shared.credentials,
              let url = URL(string:
                "https://amp-api.music.apple.com/v1/storefronts/\(creds.storefront)")
        else { return }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let payload = try? JSONDecoder().decode(StorefrontResponse.self, from: data),
              let attributes = payload.data.first?.attributes
        else { return }

        storefrontDefault = attributes.defaultLanguageTag
        storefrontSupported = attributes.supportedLanguageTags ?? []
        UserDefaults.standard.set(resolvedAutomatic, forKey: Self.automaticKey)
    }

    /// What "automatic" resolves to.
    ///
    /// The storefront's own default comes first, because that is Apple's answer
    /// for this account rather than a guess. Following the Mac's language
    /// instead was tried and looked wrong in practice: a Brazilian storefront
    /// also serves en-GB, so an English Mac produced an English catalog inside a
    /// Portuguese interface. The system language is kept as a fallback for
    /// storefronts that declare no default.
    var resolvedAutomatic: String {
        if let preferred = storefrontDefault, !preferred.isEmpty { return preferred }

        let system = Locale.preferredLanguages.first ?? "en-US"
        if let match = storefrontSupported.first(where: {
            $0.lowercased().hasPrefix(String(system.prefix(2)).lowercased())
        }) { return match }

        return storefrontSupported.first ?? "en-US"
    }

    private struct StorefrontResponse: Decodable {
        struct Entry: Decodable {
            struct Attributes: Decodable {
                let defaultLanguageTag: String?
                let supportedLanguageTags: [String]?
            }
            let attributes: Attributes?
        }
        let data: [Entry]
    }

    nonisolated static let automaticKey = "cadenza.language.automatic"

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
        let raw = UserDefaults.standard.string(forKey: languageKey) ?? ""
        if let language = Language(rawValue: raw), let code = language.code { return code }
        // "Automatic" resolves against the storefront, computed when the
        // storefront was fetched and stored so any context can read it.
        return UserDefaults.standard.string(forKey: automaticKey)
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
        language = Language(rawValue: raw) ?? .automatic
    }
}
