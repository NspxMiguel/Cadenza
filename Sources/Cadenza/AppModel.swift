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
    /// Rows beyond what the screen endpoint returns, fetched separately.
    private(set) var extraItems: [Item] = []
    private(set) var isLoadingMore = false
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
                        path: "/query/view/\(storefront)//recently-added"),
            // The catalog offers favourites for recordings, works and composers
            // but not for songs — those live in a playlist Apple keeps, mixed
            // across genres. This is that playlist, kept to classical.
            Destination(name: "Músicas favoritas", symbol: "star",
                        path: LibraryRoute.favouriteSongs),
            // Files on this Mac. Not part of Apple's library at all, which is
            // exactly why it belongs here: nothing else in the app can reach
            // a recording that was never on the service.
            Destination(name: "Músicas locais", symbol: "internaldrive",
                        path: LocalRoute.path),
            Destination(name: "Álbuns locais", symbol: "square.stack.3d.up",
                        path: LocalRoute.albums)
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
        await PlaylistStore.shared.refresh()
        rebuildPlaylistRows()
    }

    /// Called again after every create, rename or delete, so the sidebar is a
    /// view of the store rather than a snapshot taken once at launch.
    func rebuildPlaylistRows() {
        playlists = PlaylistStore.shared.playlists.map {
            Destination(name: $0.name, symbol: "music.note.list",
                        path: LibraryRoute.playlist($0.id))
        }
    }

    /// The playlist being looked at, when it is one the user can edit.
    var currentPlaylist: LibraryAPI.PlaylistSummary? {
        guard let path = current?.path, path.hasPrefix(LibraryRoute.playlistPrefix)
        else { return nil }
        let id = String(path.dropFirst(LibraryRoute.playlistPrefix.count))
        return PlaylistStore.shared.playlists.first { $0.id == id }
    }

    /// Drops a screen from the cache and rereads it — used after the app itself
    /// changes what is on it.
    func refreshCurrent() async {
        guard let path = current?.path else { return }
        await ScreenCache.shared.forget(path)
        await reload()
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
        // The library screens had no Play button at all, which is where the
        // listener spends most of their time. They have no catalog identifier
        // to queue, so the header plays their rows instead.
        if let items = screen?.firstPage?.items, items.contains(where: \.isTrack) {
            return Payload(id: "cadenza-screen", type: "screen")
        }
        return nil
    }

    /// The rows a "play this screen" button should queue.
    var screenTracks: [Item] {
        ((screen?.firstPage?.items ?? []) + extraItems).filter(\.isTrack)
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

    /// Whether the screen being fetched is still the one being looked at.
    ///
    /// Every fetch below crosses an `await`, and the user can move in that
    /// gap. Without this check the *slowest* request wins rather than the
    /// newest: clicking Músicas locais — which needs no network and appears
    /// instantly — while the favourites request was still in flight put the
    /// favourites back on screen a second later, under a sidebar that said
    /// Músicas locais. It looked like the click had been ignored.
    private func stillWanted(_ path: String) -> Bool { current?.path == path }

    /// Screens assembled from files on this Mac. They need no network, so they
    /// render at once and have nothing to revalidate behind them.
    private func localScreen(for path: String) -> Screen? {
        switch path {
        case LocalRoute.path: LocalLibrary.shared.screen()
        case LocalRoute.albums: LocalLibrary.shared.albumsScreen()
        default:
            path.hasPrefix(LocalRoute.albumPrefix)
                ? LocalLibrary.shared.albumScreen(
                    name: String(path.dropFirst(LocalRoute.albumPrefix.count)))
                : nil
        }
    }

    func reload() async {
        guard let path = current?.path else { return }
        error = nil

        // Stale-while-revalidate: show what we already have, then refresh
        // behind it. A spinner appears only when there is nothing to show.
        extraItems = []
        // The local library is already in memory, so it renders at once and
        // has nothing to revalidate behind it.
        if let local = localScreen(for: path) {
            screen = local
            isLoading = false
            return
        }

        let cached = await ClassicalAPI.shared.cachedScreen(at: path)
        guard stillWanted(path) else { return }
        if let cached {
            screen = cached
            isLoading = false
        } else {
            screen = nil
            isLoading = true
        }
        defer { if stillWanted(path) { isLoading = false } }

        do {
            let fetched: Screen
            if path == LibraryRoute.favouriteSongs {
                fetched = try await LibraryAPI.shared.favouriteSongsScreen()
            } else if path == LibraryRoute.playlists {
                fetched = try await LibraryAPI.shared.playlistsScreen()
            } else if path.hasPrefix(LibraryRoute.playlistPrefix) {
                let id = String(path.dropFirst(LibraryRoute.playlistPrefix.count))
                fetched = try await LibraryAPI.shared.playlistScreen(
                    id: id, name: current?.name ?? "Playlist")
            } else {
                fetched = try await ClassicalAPI.shared.screen(at: path)
            }
            guard stillWanted(path) else { return }
            screen = fetched
        } catch {
            // A failed refresh must not wipe a screen that is already readable,
            // and must not report on a screen the user has already left.
            guard stillWanted(path) else { return }
            if screen == nil { self.error = error.localizedDescription }
        }

        await loadRemainder(for: path)
    }

    /// Long lists arrive truncated, and the screen endpoint will not serve the
    /// rest. The catalog API will.
    private func loadRemainder(for path: String) async {
        guard let page = screen?.firstPage, page.hasMore, let offset = page.offset else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let more = await LibraryAPI.shared.remainingTracks(forScreenPath: path, from: offset)
        guard current?.path == path else { return }
        extraItems = more
    }
}
