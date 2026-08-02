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

    /// Reads the library sidebar from the API rather than assuming its routes.
    private func loadLibraryDestinations() async {
        do {
            let root = try await ClassicalAPI.shared.screen(at: "/query/view/\(storefront)/favorites")
            library = root.allItems.compactMap { item in
                guard let name = item.title, let path = item.action?.url else { return nil }
                return Destination(name: name, symbol: Self.symbol(for: item.action?.screenType), path: path)
            }
        } catch {
            // A missing sidebar should not stop the app from showing Home.
            library = []
        }
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

    func reload() async {
        guard let path = current?.path else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            screen = try await ClassicalAPI.shared.screen(at: path)
        } catch {
            self.error = error.localizedDescription
            screen = nil
        }
    }
}
