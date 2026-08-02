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
    static let favouriteSongs = "cadenza-library:favourite-songs"
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

    /// Playlists that actually contain classical music.
    ///
    /// The library is not classical-only, and the API offers no server-side
    /// filter — `filter[tracks:classical]` is rejected on library endpoints. But
    /// library tracks do carry `genreNames`, so each playlist is sampled once
    /// and the verdict cached. A classical app showing someone's hip-hop
    /// playlists is worse than one extra request per playlist, once.
    func classicalPlaylists() async throws -> [PlaylistSummary] {
        let all = try await playlists()
        var keep: [PlaylistSummary] = []

        for summary in all {
            if let cached = Self.cachedVerdict(for: summary.id) {
                if cached { keep.append(summary) }
                continue
            }
            let verdict = await isClassical(playlist: summary.id)
            Self.cacheVerdict(verdict, for: summary.id)
            if verdict { keep.append(summary) }
        }
        return keep
    }

    private func isClassical(playlist id: String) async -> Bool {
        guard let payload: Response<TrackItem> = try? await get(
            "/playlists/\(id)/tracks?limit=25") else { return false }

        let tracks = payload.data
        guard !tracks.isEmpty else { return false }

        let classical = tracks.filter { entry in
            (entry.attributes?.genreNames ?? []).contains { Self.readsAsClassical($0) }
        }
        // Presence alone was too weak: a pop playlist with one crossover track
        // was being kept. A playlist is classical when most of it is.
        return Double(classical.count) / Double(tracks.count) >= 0.5
    }

    /// Genre names arrive localised — "Classical", "Música clássica",
    /// "Crossover clássico" — so the comparison strips diacritics first.
    nonisolated static func readsAsClassical(_ genre: String) -> Bool {
        genre.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .contains("classic")
    }

    /// The rule's version is part of the key. Without it, tightening the rule
    /// changes nothing for playlists already judged — a pop playlist accepted
    /// by the old "one classical track is enough" test stays accepted forever,
    /// because the stored verdict is consulted before the rule ever runs.
    private static let verdictVersion = 2

    private static func verdictKey(_ id: String) -> String {
        "cadenza.classical.v\(verdictVersion)." + id
    }

    private static func cachedVerdict(for id: String) -> Bool? {
        UserDefaults.standard.object(forKey: verdictKey(id)) as? Bool
    }

    private static func cacheVerdict(_ value: Bool, for id: String) {
        UserDefaults.standard.set(value, forKey: verdictKey(id))
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
        let summaries = try await classicalPlaylists()
        let items = summaries.map { summary in
            Item(catalogID: summary.id,
                 type: "playlist",
                 title: summary.name,
                 addition: "Sua biblioteca",
                 action: Action(type: "componentScreen", screenType: "playlist",
                                url: LibraryRoute.playlist(summary.id)),
                 payload: Payload(id: summary.id, type: "playlists"))
        }
        guard !items.isEmpty else {
            return Screen(
                screenType: "libraryPlaylists",
                title: "Playlists",
                firstPage: Page(type: "empty", items: [],
                                heading: "Nenhuma playlist de clássica",
                                description: "Nenhuma playlist da sua biblioteca do Apple Music "
                                    + "contém gravações de música clássica."))
        }

        return Screen(
            screenType: "libraryPlaylists",
            title: "Playlists de clássica",
            sections: [ScreenSection(type: "playlists", heading: "Apple Music",
                                     components: [Component(type: "shelf", items: items)])])
    }

    /// The songs marked as favourites, kept to the classical ones.
    ///
    /// The classical sidebar has no favourite-tracks screen of its own: it
    /// offers favourites for recordings, works and composers, while "Faixas"
    /// is `libraryTracks` — what was added to the library, not what was loved.
    /// Favourited songs land instead in a playlist Apple maintains and does not
    /// let you edit, mixed across every genre. Filtering it is what makes it
    /// belong in a classical app.
    func favouriteSongsScreen() async throws -> Screen {
        guard let id = try await favouritesPlaylistID() else {
            return Screen(
                screenType: "favouriteSongs", title: "Músicas favoritas",
                firstPage: Page(type: "empty", items: [],
                                heading: "Nenhuma música favorita",
                                description: "Marque uma gravação com a estrela para vê-la aqui."))
        }

        let payload: Response<TrackItem> = try await get("/playlists/\(id)/tracks?limit=100")
        let classical = payload.data.filter { entry in
            (entry.attributes?.genreNames ?? []).contains { Self.readsAsClassical($0) }
        }

        let items = classical.map { entry -> Item in
            let attributes = entry.attributes
            return Item(
                catalogID: attributes?.playParams?.catalogId ?? entry.id,
                type: "track",
                title: attributes?.name,
                subtitle: attributes?.artistName,
                durationMs: attributes?.durationInMillis,
                image: attributes?.artwork.map { Artwork(url: $0.url) },
                payload: (attributes?.playParams?.catalogId).map { Payload(id: $0, type: "songs") })
        }

        guard !items.isEmpty else {
            return Screen(
                screenType: "favouriteSongs", title: "Músicas favoritas",
                firstPage: Page(type: "empty", items: [],
                                heading: "Nenhuma música clássica favorita",
                                description: "Você tem \(payload.data.count) música(s) favorita(s), "
                                    + "mas nenhuma do catálogo clássico."))
        }

        return Screen(
            screenType: "favouriteSongs",
            title: "Músicas favoritas",
            header: Header(type: "playlist", title: "Músicas favoritas",
                           subtitle: "Suas favoritas de clássica"),
            firstPage: Page(type: "list", items: items))
    }

    /// Found rather than hardcoded: the identifier is per-account. Apple's own
    /// favourites playlist is the one it will not let you edit and that has no
    /// catalog counterpart — a shared playlist saved to the library also has
    /// canEdit false, but carries a globalId.
    private func favouritesPlaylistID() async throws -> String? {
        let payload: Response<PlaylistItem> = try await get("/playlists?limit=40")
        return payload.data.first { entry in
            entry.attributes?.canEdit == false && entry.attributes?.playParams?.globalId == nil
        }?.id
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
        struct PlayParams: Decodable { let globalId: String? }
        struct Attributes: Decodable {
            let name: String?
            let canEdit: Bool?
            let playParams: PlayParams?
        }
        let id: String
        let attributes: Attributes?
    }

    private struct TrackItem: Decodable {
        struct Artwork: Decodable { let url: String? }
        struct PlayParams: Decodable { let catalogId: String? }
        struct Attributes: Decodable {
            let name: String?
            let artistName: String?
            let genreNames: [String]?
            let durationInMillis: Int?
            let artwork: Artwork?
            let playParams: PlayParams?
        }
        let id: String
        let attributes: Attributes?
    }
}

