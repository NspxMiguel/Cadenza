import Foundation

/// Finds and fetches engraved scores for the piece being played.
///
/// Automatic score following normally aligns the audio signal against the
/// score. That is impossible here: FairPlay never hands over the samples. What
/// is possible is the symbolic route — a score carries its own timeline in
/// beats, and scaling that timeline to the track's real duration gives a usable
/// follow for music in steady tempo.
///
/// Two kinds of source feed this, because one was nowhere near enough.
///
/// **OpenScore** (CC0, MusicXML) covers Lieder and string quartets, and lands
/// where it is most useful: in art song the file carries the sung text as
/// `<lyric>`, so score and words arrive already aligned rather than stitched
/// together.
///
/// **Humdrum `**kern`** corpora cover the keyboard repertoire OpenScore does
/// not — Beethoven, Mozart and Haydn sonatas, Chopin, Scarlatti, Joplin,
/// Beethoven quartets. Verovio reads `kern` natively, so these need no
/// conversion; they are handed over exactly as downloaded.
///
/// Coverage is still not everything, and never will be: a score has to be out
/// of copyright before anyone can publish it freely. Film and game soundtracks
/// are not, and no amount of searching will produce one.
actor ScoreService {
    static let shared = ScoreService()

    enum Format: String, Codable, Sendable {
        /// Zipped MusicXML — one `.xml` inside.
        case compressedMusicXML
        /// Humdrum `**kern`, plain text, handed to Verovio as-is.
        case humdrum
    }

    struct Match: Sendable {
        let title: String
        let composer: String
        let downloadURL: URL
        let format: Format
    }

    struct Entry: Codable, Sendable {
        let path: String
        let format: Format
        let composer: String
        let work: String
        let movement: String
        /// "Sonata **No. 14**" — the number that identifies the work in a set.
        var workNumber: Int?
        /// Which movement of it, 1-based.
        var movementNumber: Int?
        /// Normalised catalogue keys: `op27no2`, `k514`, `bwv988`, `d550`.
        /// The single most reliable signal there is — a recording's title
        /// almost always carries one, and two different pieces almost never
        /// share one.
        var catalogue: [String] = []
        /// What kind of work it is — `sonata`, `quartet` — for corpora whose
        /// files are named by sequence and carry no catalogue number. Those
        /// entries are identified by that word plus their number and by nothing
        /// else, so both must be present in the query or the match is a guess.
        var kind: String?
    }

    private var index: [Entry]?

    private var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Cadenza/scores", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Index

    /// The index version is part of the cache name. Without it, widening the
    /// corpus changes nothing for a week — the old, narrower index is read from
    /// disk and the new sources never appear.
    private static let indexVersion = 3

    private func loadIndex() async -> [Entry] {
        if let index { return index }

        let cache = cacheDirectory.appendingPathComponent("index-v\(Self.indexVersion).json")
        if let data = try? Data(contentsOf: cache),
           let modified = try? cache.resourceValues(forKeys: [.contentModificationDateKey])
               .contentModificationDate,
           Date().timeIntervalSince(modified) < 7 * 24 * 3600,
           let stored = try? JSONDecoder().decode([Entry].self, from: data), !stored.isEmpty {
            index = stored
            return stored
        }

        var entries: [Entry] = []
        entries += await openScoreEntries()
        entries += await humdrumEntries()

        // Per-source counts, because a corpus that silently failed to download
        // — GitHub rate-limits unauthenticated tree requests — leaves an index
        // that looks healthy and is missing a composer entirely.
        let byComposer = Dictionary(grouping: entries, by: \.composer)
            .mapValues(\.count)
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ", ")
        Diagnostics.log("[partituras] fontes — \(byComposer)")

        index = entries
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: cache)
        }
        Diagnostics.log("[partituras] índice com \(entries.count) movimentos")
        return entries
    }

    /// Forces the next lookup to rebuild the index. Offered in Settings, for
    /// when a corpus has grown and the user does not want to wait a week.
    func rebuildIndex() async -> Int {
        index = nil
        try? FileManager.default.removeItem(
            at: cacheDirectory.appendingPathComponent("index-v\(Self.indexVersion).json"))
        return await loadIndex().count
    }

    var indexedCount: Int {
        get async { await loadIndex().count }
    }

    // MARK: OpenScore

    /// Layout is `scores/<Composer>/<Work>/<Movement>/<id>.mxl`, so one tree
    /// request per repository is enough to know everything available.
    private func openScoreEntries() async -> [Entry] {
        var entries: [Entry] = []
        for repo in ["OpenScore/Lieder", "OpenScore/StringQuartets"] {
            guard let paths = await tree(repo: repo, branch: "main") else { continue }
            for path in paths where path.hasSuffix(".mxl") {
                let parts = path.split(separator: "/")
                guard parts.count >= 5, parts[0] == "scores" else { continue }
                let work = Self.humanise(String(parts[2]))
                let movement = Self.movementName(String(parts[3]))
                // Lieder carry their Deutsch number in the *song* folder, not
                // the cycle folder — "Die_Forelle_Op.32_D550d" — so both levels
                // have to be read or the single most identifying fact about the
                // piece is thrown away.
                entries.append(Entry(
                    path: "https://raw.githubusercontent.com/\(repo)/main/\(path)",
                    format: .compressedMusicXML,
                    composer: Self.humanise(String(parts[1])),
                    work: work,
                    movement: movement,
                    workNumber: nil,
                    movementNumber: Self.leadingNumber(String(parts[3])),
                    catalogue: Self.catalogueKeys(in: work + " " + movement)))
            }
        }
        return entries
    }

    // MARK: Humdrum

    /// A corpus of `**kern` files, and how to read a title out of it.
    private struct Corpus {
        let repo: String
        let branch: String
        let composer: String
        /// Where the human-readable titles live, when the corpus ships them.
        let indexPath: String?
        /// Column of the index holding the description, 0-based.
        var descriptionColumn = 4
        /// Fallback when there is no index: the work's name, given its number.
        var kind: String?
        /// For corpora keyed by catalogue number rather than sequence.
        var catalogueLetter: String?
    }

    /// Chosen for what they cover rather than for how many files they are: the
    /// keyboard sonatas and Chopin account for a large share of what anyone
    /// actually plays, and none of it was reachable before.
    private static let corpora: [Corpus] = [
        Corpus(repo: "craigsapp/beethoven-piano-sonatas", branch: "main",
               composer: "Beethoven", indexPath: "index.hmd"),
        Corpus(repo: "craigsapp/chopin-mazurkas", branch: "main",
               composer: "Chopin", indexPath: "kern/.ref", descriptionColumn: 2),
        Corpus(repo: "craigsapp/mozart-piano-sonatas", branch: "main",
               composer: "Mozart", indexPath: nil, kind: "Piano Sonata"),
        Corpus(repo: "craigsapp/haydn-piano-sonatas", branch: "master",
               composer: "Haydn", indexPath: nil, kind: "Piano Sonata"),
        Corpus(repo: "craigsapp/beethoven-string-quartets", branch: "main",
               composer: "Beethoven", indexPath: nil, kind: "String Quartet"),
        Corpus(repo: "craigsapp/chopin-preludes", branch: "main",
               composer: "Chopin", indexPath: nil, kind: "Prelude"),
        Corpus(repo: "craigsapp/scarlatti-keyboard-sonatas", branch: "main",
               composer: "Scarlatti", indexPath: nil, kind: "Keyboard Sonata",
               catalogueLetter: "k"),
        Corpus(repo: "craigsapp/joplin", branch: "main",
               composer: "Joplin", indexPath: nil),
    ]

    private func humdrumEntries() async -> [Entry] {
        await withTaskGroup(of: [Entry].self) { group in
            for corpus in Self.corpora {
                group.addTask { await self.entries(for: corpus) }
            }
            var all: [Entry] = []
            for await batch in group { all += batch }
            return all
        }
    }

    private func entries(for corpus: Corpus) async -> [Entry] {
        if let indexPath = corpus.indexPath,
           let raw = await text(
            "https://raw.githubusercontent.com/\(corpus.repo)/\(corpus.branch)/\(indexPath)") {
            return Self.parseHumdrumIndex(raw, corpus: corpus)
        }

        guard let paths = await tree(repo: corpus.repo, branch: corpus.branch) else { return [] }
        return paths.compactMap { path in
            guard path.hasSuffix(".krn") else { return nil }
            let base = String(path.split(separator: "/").last!.dropLast(4))
            let url = "https://raw.githubusercontent.com/\(corpus.repo)/\(corpus.branch)/\(path)"

            // Scarlatti files are named by catalogue: L001K514 is Kirkpatrick
            // 514, which is exactly how the recording will be titled.
            if let letter = corpus.catalogueLetter,
               let number = Self.capture("(?i)\(letter)0*(\\d+)", base) {
                return Entry(path: url, format: .humdrum, composer: corpus.composer,
                             work: "\(corpus.kind ?? "") \(letter.uppercased()). \(number)",
                             movement: "", workNumber: Int(number), movementNumber: nil,
                             catalogue: ["\(letter)\(number)"])
            }

            // sonata14-1 → work 14, movement 1.
            if let kind = corpus.kind,
               let work = Self.capture("[a-zA-Z]+0*(\\d+)", base) {
                let movement = Self.capture("[a-zA-Z]+\\d+-0*(\\d+)", base)

                // The preludes are a single opus: in prelude28-04 the 28 is the
                // opus and the 04 is the piece. Read the other way round — as
                // it was — every prelude claimed to be Op. 28 No. 28, which
                // matched the wrong piece and outscored the right one.
                if corpus.repo.hasSuffix("chopin-preludes"), let movement {
                    return Entry(
                        path: url, format: .humdrum, composer: corpus.composer,
                        work: "\(kind) Op. \(work) No. \(movement)", movement: "",
                        workNumber: Int(movement), movementNumber: nil,
                        catalogue: ["op\(work)no\(movement)"])
                }

                return Entry(
                    path: url, format: .humdrum, composer: corpus.composer,
                    work: "\(kind) No. \(work)",
                    movement: movement.map { "Movimento \($0)" } ?? "",
                    workNumber: Int(work),
                    movementNumber: movement.flatMap(Int.init),
                    catalogue: [],
                    kind: kind.split(separator: " ").last.map {
                        $0.lowercased()
                    })
            }

            // Otherwise the filename is the title: maple_leaf_rag.
            return Entry(path: url, format: .humdrum, composer: corpus.composer,
                         work: Self.humanise(base), movement: Self.humanise(base),
                         workNumber: nil, movementNumber: nil, catalogue: [])
        }
    }

    /// Both index formats are tab-separated with `@` marking a work and the
    /// lines under it its movements. They differ only in which column carries
    /// the description, and in light HTML markup that has to come off.
    private static func parseHumdrumIndex(_ raw: String, corpus: Corpus) -> [Entry] {
        var entries: [Entry] = []
        var work = ""
        var workCatalogue: [String] = []
        var counter = 0

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)

            if line.hasPrefix("@") {
                guard columns.count > corpus.descriptionColumn else { continue }
                work = stripMarkup(columns[corpus.descriptionColumn])
                workCatalogue = catalogueKeys(in: work)
                counter = 0
                continue
            }

            guard let file = columns.first, file.hasSuffix(".krn"),
                  columns.count > corpus.descriptionColumn else { continue }
            counter += 1

            // The Beethoven index gives paths, the Chopin one bare filenames.
            let path = file.contains("/") ? file : "kern/" + file
            let movement = stripMarkup(columns[corpus.descriptionColumn])

            entries.append(Entry(
                path: "https://raw.githubusercontent.com/\(corpus.repo)/\(corpus.branch)/\(path)",
                format: .humdrum,
                composer: corpus.composer,
                work: work,
                movement: movementName(movement),
                workNumber: capture("(?i)no\\.?\\s*(\\d+)", work).flatMap(Int.init),
                movementNumber: leadingNumber(movement) ?? counter,
                catalogue: workCatalogue))
        }
        return entries
    }

    // MARK: Fetching

    private func tree(repo: String, branch: String) async -> [String]? {
        guard let raw = await text(
            "https://api.github.com/repos/\(repo)/git/trees/\(branch)?recursive=1"),
              let payload = try? JSONDecoder().decode(Tree.self, from: Data(raw.utf8))
        else { return nil }
        return payload.tree.map(\.path)
    }

    private func text(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Cadenza", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private struct Tree: Decodable {
        struct Node: Decodable { let path: String }
        let tree: [Node]
    }

    // MARK: Matching

    /// Deliberately conservative: a wrong score is worse than none, because it
    /// would appear to follow while showing different music.
    ///
    /// The strongest signal is the catalogue number, and it cuts both ways — a
    /// recording titled `Op. 27 No. 2` must never be given `Op. 2 No. 1`, so a
    /// disagreement between two known opus numbers is a rejection rather than a
    /// low score.
    func score(forTrack title: String, artist: String, work: String?) async -> Match? {
        let entries = await loadIndex()
        guard !entries.isEmpty else { return nil }

        let haystack = title + " " + (work ?? "") + " " + artist
        let words = Set(Self.normalise(haystack).split(separator: " ").map(String.init))
        let queryCatalogue = Set(Self.catalogueKeys(in: haystack))
        let queryNumbers = Set(Self.workNumbers(in: haystack))
        let queryMovement = Self.movementIndex(in: title)

        // The same text with the spaces taken out, because some corpora name
        // their files as one run-together word — `mapleleaf.krn` for *Maple
        // Leaf Rag*. Compared token by token it matches nothing.
        let squashed = Self.normalise(haystack).replacingOccurrences(of: " ", with: "")

        var best: (Entry, Int)?
        for entry in entries {
            guard let value = Self.rate(
                entry, words: words, catalogue: queryCatalogue,
                numbers: queryNumbers, movement: queryMovement, squashed: squashed)
            else { continue }
            if best == nil || value > best!.1 { best = (entry, value) }
        }

        guard let (entry, _) = best, let url = URL(string: entry.path) else { return nil }
        let name = entry.movement.isEmpty ? entry.work
            : (entry.work.isEmpty ? entry.movement : "\(entry.work) — \(entry.movement)")
        return Match(title: name, composer: entry.composer,
                     downloadURL: url, format: entry.format)
    }

    /// Words that describe a piece without identifying it. Left in, they
    /// corroborate anything against anything: *Symphony No. 40 in G Minor* was
    /// given a Beethoven piano sonata because both are "in … Minor" and both
    /// have a movement marked *Allegro*.
    private static let generic: Set<String> = [
        "minor", "major", "sharp", "flat", "piano", "sonata", "sonatas", "quartet",
        "quartets", "string", "keyboard", "prelude", "preludes", "movement",
        "movimento", "opus", "number", "and", "the", "for", "trio", "duo",
        "allegro", "adagio", "andante", "largo", "presto", "menuetto", "minuet",
        "scherzo", "rondo", "finale", "vivace", "moderato", "lento", "grave"
    ]

    private static func rate(_ entry: Entry, words: Set<String>, catalogue: Set<String>,
                             numbers: Set<Int>, movement: Int?, squashed: String) -> Int? {
        let composerMatches = tokens(entry.composer).first.map {
            $0.count > 3 && matches($0, in: words)
        } ?? false

        // Catalogue numbers known on both sides that share nothing are
        // decisive. This is the single most useful rejection there is: a
        // recording of K. 550 must never be handed Op. 2 No. 1, however well
        // their movement markings happen to agree.
        let entryKeys = Set(entry.catalogue)
        var catalogueAgrees = false
        if !entryKeys.isEmpty, !catalogue.isEmpty {
            let shared = entryKeys.intersection(catalogue)
            if shared.isEmpty { return nil }
            catalogueAgrees = true
            // An opus alone is weak — Op. 28 is a Chopin prelude set and also a
            // pair of Lieder by Josephine Lang. A key that names the piece
            // within the opus, or a composer catalogue like K. or D., is not.
            let specific = shared.contains { $0.contains("no") || !$0.hasPrefix("op") }
            if !specific, !composerMatches { return nil }
        }

        // Nothing identifies a score without one of these two. Movement
        // markings and key signatures are shared by thousands of pieces.
        guard composerMatches || catalogueAgrees else { return nil }

        // An entry known only as "Piano Sonata No. 11" has exactly two facts
        // about it. Both have to hold, or every Mozart recording matches some
        // Mozart sonata movement — which is how a symphony was given a piano
        // sonata and followed it convincingly for the whole first movement.
        if let kind = entry.kind, let number = entry.workNumber, entry.catalogue.isEmpty {
            guard words.contains(kind), numbers.contains(number) else { return nil }
        }

        var score = 0
        if composerMatches { score += 40 }
        if catalogueAgrees { score += 70 }

        if let number = entry.workNumber, numbers.contains(number) { score += 30 }

        // Movement titles: the original rule, which is what makes Lieder work,
        // now as a refinement between candidates rather than a reason to
        // accept one.
        let movementTokens = tokens(entry.movement).filter { !generic.contains($0) }
        if !movementTokens.isEmpty {
            let present = movementTokens.filter {
                matches($0, in: words) || ($0.count >= 6 && squashed.contains($0))
            }
            let coverage = Double(present.count) / Double(movementTokens.count)
            let weight = present.reduce(0) { $0 + $1.count }
            // Five characters rather than six: the Joplin corpus names its
            // files by a single distinctive word — `maple` for *Maple Leaf
            // Rag* — and one letter of margin was the difference between
            // finding it and not. Safe now that the composer has to agree
            // before any of this is reached.
            if coverage >= 0.6, weight >= 5 {
                score += weight + Int(coverage * 20)
            } else if coverage > 0 {
                score += Int(coverage * 10)
            }
        }

        if let movement, let own = entry.movementNumber {
            // Right work, wrong movement is a real failure mode: it follows
            // convincingly and is the wrong music.
            if movement == own { score += 35 } else { score -= 45 }
        }

        guard score >= 60 else { return nil }
        return score
    }

    /// Whole-word comparison, with a prefix allowance for longer tokens so
    /// "Müller" still finds "Müllerin".
    ///
    /// Substring matching looked equivalent and was not: "der" matches inside
    /// "wandern", which let *Der Müller und der Bach* outscore *Das Wandern* on
    /// three false hits.
    private static func matches(_ token: String, in words: Set<String>) -> Bool {
        if words.contains(token) { return true }
        guard token.count >= 5 else { return false }
        return words.contains { $0.hasPrefix(token) }
    }

    // MARK: Downloading

    /// Downloads the score, once. Reopening the panel on the same piece should
    /// not fetch and unpack it again.
    func contents(for match: Match) async -> String? {
        let key = String(abs(match.downloadURL.absoluteString.hashValue), radix: 36)
        let cache = cacheDirectory.appendingPathComponent("\(key).score")
        if let cached = try? String(contentsOf: cache, encoding: .utf8), !cached.isEmpty {
            return cached
        }

        guard let (data, _) = try? await URLSession.shared.data(from: match.downloadURL)
        else { return nil }

        let contents: String?
        switch match.format {
        case .compressedMusicXML: contents = Self.unzipMXL(data)
        // Humdrum needs no conversion at all: Verovio reads kern directly, and
        // converting it here would only be a chance to lose something.
        case .humdrum: contents = String(data: data, encoding: .utf8)
        }

        guard let contents, !contents.isEmpty else { return nil }
        try? contents.write(to: cache, atomically: true, encoding: .utf8)
        return contents
    }

    // MARK: Text helpers

    /// Catalogue keys found in a title: `Op. 27 No. 2` → `op27no2` and `op27`;
    /// `K. 331` → `k331`; `BWV 988`, `D. 550`, `Hob. XVI:52`.
    ///
    /// Both the entry and the query go through this, so they meet in the same
    /// vocabulary regardless of how each was punctuated.
    static func catalogueKeys(in raw: String) -> [String] {
        var keys: [String] = []
        let text = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)

        if let opus = capture(#"op\.?\s*(\d+)"#, text) {
            keys.append("op\(Int(opus) ?? 0)")
            if let number = capture(#"op\.?\s*\d+[,\s]*(?:no|n)\.?\s*(\d+)"#, text) {
                keys.append("op\(Int(opus) ?? 0)no\(Int(number) ?? 0)")
            }
        }
        for letter in ["bwv", "hwv", "kv", "k", "d", "hob", "wwv", "rv", "s"] {
            // `k` must not swallow the k in "work"; require a boundary and a
            // number close behind.
            guard let value = capture("\\b\(letter)\\.?\\s*:?\\s*(\\d+)", text) else { continue }
            keys.append("\(letter)\(Int(value) ?? 0)")
        }
        return keys
    }

    /// Work numbers stated as "No. 14" or "Sonata 14".
    private static func workNumbers(in raw: String) -> [Int] {
        let text = normalise(raw)
        var found: [Int] = []
        let pattern = #"(?:no|n|nr)\s*(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            if let r = Range(m.range(at: 1), in: text), let value = Int(text[r]) {
                found.append(value)
            }
        }
        return found
    }

    /// "III. Rondo" → 3. Classical track titles number their movements with
    /// roman numerals almost without exception.
    static func movementIndex(in title: String) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        // The numeral comes after the work, following a colon, or opens the
        // title outright.
        for candidate in trimmed.split(separator: ":").map(String.init).reversed() {
            let piece = candidate.trimmingCharacters(in: .whitespaces)
            guard let numeral = capture(#"^([IVXivx]+)[\.\)]"#, piece) else { continue }
            if let value = roman(numeral.uppercased()) { return value }
        }
        return nil
    }

    private static func roman(_ text: String) -> Int? {
        let values: [Character: Int] = ["I": 1, "V": 5, "X": 10]
        var total = 0
        var previous = 0
        for character in text.reversed() {
            guard let value = values[character] else { return nil }
            total += value < previous ? -value : value
            previous = max(previous, value)
        }
        return total > 0 && total < 40 ? total : nil
    }

    /// Movement folders and index rows are prefixed with their order —
    /// "13_Die_Post", "3. Minuet and Trio" — and that number never appears in a
    /// track title, so it is dropped before matching.
    private static func movementName(_ raw: String) -> String {
        humanise(raw.replacingOccurrences(
            of: "^[0-9]+[\\._ ]*", with: "", options: .regularExpression))
    }

    private static func leadingNumber(_ raw: String) -> Int? {
        capture(#"^0*(\d+)"#, raw).flatMap(Int.init)
    }

    private static func stripMarkup(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func humanise(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ",", with: "")
    }

    /// Words worth comparing: short ones match by accident.
    private static func tokens(_ raw: String) -> [String] {
        normalise(raw).split(separator: " ").map(String.init).filter { $0.count >= 3 }
    }

    private static func normalise(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r])
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
