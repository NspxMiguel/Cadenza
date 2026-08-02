import Foundation
import Observation

/// Writing to the library: playlists, and what belongs to it.
///
/// Every route here was established against the live API rather than from
/// documentation, because the documented public API and the one the web client
/// uses are not the same surface. What that probing settled:
///
/// - Creating answers `201` with the new playlist; editing answers `204`, and
///   both `PATCH` and `PUT` are accepted.
/// - Removing a track needs `mode=all` alongside `ids[library-songs]`. Without
///   it the API answers `400 Missing Parameter`, naming `mode` — which reads
///   like a broken endpoint until you notice the parameter it is asking for.
/// - Adding to the library answers `202 Accepted`, not `200`: the row appears a
///   moment later, so anything that reads straight back sees nothing.
/// - Deleting from the library needs the *library* identifier (`i.…`), not the
///   catalog one, so the catalog id has to be resolved first.
/// - There is no route for playlist artwork. `GET` says the relationship does
///   not exist and every write verb answers `405`, so a custom cover is not
///   something this API can be made to do.
extension LibraryAPI {

    // MARK: Playlists

    @discardableResult
    func createPlaylist(name: String, description: String? = nil,
                        catalogIDs: [String] = []) async throws -> String {
        var attributes: [String: Any] = ["name": name]
        if let description, !description.isEmpty { attributes["description"] = description }

        var body: [String: Any] = ["attributes": attributes]
        if !catalogIDs.isEmpty {
            body["relationships"] = ["tracks": ["data": catalogIDs.map {
                ["id": $0, "type": "songs"]
            }]]
        }

        let data = try await send("POST", "/me/library/playlists", body: body)
        struct Created: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        guard let id = (try? JSONDecoder().decode(Created.self, from: data))?.data.first?.id else {
            throw APIError.http(-2)
        }
        return id
    }

    func renamePlaylist(id: String, name: String, description: String? = nil) async throws {
        var attributes: [String: Any] = ["name": name]
        if let description { attributes["description"] = description }
        _ = try await send("PATCH", "/me/library/playlists/\(id)",
                           body: ["attributes": attributes])
    }

    func deletePlaylist(id: String) async throws {
        _ = try await send("DELETE", "/me/library/playlists/\(id)")
    }

    func addTracks(to playlistID: String, catalogIDs: [String]) async throws {
        guard !catalogIDs.isEmpty else { return }
        _ = try await send("POST", "/me/library/playlists/\(playlistID)/tracks",
                           body: ["data": catalogIDs.map { ["id": $0, "type": "songs"] }])
    }

    /// Removal is by the track's identifier *within the playlist*, which is not
    /// the catalog identifier — the same recording added twice has two of them.
    func removeTrack(from playlistID: String, libraryID: String) async throws {
        _ = try await send(
            "DELETE",
            "/me/library/playlists/\(playlistID)/tracks"
                + "?ids%5Blibrary-songs%5D=\(libraryID)&mode=all")
    }

    // MARK: Library membership

    func addToLibrary(catalogID: String, type: String) async throws {
        _ = try await send("POST", "/me/library?ids%5B\(type)%5D=\(catalogID)")
    }

    func removeFromLibrary(libraryID: String, type: String) async throws {
        _ = try await send("DELETE", "/me/library/\(type)/\(libraryID)")
    }

    /// The library identifier for something known only by its catalog id.
    ///
    /// Needed because adding and removing speak different dialects: you add by
    /// catalog id and delete by library id, and nothing in the add response
    /// tells you the second one.
    func libraryID(forCatalog catalogID: String, type: String) async -> String? {
        struct Entry: Decodable {
            struct PlayParams: Decodable { let catalogId: String? }
            struct Attributes: Decodable { let playParams: PlayParams? }
            let id: String
            let attributes: Attributes?
        }
        struct Payload: Decodable { let data: [Entry] }

        guard let data = try? await send(
            "GET", "/me/library/\(type)?limit=100&sort=-dateAdded"),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        return payload.data.first { $0.attributes?.playParams?.catalogId == catalogID }?.id
    }

    /// Whether something is already in the library.
    func isInLibrary(catalogID: String, type: String) async -> Bool {
        await libraryID(forCatalog: catalogID, type: type) != nil
    }

    /// Playlists the user is allowed to write to.
    ///
    /// Separate from `classicalPlaylists()`: that one answers "what is worth
    /// browsing", this one answers "where can this recording go". Apple's own
    /// favourites playlist reports `canEdit false` and is excluded by that.
    func editablePlaylists() async throws -> [PlaylistSummary] {
        try await classicalPlaylists().filter { $0.canEdit }
    }

    // MARK: Transport

    @discardableResult
    func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let creds = TokenStore.shared.credentials else { throw APIError.noCredentials }
        guard let url = URL(string: "https://amp-api.music.apple.com/v1" + path) else {
            throw APIError.http(-1)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(creds.developerToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.musicUserToken, forHTTPHeaderField: "Music-User-Token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            FileHandle.standardError.write(
                Data("[library] \(method) \(path) → \(code)\n".utf8))
            throw APIError.http(code)
        }
        return data
    }
}

