import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a request to edit gets parked until the window can present it.
///
/// The button that asks for the editor usually lives inside a context menu, and
/// a sheet attached inside a menu never appears — the menu is gone by the time
/// the sheet would be presented. So the menu records what should be edited and
/// the window, which outlives it, does the presenting.
@MainActor
@Observable
final class TrackInfoRequest {
    static let shared = TrackInfoRequest()

    private(set) var tracks: [LocalTrack] = []
    var isPresented = false

    func open(_ tracks: [LocalTrack]) {
        guard !tracks.isEmpty else { return }
        self.tracks = tracks
        isPresented = true
    }
}

/// Correcting what a rip got wrong.
///
/// Local files arrive mislabelled far more often than they arrive right: the
/// conductor sitting in the artist field, no composer anywhere, an album called
/// "Unknown Album" or "Track 01". For classical that is not cosmetic — the
/// composer *is* the filing system, and without it a library is a heap.
///
/// The same sheet edits one track or a whole album. Editing several at once is
/// the common case (a rip is wrong the same way twelve times over), so a field
/// left untouched is left alone rather than flattened across every track: only
/// what was actually typed into gets written.
struct TrackInfoEditor: View {
    let tracks: [LocalTrack]
    var onSave: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private struct Fields: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var composer = ""
        var genre = ""
        var year = ""
        var number = ""
    }

    @State private var fields = Fields()
    @State private var initial = Fields()
    @State private var artwork: Data?
    @State private var artworkTouched = false
    @State private var targeted = false
    @State private var loaded = false

    private var isMultiple: Bool { tracks.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 20) {
                cover
                form
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(width: 620)
        .onAppear(perform: load)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(isMultiple ? "Informações de \(tracks.count) faixas"
                 : (tracks.first?.title ?? "Informações"))
                .font(.headline)
                .lineLimit(1)
            Text(isMultiple
                 ? "O que ficar em branco continua como está em cada faixa."
                 : "Estes dados ficam no catálogo do Cadenza. O arquivo não é alterado.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var cover: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))

                if let artwork, let image = NSImage(data: artwork) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                        Text("Arraste uma imagem")
                            .font(.caption2)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                }

                if targeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .frame(width: 150, height: 150)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture(perform: chooseArtwork)
            .onDrop(of: [.fileURL, .image], isTargeted: $targeted, perform: acceptDrop)
            .animation(.easeOut(duration: 0.15), value: targeted)

            HStack(spacing: 10) {
                Button("Escolher…", action: chooseArtwork)
                    .buttonStyle(.link)
                    .font(.caption)
                if artwork != nil {
                    Button("Remover") {
                        artwork = nil
                        artworkTouched = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
            // Editing twelve tracks means giving twelve different pieces the
            // same name, which is never what anyone wants.
            if !isMultiple {
                field("Título", $fields.title)
            }
            field("Compositor", $fields.composer, prompt: "Beethoven, Ludwig van")
            field("Intérpretes", $fields.artist, prompt: "orquestra, regente, solista")
            field("Álbum", $fields.album)
            field("Gênero", $fields.genre)

            GridRow {
                Text("Ano").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    TextField("", text: $fields.year, prompt: Text("1965"))
                        .frame(width: 70)
                    if !isMultiple {
                        Text("Faixa nº").foregroundStyle(.secondary)
                        TextField("", text: $fields.number)
                            .frame(width: 50)
                    }
                    Spacer()
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .frame(maxWidth: .infinity)
    }

    private func field(_ label: String, _ binding: Binding<String>,
                       prompt: String? = nil) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            TextField("", text: binding,
                      prompt: Text(prompt ?? (isMultiple && binding.wrappedValue.isEmpty
                                              ? "vários" : "")))
        }
    }

    private var footer: some View {
        HStack {
            if !isMultiple, let track = tracks.first {
                Button("Mostrar no Finder") {
                    if let url = LocalLibrary.shared.url(for: track) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                .buttonStyle(.link)
            }
            Spacer()
            Button("Cancelar") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Salvar", action: save)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(fields == initial && !artworkTouched)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Loading and saving

    private func load() {
        guard !loaded else { return }
        loaded = true

        fields.title = tracks.count == 1 ? tracks[0].title : ""
        fields.artist = shared { $0.artist } ?? ""
        fields.album = shared { $0.album } ?? ""
        fields.composer = shared { $0.composer ?? "" } ?? ""
        fields.genre = shared { $0.genre ?? "" } ?? ""
        fields.year = shared { $0.year.map(String.init) ?? "" } ?? ""
        fields.number = tracks.count == 1
            ? (tracks[0].trackNumber.map(String.init) ?? "") : ""
        initial = fields

        artwork = tracks.compactMap { LocalLibrary.shared.artworkData(for: $0) }.first
    }

    /// The value every selected track agrees on, or nil when they differ.
    private func shared(_ value: (LocalTrack) -> String) -> String? {
        guard let first = tracks.first.map(value) else { return nil }
        return tracks.allSatisfy { value($0) == first } ? first : nil
    }

    private func save() {
        var edits = LocalTrackEdits()
        if fields.title != initial.title { edits.title = fields.title }
        if fields.artist != initial.artist { edits.artist = fields.artist }
        if fields.album != initial.album { edits.album = fields.album }
        if fields.composer != initial.composer { edits.composer = fields.composer }
        if fields.genre != initial.genre { edits.genre = fields.genre }
        if fields.year != initial.year { edits.year = Int(fields.year) ?? 0 }
        if fields.number != initial.number { edits.trackNumber = Int(fields.number) ?? 0 }

        if artworkTouched {
            if let artwork { edits.artwork = artwork } else { edits.clearsArtwork = true }
        }

        LocalLibrary.shared.apply(edits, to: tracks.map(\.id))
        onSave()
        dismiss()
    }

    // MARK: Artwork

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Escolha a capa"
        panel.prompt = "Usar"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(url)
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        Task {
            for provider in providers {
                // An image dragged out of a browser arrives as bytes; one
                // dragged from the Finder arrives as a URL.
                if let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url") {
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        adopt(url)
                        return
                    }
                    if let url = item as? URL { adopt(url); return }
                }
                guard let item = try? await provider.loadItem(
                    forTypeIdentifier: UTType.image.identifier) else { continue }
                if let data = item as? Data { set(data); return }
                if let url = item as? URL { adopt(url); return }
                if let image = item as? NSImage, let tiff = image.tiffRepresentation {
                    set(tiff)
                    return
                }
            }
        }
        return true
    }

    private func adopt(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        set(data)
    }

    /// Covers get re-encoded rather than stored as dropped: a 12-megapixel
    /// scan of a sleeve is not worth carrying to Drive on every sync, and at
    /// the sizes this app draws it at nobody could tell.
    private func set(_ data: Data) {
        guard let image = NSImage(data: data) else { return }
        let side: CGFloat = 1000
        let longest = max(image.size.width, image.size.height)

        var encoded = data
        if longest > side, longest > 0 {
            let scale = side / longest
            let target = NSSize(width: image.size.width * scale,
                                height: image.size.height * scale)
            let resized = NSImage(size: target)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: target))
            resized.unlockFocus()
            if let tiff = resized.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(using: .jpeg,
                                                properties: [.compressionFactor: 0.9]) {
                encoded = jpeg
            }
        }

        artwork = encoded
        artworkTouched = true
    }
}
