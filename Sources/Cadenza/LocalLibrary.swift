import AVFoundation
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Music the listener already owns, on this Mac.
///
/// Everything else in this app plays through Apple's subscription, and there is
/// a whole category of classical listening that never does: rips of one's own
/// discs, live recordings, radio captures, transfers of LPs. The official app
/// has no place for any of it.
///
/// Files are referenced, never copied. A bookmark is stored alongside the path
/// so a track survives being moved or renamed, which for a library that took
/// years to organise matters more than it sounds.
@MainActor
@Observable
final class LocalLibrary {
    static let shared = LocalLibrary()

    private(set) var tracks: [LocalTrack] = []
    private(set) var importing = false
    /// How the last import went, in one line.
    private(set) var notice: String?

    private var storeURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Cadenza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("local-library.json")
    }

    private var artworkDirectory: URL {
        let directory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("local-artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private init() {
        if let data = try? Data(contentsOf: storeURL),
           let stored = try? JSONDecoder().decode([LocalTrack].self, from: data) {
            tracks = stored
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tracks) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Formats

    /// Extensions the open panel will show.
    ///
    /// Deliberately generous rather than a curated allow-list. Guessing what
    /// the system can decode is how a real format gets locked out: Ogg Vorbis
    /// was on a rejection list here until a file of it played perfectly on the
    /// first try, because macOS does ship a decoder for it. The list below only
    /// decides what the panel offers; whether a file actually plays is settled
    /// by asking AVFoundation to open it, one file at a time.
    static let readableExtensions = [
        "mp3", "m4a", "m4b", "aac", "adts", "aif", "aiff", "aifc", "wav", "wave",
        "caf", "flac", "alac", "au", "snd", "ac3", "eac3", "amr", "mp2", "mp4",
        "ogg", "oga", "opus", "wma", "ape", "mka", "dsf", "aa", "aax", "3gp"
    ]

    static let readableTypes: [UTType] = {
        var types: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        for ext in readableExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()

    // MARK: Importing

    func promptForFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.readableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Escolha arquivos de música ou uma pasta"
        panel.prompt = "Importar"
        guard panel.runModal() == .OK else { return }
        Task { await importItems(panel.urls) }
    }

    /// Folders are walked, because nobody keeps a music collection as a flat
    /// list of files.
    private func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            else { continue }
            if isDirectory.boolValue {
                let enumerator = FileManager.default.enumerator(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let entry = enumerator?.nextObject() as? URL {
                    files.append(entry)
                }
            } else {
                files.append(url)
            }
        }
        return files
    }

    func importItems(_ urls: [URL]) async {
        importing = true
        defer { importing = false }

        let candidates = expand(urls)
        var added = 0
        var skipped = 0
        var unsupported: Set<String> = []

        for url in candidates {
            let ext = url.pathExtension.lowercased()
            guard !ext.isEmpty, Self.readableExtensions.contains(ext) else { continue }
            if tracks.contains(where: { $0.path == url.path }) {
                skipped += 1
                continue
            }
            // The file itself is the authority: if AVFoundation will not open
            // it, this Mac cannot play it, whatever its extension suggests.
            guard let track = await describe(url) else {
                unsupported.insert(ext)
                continue
            }
            tracks.append(track)
            added += 1
        }

        tracks.sort { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        save()

        var parts: [String] = []
        if added > 0 { parts.append("\(added) faixa\(added == 1 ? "" : "s") importada\(added == 1 ? "" : "s")") }
        if skipped > 0 { parts.append("\(skipped) ignorada\(skipped == 1 ? "" : "s")") }
        if !unsupported.isEmpty {
            parts.append("este Mac não decodifica: \(unsupported.sorted().joined(separator: ", "))")
        }
        notice = parts.isEmpty ? "Nada para importar." : parts.joined(separator: " · ")
        Task {
            try? await Task.sleep(for: .seconds(6))
            notice = nil
        }
    }

    /// Reads what the file says about itself. Tags are wildly inconsistent
    /// across rippers, so the filename is the last resort rather than the
    /// first — but it is always there.
    private func describe(_ url: URL) async -> LocalTrack? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.load(.isPlayable)) == true else { return nil }

        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        var title = url.deletingPathExtension().lastPathComponent
        var artist = ""
        var album = ""
        var artworkData: Data?

        if let metadata = try? await asset.load(.commonMetadata) {
            for item in metadata {
                guard let key = item.commonKey else { continue }
                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue), !value.isEmpty {
                        title = value
                    }
                case .commonKeyArtist, .commonKeyCreator:
                    if artist.isEmpty, let value = try? await item.load(.stringValue) {
                        artist = value
                    }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue) { album = value }
                case .commonKeyArtwork:
                    artworkData = try? await item.load(.dataValue)
                default:
                    break
                }
            }
        }

        let id = UUID().uuidString
        var artworkName: String?
        if let artworkData, !artworkData.isEmpty {
            let file = artworkDirectory.appendingPathComponent("\(id).img")
            if (try? artworkData.write(to: file)) != nil { artworkName = file.lastPathComponent }
        }

        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        return LocalTrack(
            id: id, title: title, artist: artist, album: album,
            duration: duration, path: url.path, bookmark: bookmark,
            artworkFile: artworkName)
    }

    // MARK: Access

    /// Resolves a track back to a readable file, preferring the bookmark so a
    /// moved or renamed file is still found.
    func url(for track: LocalTrack) -> URL? {
        if let bookmark = track.bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = resolved.startAccessingSecurityScopedResource()
                if FileManager.default.fileExists(atPath: resolved.path) { return resolved }
            }
        }
        let direct = URL(fileURLWithPath: track.path)
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    func artworkURL(for track: LocalTrack) -> URL? {
        track.artworkFile.map { artworkDirectory.appendingPathComponent($0) }
    }

    func remove(_ track: LocalTrack) {
        tracks.removeAll { $0.id == track.id }
        if let artwork = artworkURL(for: track) { try? FileManager.default.removeItem(at: artwork) }
        save()
        notice = "“\(track.title)” saiu da lista. O arquivo continua no disco."
    }

    func track(id: String) -> LocalTrack? { tracks.first { $0.id == id } }

    // MARK: As a screen

    /// Mapped onto the same model the catalog uses, so the list, the transport
    /// and the context menu need to know nothing about where a track came from.
    func screen() -> Screen {
        guard !tracks.isEmpty else {
            return Screen(
                screenType: LocalRoute.screenType, title: "Músicas locais",
                firstPage: Page(type: "empty", items: [],
                                heading: "Nenhum arquivo importado",
                                description: "Importe MP3, AAC, ALAC, FLAC, WAV ou AIFF "
                                    + "que já estejam no seu Mac."))
        }

        let items = tracks.map { track in
            Item(catalogID: track.id, type: "track", title: track.title,
                 subtitle: [track.artist, track.album].filter { !$0.isEmpty }
                    .joined(separator: " — "),
                 durationMs: Int(track.duration * 1000),
                 image: artworkURL(for: track).map { Artwork(url: $0.absoluteString) },
                 payload: Payload(id: track.id, type: LocalRoute.payloadType))
        }

        return Screen(
            screenType: LocalRoute.screenType,
            title: "Músicas locais",
            header: Header(type: "playlist", title: "Músicas locais",
                           subtitle: "\(tracks.count) faixa\(tracks.count == 1 ? "" : "s") neste Mac"),
            firstPage: Page(type: "list", items: items))
    }
}

/// One file in the local library.
struct LocalTrack: Codable, Identifiable, Sendable, Hashable {
    let id: String
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    /// Where it was when imported. The bookmark outranks this if both resolve.
    var path: String
    var bookmark: Data?
    var artworkFile: String?

    var sortKey: String { [artist, album, title].filter { !$0.isEmpty }.joined(separator: " ") }
}

enum LocalRoute {
    static let path = "cadenza-local:tracks"
    static let screenType = "localTracks"
    /// Marks a queue descriptor as belonging to the local engine rather than to
    /// any Apple catalog.
    static let payloadType = "cadenza-local"
}
