import AppKit
import Foundation
import Observation

/// Keeps the local library in a folder that a cloud service already syncs.
///
/// The ask was "log in to Google Drive". This does not do that, and the reason
/// is worth stating rather than burying: an OAuth login needs a client ID and
/// secret registered with Google, which means either shipping credentials in a
/// public repository — where anyone can lift them — or asking every user to
/// register their own project in the Google Cloud console before they can save
/// a file. Both are worse than the alternative.
///
/// The alternative is that Google Drive, iCloud Drive, Dropbox and OneDrive all
/// mount as ordinary folders on macOS. Pointing the library at one of them
/// gives the same result — the music and the catalogue follow the user to
/// another Mac — with no login, no token to expire, no credentials to leak, and
/// it works for whichever service the user already pays for instead of the one
/// this app happened to pick.
///
/// What it does not give is streaming from the cloud without the files being
/// on disk. That would need a real API client, and it is the one thing this
/// approach cannot do.
@MainActor
@Observable
final class CloudSync {
    static let shared = CloudSync()

    /// Where the library is mirrored, if anywhere.
    private(set) var folder: URL?
    private(set) var lastSync: Date?
    private(set) var status: String?

    private static let bookmarkKey = "cadenza.cloud.bookmark"
    private static let dateKey = "cadenza.cloud.lastSync"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            folder = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = folder?.startAccessingSecurityScopedResource()
        }
        lastSync = UserDefaults.standard.object(forKey: Self.dateKey) as? Date
    }

    /// Folders the common services mount at, so the user is offered a starting
    /// point instead of hunting through the file system.
    static func knownServices() -> [(name: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, URL)] = [
            ("Google Drive", home.appendingPathComponent("Library/CloudStorage")),
            ("iCloud Drive", home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")),
            ("Dropbox", home.appendingPathComponent("Dropbox")),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.1.path) }
            .map { (name: $0.0, url: $0.1) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Escolha uma pasta sincronizada — Google Drive, iCloud Drive, Dropbox"
        panel.prompt = "Usar esta pasta"
        if let first = Self.knownServices().first { panel.directoryURL = first.url }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        folder = url
        _ = url.startAccessingSecurityScopedResource()
        if let data = try? url.bookmarkData(options: .withSecurityScope,
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
        }
        status = "Pasta definida. Nada foi copiado ainda."
    }

    /// Used by the self-test, which has no panel to click.
    func useFolderForTesting(_ url: URL) { folder = url }

    func forget() {
        folder?.stopAccessingSecurityScopedResource()
        folder = nil
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        status = nil
    }

    // MARK: Syncing

    /// Copies the audio files and the catalogue into the folder.
    ///
    /// Copies rather than moves, and never deletes anything: a sync that can
    /// remove the user's only copy of a recording is not a feature. Files
    /// already there with the same size are skipped, so running it again is
    /// cheap.
    func push() async {
        guard let folder else { return }
        let root = folder.appendingPathComponent("Cadenza", isDirectory: true)
        let audio = root.appendingPathComponent("Músicas", isDirectory: true)
        try? FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)

        var copied = 0
        var skipped = 0
        for track in LocalLibrary.shared.tracks {
            guard let source = LocalLibrary.shared.url(for: track) else { continue }
            let destination = audio.appendingPathComponent(source.lastPathComponent)

            if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               let original = try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               existing == original {
                skipped += 1
                continue
            }
            try? FileManager.default.removeItem(at: destination)
            if (try? FileManager.default.copyItem(at: source, to: destination)) != nil {
                copied += 1
            }
        }

        // The catalogue travels too, so the other Mac knows the titles, the
        // albums and which scores were saved — not just that some files exist.
        let manifest = root.appendingPathComponent("biblioteca.json")
        if let data = try? JSONEncoder().encode(LocalLibrary.shared.tracks) {
            try? data.write(to: manifest, options: .atomic)
        }

        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: Self.dateKey)
        status = copied == 0 && skipped > 0
            ? "Tudo já estava lá (\(skipped) arquivo\(skipped == 1 ? "" : "s"))."
            : "\(copied) arquivo\(copied == 1 ? "" : "s") enviado\(copied == 1 ? "" : "s")"
                + (skipped > 0 ? ", \(skipped) já estava\(skipped == 1 ? "" : "m") lá." : ".")
    }

    /// Brings the folder's music into this Mac's library.
    func pull() async {
        guard let folder else { return }
        let audio = folder.appendingPathComponent("Cadenza/Músicas", isDirectory: true)
        guard FileManager.default.fileExists(atPath: audio.path) else {
            status = "Nada encontrado nessa pasta ainda."
            return
        }
        await LocalLibrary.shared.importItems([audio])
        lastSync = Date()
        UserDefaults.standard.set(lastSync, forKey: Self.dateKey)
        status = LocalLibrary.shared.notice ?? "Importado."
    }
}
