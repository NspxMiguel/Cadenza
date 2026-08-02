import AppKit
import SwiftUI
// TranslationSession predates strict concurrency: it is a plain class, and
// translationTask's closure is not @Sendable, so it inherits the view's main
// actor. Calling a nonisolated async method on it then reads as sending a
// non-Sendable value, though the session never leaves the main actor here.
@preconcurrency import Translation
import UniformTypeIdentifiers

// MARK: - Root

struct RootView: View {
    @State private var model = AppModel()
    @State private var showingLogin = false
    @State private var expanded = false

    /// Filtering and ordering belong to the screen being looked at, not to the
    /// app: carrying a filter from one album into the next would hide most of
    /// the next one for no reason the user could see. All three reset on
    /// navigation. They live here rather than in ScreenView because a toolbar
    /// declared inside the detail column never reached the window.
    @State private var filter = ""
    @State private var order: TrackOrder = .original
    @State private var onlyFavourites = false

    /// True where these controls mean something — a list of tracks. A wall of
    /// shelves has nothing to sort.
    private var isTrackList: Bool {
        guard let page = model.screen?.firstPage else { return false }
        return !page.isEmptyState && page.items.contains(where: \.isTrack)
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            ScreenView(model: model, filter: filter, order: order,
                       onlyFavourites: onlyFavourites)
            // The player floats over the list rather than displacing it, which
            // is why the pill has to be an overlay and not another row. The
            // status line rides above it in the same stack: left at the bottom
            // of the window it was drawn *under* the pill and clipped by the
            // window edge, which is why it could not be read.
            .overlay(alignment: .bottom) {
                VStack(spacing: 8) {
                    StatusStrip()
                    FloatingPlayer(expanded: $expanded)
                }
            }
            .overlay(alignment: .bottomLeading) {
                EngineHost().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
            .overlay {
                if expanded { NowPlayingScreen(expanded: $expanded) }
            }
            .animation(.snappy(duration: 0.28), value: expanded)
            // A write that succeeds silently is indistinguishable from one that
            // failed silently, so every one of them says what it did.
            .overlay(alignment: .top) {
                if let notice = LocalLibrary.shared.notice ?? PlaylistStore.shared.notice {
                    Text(notice)
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .shadow(radius: 6, y: 2)
                        .padding(.top, 12)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: LocalLibrary.shared.notice ?? PlaylistStore.shared.notice)
        }
        .searchable(text: Binding(
            get: { model.searchTerm },
            set: { model.searchTerm = $0 }
        ), placement: .sidebar, prompt: "Obras, compositores, gravações")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await model.goBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)
                .help("Voltar")
            }

            // Nothing about playback lives up here. Music keeps the title bar
            // for what the screen is, and the player floats over the content.
            ToolbarItem(placement: .primaryAction) {
                if isTrackList { listControls }
            }