// MARK: - Playlist store

/// The playlists the app can write to, kept in one place so every menu that
/// offers them shows the same list and a newly created one appears everywhere
/// at once.
@MainActor
@Observable
final class PlaylistStore {
    static let shared = PlaylistStore()

    private(set) var playlists: [LibraryAPI.PlaylistSummary] = []
    private(set) var busy = false

    /// What just happened, for the one line of feedback a write deserves.
    var notice: String?

    func loadIfNeeded() async {
        guard playlists.isEmpty else { return }
        await refresh()
    }

    func refresh() async {
        playlists = (try? await LibraryAPI.shared.editablePlaylists()) ?? []
    }

    func create(name: String, adding catalogIDs: [String] = []) async {
        busy = true
        defer { busy = false }
        do {
            let id = try await LibraryAPI.shared.createPlaylist(
                name: name, catalogIDs: catalogIDs)
            // Inserted rather than refetched. The listing endpoint is eventually
            // consistent: a playlist created a moment ago is not in it yet, so
            // refreshing here produced the same list as before and the new
            // playlist simply did not appear until the next launch.
            playlists.append(LibraryAPI.PlaylistSummary(id: id, name: name, canEdit: true))
            playlists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            announce("Playlist “\(name)” criada.")
        } catch {
            announce("Não consegui criar a playlist.")
        }
    }

    func rename(_ summary: LibraryAPI.PlaylistSummary, to name: String) async {
        do {
            try await LibraryAPI.shared.renamePlaylist(id: summary.id, name: name)
            // Same reason as create: the listing lags the write.
            if let index = playlists.firstIndex(where: { $0.id == summary.id }) {
                playlists[index] = LibraryAPI.PlaylistSummary(
                    id: summary.id, name: name, canEdit: summary.canEdit)
            }
            announce("Renomeada para “\(name)”.")
        } catch {
            announce("Não consegui renomear.")
        }
    }

    func delete(_ summary: LibraryAPI.PlaylistSummary) async {
        do {
            try await LibraryAPI.shared.deletePlaylist(id: summary.id)
            playlists.removeAll { $0.id == summary.id }
            await ScreenCache.shared.forget(LibraryRoute.playlists)
            announce("Playlist “\(summary.name)” apagada.")
        } catch {
            announce("Não consegui apagar.")
        }
    }

    func add(catalogIDs: [String], to summary: LibraryAPI.PlaylistSummary) async {
        do {
            try await LibraryAPI.shared.addTracks(to: summary.id, catalogIDs: catalogIDs)
            await ScreenCache.shared.forget(LibraryRoute.playlist(summary.id))
            announce(catalogIDs.count == 1
                     ? "Adicionada a “\(summary.name)”."
                     : "\(catalogIDs.count) faixas adicionadas a “\(summary.name)”.")
        } catch {
            announce("Não consegui adicionar.")
        }
    }

    func remove(libraryID: String, from playlistID: String, named name: String) async {
        do {
            try await LibraryAPI.shared.removeTrack(from: playlistID, libraryID: libraryID)
            await ScreenCache.shared.forget(LibraryRoute.playlist(playlistID))
            announce("Removida de “\(name)”.")
        } catch {
            announce("Não consegui remover.")
        }
    }

    private var noticeTask: Task<Void, Never>?

    private func announce(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}

// MARK: - Library membership, as the UI sees it

/// Whether a recording is in the library, and the toggle for it.
///
/// Kept apart from `Favourites` on purpose: adding to the library and marking a
/// favourite are different acts, and the official app treats them so. Conflating
/// them is why the star seemed to lie.
@MainActor
@Observable
final class LibraryMembership {
    static let shared = LibraryMembership()

    private var known: [String: Bool] = [:]
    private var inFlight: Set<String> = []

    func contains(_ catalogID: String) -> Bool? { known[catalogID] }

    func check(_ catalogID: String, type: String = "songs") {
        guard known[catalogID] == nil, !inFlight.contains(catalogID) else { return }
        inFlight.insert(catalogID)
        Task {
            let present = await LibraryAPI.shared.isInLibrary(catalogID: catalogID, type: type)
            known[catalogID] = present
            inFlight.remove(catalogID)
        }
    }

    func toggle(_ catalogID: String, type: String = "songs") {
        let present = known[catalogID] ?? false
        known[catalogID] = !present

        Task {
            if present {
                if let libraryID = await LibraryAPI.shared.libraryID(
                    forCatalog: catalogID, type: type) {
                    try? await LibraryAPI.shared.removeFromLibrary(
                        libraryID: libraryID, type: type)
                }
            } else {
                try? await LibraryAPI.shared.addToLibrary(catalogID: catalogID, type: type)
            }
            // The write is accepted asynchronously, so the truth is read back
            // rather than assumed — the same lesson the star taught.
            try? await Task.sleep(for: .seconds(3))
            known[catalogID] = await LibraryAPI.shared.isInLibrary(
                catalogID: catalogID, type: type)
        }
    }
}
