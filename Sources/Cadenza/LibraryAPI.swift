import Foundation
import Observation

/// The user's own Apple Music library.
///
/// The classical catalog and the personal library live in different places: the
/// `v10` endpoints answer "Nenhuma playlist" because classical keeps no playlist
/// library of its own, while the playlists the user actually has — the ones the
/// official app lists in its sidebar — come from the standard Apple Music API.
///
/// Results are mapped onto the same `Screen`/`Item` model the rest of the app
/// uses, so views do not need to know which source a screen came from.
/// Paths for screens assembled from the personal library rather than fetched
/// from the classical catalog. Kept out of any actor so both sides can name them.
enum LibraryRoute {
    static let playlists = "cadenza-library:playlists"
    static let playlistPrefix = "cadenza-library:playlist:"

    static func playlist(_ id: String) -> String { playlistPrefix + id }
}

actor LibraryAPI {
    static let shared = LibraryAPI()

    private let base = "https://amp-api.music.apple.com/v1/me/library"

    struct PlaylistSummary: Sendable {
        let id: String
        let name: String
    }

    func playlists(limit: Int = 40) async throws -> [PlaylistSummary] {
        let payload: Response<PlaylistItem> = try await get("/playlists?limit=\(limit)")
        return payload.data.compactMap { entry in
            guard let name = entry.attributes?.name else { return nil }
            return PlaylistSummary(id: entry.id, name: name)
        }
    }

    /// All library playlists as one browsable screen.
    ///
    /// They are not split into the sidebar: the personal library is not
    /// classical-only, and there is no server-side filter for that — the
    /// `filter[tracks:classical]` parameter the catalog uses internally is
    /// rejected here. Listing every playlist in a classical app's sidebar turns
    /// it into a general music library, so they live one click away instead.
    func playlistsScreen() async throws -> Screen {
        let summaries = try await playlists()
        let items = summaries.map { summary in
            Item(catalogID: summary.id,
                 type: "playlist",
                 title: summary.name,
                 addition: "Sua biblioteca",
                 action: Action(type: "componentScreen", screenType: "playlist",
                                url: LibraryRoute.playlist(summary.id)),
                 payload: Payload(id: summary.id, type: "playlists"))
        }
        return Screen(
            screenType: "libraryPlaylists",
            title: "Playlists da sua biblioteca",
            sections: [ScreenSection(type: "playlists", heading: "Apple Music",
                                     components: [Component(type: "shelf", items: items)])])
    }

    /// Tracks of a library playlist, shaped as a list screen.
    func playlistScreen(id: String, name: String) async throws -> Screen {
        let payload: Response<TrackItem> = try await get(
            "/playlists/\(id)/tracks?limit=100")

        let items = payload.data.map { entry -> Item in
            let attributes = entry.attributes
            return Item(
                catalogID: attributes?.playParams?.catalogId ?? entry.id,
                type: "track",
                title: attributes?.name,
                subtitle: attributes?.artistName,
                durationMs: attributes?.durationInMillis,
                image: attributes?.artwork.map { Artwork(url: $0.url) },
                payload: (attributes?.playParams?.catalogId).map {
                    Payload(id: $0, type: "songs")
                })
        }

        return Screen(
            screenType: "libraryPlaylist",
            title: name,
            header: Header(type: "playlist", title: name, subtitle: "Sua biblioteca"),
            firstPage: Page(type: "list", items: items))
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String) async throws -> Response<T> {
        guard let creds = TokenStore.shared.credentials else { throw APIError.noCredentials }
        guard let url = URL(string: base + path) else { throw APIError.http(-1) }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw APIError.http(code) }
        return try JSONDecoder().decode(Response<T>.self, from: data)
    }

    // MARK: Wire types

    private struct Response<T: Decodable>: Decodable { let data: [T] }

    private struct PlaylistItem: Decodable {
        struct Attributes: Decodable { let name: String? }
        let id: String
        let attributes: Attributes?
    }

    private struct TrackItem: Decodable {
        struct Artwork: Decodable { let url: String? }
        struct PlayParams: Decodable { let catalogId: String? }
        struct Attributes: Decodable {
            let name: String?
            let artistName: String?
            let durationInMillis: Int?
            let artwork: Artwork?
            let playParams: PlayParams?
        }
        let id: String
        let attributes: Attributes?
    }
}

// MARK: - Favourites

/// Loving a track is a rating in Apple Music's vocabulary: value 1 on
/// `/me/ratings`. The classical context menu does not expose it — its response
/// carries only sharing and navigation — so this goes through the standard API.
@MainActor
@Observable
final class Favourites {
    static let shared = Favourites()

    /// Local overlay on top of what the catalog reported, so a star flips the
    /// moment it is pressed instead of after a refetch.
    private var overrides: [String: Bool] = [:]

    func isFavourite(_ item: Item) -> Bool {
        if let id = item.playable?.id, let override = overrides[id] { return override }
        return item.inFavorites ?? false
    }

    func isFavourite(id: String, fallback: Bool = false) -> Bool {
        overrides[id] ?? fallback
    }

    func toggle(_ item: Item) {
        guard let id = item.playable?.id else { return }
        let next = !isFavourite(item)
        overrides[id] = next
        Task { await Self.push(id: id, favourite: next) }
    }

    func toggle(id: String, current: Bool) {
        let next = !current
        overrides[id] = next
        Task { await Self.push(id: id, favourite: next) }
    }

    private static func push(id: String, favourite: Bool) async {
        guard let creds = TokenStore.shared.credentials,
              let url = URL(string: "https://amp-api.music.apple.com/v1/me/ratings/songs/\(id)")
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = favourite ? "PUT" : "DELETE"
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        if favourite {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(
                withJSONObject: ["type": "rating", "attributes": ["value": 1]])
        }

        _ = try? await URLSession.shared.data(for: request)
    }
}
