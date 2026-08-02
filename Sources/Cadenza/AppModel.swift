import Foundation
import Observation

/// One entry in the sidebar. Library destinations are not hardcoded — they are
/// read from the live `favorites` screen, because their query strings carry sort
/// and filter parameters that are Apple's to change, not ours to guess.
struct Destination: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let symbol: String
    let path: String

    static func == (a: Destination, b: Destination) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

@MainActor
@Observable
final class AppModel {
    private(set) var fixed: [Destination] = []
    private(set) var library: [Destination] = []
    private(set) var playlists: [Destination] = []

    private(set) var screen: Screen?
    private(set) var isLoading = false
    private(set) var error: String?

    /// Where we are, so back navigation works without SwiftUI owning the state.
    private(set) var history: [Destination] = []
    var current: Destination? { history.last }
    var canGoBack: Bool { history.count > 1 }

    var needsLogin: Bool { TokenStore.shared.credentials == nil }

    private var storefront: String { TokenStore.shared.credentials?.storefront ?? "us" }

    // MARK: Bootstrap

    func start() async {
        guard !needsLogin else { return }
        fixed = [
            Destination(name: "Início", symbol: "house", path: "/query/view/\(storefront)/listen-now"),
            Destination(name: "Explorar", symbol: "square.grid.2x2", path: "/query/view/\(storefront)/browse"),
        ]
        if history.isEmpty, let home = fixed.first { history = [home] }
        await loadLibraryDestinations()
        await reload()
    }

    /// Reads the library sidebar from the API rather than assuming its routes,
    /// then arranges it the way the official client does: recently added first,
    /// playlists pulled out into their own group.
    private func loadLibraryDestinations() async {
        var entries: [Destination] = [
            Destination(name: "Adições recentes", symbol: "clock",
                        path: "/query/view/\(storefront)//recently-added")
        ]
        var playlistRoot: Destination?

        do {
            let root = try await ClassicalAPI.shared.screen(at: "/query/view/\(storefront)/favorites")
            var found: [String: Destination] = [:]
            for item in root.allItems {
                guard let name = item.title, let path = item.action?.url,
                      let screenType = item.action?.screenType else { continue }
                let destination = Destination(
                    name: name, symbol: Self.symbol(for: screenType), path: path)
                if screenType == "libraryPlaylists" {
                    playlistRoot = destination
                } else {
                    found[screenType] = destination
                }
            }
            // The order Apple uses, rather than whatever the response happens to
            // list first.
            for key in ["libraryAlbums", "libraryTracks", "libraryArtists",
                        "favoritesRecordings", "favoritesWorks", "favoritesComposers"] {
                if let destination = found[key] { entries.append(destination) }
            }
        } catch {
            // A missing sidebar should not stop the app from showing Home.
        }

        library = entries
        await loadPlaylists(root: playlistRoot)
    }

    /// The user's own playlists, listed individually the way the official app
    /// shows them rather than hidden behind one row.
    /// Playlists come from the personal Apple Music library, not from the
    /// classical catalog — `favorites/playlists` genuinely answers "Nenhuma
    /// playlist", because classical keeps no playlist library of its own.
    private func loadPlaylists(root: Destination?) async {
        playlists = [Destination(name: "Playlists da biblioteca",
                                 symbol: "music.note.list",
                                 path: LibraryRoute.playlists)]
    }



    private static func symbol(for screenType: String?) -> String {
        switch screenType {
        case "libraryAlbums": "square.stack"
        case "libraryPlaylists": "music.note.list"
        case "libraryTracks": "music.note"
        case "libraryArtists": "person.2"
        case "favoritesRecordings": "waveform"
        case "favoritesWorks": "doc.text"
        case "favoritesComposers": "person.crop.square"
        default: "circle"
        }
    }

    // MARK: Navigation

    func go(to destination: Destination) async {
        history.append(destination)
        await reload()
    }

    /// Follows a section's "see all" button.
    func go(toAction action: Action, named title: String) async {
        guard let path = action.url else { return }
        await go(to: Destination(name: title, symbol: "square.grid.2x2", path: path))
    }

    func open(_ item: Item) async {
        guard let path = item.action?.url else { return }
        await go(to: Destination(name: item.title ?? "", symbol: "circle", path: path))
    }

    func goBack() async {
        guard canGoBack else { return }
        history.removeLast()
        await reload()
    }

    /// Jumps to a sidebar root, replacing history rather than stacking onto it.
    func select(_ destination: Destination) async {
        history = [destination]
        await reload()
    }

    /// A playlist or album screen is itself playable: its identifier is right
    /// there in the path, so the whole thing can be queued without resolving
    /// every track first.
    var playableContext: Payload? {
        guard let path = current?.path else { return nil }
        if let id = Self.firstMatch(#"/playlist/(pl\.[A-Za-z0-9]+)"#, in: path) {
            return Payload(id: id, type: "playlists")
        }
        if let id = Self.firstMatch(#"/album/(\d+)"#, in: path) {
            return Payload(id: id, type: "albums")
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    // MARK: Search

    var searchTerm = "" {
        didSet {
            guard searchTerm != oldValue else { return }
            searchTask?.cancel()
            let term = searchTerm.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2 else {
                if isSearching { Task { await exitSearch() } }
                return
            }
            searchTask = Task { [weak self] in
                // Debounced: the field fires on every keystroke.
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await self?.runSearch(term)
            }
        }
    }

    private(set) var isSearching = false
    private var searchTask: Task<Void, Never>?
    private var historyBeforeSearch: [Destination] = []

    private func runSearch(_ term: String) async {
        guard let encoded = term.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) else { return }
        if !isSearching {
            historyBeforeSearch = history
            isSearching = true
        }
        history = [Destination(
            name: "Busca", symbol: "magnifyingglass",
            path: "/query/view/\(storefront)/browse-search?q=\(encoded)")]
        await reload()
    }

    private func exitSearch() async {
        isSearching = false
        if !historyBeforeSearch.isEmpty {
            history = historyBeforeSearch
            historyBeforeSearch = []
            await reload()
        }
    }

    func reload() async {
        guard let path = current?.path else { return }
        error = nil

        // Stale-while-revalidate: show what we already have, then refresh
        // behind it. A spinner appears only when there is nothing to show.
        if let cached = await ClassicalAPI.shared.cachedScreen(at: path) {
            screen = cached
            isLoading = false
        } else {
            screen = nil
            isLoading = true
        }
        defer { isLoading = false }

        do {
            if path == LibraryRoute.playlists {
                screen = try await LibraryAPI.shared.playlistsScreen()
            } else if path.hasPrefix(LibraryRoute.playlistPrefix) {
                let id = String(path.dropFirst(LibraryRoute.playlistPrefix.count))
                screen = try await LibraryAPI.shared.playlistScreen(
                    id: id, name: current?.name ?? "Playlist")
            } else {
                screen = try await ClassicalAPI.shared.screen(at: path)
            }
        } catch {
            // A failed refresh must not wipe a screen that is already readable.
            if screen == nil { self.error = error.localizedDescription }
        }
    }
}
