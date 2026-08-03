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
        var creator = ""
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
                case .commonKeyArtist:
                    if artist.isEmpty, let value = try? await item.load(.stringValue) {
                        artist = value
                    }
                // Kept apart from the artist rather than folded into it. In an
                // ID3 file the "creator" common key is the composer's tag, and
                // taking whichever of the two came first put Beethoven in the
                // performer's place on a Kempff recording — the wrong name in
                // the one field where, in this repertoire, both names matter.
                case .commonKeyCreator:
                    if creator.isEmpty, let value = try? await item.load(.stringValue) {
                        creator = value
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

        // The common keys stop short of everything classical listening depends
        // on. There is no common key for composer at all — which for this
        // library is the single most important field, since a symphony is
        // filed under the person who wrote it and not under whoever conducted
        // it that night. Those tags exist, but only under each container's own
        // vocabulary, so they have to be asked for by name.
        let full = (try? await asset.load(.metadata)) ?? []
        let composer = await string(in: full, [
            .iTunesMetadataComposer, .id3MetadataComposer, .quickTimeMetadataComposer,
        ])
        let genre = await string(in: full, [
            .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre,
            .id3MetadataContentType, .quickTimeMetadataGenre,
        ])
        let trackNumber = await number(in: full, [
            .iTunesMetadataTrackNumber, .id3MetadataTrackNumber,
        ])
        let year = await number(in: full, [
            .id3MetadataYear, .iTunesMetadataReleaseDate, .commonIdentifierCreationDate,
        ])

        // Only now can the creator tag be judged: it is worth using as the
        // performer when there is no performer tag, and worth discarding when
        // it is simply the composer's name arriving a second time.
        if artist.isEmpty, creator != composer { artist = creator }

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
            artworkFile: artworkName, composer: composer, genre: genre,
            trackNumber: trackNumber, year: year)
    }

    /// Reads a file's tags without importing it.
    ///
    /// Exists for the self-test: checking what the reader makes of a file has
    /// to be possible without adding it to someone's library and taking it out
    /// again, which would be a destructive test of a non-destructive thing.
    func inspect(_ url: URL) async -> LocalTrack? { await describe(url) }

    /// The first of several tag names that actually carries text.
    private func string(in items: [AVMetadataItem],
                        _ identifiers: [AVMetadataIdentifier]) async -> String? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items,
                                                     filteredByIdentifier: identifier) {
                if let value = try? await item.load(.stringValue),
                   !value.trimmingCharacters(in: .whitespaces).isEmpty {
                    return value.trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    /// Numeric tags arrive in three shapes and the first one tried is usually
    /// the wrong one: `trkn` is a binary atom, ID3 writes "3/12" as text, and a
    /// release date is a whole date when only the year is wanted.
    private func number(in items: [AVMetadataItem],
                        _ identifiers: [AVMetadataIdentifier]) async -> Int? {
        for identifier in identifiers {
            for item in AVMetadataItem.metadataItems(from: items,
                                                     filteredByIdentifier: identifier) {
                if let value = try? await item.load(.numberValue), value.intValue > 0 {
                    return value.intValue
                }
                if let text = try? await item.load(.stringValue) {
                    // "3/12" is a track out of a total; "1987-05-02" is a date.
                    let head = text.split(whereSeparator: { "/-".contains($0) }).first ?? ""
                    if let parsed = Int(head.trimmingCharacters(in: .whitespaces)), parsed > 0 {
                        return parsed
                    }
                }
                // The `trkn` atom is eight bytes with the number in the third
                // and fourth; nothing else in it is of any use here.
                if let data = try? await item.load(.dataValue), data.count >= 4 {
                    let parsed = Int(data[2]) << 8 | Int(data[3])
                    if parsed > 0 { return parsed }
                }
            }
        }
        return nil
    }

    // MARK: Editing

    /// Corrects what the tags got wrong.
    ///
    /// Rips and downloads arrive mislabelled constantly — the conductor in the
    /// artist field, the composer nowhere, an album called "Track 01". Nothing
    /// here rewrites the file: tag formats differ per container and a botched
    /// write damages the only copy someone has. The correction lives in
    /// Cadenza's own catalogue, which is also what travels to Drive, so a
    /// second Mac sees the fixed version rather than the broken tags.
    func apply(_ edits: LocalTrackEdits, to ids: [String]) {
        guard !ids.isEmpty else { return }
        let targets = Set(ids)

        for index in tracks.indices where targets.contains(tracks[index].id) {
            var track = tracks[index]
            if let value = edits.title, !value.isEmpty { track.title = value }
            if let value = edits.artist { track.artist = value }
            if let value = edits.album { track.album = value }
            if let value = edits.composer { track.composer = value.isEmpty ? nil : value }
            if let value = edits.genre { track.genre = value.isEmpty ? nil : value }
            if let value = edits.year { track.year = value > 0 ? value : nil }
            if let value = edits.trackNumber { track.trackNumber = value > 0 ? value : nil }

            if edits.clearsArtwork {
                if let existing = artworkURL(for: track) {
                    try? FileManager.default.removeItem(at: existing)
                }
                track.artworkFile = nil
            } else if let artwork = edits.artwork, !artwork.isEmpty {
                // One copy per track rather than a shared file: removing a
                // single track deletes its own cover, and a shared one would
                // take the rest of the album's covers with it.
                let file = artworkDirectory.appendingPathComponent("\(track.id).img")
                if (try? artwork.write(to: file, options: .atomic)) != nil {
                    track.artworkFile = file.lastPathComponent
                }
            }

            tracks[index] = track
        }

        tracks.sort { $0.sortKey.localizedCaseInsensitiveCompare($1.sortKey) == .orderedAscending }
        save()
        notice = ids.count == 1
            ? "Informações salvas."
            : "Informações de \(ids.count) faixas salvas."
        Task {
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
    }

    /// Artwork bytes as they are on disk, for the editor to show.
    func artworkData(for track: LocalTrack) -> Data? {
        artworkURL(for: track).flatMap { try? Data(contentsOf: $0) }
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

    // MARK: Albums

    /// Local files grouped the way they were released.
    ///
    /// A rip is an album before it is a pile of files, and a classical album is
    /// the unit that matters most — a symphony spread over four files is one
    /// thing, not four. Tracks whose tags name no album are gathered under one
    /// heading rather than each becoming an album of one.
    private static let looseAlbum = "Sem álbum"

    func albums() -> [(name: String, tracks: [LocalTrack])] {
        Dictionary(grouping: tracks) { track in
            track.album.isEmpty ? Self.looseAlbum : track.album
        }
        .map { (name: $0.key, tracks: $0.value.sorted(by: LocalTrack.inAlbumOrder)) }
        .sorted { a, b in
            // The unnamed pile sits last: it is a leftover, not an album.
            if a.name == Self.looseAlbum { return false }
            if b.name == Self.looseAlbum { return true }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func albumsScreen() -> Screen {
        let groups = albums()
        guard !groups.isEmpty else {
            return Screen(
                screenType: LocalRoute.albumsScreenType, title: "Álbuns locais",
                firstPage: Page(type: "empty", items: [],
                                heading: "Nenhum álbum local",
                                description: "Importe arquivos com etiquetas de álbum "
                                    + "para vê-los agrupados aqui."))
        }

        let items = groups.map { group in
            Item(catalogID: group.name,
                 type: "album",
                 title: group.name,
                 addition: performers(of: group.tracks),
                 image: group.tracks.compactMap { artworkURL(for: $0) }.first
                    .map { Artwork(url: $0.absoluteString) },
                 action: Action(type: "componentScreen", screenType: "album",
                                url: LocalRoute.album(group.name)))
        }

        return Screen(
            screenType: LocalRoute.albumsScreenType,
            title: "Álbuns locais",
            sections: [ScreenSection(type: "albums", heading: "Neste Mac",
                                     components: [Component(type: "shelf", items: items)])])
    }

    /// One local album as a track list.
    func albumScreen(name: String) -> Screen {
        let group = albums().first { $0.name == name }
        let tracks = group?.tracks ?? []
        let items = tracks.map { track in
            // Inside an album the album's own name is not worth repeating on
            // every row, but the composer is.
            Item(catalogID: track.id, type: "track", title: track.title,
                 subtitle: [track.composer, track.artist.isEmpty ? nil : track.artist]
                    .compactMap { $0 }.joined(separator: " — "),
                 durationMs: Int(track.duration * 1000),
                 image: artworkURL(for: track).map { Artwork(url: $0.absoluteString) },
                 payload: Payload(id: track.id, type: LocalRoute.payloadType))
        }

        return Screen(
            screenType: LocalRoute.screenType,
            title: name,
            header: Header(type: "album", title: name,
                           subtitle: performers(of: tracks),
                           image: tracks.compactMap { artworkURL(for: $0) }.first
                            .map { Artwork(url: $0.absoluteString) }),
            firstPage: Page(type: "list", items: items))
    }

    /// Who is on the record, without repeating a name once per track.
    private func performers(of tracks: [LocalTrack]) -> String {
        var seen: [String] = []
        for name in tracks.map(\.artist) where !name.isEmpty && !seen.contains(name) {
            seen.append(name)
        }
        return seen.prefix(3).joined(separator: ", ")
    }

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
                 subtitle: track.billing,
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
///
/// The fields below `artworkFile` are optional so that a library written by an
/// earlier build still decodes: a missing key in the stored JSON is nil rather
/// than a decoding failure that would empty someone's library on upgrade.
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
    /// Who wrote it, which in this repertoire outranks who played it.
    var composer: String?
    var genre: String?
    var trackNumber: Int?
    var year: Int?

    var sortKey: String { [artist, album, title].filter { !$0.isEmpty }.joined(separator: " ") }

    /// Ordering inside an album: the printed order when the tags know it, and
    /// alphabetical only as a fallback. A symphony whose movements sort as
    /// "Adagio, Allegro, Finale" is in nobody's intended order.
    static func inAlbumOrder(_ a: LocalTrack, _ b: LocalTrack) -> Bool {
        switch (a.trackNumber, b.trackNumber) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// The line under the title: composer first, then who is playing.
    var billing: String {
        [composer, artist.isEmpty ? nil : artist, album.isEmpty ? nil : album]
            .compactMap { $0 }
            .joined(separator: " — ")
    }
}

/// A set of corrections. `nil` means "leave this field as it is", which is what
/// lets one sheet edit a whole album without flattening the fields that legitimately
/// differ from track to track.
struct LocalTrackEdits {
    var title: String?
    var artist: String?
    var album: String?
    var composer: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var artwork: Data?
    var clearsArtwork = false
}

enum LocalRoute {
    static let path = "cadenza-local:tracks"
    static let albums = "cadenza-local:albums"
    static let albumPrefix = "cadenza-local:album:"
    static let screenType = "localTracks"
    static let albumsScreenType = "localAlbums"

    static func album(_ name: String) -> String { albumPrefix + name }
    /// Marks a queue descriptor as belonging to the local engine rather than to
    /// any Apple catalog.
    static let payloadType = "cadenza-local"
}
