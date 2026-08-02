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
            VStack(spacing: 0) {
                ScreenView(model: model)
                NowPlayingBar()
            }
            .overlay(alignment: .bottomLeading) {
                EngineHost().frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false)
            }
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

            ToolbarItem(placement: .primaryAction) {
                if let context = model.playableContext {
                    Button {
                        Task {
                            try? await Playback.shared.active.play(
                                id: context.id, kind: context.type)
                        }
                    } label: {
                        Label("Reproduzir", systemImage: "play.fill")
                    }
                    .help("Reproduzir tudo")
                }
            }
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

            if !model.playlists.isEmpty {
                Section("Playlists") {
                    ForEach(model.playlists) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { Color.clear.frame(height: 6) }
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
                    VStack(spacing: 0) {
                        if let header = screen.header {
                            ScreenHeader(header: header, context: model.playableContext)
                        }
                        TrackListView(page: page, model: model)
                    }
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
                            ShelfView(
                                component: component,
                                heading: section.displayTitle,
                                seeAll: section.heading?.seeAll,
                                model: model)
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
                if hovering, let context = item.playable {
                    Button {
                        Task { try? await Playback.shared.active.play(
                            id: context.id, kind: context.type) }
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

    private func play(_ item: Item) {
        guard let payload = item.playable else { return }
        Task { try? await Playback.shared.active.play(id: payload.id, kind: payload.type) }
    }

    var body: some View {
        List {
            ForEach(numbered, id: \.item.id) { entry in
                if entry.item.isHeading {
                    WorkHeadingRow(item: entry.item, model: model)
                } else {
                    TrackRow(item: entry.item, number: entry.number)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { play(entry.item) }
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

struct TrackRow: View {
    let item: Item
    let number: Int?
    @State private var hovering = false

    private var isCurrent: Bool {
        item.playable?.id == Playback.shared.active.nowPlaying?.trackID
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if hovering, item.playable != nil {
                    Image(systemName: "play.fill").font(.caption)
                } else if isCurrent {
                    Image(systemName: Playback.shared.active.status == .playing
                          ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                } else {
                    Text(number.map(String.init) ?? "")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 26, alignment: .trailing)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "—").font(.body).lineLimit(1)
                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if item.playable != nil, hovering || Favourites.shared.isFavourite(item) {
                Button {
                    Favourites.shared.toggle(item)
                } label: {
                    Image(systemName: Favourites.shared.isFavourite(item) ? "star.fill" : "star")
                        .font(.caption)
                        .foregroundStyle(Favourites.shared.isFavourite(item) ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Favoritar")
            }
            if let duration = item.duration {
                Text(duration)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
    }
}

// MARK: - Now playing

/// The transport. It also states the engine's ceiling when the recording on
/// offer is better than what this engine can deliver — the honest alternative
/// to implying a quality the app cannot produce.
struct NowPlayingBar: View {
    private var engine: any Player { Playback.shared.active }
    @State private var showingLyrics = false
    @State private var showingScore = false

    var body: some View {
        if let track = engine.nowPlaying {
            Divider()
            HStack(spacing: 14) {
                AsyncImage(url: track.artworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                .frame(width: 42, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title).font(.callout).lineLimit(1)
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 16)

                if track.duration > 0 {
                    Text("\(clock(engine.position)) / \(clock(track.duration))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(engine.ceiling.rawValue)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help(engine.ceiling.isLossless
                          ? "Reproduzindo sem perdas"
                          : "Este motor é limitado a 256 kbps AAC")

                Button {
                    Favourites.shared.toggle(id: track.trackID,
                                             current: Favourites.shared.isFavourite(id: track.trackID))
                } label: {
                    Image(systemName: Favourites.shared.isFavourite(id: track.trackID)
                          ? "star.fill" : "star")
                        .foregroundStyle(Favourites.shared.isFavourite(id: track.trackID)
                                         ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help("Favoritar")

                Button {
                    showingLyrics.toggle()
                } label: {
                    Image(systemName: "quote.bubble")
                }
                .buttonStyle(.plain)
                .help("Letra")
                .popover(isPresented: $showingLyrics, arrowEdge: .top) {
                    LyricsPanel().frame(width: 460, height: 420)
                }

                Button {
                    showingScore.toggle()
                } label: {
                    Image(systemName: "music.quarternote.3")
                }
                .buttonStyle(.plain)
                .help("Partitura")
                .popover(isPresented: $showingScore, arrowEdge: .top) {
                    ScorePanel().frame(width: 720, height: 560)
                }

                SleepTimerMenu()

                HStack(spacing: 14) {
                    Button { engine.skipBackward() } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { engine.togglePlayPause() } label: {
                        Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill")
                            .frame(width: 16)
                    }
                    Button { engine.skipForward() } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Screen header

/// The masthead of a playlist, album or work: cover, title, credits, and the
/// button that plays the whole thing.
struct ScreenHeader: View {
    let header: Header
    let context: Payload?

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            AsyncImage(url: header.image?.url(size: 600)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Rectangle().fill(.quaternary)
                        .overlay(Image(systemName: "music.note").font(.largeTitle)
                            .foregroundStyle(.secondary))
                }
            }
            .frame(width: 208, height: 208)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 12, y: 4)

            VStack(alignment: .leading, spacing: 8) {
                Text(header.title ?? "")
                    .font(.cadenzaTitle(27))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.title3).foregroundStyle(.tint).lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let extra = header.year ?? header.lastUpdated {
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
                    Button {
                        Task { try? await Playback.shared.active.play(
                            id: context.id, kind: context.type) }
                    } label: {
                        Label("Reproduzir", systemImage: "play.fill")
                            .frame(minWidth: 76)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, 6)
                }

            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - Sleep timer

/// Stops the music after a chosen interval, fading out rather than cutting.
/// The kind of thing the official app never offered on any platform.
struct SleepTimerMenu: View {
    private var engine: any Player { Playback.shared.active }
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

// MARK: - Lyrics

/// Timed lyrics for the current track, scrolling with playback.
///
/// Most of the classical catalog has none — Apple answers 404 — so this says so
/// plainly instead of presenting an empty panel as a failure.
struct LyricsPanel: View {
    private var engine: any Player { Playback.shared.active }

    @State private var lines: [LyricLine] = []
    @State private var loadedFor: String?

    private var currentLine: LyricLine.ID? {
        lines.first { $0.contains(engine.position) }?.id
    }

    var body: some View {
        Group {
            if lines.isEmpty {
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
                                Text(line.text)
                                    .font(.title3.weight(line.id == currentLine ? .semibold : .regular))
                                    .foregroundStyle(line.id == currentLine ? .primary : .tertiary)
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
    }

    private func load() async {
        guard let id = engine.nowPlaying?.trackID, !id.isEmpty, id != loadedFor else { return }
        loadedFor = id
        lines = await LyricsService.shared.lyrics(forTrack: id)
    }
}

// MARK: - Artwork placeholder

/// Many catalog entries genuinely have no image — lesser-known composers,
/// smaller ensembles, and every "see all" row. A blank grey box reads as a
/// broken download, so this shows an initial and a fitting symbol instead.
struct ArtworkPlaceholder: View {
    let item: Item

    private var symbol: String {
        switch item.type {
        case "artist": "person.fill"
        case "work": "doc.text.fill"
        case "album": "square.stack.fill"
        case "playlist": "music.note.list"
        case "recording": "waveform"
        default: "music.note"
        }
    }

    private var initial: String? {
        guard let first = item.title?.trimmingCharacters(in: .whitespaces).first,
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

/// Where the quality ceiling is chosen — and explained when it cannot be lifted.
struct SettingsView: View {
    @State private var playback = Playback.shared

    var body: some View {
        Form {
            Picker("Motor de áudio", selection: Binding(
                get: { playback.preference },
                set: { playback.preference = $0 }
            )) {
                ForEach(Playback.Preference.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            Divider().padding(.vertical, 4)

            LabeledContent("Reproduzindo em") {
                Text(playback.active.ceiling.rawValue).foregroundStyle(.secondary)
            }

            if playback.losslessAvailable {
                Label("Lossless ativo neste build.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                LosslessSetupSection()
            }

            Divider().padding(.vertical, 4)
            CacheSection()
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
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
extension Font {
    static func cadenzaTitle(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Shelf and section headings.
    static var cadenzaHeading: Font { .system(size: 21, weight: .semibold, design: .serif) }

    /// Work titles standing above their movements.
    static var cadenzaWork: Font { .system(size: 15, weight: .semibold, design: .serif) }
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

    var body: some View {
        VStack(spacing: 0) {
            if let musicXML, let track = engine.nowPlaying {
                ScoreView(musicXML: musicXML,
                          position: engine.position,
                          duration: track.duration,
                          offset: offset)

                Divider()
                HStack(spacing: 10) {
                    if let match {
                        Text("\(match.composer) — \(match.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("Ajuste").font(.caption).foregroundStyle(.tertiary)
                    Button { offset -= 0.5 } label: { Image(systemName: "minus") }
                    Text("\(offset, specifier: "%.1f")s")
                        .font(.caption.monospacedDigit())
                        .frame(width: 40)
                    Button { offset += 0.5 } label: { Image(systemName: "plus") }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            } else if searching {
                ProgressView("Procurando partitura…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Sem partitura",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Nenhuma gravura de domínio público foi encontrada "
                                      + "para esta faixa. O acervo aberto cobre sobretudo "
                                      + "Lieder e quartetos de cordas."))
            }
        }
        .task(id: engine.nowPlaying?.trackID) { await load() }
    }

    private func load() async {
        guard let track = engine.nowPlaying, track.trackID != loadedFor else { return }
        loadedFor = track.trackID
        musicXML = nil
        match = nil
        offset = 0
        searching = true
        defer { searching = false }

        guard let found = await ScoreService.shared.score(
            forTrack: track.title, artist: track.artist, work: nil) else { return }
        match = found
        musicXML = await ScoreService.shared.musicXML(for: found)
    }
}
