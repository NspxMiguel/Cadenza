import SwiftUI

/// The player, copied from the one Apple Music actually ships.
///
/// Two earlier attempts were both wrong, and wrong in instructive ways. A bar
/// welded to the bottom edge is Spotify. A rectangular display in the title bar
/// is iTunes. What Music does today is neither: a floating pill, centred, held
/// off every edge, drifting over the content with the list visible around it.
///
/// The order inside it is Apple's: transport first, then the record — artwork,
/// title, album and artist on a second line, the favourite star — then the
/// controls that open something, and the volume at the end. A hairline of
/// progress runs along the bottom of the pill itself rather than sitting
/// anywhere as a separate scrubber.
struct FloatingPlayer: View {
    @Binding var expanded: Bool

    private var engine: any Player { Playback.shared.active }

    @State private var hovering = false
    @State private var dragFraction: Double?
    @State private var showingLyrics = false
    @State private var showingQueue = false
    @State private var showingScore = false

    var body: some View {
        HStack(spacing: 0) {
            transport
                .padding(.leading, 20)
                .padding(.trailing, 18)

            record
                .frame(maxWidth: .infinity)

            extras
                .padding(.leading, 16)
                .padding(.trailing, 20)
        }
        .frame(height: 64)
        .frame(maxWidth: 760)
        .background {
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(.white.opacity(0.07), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        }
        .overlay(alignment: .bottom) { progressHairline }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: 17) {
            Button { engine.setShuffle(!engine.shuffle) } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(engine.shuffle
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            }
            .help(engine.shuffle ? "Aleatório ligado" : "Aleatório desligado")

            Button { engine.skipBackward() } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .help("Anterior")

            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 23))
                    .frame(width: 24)
            }
            .help(engine.status == .playing ? "Pausar" : "Reproduzir")

            Button { engine.skipForward() } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .help("Próxima")

            Button { engine.setRepeat(engine.repeatMode.next) } label: {
                Image(systemName: engine.repeatMode.symbol)
                    .foregroundStyle(engine.repeatMode == .off
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint))
            }
            .help(engine.repeatMode.label)
        }
        .buttonStyle(.plain)
        .font(.body)
        .disabled(Playback.shared.displayed == nil)
    }

    // MARK: The record

    @ViewBuilder
    private var record: some View {
        if let track = Playback.shared.displayed {
            HStack(spacing: 10) {
                artwork(track)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)

                        if Favourites.shared.isFavourite(id: track.trackID) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.tint)
                        }
                    }

                    Text(Playback.shared.isPreparing ? "Carregando…" : track.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // The elapsed time replaces the second line on hover in Music;
                // here it simply appears at the edge, where it costs nothing.
                if hovering, track.duration > 0 {
                    Text("\(clock(engine.position)) / \(clock(track.duration))")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .onTapGesture { expanded = true }
            .help("Abrir Tocando Agora")
        } else {
            Text("Cadenza")
                .font(.system(size: 13, weight: .medium, design: .serif))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func artwork(_ track: NowPlaying) -> some View {
        ZStack {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note")
                        .font(.caption).foregroundStyle(.secondary))
            }
            if Playback.shared.isPreparing {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.small)
            }
        }
    }

    // MARK: Extras

    private var extras: some View {
        HStack(spacing: 15) {
            Menu {
                if let track = Playback.shared.displayed {
                    Button(Favourites.shared.isFavourite(id: track.trackID)
                           ? "Desfavoritar" : "Favoritar") {
                        Favourites.shared.toggle(
                            id: track.trackID,
                            current: Favourites.shared.isFavourite(id: track.trackID))
                    }
                }
                Button("Partitura") { showingScore = true }
                Divider()
                SleepTimerMenu()
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .popover(isPresented: $showingScore, arrowEdge: .top) {
                ScorePanel().frame(width: 900, height: 660)
            }

            Button { showingLyrics.toggle() } label: {
                Image(systemName: "quote.bubble")
            }
            .help("Letra")
            .popover(isPresented: $showingLyrics, arrowEdge: .top) {
                LyricsPanel().frame(width: 440, height: 420)
            }

            Button { showingQueue.toggle() } label: {
                Image(systemName: "list.bullet")
            }
            .help("A seguir")
            .popover(isPresented: $showingQueue, arrowEdge: .top) {
                QueueList().frame(width: 340, height: 400)
            }

            // Where Music puts AirPlay. Routing belongs to the system here —
            // the engine plays through whatever output the Mac is using — so
            // this opens Sound settings rather than pretending to a picker the
            // app does not own.
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "airplayaudio")
            }
            .help("Saída de áudio (Ajustes do Sistema)")

            if engine.supportsVolume {
                HStack(spacing: 5) {
                    Image(systemName: engine.volume == 0
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                    Slider(value: Binding(get: { engine.volume },
                                          set: { engine.setVolume($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 62)
                }
            }
        }
        .buttonStyle(.plain)
        .font(.body)
    }

    // MARK: Progress

    /// A hairline along the bottom edge of the pill, thickening into a real
    /// scrubber under the pointer — which is how Music does it, and why the
    /// player never needs to be taller than the record it is showing.
    @ViewBuilder
    private var progressHairline: some View {
        if let track = Playback.shared.displayed, track.duration > 0 {
            GeometryReader { geometry in
                let width = geometry.size.width
                let fraction = dragFraction
                    ?? min(1, max(0, engine.position / track.duration))
                let thickness: CGFloat = hovering || dragFraction != nil ? 5 : 2

                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(.tint).frame(width: max(0, width * fraction))
                }
                .frame(height: thickness)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle().inset(by: -8))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(1, max(0, value.location.x / width))
                        }
                        .onEnded { value in
                            let target = min(1, max(0, value.location.x / width))
                            engine.seek(to: target * track.duration)
                            dragFraction = nil
                        }
                )
                .animation(.easeOut(duration: 0.12), value: thickness)
            }
            .frame(height: 14)
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Now Playing

/// The full-window Now Playing view.
///
/// Apple Music gives the record the whole window when you ask for it: large
/// artwork, the words beside it, and nothing else competing. Everything here
/// is already in the app — this is where it stops being a strip at the edge
/// of the screen.
struct NowPlayingScreen: View {
    @Binding var expanded: Bool

    private var engine: any Player { Playback.shared.active }

    enum Panel: String, CaseIterable, Identifiable {
        case none = "Só a capa"
        case lyrics = "Letra"
        case score = "Partitura"
        var id: String { rawValue }
    }

    @AppStorage("cadenza.nowplaying.panel") private var panel: Panel = .lyrics

    var body: some View {
        ZStack {
            Rectangle().fill(.background)

            VStack(spacing: 0) {
                header

                if let track = Playback.shared.displayed {
                    HStack(spacing: 34) {
                        cover(track)

                        if panel != .none {
                            Group {
                                switch panel {
                                case .lyrics: LyricsPanel()
                                case .score: ScorePanel()
                                case .none: EmptyView()
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.quaternary.opacity(0.18),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 26)
                } else {
                    ContentUnavailableView("Nada tocando", systemImage: "music.note")
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var header: some View {
        HStack {
            Button {
                expanded = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.medium))
            }
            .buttonStyle(.plain)
            .help("Fechar")

            Spacer()

            Picker("", selection: $panel) {
                ForEach(Panel.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)

            Spacer()

            // Balances the chevron so the picker sits truly centred.
            Image(systemName: "chevron.down").opacity(0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 20)
    }

    private func cover(_ track: NowPlaying) -> some View {
        VStack(spacing: 20) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                RoundedRectangle(cornerRadius: 12)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 60)).foregroundStyle(.secondary))
            }
            .frame(maxWidth: 360, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 26, y: 12)

            VStack(spacing: 5) {
                Text(track.title)
                    .font(.cadenzaTitle(21))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Text(track.artist)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .frame(maxWidth: 380)

            Scrubber()
                .frame(maxWidth: 380)

            HStack(spacing: 22) {
                Button { engine.setShuffle(!engine.shuffle) } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(engine.shuffle
                                         ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                Button { engine.skipBackward() } label: { Image(systemName: "backward.fill") }
                Button { engine.togglePlayPause() } label: {
                    Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 30))
                        .frame(width: 34)
                }
                Button { engine.skipForward() } label: { Image(systemName: "forward.fill") }
                Button { engine.setRepeat(engine.repeatMode.next) } label: {
                    Image(systemName: engine.repeatMode.symbol)
                        .foregroundStyle(engine.repeatMode == .off
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
            }
            .buttonStyle(.plain)
            .font(.title2)

            if let id = Playback.shared.displayed?.trackID {
                Button {
                    Favourites.shared.toggle(id: id,
                                             current: Favourites.shared.isFavourite(id: id))
                } label: {
                    Label(Favourites.shared.isFavourite(id: id) ? "Favoritada" : "Favoritar",
                          systemImage: Favourites.shared.isFavourite(id: id)
                            ? "star.fill" : "star")
                        .foregroundStyle(Favourites.shared.isFavourite(id: id)
                                         ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .font(.callout)
            }
        }
        .frame(width: 390)
    }
}
