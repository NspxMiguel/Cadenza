import Foundation

/// Finds and fetches engraved scores for the piece being played.
///
/// Automatic score following normally aligns the audio signal against the
/// score. That is impossible here: FairPlay never hands over the samples. What
/// is possible is the symbolic route — a MusicXML score carries its own
/// timeline in beats, and scaling that timeline to the track's real duration
/// gives a usable follow for music in steady tempo.
///
/// The source is OpenScore, released CC0. Coverage is narrow — Lieder and
/// string quartets — but it lands exactly where it is most useful: in art song
/// the MusicXML carries the sung text as `<lyric>` elements, so score and words
/// arrive already aligned, from one file, rather than being stitched together.
actor ScoreService {
    static let shared = ScoreService()

    struct Match: Sendable {
        let title: String
        let composer: String
        let downloadURL: URL
    }

    private struct Entry: Sendable {
        let path: String
        let composer: String
        let work: String
        let movement: String
    }

    private var index: [Entry]?

    // MARK: Index

    /// The corpus layout is `scores/<Composer>/<Work>/<Movement>/<id>.mxl`, so
    /// one tree request is enough to know everything available.
    private func loadIndex() async -> [Entry] {
        if let index { return index }

        var entries: [Entry] = []
        for repo in ["OpenScore/Lieder", "OpenScore/StringQuartets"] {
            let url = URL(string:
                "https://api.github.com/repos/\(repo)/git/trees/main?recursive=1")!
            var request = URLRequest(url: url)
            request.setValue("Cadenza", forHTTPHeaderField: "User-Agent")

            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let payload = try? JSONDecoder().decode(Tree.self, from: data)
            else { continue }

            for node in payload.tree where node.path.hasSuffix(".mxl") {
                let parts = node.path.split(separator: "/")
                guard parts.count >= 5, parts[0] == "scores" else { continue }
                entries.append(Entry(
                    path: "https://raw.githubusercontent.com/\(repo)/main/\(node.path)",
                    composer: Self.humanise(String(parts[1])),
                    work: Self.humanise(String(parts[2])),
                    movement: Self.movementName(String(parts[3]))))
            }
        }

        index = entries
        return entries
    }

    private struct Tree: Decodable {
        struct Node: Decodable { let path: String }
        let tree: [Node]
    }

    // MARK: Matching

    /// Matches on composer surname plus movement or work title. Deliberately
    /// conservative: a wrong score is worse than none, because it would appear
    /// to follow while showing different music.
    func score(forTrack title: String, artist: String, work: String?) async -> Match? {
        let entries = await loadIndex()
        guard !entries.isEmpty else { return nil }

        let haystack = Self.normalise(title + " " + (work ?? "") + " " + artist)

        var best: (Entry, Int)?
        for entry in entries {
            let movement = Self.normalise(entry.movement)
            // The movement title is the strongest signal, and short ones are
            // too common to trust on their own.
            guard movement.count >= 5, haystack.contains(movement) else { continue }

            var score = movement.count

            // Corroboration. The composer is often absent from a recording's
            // performer list — "Julius Patzak & Jörg Demus" never says Schubert
            // — so requiring it as a gate rejected correct matches. The work
            // title corroborates just as well, compared by token because
            // "Winterreise, D.911" is not a substring of "Winterreise: Die Post".
            var corroborated = false
            if let surname = Self.normalise(entry.composer).split(separator: " ").first,
               surname.count > 3, haystack.contains(surname) {
                score += 40
                corroborated = true
            }
            for token in Self.normalise(entry.work).split(separator: " ")
            where token.count >= 5 && haystack.contains(token) {
                score += 25
                corroborated = true
                break
            }
            guard corroborated else { continue }

            if best == nil || score > best!.1 { best = (entry, score) }
        }

        guard let (entry, _) = best, let url = URL(string: entry.path) else { return nil }
        return Match(title: entry.movement, composer: entry.composer, downloadURL: url)
    }

    /// Downloads and unpacks the compressed MusicXML.
    func musicXML(for match: Match) async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: match.downloadURL)
        else { return nil }
        return Self.unzipMXL(data)
    }

    // MARK: Helpers

    /// Movement folders are prefixed with their order — "13_Die_Post" — which
    /// never appears in a track title, so the number is dropped before matching.
    private static func movementName(_ raw: String) -> String {
        humanise(raw.replacingOccurrences(
            of: "^[0-9]+[_ ]*", with: "", options: .regularExpression))
    }

    private static func humanise(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: "")
    }

    private static func normalise(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// `.mxl` is a zip holding one `.xml`. Unpacked with the system unzip
    /// rather than a dependency.
    private static func unzipMXL(_ data: Data) -> String? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cadenza-score-\(abs(data.count))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("score.mxl")
        guard (try? data.write(to: archive)) != nil else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-q", archive.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }

        for file in files where file.pathExtension == "xml" {
            if let text = try? String(contentsOf: file, encoding: .utf8) { return text }
        }
        return nil
    }
}