            ToolbarItem(placement: .primaryAction) {
                if model.current?.path == LocalRoute.path {
                    Button {
                        LocalLibrary.shared.promptForFiles()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help("Importar arquivos de música deste Mac")
                }
            }
        }
        // The page names itself in its own header. Repeating it in the title
        // bar only crowded the player, and Music does not do it either.
        .navigationTitle("")
        .onChange(of: model.current?.path) { _, _ in
            filter = ""
            order = .original
            onlyFavourites = false
        }
        .task {
            if model.needsLogin {
                showingLogin = true
            } else {
                Task { await Playback.shared.start() }
                await model.start()
            }
        }
        .sheet(isPresented: $showingLogin) {
            LoginSheet {
                showingLogin = false
                Task { await Playback.shared.start() }
                Task { await model.start() }
            }
        }
    }

    /// The sort menu and the in-screen search field, the way Music puts them:
    /// top right, above the list they act on.
    private var listControls: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("Ordenar por", selection: $order) {
                    ForEach(TrackOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Só favoritas", isOn: $onlyFavourites)
            } label: {
                Image(systemName: order == .original && !onlyFavourites
                      ? "line.3.horizontal.decrease"
                      : "line.3.horizontal.decrease.circle.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
            .help("Ordenar e filtrar")

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // A plain field rather than a second `.searchable`: the sidebar
                // already owns that modifier for catalog search, and two of them
                // in one window fight over the same keyboard shortcut.
                TextField("Buscar nesta lista", text: $filter)
                    .textFieldStyle(.plain)
                    .frame(width: 140)
                if !filter.isEmpty {
                    Button { filter = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}

// MARK: - Login

/// Credentials are only obtainable from a signed-in session, so first run hands
/// the user Apple's own login page and waits for the harvester to fire.
struct LoginSheet: View {
    let onComplete: () -> Void
    @State private var probe = DRMProbe()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Entre com seu Apple ID para o Cadenza acessar seu catálogo.")
                    .font(.callout)
                Spacer()
                Button("Cancelar", action: onComplete)
            }
            .padding(12)

            Divider()
            ClassicalWebView(probe: probe)
        }
        .frame(width: 980, height: 700)
        .task {
            // The harvester runs in the page; poll until it has both tokens.
            while !Task.isCancelled {
                if TokenStore.shared.credentials != nil { onComplete(); return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    let model: AppModel

    var body: some View {
        List(selection: Binding(
            get: { model.history.first },
            set: { if let d = $0 { Task { await model.select(d) } } }
        )) {
            ForEach(model.fixed) { row($0) }

            if !model.library.isEmpty {
                Section("Biblioteca") {
                    ForEach(model.library) { row($0) }
                }
            }

            Section {
                ForEach(model.playlists) { destination in
                    row(destination)
                        .contextMenu { playlistMenu(for: destination) }
                }
                Label("Nova playlist…", systemImage: "plus")
                    .foregroundStyle(.secondary)
                    .onTapGesture { creating = true }
            } header: {
                Text("Playlists")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 6) }
        .alert("Nova playlist", isPresented: $creating) {
            TextField("Nome", text: $draftName)
            Button("Cancelar", role: .cancel) { draftName = "" }
            Button("Criar") { commitCreate() }
        }
        .alert("Renomear playlist", isPresented: $renaming) {
            TextField("Nome", text: $draftName)
            Button("Cancelar", role: .cancel) { draftName = "" }
            Button("Renomear") { commitRename() }
        }
        .confirmationDialog(
            "Apagar “\(target?.name ?? "")”?",
            isPresented: $deleting, titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) { commitDelete() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A playlist sai da sua biblioteca do Apple Music. As músicas continuam lá.")
        }
    }

    @State private var creating = false
    @State private var renaming = false
    @State private var deleting = false
    @State private var draftName = ""
    @State private var target: LibraryAPI.PlaylistSummary?

    @ViewBuilder
    private func playlistMenu(for destination: Destination) -> some View {
        if let summary = summary(for: destination) {
            Button("Renomear…") {
                target = summary
                draftName = summary.name
                renaming = true
            }
            Button("Apagar…", role: .destructive) {
                target = summary
                deleting = true
            }
        }
    }

    private func summary(for destination: Destination) -> LibraryAPI.PlaylistSummary? {
        let id = String(destination.path.dropFirst(LibraryRoute.playlistPrefix.count))
        return PlaylistStore.shared.playlists.first { $0.id == id }
    }

    private func commitCreate() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        draftName = ""
        guard !name.isEmpty else { return }
        Task {
            await PlaylistStore.shared.create(name: name)
            model.rebuildPlaylistRows()
        }
    }

    private func commitRename() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        draftName = ""
        guard !name.isEmpty, let target else { return }
        Task {
            await PlaylistStore.shared.rename(target, to: name)
            model.rebuildPlaylistRows()
        }
    }

    private func commitDelete() {
        guard let target else { return }
        Task {
            await PlaylistStore.shared.delete(target)
            model.rebuildPlaylistRows()
        }
    }

    private func row(_ destination: Destination) -> some View {
        Label(destination.name, systemImage: destination.symbol)
            .tag(destination)
    }
}

// MARK: - Screen

struct ScreenView: View {
    let model: AppModel
    @State private var droppingHere = false

    /// Owned by RootView, because a toolbar declared this deep inside the
    /// detail column is silently dropped — the sort menu and the search field
    /// simply never appeared.
    var filter: String = ""
    var order: TrackOrder = .original
    var onlyFavourites = false

    var body: some View {
        Group {
            if let error = model.error {
                ContentUnavailableView("Não foi possível carregar",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let screen = model.screen {
                if let page = screen.firstPage, !page.isEmptyState {
                    VStack(spacing: 0) {
                        if let header = screen.header {
                            ScreenHeader(header: header, context: model.playableContext, model: model)
                        }
                        TrackListView(page: page, extra: model.extraItems,
                                      loadingMore: model.isLoadingMore, model: model,
                                      filter: filter, order: order,
                                      onlyFavourites: onlyFavourites)
                    }
                } else if screen.screenType == LocalRoute.screenType,
                          let page = screen.firstPage, page.isEmptyState {
                    LocalEmptyState(heading: page.heading ?? "Nenhum arquivo importado",
                                    description: page.description ?? "")
                } else if screen.sections.isEmpty, let page = screen.firstPage {
                    ContentUnavailableView(
                        page.heading ?? screen.title ?? "Vazio",
                        systemImage: "music.note.list",
                        description: Text(page.description ?? ""))
                } else {
                    VStack(spacing: 0) {
                        if let header = screen.header, header.isDecorative {
                            ScreenHeader(header: header,
                                         context: model.playableContext, model: model)
                        }
                        content(screen)
                    }
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Room for the floating player, so the last row of a list is not left
        // sitting under it.
        .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 84) }
        // Dropping onto the populated list works too, not just the empty state.
        .localMusicDrop(isTargeted: $droppingHere)
        // No page title in the title bar: the screen already names itself in
        // its own header, and repeating it there shoved the player off centre.
        .navigationTitle("")
        .overlay(alignment: .top) {
            if model.isLoading && model.screen != nil {
                ProgressView().controlSize(.small).padding(6)
            }
        }
    }

    private func content(_ screen: Screen) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(Array(screen.sections.enumerated()), id: \.offset) { _, section in
                    ForEach(Array(section.components.enumerated()), id: \.offset) { _, component in
                        if !component.items.isEmpty {
                            // The API distinguishes a shelf of covers from a
                            // list of rows. Rendering a track list as cards
                            // produced a wall of placeholder initials, because
                            // individual tracks carry no artwork of their own.
                            if component.type == "list" {
                                SectionListView(
                                    component: component,
                                    heading: section.displayTitle,
                                    seeAll: section.heading?.seeAll,
                                    sectionType: section.type,
                                    model: model)
                            } else {
                                ShelfView(
                                    component: component,
                                    heading: section.displayTitle,
                                    seeAll: section.heading?.seeAll,
                                    model: model)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }
}

/// The local library before anything is in it.
///
/// Written by hand rather than with `ContentUnavailableView` because that view
/// lays its actions out in a row: the button and the note about formats ended
/// up side by side, which put the button off-centre and buried the note next
/// to it. The button belongs under the sentence it answers, and the small
/// print belongs at the bottom.
struct LocalEmptyState: View {
    let heading: String
    let description: String

    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            Image(systemName: targeted ? "square.and.arrow.down" : "internaldrive")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .padding(.bottom, 18)

            Text(targeted ? "Solte para importar" : heading)
                .font(.cadenzaTitle(24))
                .padding(.bottom, 8)

            Text(description)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(.bottom, 20)

            Button("Importar músicas…") { LocalLibrary.shared.promptForFiles() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            Text("…ou arraste arquivos e pastas para esta janela.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)

            Spacer()

            Text("MP3, AAC, ALAC, FLAC, WAV, AIFF, CAF, Ogg e mais. Cada arquivo é "
                 + "testado ao importar; o que este Mac não decodificar é informado.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(14)
            }
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
        .localMusicDrop(isTargeted: $targeted)
    }
}

/// Accepts audio files dropped anywhere on the view.
///
/// Offered on the whole library screen, not only the empty state: dragging a
/// folder in is the fastest way to add music, and it should keep working once
/// there is already something there.
struct LocalMusicDrop: ViewModifier {
    @Binding var isTargeted: Bool

    func body(content: Content) -> some View {
        content.onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    guard let item = try? await provider.loadItem(
                        forTypeIdentifier: "public.file-url") else { continue }
                    // A dropped file arrives either as bytes holding the URL
                    // string or as the URL itself, depending on the source.
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    } else if let url = item as? URL {
                        urls.append(url)
                    }
                }
                guard !urls.isEmpty else { return }
                await LocalLibrary.shared.importItems(urls)
            }
            return true
        }
    }
}

extension View {
    func localMusicDrop(isTargeted: Binding<Bool>) -> some View {
        modifier(LocalMusicDrop(isTargeted: isTargeted))
    }
}

// MARK: - Shelf

struct ShelfView: View {
    let component: Component
    var heading: String? = nil
    var seeAll: Action? = nil
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = component.heading ?? heading, !title.isEmpty {
                HStack(spacing: 5) {
                    Text(title).font(.cadenzaHeading)
                    if seeAll?.url != nil {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 24)
                .onTapGesture {
                    guard let action = seeAll, action.url != nil else { return }
                    Task { await model.go(toAction: action, named: title) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(component.items) { item in
                        ItemCard(item: item)
                            .onTapGesture { Task { await model.open(item) } }
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }
}

struct ItemCard: View {
    let item: Item
    @State private var hovering = false

    /// Editorial items are wide banners; catalog items are square tiles.
    private var isFeatured: Bool { item.type == "featured" }
    private var width: CGFloat { isFeatured ? 420 : 176 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: item.image?.url(size: isFeatured ? 900 : 400)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    ArtworkPlaceholder(item: item)
                }
            }
            .frame(width: width, height: isFeatured ? 236 : 176)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottomLeading) {
                if hovering, item.playable != nil {
                    Button {
                        Playback.shared.play(item)
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)

            if let addition = item.addition, !addition.isEmpty {
                Text(addition.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if let title = item.title, !title.isEmpty {
                Text(title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Track list

/// List screens carry only row titles up front; the metadata that makes a
/// classical listing useful — movement, performers, duration — comes from a
/// second request, so rows stay deliberately plain until that lands.
/// How a list can be reordered.
///
/// `original` is not one option among five — it is the only correct one for a
/// work in movements, and the default everywhere for that reason. A symphony
/// sorted alphabetically is not a symphony.
enum TrackOrder: String, CaseIterable, Identifiable {
    case original, title, artist, duration

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Ordem do álbum"
        case .title: "Título"
        case .artist: "Intérprete"
        case .duration: "Duração"
        }
    }
}

struct TrackListView: View {
    let page: Page
    var extra: [Item] = []
    var loadingMore = false
    let model: AppModel
    var filter: String = ""
    var order: TrackOrder = .original
    var onlyFavourites = false

    private var allItems: [Item] { page.items + extra }

    /// The rows to draw, after filtering and sorting.
    ///
    /// Headings are dropped when nothing under them survives: a work title
    /// standing alone over no movements is a lie about what is in the list.
    /// Sorting drops them entirely, because once the movements are out of order
    /// the grouping they announce no longer holds.
    private var visible: [Item] {
        var items = allItems

        if onlyFavourites {
            items = items.filter { $0.isTrack && Favourites.shared.isFavourite($0) }
        }

        let needle = Self.fold(filter)
        if !needle.isEmpty {
            items = items.filter { item in
                guard item.isTrack else { return true }
                return Self.fold([item.title, item.subtitle, item.addition]
                    .compactMap { $0 }.joined(separator: " ")).contains(needle)
            }
        }

        switch order {
        case .original: break
        case .title:
            items = items.filter(\.isTrack).sorted {
                ($0.title ?? "").localizedStandardCompare($1.title ?? "") == .orderedAscending
            }
        case .artist:
            items = items.filter(\.isTrack).sorted {
                ($0.subtitle ?? "").localizedStandardCompare($1.subtitle ?? "") == .orderedAscending
            }
        case .duration:
            items = items.filter(\.isTrack).sorted { ($0.durationMs ?? 0) < ($1.durationMs ?? 0) }
        }

        return Self.withoutOrphanHeadings(items)
    }

    /// Removes headings that no longer have a track beneath them.
    private static func withoutOrphanHeadings(_ items: [Item]) -> [Item] {
        items.enumerated().filter { index, item in
            guard item.isHeading else { return true }
            let next = items.dropFirst(index + 1).first
            return next?.isTrack == true
        }.map(\.element)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    /// Track numbering restarts under each work, and headings are not counted —
    /// they are work titles standing above their movements, not playable rows.
    private var numbered: [(item: Item, number: Int?)] {
        var counter = 0
        return visible.map { item in
            guard item.isTrack else { counter = 0; return (item, nil) }
            counter += 1
            return (item, counter)
        }
    }

    private func play(_ item: Item) {
        // Played within what is on screen, not within the whole page: if the
        // list is filtered or sorted, the queue should follow what the listener
        // is actually looking at.
        Playback.shared.play(item, within: visible.filter(\.isTrack))
    }

    var body: some View {
        List {
            if !filter.isEmpty && !numbered.contains(where: { $0.item.isTrack }) {
                Text("Nada nesta tela corresponde a “\(filter)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(numbered, id: \.item.id) { entry in
                if entry.item.isHeading {
                    WorkHeadingRow(item: entry.item, model: model)
                } else {
                    TrackRow(item: entry.item, number: entry.number,
                             playlist: model.currentPlaylist, model: model)
                        .contentShape(Rectangle())
                        .onTapGesture { play(entry.item) }
                        .contextMenu {
                            TrackMenu(item: entry.item, playlist: model.currentPlaylist,
                                      model: model)
                        }
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .bottom) {
            if loadingMore {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Carregando o restante…").font(.caption).foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
            }
        }
    }
}

/// What can be done to a track besides playing it.
///
/// Four separate ideas the official app also keeps separate, and which this app
/// conflated until now: playing, favouriting, belonging to the library, and
/// belonging to a playlist. A recording can be any combination of those.
struct TrackMenu: View {
    let item: Item
    var playlist: LibraryAPI.PlaylistSummary?
    let model: AppModel

    @State private var store = PlaylistStore.shared
    @State private var membership = LibraryMembership.shared

    private var catalogID: String? { item.playable?.id }

    var body: some View {
        // A local file is not in anyone's catalog: favouriting it, adding it to
        // an Apple playlist or to the Apple library are all meaningless, and
        // offering them would be offering actions that cannot work.
        if item.playable?.type == LocalRoute.payloadType, let id = catalogID {
            Button("Mostrar no Finder") {
                if let track = LocalLibrary.shared.track(id: id),
                   let url = LocalLibrary.shared.url(for: track) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("Remover da lista", role: .destructive) {
                guard let track = LocalLibrary.shared.track(id: id) else { return }
                LocalLibrary.shared.remove(track)
                Task { await model.reload() }
            }
        } else if let catalogID {
            Button(Favourites.shared.isFavourite(item) ? "Desfavoritar" : "Favoritar") {
                Favourites.shared.toggle(item)
            }
            // Asked for when the menu opens rather than for every visible row:
            // resolving library membership costs a request, and most rows are
            // never right-clicked.
            .onAppear { membership.check(catalogID) }

            Button(membership.contains(catalogID) == true
                   ? "Remover da biblioteca" : "Adicionar à biblioteca") {
                membership.toggle(catalogID)
            }

            if let album = item.albumAction {
                Button("Ir para o álbum") {
                    Task { await model.go(toAction: album, named: album.title ?? "Álbum") }
                }
            }

            Menu("Adicionar a playlist") {
                ForEach(store.playlists) { summary in
                    Button(summary.name) {
                        Task {
                            await store.add(catalogIDs: [catalogID], to: summary)
                            // The playlist does not contain the track the
                            // instant the write returns — rereading at once
                            // shows it still empty, which reads as a failure.
                            if model.currentPlaylist?.id == summary.id {
                                try? await Task.sleep(for: .seconds(3))
                                await model.refreshCurrent()
                            }
                        }
                    }
                }
                if !store.playlists.isEmpty { Divider() }
                Button("Nova playlist com esta faixa…") {
                    Task {
                        await store.create(name: item.title ?? "Nova playlist",
                                           adding: [catalogID])
                        model.rebuildPlaylistRows()
                    }
                }
            }

            // Only offered where it means something: a track can only be
            // removed from a playlist while that playlist is what is on screen,
            // and only by the identifier it has inside it.
            if let playlist, let libraryID = item.libraryID {
                Divider()
                Button("Remover desta playlist", role: .destructive) {
                    Task {
                        await store.remove(libraryID: libraryID, from: playlist.id,
                                           named: playlist.name)
                        await model.refreshCurrent()
                    }
                }
            }
        }
    }
}

/// A work title. Tapping it opens the work screen, which is the piece of
/// navigation the ordinary Apple Music app has no concept of.
struct WorkHeadingRow: View {
    let item: Item
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Text(item.title ?? "")
                .font(.cadenzaWork)
            if item.action?.url != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if item.action?.url != nil { Task { await model.open(item) } }
        }
    }
}

/// One row of a track list, in the shape Music gives it.
///
/// Columns: the favourite star, then the cover, then the words, then the time
/// and the menu. The number the row used to lead with is gone from the normal
/// case because it was redundant — a classical track titles itself "I. Molto
/// allegro", so the numeral is already in the words. It comes back only where
/// there is no cover to show, which is exactly the work screens, where the
/// movement number is the one thing orienting the reader.
struct TrackRow: View {
    let item: Item
    let number: Int?
    var playlist: LibraryAPI.PlaylistSummary? = nil
    var model: AppModel? = nil

    @State private var hovering = false

    private var isCurrent: Bool {
        item.playable?.id == Playback.shared.active.nowPlaying?.trackID
    }

    /// Only the catalog's own. It sends artwork on playlist rows and withholds
    /// it on album rows — where the cover is the same for every track and
    /// already sits 208pt above — so following it is following the server's
    /// judgement instead of overriding it with the same picture 22 times.
    private var artwork: Artwork? { item.image }

    private var isFavourite: Bool { Favourites.shared.isFavourite(item) }

    var body: some View {
        HStack(spacing: 11) {
            star
            cover
            words
            Spacer(minLength: 12)

            if let duration = item.duration {
                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if let model {
                Menu {
                    TrackMenu(item: item, playlist: playlist, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout)
                        .foregroundStyle(hovering ? AnyShapeStyle(.secondary)
                                         : AnyShapeStyle(Color.clear))
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 18)
                .disabled(item.playable == nil)
            }
        }
        .padding(.vertical, 3)
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary.opacity(0.5))
                    .padding(.horizontal, -8)
            }
        }
        .onHover { hovering = $0 }
    }

    /// Always present, so the column never shifts under the pointer — dimmed
    /// to nothing until the row is hovered or the track is actually a
    /// favourite.
    private var star: some View {
        Button {
            Favourites.shared.toggle(item)
        } label: {
            Image(systemName: isFavourite ? "star.fill" : "star")
                .font(.caption)
                .foregroundStyle(isFavourite ? AnyShapeStyle(.tint)
                                 : (hovering ? AnyShapeStyle(.secondary)
                                    : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .frame(width: 18)
        .disabled(item.playable == nil)
        .help(isFavourite ? "Desfavoritar" : "Favoritar")
    }

    private var cover: some View {
        ZStack {
            if let url = artwork?.url(size: 96) {
                AsyncImage(url: url) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                }
            } else {
                Rectangle().fill(.quaternary.opacity(0.4))
                    .overlay {
                        Text(number.map(String.init) ?? "")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
            }

            if isCurrent {
                Color.black.opacity(0.45)
                Image(systemName: Playback.shared.active.status == .playing
                      ? "waveform" : "speaker.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative,
                                  isActive: Playback.shared.active.status == .playing)
            } else if hovering, item.playable != nil {
                Color.black.opacity(0.45)
                Image(systemName: "play.fill")
                    .font(.callout)
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title ?? "—")
                .font(.body)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .lineLimit(1)

            // "Álbum – Intérprete" when both are known. The catalog puts the
            // performers in `subtitle` and the collection in `addition`, and
            // for a track row the two together are what identifies it.
            if let second = Self.secondLine(item) {
                Text(second)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// "Álbum — Intérpretes", where the album is known.
    ///
    /// It comes from `contextMenuAction.previewAction.title`, which the catalog
    /// attaches to playlist and search rows and omits on album rows. An earlier
    /// version composed this from `item.addition`; that field is empty in all
    /// 106 track rows in the cache, so the promised first half never appeared.
    private static func secondLine(_ item: Item) -> String? {
        let parts = [item.albumName, item.subtitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " — ")
    }
}

// MARK: - Now playing

/// A thin strip for what the app is doing, under the content.
///
/// The player itself moved to the title bar, where Apple Music keeps it. What
/// remains here is the two things that need a whole line to say: that a click
/// is being worked on, and that the score engine is grinding through a page.
struct StatusStrip: View {
    @State private var ai = ScoreAI.shared

    var body: some View {
        VStack(spacing: 0) {
            if let hint = Playback.shared.hint {
                line(icon: "info.circle", text: hint, working: false)
            }
            // Recognition takes minutes, and choosing the file closes the panel
            // that was showing its progress — so without this the app looks
            // idle while it saturates four cores.
            if case .working(let step) = ai.state {
                line(icon: nil, text: "Partitura por IA — " + step, working: true)
            }
        }
    }

    private func line(icon: String?, text: String, working: Bool) -> some View {
        HStack(spacing: 7) {
            if working {
                ProgressView().controlSize(.small)
            } else if let icon {
                Image(systemName: icon)
            }
            Text(text).font(.callout)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(.quaternary.opacity(0.5))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}


// MARK: - Screen header

/// The masthead of a playlist, album or work: cover, title, credits, and the
/// button that plays the whole thing.
struct ScreenHeader: View {
    let header: Header
    let context: Payload?
    var model: AppModel? = nil

    @State private var notesExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            cover
                .frame(width: 208, height: 208)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 12, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(header.title ?? "")
                    .font(.cadenzaTitle(27))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // A work names its composer; a recording names its performers.
                if let composer = header.composerName, !composer.isEmpty {
                    composerLink(composer)
                } else if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.title3).foregroundStyle(.tint).lineLimit(2)
                }

                HStack(spacing: 8) {
                    // On a work this is the catalogue number — K. 626 — which
                    // identifies the piece far better than a year would.
                    if header.composerName != nil, let catalogue = header.subtitle,
                       !catalogue.isEmpty {
                        Text(catalogue).font(.subheadline).foregroundStyle(.secondary)
                    } else if let extra = header.year ?? header.lastUpdated {
                        Text(extra).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if header.offersLossless {
                        Text("Lossless")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                            .help("Esta gravação é lossless no catálogo. "
                                  + "O motor atual reproduz em 256 kbps AAC.")
                    }
                }

                if let context {
                    HStack(spacing: 12) {
                        bigButton("Reproduzir", icon: "play.fill") {
                            start(context, shuffled: false)
                        }

                        // Offered on collections, withheld on a work. Shuffling
                        // the movements of a symphony is not a preference, it
                        // is a way of not hearing the piece — the movements are
                        // ordered by the composer, and the button would be an
                        // invitation to break that.
                        if header.composerName == nil {
                            bigButton("Aleatório", icon: "shuffle") {
                                start(context, shuffled: true)
                            }
                        }
                    }
                    .padding(.top, 6)
                }

                if let notes = header.editorialNotes?.text {
                    programmeNote(notes)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    /// A library screen has no catalog identifier to hand the player, so it
    /// queues its own rows instead. Everything else queues the collection.
    private func start(_ context: Payload, shuffled: Bool) {
        if context.type == "screen" {
            let tracks = model?.screenTracks ?? []
            guard let first = tracks.first else { return }
            Playback.shared.active.setShuffle(shuffled)
            Playback.shared.play(first, within: shuffled ? tracks.shuffled() : tracks)
            return
        }
        Playback.shared.play(context: context, title: header.title ?? "",
                             artwork: header.image?.url(size: 256), shuffled: shuffled)
    }

    /// The wide, dark, tinted-label button Music uses for Play and Shuffle.
    /// Not `.borderedProminent`, which fills the whole shape with the accent
    /// colour and reads as a system alert button rather than a transport.
    private func bigButton(_ title: String, icon: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.callout)
                Text(title).font(.system(size: 15, weight: .medium))
            }
            .foregroundStyle(.tint)
            .frame(width: 152, height: 40)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var cover: some View {
        if header.hasArtwork {
            AsyncImage(url: header.image?.url(size: 600)) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    /// Works have no cover art in the catalog, so the composer's initial stands
    /// in rather than an empty grey square.
    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [.secondary.opacity(0.30), .secondary.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let initial = (header.composerName ?? header.title)?
                .trimmingCharacters(in: .whitespaces).first, initial.isLetter {
                Text(String(initial).uppercased())
                    .font(.system(size: 78, weight: .light, design: .serif))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "music.quarternote.3")
                    .font(.system(size: 44)).foregroundStyle(.secondary)
            }
        }
    }

    private func composerLink(_ composer: String) -> some View {
        HStack(spacing: 4) {
            Text(composer).font(.title3).foregroundStyle(.tint)
            if header.composerAction?.url != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(.tint.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard let action = header.composerAction, action.url != nil, let model else { return }
            Task { await model.go(toAction: action, named: composer) }
        }
    }

    private func programmeNote(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(notes)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(notesExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)
            Button(notesExpanded ? "menos" : "mais") {
                withAnimation(.easeInOut(duration: 0.18)) { notesExpanded.toggle() }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.top, 8)
        .frame(maxWidth: 640, alignment: .leading)
    }
}

// MARK: - Lyrics

/// Timed lyrics for the current track, scrolling with playback.
///
/// Most of the classical catalog has none — Apple answers 404 — so this says so
/// plainly instead of presenting an empty panel as a failure.
struct LyricsPanel: View {
    private var engine: any Player { Playback.shared.active }

    @State private var translations = Translations()
    @State private var translationConfig: TranslationSession.Configuration?

    /// The sung line is the text; the translation is a gloss beneath it, kept
    /// deliberately quiet so it never competes with the words being sung.
    @ViewBuilder
    private func lineView(_ line: LyricLine) -> some View {
        let isCurrent = line.id == currentLine
        VStack(alignment: .leading, spacing: 3) {
            Text(line.text)
                .font(.title3.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .tertiary)

            if let translated = translations[line.id], translated != line.text {
                Text(translated)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .opacity(isCurrent ? 0.62 : 0.32)
            }
        }
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }

    private func prepareTranslation() {
        guard !lines.isEmpty, let code = AppSettings.storedLanguageCode else {
            translationConfig = nil
            return
        }
        translationConfig = TranslationSession.Configuration(
            source: nil, target: Locale.Language(identifier: code))
    }

    @State private var lines: [LyricLine] = []
    @State private var pendingTexts: [PendingLine] = []
    @State private var loadedFor: String?

    private var currentLine: LyricLine.ID? {
        lines.first { $0.contains(engine.position) }?.id
    }

    var body: some View {
        Group {
            if engine.nowPlaying == nil {
                // Nothing is playing, so nothing can be said about a lyric —
                // announcing "sem letra" here states something false about a
                // recording that has not been chosen yet.
                ContentUnavailableView(
                    "Nada tocando",
                    systemImage: "music.note",
                    description: Text("Entre numa música para ver se ela tem letra."))
            } else if lines.isEmpty {
                ContentUnavailableView(
                    "Sem letra",
                    systemImage: "text.quote",
                    description: Text("A Apple não fornece letra para esta gravação. "
                                      + "É comum no catálogo clássico."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(lines) { line in
                                lineView(line)
                                    .id(line.id)
                                    .onTapGesture { engine.seek(to: line.start) }
                            }
                        }
                        .padding(28)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: currentLine) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .task(id: engine.nowPlaying?.trackID) { await load() }
        // Apple's on-device translator. The text never leaves this Mac, and the
        // source language is left unset so the framework identifies it — a Lied
        // is German, an aria Italian, and the catalog never says which.
        //
        // The work stays inside the closure: handing the session to a method
        // would send it across an isolation boundary it is not built to cross.
        .translationTask(translationConfig) { [store = translations, pending = pendingTexts] session in
            var mapped: [(UUID, String)] = []
            for entry in pending {
                guard let response = try? await session.translate(entry.text) else { continue }
                mapped.append((entry.id, response.targetText))
            }
            let finished = mapped
            await store.apply(finished)
        }
    }

    private func load() async {
        guard let id = engine.nowPlaying?.trackID, !id.isEmpty, id != loadedFor else { return }
        loadedFor = id
        translations.reset()
        lines = await LyricsService.shared.lyrics(forTrack: id)
        pendingTexts = lines.map { PendingLine(id: $0.id, text: $0.text) }
        prepareTranslation()
    }
}

// MARK: - Artwork placeholder

/// Many catalog entries genuinely have no image — lesser-known composers,
/// smaller ensembles, and every "see all" row. A blank grey box reads as a
/// broken download, so this shows an initial and a fitting symbol instead.
struct ArtworkPlaceholder: View {
    let item: Item

    private var symbol: String {
        if isNavigation { return "square.grid.2x2" }
        switch item.type {
        case "artist": return "person.fill"
        case "work": return "doc.text.fill"
        case "album": return "square.stack.fill"
        case "playlist": return "music.note.list"
        case "recording": return "waveform"
        default: return "music.note"
        }
    }

    /// A "see all" row is navigation, not an entity — an initial there reads as
    /// the name of something that does not exist.
    private var isNavigation: Bool { item.action?.screenType == "seeAll" }

    private var initial: String? {
        guard !isNavigation,
              let first = item.title?.trimmingCharacters(in: .whitespaces).first,
              first.isLetter else { return nil }
        return String(first).uppercased()
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.secondary.opacity(0.28), .secondary.opacity(0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing)

            if let initial {
                Text(initial)
                    .font(.system(size: 46, weight: .light, design: .serif))
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Settings

/// Tabbed the way macOS settings are: one subject per tab, grouped sections
/// inside, and a fixed size so the window never resizes as tabs change.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            PlaybackSettings()
                .tabItem { Label("Reprodução", systemImage: "play.circle") }
            ScoreSettings()
                .tabItem { Label("Partituras", systemImage: "music.quarternote.3") }
            StorageSettings()
                .tabItem { Label("Armazenamento", systemImage: "internaldrive") }
            AboutSettings()
                .tabItem { Label("Sobre", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 430)
    }
}

// MARK: General

struct GeneralSettings: View {
    @State private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Picker("Idioma do conteúdo", selection: Binding(
                    get: { settings.language },
                    set: { settings.language = $0 }
                )) {
                    ForEach(AppSettings.Language.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
            } header: {
                Text("Idioma")
            } footer: {
                Text("Define o idioma de títulos, seções e textos do catálogo. "
                     + "Não muda a música: a letra cantada e as indicações da partitura "
                     + "pertencem à obra — um Lied é em alemão porque o poema é alemão. "
                     + "Para esses, use a legenda no painel de partitura.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: Playback

struct PlaybackSettings: View {
    @State private var playback = Playback.shared

    var body: some View {
        Form {
            Section {
                Picker("Motor de áudio", selection: Binding(
                    get: { playback.preference },
                    set: { playback.preference = $0 }
                )) {
                    ForEach(Playback.Preference.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)

                LabeledContent("Reproduzindo em") {
                    HStack(spacing: 6) {
                        Text(playback.active.ceiling.rawValue)
                        if playback.active.ceiling.isLossless {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Qualidade")
            } footer: {
                Text("O motor compatível reproduz pelo WebKit, limitado a 256 kbps AAC. "
                     + "Lossless e Spatial Audio exigem MusicKit nativo.")
                .font(.caption).foregroundStyle(.secondary)
            }

            if !playback.losslessAvailable {
                Section("Lossless") { LosslessSetupSection() }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: Scores

struct ScoreSettings: View {
    var body: some View {
        Form {
            Section {
                ScoreAISection()
            } header: {
                Text("Reconhecimento de gravuras")
            } footer: {
                Text("As partituras de domínio público vêm do acervo OpenScore (CC0) e "
                     + "não dependem desta opção.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: Storage

struct StorageSettings: View {
    @State private var cloud = CloudSync.shared
    @State private var cd = CDRip.shared
    @State private var size: Int64 = 0
    @State private var clearing = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Cache de telas") {
                    Text(size > 0
                         ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
                         : "vazio")
                    .foregroundStyle(.secondary)
                }
                Button("Limpar cache") {
                    clearing = true
                    Task {
                        await ScreenCache.shared.clear()
                        size = await ScreenCache.shared.size()
                        clearing = false
                    }
                }
                .disabled(clearing || size == 0)
            } header: {
                Text("Cache")
            } footer: {
                Text("As telas visitadas são guardadas para abrir na hora e atualizar em "
                     + "segundo plano. Limpar não apaga nada da sua biblioteca.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let disc = cd.disc {
                    LabeledContent("Disco") {
                        Text("\(disc.name) — \(disc.tracks.count) faixas")
                            .foregroundStyle(.secondary)
                    }
                    TextField("Nome do álbum", text: $cd.albumName)
                    TextField("Intérpretes", text: $cd.artistName)
                    Picker("Qualidade", selection: $cd.quality) {
                        ForEach(CDRip.Quality.allCases) { Text($0.label).tag($0) }
                    }
                    switch cd.state {
                    case .ripping(let n, let total):
                        HStack(spacing: 7) {
                            ProgressView(value: Double(n), total: Double(total))
                                .frame(width: 140)
                            Text("Faixa \(n) de \(total)").font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    default:
                        Button("Extrair para a biblioteca") { Task { await cd.rip() } }
                            .buttonStyle(.borderedProminent)
                    }
                    if case .done(let message) = cd.state {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    if case .failed(let message) = cd.state {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("Nenhum CD de áudio inserido.")
                            .foregroundStyle(.secondary)
                        Button("Procurar") { cd.refresh() }.buttonStyle(.link)
                    }
                }
            } header: {
                Text("Extrair CD")
            } footer: {
                Text("O disco não guarda títulos — nunca guardou. Dê o nome do álbum e "
                     + "dos intérpretes uma vez e as faixas saem numeradas e etiquetadas.")
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let folder = cloud.folder {
                    LabeledContent("Pasta") {
                        Text(folder.lastPathComponent).foregroundStyle(.secondary)
                    }
                    if let last = cloud.lastSync {
                        LabeledContent("Última cópia") {
                            Text(last.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 10) {
                        Button("Enviar para a nuvem") { Task { await cloud.push() } }
                        Button("Trazer da nuvem") { Task { await cloud.pull() } }
                        Spacer()
                        Button("Esquecer pasta") { cloud.forget() }.buttonStyle(.link)
                    }
                    if let status = cloud.status {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Escolher pasta sincronizada…") { cloud.chooseFolder() }
                    if !CloudSync.knownServices().isEmpty {
                        Text("Encontrei aqui: "
                             + CloudSync.knownServices().map(\.name).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Músicas locais na nuvem")
            } footer: {
                Text("Sem login: o Google Drive, o iCloud Drive e o Dropbox já aparecem "
                     + "como pastas no Mac, e o Cadenza copia sua biblioteca para a que "
                     + "você escolher. Nada é apagado — só copiado.")
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task { size = await ScreenCache.shared.size() }
    }
}

// MARK: About

struct AboutSettings: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable().frame(width: 84, height: 84)
            }
            Text("Cadenza").font(.cadenzaTitle(26))
            Text("Versão \(version)").font(.callout).foregroundStyle(.secondary)

            Text("Um cliente nativo para o Apple Music Classical, que a Apple nunca "
                 + "lançou para o Mac.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 44)
            .padding(.top, 2)

            Link("Código-fonte no GitHub",
                 destination: URL(string: "https://github.com/NspxMiguel/Cadenza")!)
            .font(.callout)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lossless setup

/// The tutorial and the button, in the place where the limitation is felt.
struct LosslessSetupSection: View {
    @State private var setup = LosslessSetup.shared
    @State private var selected: LosslessSetup.Identity?
    @State private var showingLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Lossless indisponível neste build", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)

            Text("Lossless e Spatial Audio exigem a entitlement MusicKit, que só o "
                 + "Apple Developer Program (US$ 99/ano) concede. Uma conta gratuita não "
                 + "registra Mac como device, então nem chega a emitir o perfil.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if setup.identities.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "Assine o Apple Developer Program em developer.apple.com.")
                    step(2, "Abra o Xcode e entre com o Apple ID em Settings ▸ Accounts.")
                    step(3, "Clique em Verificar novamente abaixo.")
                }
                .padding(.top, 2)

                Button("Verificar novamente") { setup.refreshIdentities() }
            } else {
                Picker("Assinar com", selection: $selected) {
                    ForEach(setup.identities) { identity in
                        Text(identity.name).tag(Optional(identity))
                    }
                }

                Text("O Cadenza baixa o próprio código, compila com a sua conta e "
                     + "instala em ~/Applications. Depois é só reabrir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button(setup.isRunning ? "Compilando…" : "Compilar com MusicKit") {
                        if let identity = selected ?? setup.identities.first {
                            setup.build(with: identity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!setup.canRun)

                    if !setup.log.isEmpty {
                        Button(showingLog ? "Ocultar log" : "Ver log") { showingLog.toggle() }
                            .buttonStyle(.link)
                    }
                }

                if setup.finished == true {
                    Label("Pronto. Feche e abra o Cadenza para usar lossless.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if setup.finished == false {
                    Label("A compilação falhou — veja o log.",
                          systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }

                if showingLog {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(setup.log.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption2, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 130)
                }
            }
        }
        .task { setup.refreshIdentities() }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number).").font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
            Text(text).font(.callout)
        }
    }
}

// MARK: - Cache

struct CacheSection: View {
    @State private var size: Int64 = 0

    var body: some View {
        LabeledContent("Cache de telas") {
            HStack(spacing: 10) {
                Text(size > 0 ? ByteCountFormatter.string(fromByteCount: size, countStyle: .file) : "vazio")
                    .foregroundStyle(.secondary)
                Button("Limpar") {
                    Task { await ScreenCache.shared.clear(); size = await ScreenCache.shared.size() }
                }
            }
        }
        .task { size = await ScreenCache.shared.size() }
    }
}

// MARK: - Typography

/// Classical music sets its titles in serif, and the official app does too.
/// Headings use the platform serif — New York — while lists, controls and
/// metadata stay in the system sans, where legibility at small sizes matters
/// more than character.
extension Color {
    /// Music is red, everywhere: the buttons, the star, the sounding track.
    /// Declared once and applied with `.tint` at the root, so every place that
    /// already asks for the accent follows without naming a colour itself —
    /// there is no accent colour in the bundle, so `.tint` was resolving to the
    /// system blue.
    static let cadenzaAccent = Color(red: 0.98, green: 0.16, blue: 0.28)
}

extension Font {
    static func cadenzaTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Shelf and section headings.
    static var cadenzaHeading: Font { .system(size: 21, weight: .semibold, design: .serif) }

    /// Work titles standing above their movements.
    static var cadenzaWork: Font { .system(size: 15, weight: .semibold, design: .serif) }
}

/// A line queued for translation. Sendable so the translation closure can
/// carry it without reaching back into the view.
struct PendingLine: Sendable {
    let id: UUID
    let text: String
}

// MARK: - Score

/// The engraved score, following the recording.
///
/// Coverage is the honest limit here: OpenScore's CC0 corpus is Lieder and
/// string quartets, so most of the catalog has no score and the panel says so.
/// Where it does exist, the MusicXML carries the sung text too, so the words
/// arrive engraved under the notes rather than as a separate list.
struct ScorePanel: View {
    private var engine: any Player { Playback.shared.active }

    @State private var musicXML: String?
    @State private var match: ScoreService.Match?
    @State private var searching = false
    @State private var loadedFor: String?
    @State private var offset: TimeInterval = 0
    @State private var ai = ScoreAI.shared
    @AppStorage("cadenza.score.zoom") private var zoom = 40
    @AppStorage("cadenza.score.following") private var following = true

    /// Whether Apple provides timed lyrics for this recording. Most of the
    /// classical catalog does not, and an empty strip would only take space.
    @State private var hasTimedLyrics = false

    var body: some View {
        VStack(spacing: 0) {
            if let musicXML, let track = engine.nowPlaying {
                ScoreView(musicXML: musicXML,
                          position: engine.position,
                          duration: track.duration,
                          offset: offset,
                          humdrum: match?.format == .humdrum,
                          zoom: zoom,
                          following: following,
                          onAnchor: anchor)

                // The engraved words sit under their own notes and do not move.
                // This is the line being sung *now*, and its translation —
                // printed under the system the way a score prints its text,
                // rather than in a column off to one side.
                if hasTimedLyrics {
                    SungLine(offset: offset)
                }

                Divider()
                HStack(spacing: 10) {
                    if let match {
                        Text("\(match.composer) — \(match.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(match.title)
                    }
                    Spacer()

                    Toggle(isOn: $following) {
                        Label("Seguir", systemImage: "scope")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .help("Rolar a página junto com a música")

                    Divider().frame(height: 12)

                    Button { zoom = max(20, zoom - 6) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .disabled(zoom <= 20)
                    Button { zoom = min(80, zoom + 6) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .disabled(zoom >= 80)

                    Divider().frame(height: 12)

                    // Calibration, phrased as what it is: click a note when you
                    // hear it and the alignment corrects itself from there.
                    let count = ScoreAnchors.shared.anchors.count
                    Text(count == 0
                         ? "Clique numa nota quando ouvi-la para alinhar"
                         : "\(count) ponto\(count == 1 ? "" : "s") de alinhamento")
                    .font(.caption)
                    .foregroundStyle(count == 0 ? .tertiary : .secondary)

                    if count > 0 {
                        Button("Limpar") { ScoreAnchors.shared.clear() }
                            .buttonStyle(.link).font(.caption)
                    }

                    Divider().frame(height: 12)
                    Text("Ajuste").font(.caption).foregroundStyle(.tertiary)
                    Button { offset -= 0.5 } label: { Image(systemName: "minus") }
                        .buttonStyle(.plain)
                    Text("\(offset, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 38)
                    Button { offset += 0.5 } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else if searching {
                ProgressView("Procurando partitura…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // The AI option belongs here, where the score is missing. It
                // was written but never placed in the view, which is the whole
                // reason turning the setting on appeared to do nothing.
                ContentUnavailableView {
                    Label("Sem partitura", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Nenhuma gravura de domínio público foi encontrada para esta "
                         + "faixa. O acervo aberto cobre sobretudo Lieder e quartetos "
                         + "de cordas — trilhas de cinema e de jogos não estão nele.")
                } actions: {
                    aiOption
                }
            }
        }
        .task(id: engine.nowPlaying?.trackID) { await load() }
    }

    /// Recognition needs a scanned score to read. Sourcing one automatically
    /// from IMSLP is not wired yet — their files sit behind a download gateway —
    /// so for now the file is chosen by hand.
    @ViewBuilder
    private var aiOption: some View {
        VStack(spacing: 7) {
            if case .working(let step) = ai.state {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                }
            } else if case .failed(let reason) = ai.state {
                Text("O reconhecimento falhou.")
                    .font(.callout).foregroundStyle(.secondary)
                Text(reason).font(.caption2).foregroundStyle(.tertiary).lineLimit(3)
                Button("Tentar outro arquivo…") { pickAndRecognise() }
            } else if case .ready = ai.state {
                Button("Ler uma partitura escaneada…") { pickAndRecognise() }
                    .buttonStyle(.borderedProminent)
                Text("PDF ou imagem. Roda no seu Mac, leva alguns minutos e pode errar.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else if case .installing(let step) = ai.state {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(step).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                // Turning the setting on is not enough — the engine has to be
                // downloaded — and sending the user back to Settings for that
                // is why enabling it appeared to do nothing.
                Button("Instalar motor de IA e tentar…") { ai.install() }
                    .buttonStyle(.borderedProminent)
                Text("~300 MB, uma vez. O reconhecimento roda no seu Mac.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        // Otherwise a machine that already has the engine is offered the
        // install button again, and pressing it does nothing.
        .onAppear { ai.refreshState() }
    }

    private func pickAndRecognise() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.message = "Escolha um PDF ou imagem da partitura"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let track = engine.nowPlaying?.trackID
        let name = engine.nowPlaying?.title ?? url.deletingPathExtension().lastPathComponent
        Task {
            if let xml = await ScoreAI.shared.generate(from: url) {
                // Saved against the recording, so the next time this track
                // plays the score is simply there. Four minutes of recognition
                // should happen once, not once per listen.
                if let track { ScoreAI.shared.store(xml, for: track, title: name) }
                musicXML = xml
                match = nil
            }
        }
    }

    /// A note was clicked: pin the moment being heard to the moment in the score.
    private func anchor(_ scoreStamp: Double) {
        guard let track = engine.nowPlaying else { return }
        ScoreAnchors.shared.load(for: track.trackID)
        ScoreAnchors.shared.add(real: max(0, engine.position + offset), score: scoreStamp)
    }

    private func load() async {
        guard let track = engine.nowPlaying, track.trackID != loadedFor else { return }
        ScoreAnchors.shared.load(for: track.trackID)
        loadedFor = track.trackID
        musicXML = nil
        match = nil
        offset = 0
        searching = true
        defer { searching = false }

        // A score read by the engine for this recording outranks the search:
        // it was chosen by the user for this track, and re-reading it would
        // cost minutes of CPU to arrive at the same file.
        if let stored = ai.cached(for: track.trackID) {
            musicXML = stored
            hasTimedLyrics = await !LyricsService.shared.lyrics(forTrack: track.trackID).isEmpty
            return
        }

        // Both are wanted together, so both are looked up together.
        async let lyrics = LyricsService.shared.lyrics(forTrack: track.trackID)
        async let found = ScoreService.shared.score(
            forTrack: track.title, artist: track.artist, work: nil)

        hasTimedLyrics = await !lyrics.isEmpty
        guard let score = await found else { return }
        match = score
        musicXML = await ScoreService.shared.contents(for: score)
    }
}

/// What is lined up after this track.
///
/// The queue was invisible until now, which made the whole app feel like it
/// played one track at a time even after it stopped doing that.
struct QueueList: View {
    private var engine: any Player { Playback.shared.active }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("A seguir")
                .font(.cadenzaHeading)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if engine.queue.isEmpty {
                ContentUnavailableView("Fila vazia", systemImage: "list.bullet",
                                       description: Text("Toque um álbum ou uma playlist."))
            } else {
                List {
                    ForEach(engine.queue) { entry in
                        HStack(spacing: 9) {
                            Image(systemName: entry.isCurrent
                                  ? "speaker.wave.2.fill" : "music.note")
                                .font(.caption)
                                .foregroundStyle(entry.isCurrent
                                                 ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title).font(.callout).lineLimit(1)
                                if !entry.artist.isEmpty {
                                    Text(entry.artist).font(.caption)
                                        .foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { engine.jump(to: entry.id) }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// The line being sung right now, printed under the score.
///
/// A printed score already carries its text, engraved under the notes it
/// belongs to — but statically, and only where the corpus supplies it. This is
/// the other half: which line is sounding at this moment, and what it means,
/// on one strip under the system rather than in a column to the side. Side by
/// side, the eye has to choose between the notes and the words; underneath, it
/// reads them the way a singer does.
struct SungLine: View {
    var offset: TimeInterval = 0

    private var engine: any Player { Playback.shared.active }

    @State private var lines: [LyricLine] = []
    @State private var loadedFor: String?
    @State private var translations = Translations()
    @State private var pendingTexts: [PendingLine] = []
    @State private var translationConfig: TranslationSession.Configuration?

    private var current: LyricLine? {
        lines.first { $0.contains(max(0, engine.position + offset)) }
    }

    var body: some View {
        Group {
            if let line = current {
                VStack(spacing: 2) {
                    Text(line.text)
                        .font(.system(size: 16, weight: .medium, design: .serif))
                        .multilineTextAlignment(.center)

                    if let translated = translations[line.id], translated != line.text {
                        Text(translated)
                            .font(.system(size: 13, design: .serif))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .opacity(0.6)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .transition(.opacity)
                .id(line.id)
            } else {
                // Between lines the strip stays, empty. Letting it collapse
                // would make the score jump every few seconds.
                Color.clear.frame(height: 1)
            }
        }
        .frame(minHeight: 34)
        .background(.quaternary.opacity(0.25))
        .animation(.easeOut(duration: 0.25), value: current?.id)
        .task(id: engine.nowPlaying?.trackID) { await load() }
        // Apple's on-device translator: the text never leaves this Mac. The
        // source language is left unset so the framework identifies it — a Lied
        // is German, an aria Italian, and the catalog never says which.
        .translationTask(translationConfig) { [store = translations, pending = pendingTexts] session in
            var mapped: [(UUID, String)] = []
            for entry in pending {
                guard let response = try? await session.translate(entry.text) else { continue }
                mapped.append((entry.id, response.targetText))
            }
            let finished = mapped
            await store.apply(finished)
        }
    }

    private func load() async {
        guard let id = engine.nowPlaying?.trackID, !id.isEmpty, id != loadedFor else { return }
        loadedFor = id
        translations.reset()
        lines = await LyricsService.shared.lyrics(forTrack: id)
        pendingTexts = lines.map { PendingLine(id: $0.id, text: $0.text) }
        guard !lines.isEmpty, let code = AppSettings.storedLanguageCode else {
            translationConfig = nil
            return
        }
        translationConfig = TranslationSession.Configuration(
            source: nil, target: Locale.Language(identifier: code))
    }
}

// MARK: - Sleep timer

/// Stops the music after a chosen interval, fading out rather than cutting.
/// The kind of thing the official app never offered on any platform.
struct SleepTimerMenu: View {
    @State private var now = Date()

    private let tick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var remaining: String? {
        guard let deadline = Playback.shared.sleepDeadline else { return nil }
        let minutes = max(0, Int(deadline.timeIntervalSince(now) / 60) + 1)
        return "\(minutes) min"
    }

    var body: some View {
        Menu {
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button("Parar em \(minutes) min") {
                    Playback.shared.scheduleSleep(after: Double(minutes) * 60)
                    now = Date()
                }
            }
            if Playback.shared.sleepDeadline != nil {
                Divider()
                Button("Cancelar timer") { Playback.shared.cancelSleep() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: Playback.shared.sleepDeadline == nil ? "moon" : "moon.fill")
                if let remaining {
                    Text(remaining).font(.caption.monospacedDigit())
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Temporizador de sono")
        .onReceive(tick) { now = $0 }
    }
}

// MARK: - Section list

/// A section the catalog marks as a list: tracks, recordings, related works.
/// These read as rows, not as covers — a movement has no artwork of its own,
/// and its title is the information that matters.
struct SectionListView: View {
    let component: Component
    var heading: String?
    var seeAll: Action?
    var sectionType: String?
    let model: AppModel

    /// An album is not a `firstPage` — it arrives as sections named
    /// `track-list`, `track-list-footer`, `on-this-album` and `credits`. Its
    /// tracks therefore never passed through TrackListView, which is why the
    /// new row shape applied to playlists and not to the screen where people
    /// actually read a track list.
    private var isTrackList: Bool { sectionType == "track-list" || sectionType == "tracks" }

    /// Numbering counts tracks only and restarts under each work heading, so a
    /// heading row does not consume position 1.
    private var numbered: [(item: Item, number: Int?)] {
        var counter = 0
        return component.items.map { item in
            guard item.isTrack else {
                if item.isHeading { counter = 0 }
                return (item, nil)
            }
            counter += 1
            return (item, counter)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let heading, !heading.isEmpty {
                let label = heading
                HStack(spacing: 5) {
                    Text(label).font(.cadenzaHeading)
                    if seeAll?.url != nil {
                        Image(systemName: "chevron.right")
                            .font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 24)
                .onTapGesture {
                    guard let action = seeAll, action.url != nil else { return }
                    Task { await model.go(toAction: action, named: label) }
                }
            }

            VStack(spacing: 0) {
                ForEach(Array(numbered.enumerated()), id: \.element.item.id) { position, entry in
                    if entry.item.isHeading {
                        WorkHeadingRow(item: entry.item, model: model)
                            .padding(.horizontal, 24)
                    } else if isTrackList {
                        TrackRow(item: entry.item, number: entry.number, model: model)
                            .padding(.horizontal, 24)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                Playback.shared.play(entry.item, within: component.items)
                            }
                            .contextMenu {
                                TrackMenu(item: entry.item, model: model)
                            }
                    } else {
                        SectionRow(item: entry.item, number: entry.number,
                                   siblings: component.items, model: model)
                        if position < numbered.count - 1 {
                            Divider().padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }
}

struct SectionRow: View {
    let item: Item
    var number: Int?
    var siblings: [Item] = []
    let model: AppModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            if item.image?.url != nil {
                AsyncImage(url: item.image?.url(size: 120)) { phase in
                    switch phase {
                    case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                    default: ArtworkPlaceholder(item: item)
                    }
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let number {
                Text("\(number)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 42, alignment: .center)
            } else if !item.isTrack {
                ArtworkPlaceholder(item: item)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—").font(.body).lineLimit(1)
                if let subtitle = item.subtitle ?? item.addition, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if item.playable != nil, hovering || Favourites.shared.isFavourite(item) {
                Button { Favourites.shared.toggle(item) } label: {
                    Image(systemName: Favourites.shared.isFavourite(item) ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(Favourites.shared.isFavourite(item) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
            }

            if let duration = item.duration {
                Text(duration).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if item.action?.url != nil {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(hovering ? Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if item.action?.url != nil {
                Task { await model.open(item) }
            } else if item.playable != nil {
                Playback.shared.play(item, within: siblings)
            }
        }
    }
}

// MARK: - AI score generation

/// The beta corner of Settings.
///
/// Stated plainly because the feature deserves it: it reads engravings, not
/// audio; it runs on this machine and costs real time; and the result may be
/// wrong.
struct ScoreAISection: View {
    @State private var ai = ScoreAI.shared
    @State private var enabled = ScoreAI.shared.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(isOn: $enabled) {
                HStack(spacing: 6) {
                    Text("Gerar partituras com IA")
                    Text("BETA")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.orange.opacity(0.22), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .onChange(of: enabled) { _, value in ai.isEnabled = value }

            Text("Quando não existir gravura de domínio público para a faixa, o Cadenza "
                 + "pode ler uma partitura escaneada e convertê-la em partitura acompanhável.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                caveat("O processamento é local: nada sai do seu Mac, e o uso de CPU é alto.")
                caveat("O reconhecimento pode errar. Scans ruins produzem partituras erradas.")
                caveat("Não transcreve o áudio — isso é impossível, o FairPlay não libera o som. "
                       + "Ele lê a imagem de uma partitura.")
            }

            if enabled { engineControls }

            if !ai.saved.isEmpty {
                Divider().padding(.vertical, 4)
                Text("Partituras guardadas")
                    .font(.headline)
                Text("Lidas uma vez e mantidas. Da próxima vez que a gravação tocar, "
                     + "a partitura já está aqui — nada é reconhecido de novo.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(ai.saved, id: \.id) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill").foregroundStyle(.tint)
                        Text(entry.title).lineLimit(1)
                        Spacer()
                        Button("Apagar") { ai.forget(trackID: entry.id) }
                            .buttonStyle(.link)
                    }
                    .font(.callout)
                }

                Text(Self.size(ai.totalSavedBytes()))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .task {
            ai.refreshState()
            ai.refreshSaved()
        }
    }

    private static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        return "Ocupando \(formatter.string(fromByteCount: bytes)) em Suporte a Aplicativos."
    }

    @ViewBuilder
    private var engineControls: some View {
        switch ai.state {
        case .notInstalled:
            HStack(spacing: 8) {
                Button("Instalar motor de reconhecimento") { ai.install() }
                Text("~300 MB").font(.caption).foregroundStyle(.tertiary)
            }
        case .installing(let step):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout).foregroundStyle(.secondary)
            }
        case .ready:
            HStack(spacing: 10) {
                Label("Motor instalado", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                Button("Remover") { ai.uninstall() }.buttonStyle(.link)
            }
        case .working(let step):
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(step).font(.callout).foregroundStyle(.secondary)
            }
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 4) {
                Label("Falhou", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red).font(.callout)
                Text(reason).font(.caption2.monospaced())
                    .foregroundStyle(.secondary).lineLimit(4)
                Button("Tentar de novo") { ai.uninstall(); ai.install() }.buttonStyle(.link)
            }
        }
    }

    private func caveat(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Scrubber

/// A draggable position bar.
///
/// Without one the transport could only start and stop: there was no way to
/// repeat a passage or skip an introduction, which in a movement lasting ten
/// minutes is most of what one wants to do.
struct Scrubber: View {
    private var engine: any Player { Playback.shared.active }

    @State private var dragging: Double?

    private var duration: TimeInterval {
        max(Playback.shared.displayed?.duration ?? 0, 0.001)
    }

    private var fraction: Double {
        if let dragging { return dragging }
        return min(1, max(0, engine.position / duration))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 3)
                Capsule().fill(.tint).frame(width: width * fraction, height: 3)

                Circle()
                    .fill(.primary)
                    .frame(width: dragging == nil ? 0 : 9, height: dragging == nil ? 0 : 9)
                    .offset(x: width * fraction - 4.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        let ratio = min(1, max(0, value.location.x / width))
                        engine.seek(to: ratio * duration)
                        dragging = nil
                    }
            )
        }
        .frame(height: 10)
        .padding(.horizontal, 16)
        .padding(.top, 2)
    }
}
