import Foundation
import Observation

/// Turns a scanned score into a followable one, locally.
///
/// This is optical music recognition, not transcription from audio. Transcribing
/// the recording is impossible here — FairPlay never releases the samples — so a
/// model given no audio would not be reading the music, it would be inventing
/// it. Reading an engraving is a different problem, and a solvable one.
///
/// The engine is `oemer`, open source and ONNX-based. It runs entirely on this
/// machine: nothing about the score leaves it, and nothing about it is fast.
/// Results vary with the quality of the scan, which is why the feature is
/// offered as a beta rather than silently.
@MainActor
@Observable
final class ScoreAI {
    static let shared = ScoreAI()

    enum State: Equatable {
        case notInstalled
        case installing(String)
        case ready
        case working(String)
        case failed(String)
    }

    private(set) var state: State = .notInstalled

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.key) }
        set { UserDefaults.standard.set(newValue, forKey: Self.key) }
    }

    private static let key = "cadenza.scoreAI.enabled"

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Cadenza/omr", isDirectory: true)
    }

    private var pythonPath: URL { root.appendingPathComponent("venv/bin/python3") }

    /// The console script, not the module.
    ///
    /// `python3 -m oemer` fails — the package ships no `__main__`, so the
    /// interpreter refuses it before any recognition starts. Every attempt at
    /// reading a score failed here, silently, which is why turning the feature
    /// on appeared to do nothing at all.
    private var toolPath: URL { root.appendingPathComponent("venv/bin/oemer") }

    func refreshState() {
        state = FileManager.default.fileExists(atPath: toolPath.path) ? .ready : .notInstalled
    }

    // MARK: Installation

    /// Downloads the engine on demand rather than bundling it: it pulls in
    /// PyTorch-sized dependencies, and most users will never turn this on.
    func install() {
        guard case .notInstalled = state else { return }
        state = .installing("Preparando ambiente…")

        Task.detached { [root, pythonPath, toolPath] in
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            let venv = root.appendingPathComponent("venv")
            _ = Self.run("/usr/bin/python3", ["-m", "venv", venv.path])

            await MainActor.run { Self.shared.state = .installing("Baixando o motor de OMR…") }
            // The pins are not caution, they are the difference between working
            // and not. The newest oemer requires `onnxruntime-gpu`, which has no
            // macOS build, so pip silently resolves back to 0.1.5 — and 0.1.5
            // still calls `np.int`, removed in NumPy 1.24. Installed unpinned,
            // recognition runs its full three minutes of inference and then dies
            // on an AttributeError.
            let output = Self.run(pythonPath.path,
                                  ["-m", "pip", "install", "--quiet",
                                   "oemer", "numpy<1.24", "opencv-python<4.10"])

            await MainActor.run {
                // The console script is the thing that has to exist: pip can
                // finish and still leave nothing runnable behind.
                if FileManager.default.fileExists(atPath: toolPath.path) {
                    Self.shared.state = .ready
                } else {
                    Self.shared.state = .failed(String(output.suffix(300)))
                }
            }
        }
    }

    func uninstall() {
        try? FileManager.default.removeItem(at: root)
        refreshState()
    }

    // MARK: Recognition

    // MARK: Saved scores

    /// A score already read for this recording, if any.
    ///
    /// Recognition takes minutes of CPU. Doing it twice for the same recording
    /// would be the app wasting the user's machine on work it already did.
    ///
    /// Kept in Application Support rather than Caches. That is the difference
    /// between a convenience and a possession: a cache is the system's to
    /// delete whenever it wants space, and a score the listener sat through
    /// four minutes of recognition for — or scanned themselves — is theirs.
    func cached(for trackID: String) -> String? {
        try? String(contentsOf: scoreURL(trackID), encoding: .utf8)
    }

    func hasScore(for trackID: String) -> Bool {
        FileManager.default.fileExists(atPath: scoreURL(trackID).path)
    }

    func store(_ musicXML: String, for trackID: String, title: String) {
        let url = scoreURL(trackID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? musicXML.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return }

        var names = savedNames
        names[trackID] = title
        savedNames = names
        saved = savedScores()
    }

    func forget(trackID: String) {
        try? FileManager.default.removeItem(at: scoreURL(trackID))
        var names = savedNames
        names[trackID] = nil
        savedNames = names
        saved = savedScores()
    }

    /// What has been saved, for the settings panel. Recognised once and kept
    /// forever is only reassuring if the user can see it and undo it.
    private(set) var saved: [(id: String, title: String)] = []

    func refreshSaved() { saved = savedScores() }

    private func savedScores() -> [(id: String, title: String)] {
        let names = savedNames
        return (try? FileManager.default.contentsOfDirectory(
            at: scoresDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "musicxml" }
            .map { url in
                let id = url.deletingPathExtension().lastPathComponent
                return (id, names[id] ?? id)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            ?? []
    }

    func totalSavedBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: scoresDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    private var savedNames: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.namesKey) }
    }

    private static let namesKey = "cadenza.scoreAI.saved"

    private var scoresDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Cadenza/partituras", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func scoreURL(_ trackID: String) -> URL {
        scoresDirectory.appendingPathComponent("\(trackID).musicxml")
    }

    /// Reads an engraving and returns MusicXML, or nil.
    func generate(from source: URL) async -> String? {
        guard case .ready = state else { return nil }
        state = .working("Lendo a gravura…")

        let workspace = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // oemer reads images, so a PDF is rasterised first. sips ships with
        // macOS, which keeps the dependency list to one.
        var images: [URL] = []
        if source.pathExtension.lowercased() == "pdf" {
            state = .working("Convertendo páginas…")
            let page = workspace.appendingPathComponent("page.png")
            _ = Self.run("/usr/bin/sips",
                         ["-s", "format", "png", "--resampleWidth", "2200",
                          source.path, "--out", page.path])
            if FileManager.default.fileExists(atPath: page.path) { images = [page] }
        } else {
            images = [source]
        }

        guard let image = images.first else {
            state = .failed("Não consegui converter o arquivo.")
            return nil
        }

        state = .working("Reconhecendo notas… alguns minutos, usando a CPU.")
        let output = await Task.detached(priority: .userInitiated) { [toolPath] in
            Self.run(toolPath.path, [image.path, "-o", workspace.path])
        }.value

        let produced = (try? FileManager.default.contentsOfDirectory(
            at: workspace, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension.lowercased() == "musicxml" || $0.pathExtension.lowercased() == "xml" }

        guard let produced, let xml = try? String(contentsOf: produced, encoding: .utf8) else {
            state = .failed(String(output.suffix(300)))
            return nil
        }

        state = .ready
        return xml
    }

    // MARK: Shell

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        // Without this the child inherits a background quality of service and
        // is niced: the same recognition that takes under four minutes from a
        // shell was still running after fifteen, pinned to a single core. The
        // user asked for this work and is waiting on it.
        process.qualityOfService = .userInitiated

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { return "falhou ao executar \(tool): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