// MARK: - Favourites

/// Favouriting goes through `/me/favorites`, which answers 202 Accepted.
///
/// `/me/ratings` was the first attempt and is the wrong concept: it writes an
/// Apple Music "love", which reads back as value 1 and leaves the classical
/// catalog's own `inFavorites` untouched. The classical context menu exposes no
/// favourite action at all — its response carries only playback, sharing and
/// navigation — so the standard endpoint is the only route.
///
/// Note the honest caveat: the write is accepted, but `inFavorites` on the
/// classical side did not flip within seconds of it. Whether that is
/// propagation delay or a separate store is not yet established, so the star
/// reflects local intent immediately rather than waiting for a round trip that
/// may never confirm.
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
        guard let creds = TokenStore.shared.credentials else { return }

        // The brackets must be percent-encoded; sent literally the API answers
        // Bad Request, which reads like a wrong endpoint rather than a wrong
        // parameter.
        var components = URLComponents(string: "https://amp-api.music.apple.com/v1/me/favorites")
        components?.percentEncodedQuery = "ids%5Bsongs%5D=\(id)"
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = favourite ? "POST" : "DELETE"
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")

        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Pagination

/// Fetches the rows a screen leaves out.
///
/// A list screen reports where the next page starts, but the screen endpoint
/// ignores every attempt to ask for it — `?page=`, `?offset=` and `?startIndex=`
/// all return the first page again. The page token decodes to ordinary Apple
/// Music parameters, which is the hint: the catalog API paginates properly, so
/// the tail is fetched from there and appended.
///
/// Those rows carry less than the classical ones — no work grouping — but a
/// truncated list is worse than a plainer tail.
extension LibraryAPI {
    func remainingTracks(forScreenPath path: String, from offset: Int) async -> [Item] {
        guard offset >= 0, let creds = TokenStore.shared.credentials else { return [] }

        let kind: String
        let identifier: String
        if let id = Self.capture(#"/playlist/(pl\.[A-Za-z0-9]+)"#, path) {
            kind = "playlists"; identifier = id
        } else if let id = Self.capture(#"/album/(\d+)"#, path) {
            kind = "albums"; identifier = id
        } else {
            return []
        }

        var collected: [Item] = []
        var cursor = offset

        // Bounded: a runaway loop against someone else's API is not acceptable.
        for _ in 0..<20 {
            let url = "https://amp-api.music.apple.com/v1/catalog/\(creds.storefront)"
                + "/\(kind)/\(identifier)/tracks?limit=100&offset=\(cursor)"
            guard let request = Self.signed(url, creds),
                  let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let payload = try? JSONDecoder().decode(CatalogTracks.self, from: data)
            else { break }

            collected += payload.data.map { entry in
                let attributes = entry.attributes
                return Item(
                    catalogID: entry.id,
                    type: "track",
                    title: attributes?.name,
                    subtitle: attributes?.artistName,
                    durationMs: attributes?.durationInMillis,
                    payload: Payload(id: entry.id, type: "songs"))
            }

            guard payload.next != nil, !payload.data.isEmpty else { break }
            cursor += payload.data.count
        }
        return collected
    }

    private static func signed(_ url: String, _ creds: TokenStore.Credentials) -> URLRequest? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        return request
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
    }

    private struct CatalogTracks: Decodable {
        struct Entry: Decodable {
            struct Attributes: Decodable {
                let name: String?
                let artistName: String?
                let durationInMillis: Int?
            }
            let id: String
            let attributes: Attributes?
        }
        let data: [Entry]
        let next: String?
    }
}
