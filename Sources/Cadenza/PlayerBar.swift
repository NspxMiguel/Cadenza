import SwiftUI

/// The player, arranged the way Apple Music arranges it.
///
/// It sat at the bottom of the window before, which is Spotify's shape, not
/// Apple's — and that one difference is most of why the app did not read as a
/// Mac music app. Apple puts the transport at the left of the title bar and a
/// rounded display in the centre carrying artwork, title, the times and the
/// scrubber, with the extras on the right. Clicking that display opens the
/// full Now Playing view.
///
/// The parts are separate views because the toolbar takes them as separate
/// items: one group leading, one principal, one trailing.
struct TransportControls: View {
    private var engine: any Player { Playback.shared.active }

    var body: some View {
        HStack(spacing: 14) {
            Button { engine.setShuffle(!engine.shuffle) } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(engine.shuffle
                                     ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .help(engine.shuffle ? "Aleatório ligado" : "Aleatório desligado")

            Button { engine.skipBackward() } label: {
                Image(systemName: "backward.fill")
            }
            .help("Anterior")

            Button { engine.togglePlayPause() } label: {
                Image(systemName: engine.status == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 22)
            }
            .help(engine.status == .playing ? "Pausar" : "Reproduzir")

            Button { engine.skipForward() } label: {
                Image(systemName: "forward.fill")
            }
            .help("Próxima")

            Button { engine.setRepeat(engine.repeatMode.next) } label: {
                Image(systemName: engine.repeatMode.symbol)
                    .foregroundStyle(engine.repeatMode == .off
                                     ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .help(engine.repeatMode.label)
        }
        .buttonStyle(.plain)
        .font(.title3)
        .disabled(Playback.shared.displayed == nil)
    }
}

/// The rounded display in the middle of the title bar.
///
/// Apple's shows artwork, two lines of text, the elapsed and remaining times
/// and a scrubber that is always live. Ours adds one thing Apple's cannot:
/// what the engine's ceiling actually is, since a recording offered as
/// lossless does not arrive that way through WebKit.
struct PlayerLCD: View {
    @Binding var expanded: Bool

    private var engine: any Player { Playback.shared.active }
    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        Group {
            if let track = Playback.shared.displayed {
                content(track)
            } else {
                Text("Cadenza")
                    .font(.cadenzaHeading)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 380, height: 44)
        .background(.quaternary.opacity(hovering ? 0.55 : 0.35),
                    in: RoundedRectangle(cornerRadius: 7))
        .overlay {
            RoundedRectangle(cornerRadius: 7).strokeBorder(.quaternary, lineWidth: 0.5)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func content(_ track: NowPlaying) -> some View {
        HStack(spacing: 9) {
            artwork(track)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .onTapGesture { expanded = true }
                .help("Abrir Tocando Agora")

            VStack(spacing: 1) {
                Text(track.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                if Playback.shared.isPreparing {
                    Text("Carregando…")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text(clock(engine.position))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 30, alignment: .trailing)

                        scrubber(track)

                        Text("-" + clock(max(0, track.duration - engine.position)))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .leading)
                    }
                }
            }

            // Shown only when it is news: the recording is lossless and this
            // engine cannot deliver it. Printing "256 kbps AAC" on every track
            // was a permanent label taking room the title needed.
            if engine.isQualityLimited {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("Esta gravação é lossless no catálogo. Este motor "
                          + "entrega 256 kbps AAC — compile com a sua conta em Ajustes.")
            }
        }
        .padding(.horizontal, 7)
    }

    /// Dragging updates a local fraction and only seeks on release, so the
    /// handle follows the pointer instead of fighting the engine's clock.
    private func scrubber(_ track: NowPlaying) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = dragFraction
                ?? (track.duration > 0 ? min(1, engine.position / track.duration) : 0)

            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 3)
                Capsule().fill(.tint).frame(width: max(0, width * fraction), height: 3)
                if hovering || dragFraction != nil {
                    Circle()
                        .fill(.primary)
                        .frame(width: 8, height: 8)
                        .offset(x: max(0, width * fraction - 4))
                }
            }
            .frame(height: 10)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard track.duration > 0 else { return }
                        dragFraction = min(1, max(0, value.location.x / width))
                    }
                    .onEnded { value in
                        guard track.duration > 0 else { return }
                        let target = min(1, max(0, value.location.x / width)) * track.duration
                        engine.seek(to: target)
                        dragFraction = nil
                    }
            )
        }
        .frame(height: 10)
    }

    @ViewBuilder
    private func artwork(_ track: NowPlaying) -> some View {
        ZStack {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "music.note")
                        .font(.caption2).foregroundStyle(.secondary))
            }
            if Playback.shared.isPreparing {
                Color.black.opacity(0.45)
                ProgressView().controlSize(.small)
            }
        }
    }

    private func clock(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Volume and the panels, on the right of the title bar.
struct PlayerExtras: View {
    private var engine: any Player { Playback.shared.active }

    @State private var showingLyrics = false
    @State private var showingScore = false
    @State private var showingQueue = false

    var body: some View {
        HStack(spacing: 12) {
            if engine.supportsVolume {
                HStack(spacing: 4) {
                    Image(systemName: engine.volume == 0
                          ? "speaker.slash.fill" : "speaker.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { engine.volume },
                                          set: { engine.setVolume($0) }), in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 66)
                }
            }

            Button { showingLyrics.toggle() } label: {
                Image(systemName: "quote.bubble")
            }
            .help("Letra")
            .popover(isPresented: $showingLyrics, arrowEdge: .bottom) {
                LyricsPanel().frame(width: 440, height: 420)
            }

            Button { showingScore.toggle() } label: {
                Image(systemName: "music.quarternote.3")
            }
            .help("Partitura")
            .popover(isPresented: $showingScore, arrowEdge: .bottom) {
                ScorePanel().frame(width: 900, height: 660)
            }

            Button { showingQueue.toggle() } label: {
                Image(systemName: "list.bullet")
            }
            .help("A seguir")
            .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
                QueueList().frame(width: 340, height: 400)
            }

            SleepTimerMenu()
        }
        .buttonStyle(.plain)
        .font(.body)
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
