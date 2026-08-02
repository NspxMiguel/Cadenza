import SwiftUI

// MARK: - Root

struct RootView: View {
    @State private var model = AppModel()
    @State private var showingLogin = false

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            ScreenView(model: model)
        }
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
        }
        .task {
            if model.needsLogin { showingLogin = true } else { await model.start() }
        }
        .sheet(isPresented: $showingLogin) {
            LoginSheet {
                showingLogin = false
                Task { await model.start() }
            }
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
        }
        .listStyle(.sidebar)
    }

    private func row(_ destination: Destination) -> some View {
        Label(destination.name, systemImage: destination.symbol)
            .tag(destination)
    }
}

// MARK: - Screen

struct ScreenView: View {
    let model: AppModel

    var body: some View {
        Group {
            if let error = model.error {
                ContentUnavailableView("Não foi possível carregar",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let screen = model.screen {
                if let page = screen.firstPage, !page.isEmptyState {
                    TrackListView(page: page, model: model)
                } else if screen.sections.isEmpty, let page = screen.firstPage {
                    ContentUnavailableView(
                        page.heading ?? screen.title ?? "Vazio",
                        systemImage: "music.note.list",
                        description: Text(page.description ?? ""))
                } else {
                    content(screen)
                }
            } else if model.isLoading {
                ProgressView()
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(model.screen?.title ?? model.current?.name ?? "Cadenza")
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
                            ShelfView(component: component, model: model)
                        }
                    }
                }
            }
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Shelf

struct ShelfView: View {
    let component: Component
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = component.heading, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 24)
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

    /// Editorial items are wide banners; catalog items are square tiles.
    private var isFeatured: Bool { item.type == "featured" }
    private var width: CGFloat { isFeatured ? 420 : 176 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: item.image?.url(size: isFeatured ? 900 : 400)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                default:
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: width, height: isFeatured ? 236 : 176)
            .clipShape(RoundedRectangle(cornerRadius: 8))

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
struct TrackListView: View {
    let page: Page
    let model: AppModel

    /// Track numbering restarts under each work, and headings are not counted —
    /// they are work titles standing above their movements, not playable rows.
    private var numbered: [(item: Item, number: Int?)] {
        var counter = 0
        return page.items.map { item in
            guard item.isTrack else { counter = 0; return (item, nil) }
            counter += 1
            return (item, counter)
        }
    }

    var body: some View {
        List {
            ForEach(numbered, id: \.item.id) { entry in
                if entry.item.isHeading {
                    WorkHeadingRow(item: entry.item, model: model)
                } else {
                    TrackRow(item: entry.item, number: entry.number)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
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
                .font(.headline)
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

struct TrackRow: View {
    let item: Item
    let number: Int?

    var body: some View {
        HStack(spacing: 12) {
            Text(number.map(String.init) ?? "")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—").font(.body).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if item.inFavorites == true {
                Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
            }
            if let duration = item.duration {
                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
