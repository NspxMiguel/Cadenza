import Foundation
import Observation

/// Keeps the local library in a folder on Google Drive.
///
/// Everything the app writes lives under one folder — `Cadenza`, with `Músicas`
/// inside it — rather than scattered at the root of someone's Drive. With the
/// `drive.file` scope the app cannot see anything else anyway, but tidiness is
/// not the same as blindness: the listener should be able to open Drive in a
/// browser and find their music where they would expect it.
///
/// The catalogue travels as `biblioteca.json` beside the audio, so a second Mac
/// learns the titles, albums and covers rather than a pile of filenames.
@MainActor
@Observable
final class DriveSync {
    static let shared = DriveSync()

    enum State: Equatable {
        case idle
        case working(String)
        case done(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var lastSync: Date?

    private static let dateKey = "cadenza.drive.lastSync"

    private init() {
        lastSync = UserDefaults.standard.object(forKey: Self.dateKey) as? Date
    }

    private var auth: GoogleAuth { GoogleAuth.shared }

    // MARK: Folders

    /// The `Cadenza/Músicas` folder, created on first use.
    ///
    /// Looked up by name each time rather than by a stored identifier: the user
    /// may have moved or deleted it in Drive, and a stale id would upload into
    /// nothing.
    private func musicFolder() async throws -> String {
        let root = try await folder(named: "Cadenza", parent: "root")
        return try await folder(named: "Músicas", parent: root)
    }

    private func folder(named name: String, parent: String) async throws -> String {
        let query = "name='\(name)' and mimeType='application/vnd.google-apps.folder'"
            + " and '\(parent)' in parents and trashed=false"
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        let found: [String: Any] = try await request(
            "GET", "https://www.googleapis.com/drive/v3/files?q=\(escaped)&fields=files(id,name)")
        if let files = found["files"] as? [[String: Any]],
           let id = files.first?["id"] as? String {
            return id
        }

        let created: [String: Any] = try await request(
            "POST", "https://www.googleapis.com/drive/v3/files",
            json: ["name": name,
                   "mimeType": "application/vnd.google-apps.folder",
                   "parents": [parent]])
        guard let id = created["id"] as? String else {
            throw CloudError.message("não consegui criar a pasta \(name)")
        }
        return id
    }

    // MARK: Uploading

    func push() async {
        guard auth.isSignedIn else { state = .failed("Entre com o Google primeiro."); return }
        do {
            let musicID = try await musicFolder()
            let existing = try await listFiles(in: musicID)
            let tracks = LocalLibrary.shared.tracks

            var sent = 0
            var skipped = 0
            for (index, track) in tracks.enumerated() {
                guard let source = LocalLibrary.shared.url(for: track) else { continue }
                let name = source.lastPathComponent
                state = .working("Enviando \(index + 1) de \(tracks.count)…")

                // Same name and same size means the same file. Re-uploading a
                // FLAC of eighty megabytes to discover it was already there is
                // not a cost worth paying for tidiness.
                let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if let remote = existing[name], remote == size {
                    skipped += 1
                    continue
                }

                try await upload(source, named: name, to: musicID)
                sent += 1
            }

            // The catalogue last, so a partial upload never leaves a manifest
            // promising files that are not there.
            if let data = try? JSONEncoder().encode(tracks) {
                let root = try await folder(named: "Cadenza", parent: "root")
                try await upload(data: data, named: "biblioteca.json",
                                 mime: "application/json", to: root)
            }

            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.dateKey)
            state = .done(sent == 0
                ? "Tudo já estava no Drive (\(skipped) arquivo\(skipped == 1 ? "" : "s"))."
                : "\(sent) enviado\(sent == 1 ? "" : "s")"
                    + (skipped > 0 ? ", \(skipped) já estava\(skipped == 1 ? "" : "m") lá." : "."))
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Downloading

    func pull() async {
        guard auth.isSignedIn else { state = .failed("Entre com o Google primeiro."); return }
        do {
            let musicID = try await musicFolder()
            let files = try await listFiles(in: musicID, withIDs: true)

            let destination = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("Cadenza/Drive", isDirectory: true)
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            try? FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)

            var brought: [URL] = []
            for (index, entry) in files.enumerated() {
                state = .working("Baixando \(index + 1) de \(files.count)…")
                let target = destination.appendingPathComponent(entry.name)
                // Already here at the same size: nothing to do.
                if let local = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   local == entry.size {
                    brought.append(target)
                    continue
                }
                let data = try await download(entry.id)
                try data.write(to: target, options: .atomic)
                brought.append(target)
            }

            await LocalLibrary.shared.importItems(brought)
            lastSync = Date()
            UserDefaults.standard.set(lastSync, forKey: Self.dateKey)
            state = .done(LocalLibrary.shared.notice ?? "\(brought.count) arquivo(s) trazido(s).")
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Transport

    private struct Entry { let id: String; let name: String; let size: Int }

    private func listFiles(in folder: String) async throws -> [String: Int] {
        let entries = try await listFiles(in: folder, withIDs: true)
        return Dictionary(entries.map { ($0.name, $0.size) }, uniquingKeysWith: { a, _ in a })
    }

    private func listFiles(in folder: String, withIDs: Bool) async throws -> [Entry] {
        let query = "'\(folder)' in parents and trashed=false"
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        var entries: [Entry] = []
        var pageToken: String?

        repeat {
            var url = "https://www.googleapis.com/drive/v3/files?q=\(escaped)"
                + "&fields=nextPageToken,files(id,name,size)&pageSize=200"
            if let pageToken { url += "&pageToken=\(pageToken)" }

            let payload: [String: Any] = try await request("GET", url)
            for file in payload["files"] as? [[String: Any]] ?? [] {
                guard let id = file["id"] as? String, let name = file["name"] as? String
                else { continue }
                // Drive returns size as a string, and only for binary files.
                let size = Int(file["size"] as? String ?? "0") ?? 0
                entries.append(Entry(id: id, name: name, size: size))
            }
            pageToken = payload["nextPageToken"] as? String
        } while pageToken != nil

        return entries
    }

    private func upload(_ file: URL, named name: String, to folder: String) async throws {
        try await upload(data: try Data(contentsOf: file), named: name,
                         mime: "application/octet-stream", to: folder)
    }

    /// Multipart upload: metadata and bytes in one request.
    private func upload(data: Data, named name: String, mime: String, to folder: String) async throws {
        // An existing file of the same name is replaced rather than duplicated,
        // or every sync would add another copy.
        let existing = try await listFiles(in: folder, withIDs: true)
            .first { $0.name == name }?.id

        let boundary = "cadenza-\(UUID().uuidString)"
        let metadata: [String: Any] = existing == nil
            ? ["name": name, "parents": [folder]]
            : ["name": name]

        var body = Data()
        body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n--\(boundary)\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        let url = existing == nil
            ? "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart"
            : "https://www.googleapis.com/upload/drive/v3/files/\(existing!)?uploadType=multipart"

        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = existing == nil ? "POST" : "PATCH"
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (responseData, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CloudError.message("Drive recusou \(name) (\(code)): "
                + (String(data: responseData.prefix(200), encoding: .utf8) ?? ""))
        }
    }

    private func download(_ id: String) async throws -> Data {
        var request = URLRequest(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/\(id)?alt=media")!)
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw CloudError.message("não consegui baixar o arquivo")
        }
        return data
    }

    @discardableResult
    private func request(_ method: String, _ url: String,
                         json: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.setValue("Bearer \(try await auth.token())", forHTTPHeaderField: "Authorization")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw CloudError.message("Drive respondeu \(code): "
                + (String(data: data.prefix(200), encoding: .utf8) ?? ""))
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
