import Foundation

// MARK: - Client

enum APIError: LocalizedError {
    case noCredentials
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Sem credenciais. Abra o app e faça login para colhê-las."
        case .http(let code):
            return "A API respondeu \(code)."
        }
    }
}

/// Native client for the classical catalog. Kept deliberately thin, because the
/// endpoints behind it are private and will need repairing rather than extending
/// when Apple changes them.
actor ClassicalAPI {
    static let shared = ClassicalAPI()

    private let base = URL(string: "https://classical.music.apple.com/api/classical/v10")!
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    /// Fetches a screen by API path, e.g. `/query/view/br/listen-now`, or by the
    /// `action.url` of an item, which is the same thing.
    func screen(at path: String) async throws -> Screen {
        let data = try await get(path)
        return try JSONDecoder().decode(Screen.self, from: data)
    }

    func listenNow() async throws -> Screen {
        guard let sf = TokenStore.shared.credentials?.storefront else { throw APIError.noCredentials }
        return try await screen(at: "/query/view/\(sf)/listen-now")
    }

    private func get(_ path: String) async throws -> Data {
        guard let creds = TokenStore.shared.credentials else { throw APIError.noCredentials }

        let suffix = path.hasPrefix("/query") ? String(path.dropFirst("/query".count)) : path
        guard let url = URL(string: base.absoluteString + "/query" + suffix) else {
            throw APIError.http(-1)
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://classical.music.apple.com", forHTTPHeaderField: "Origin")

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        return data
    }
}
