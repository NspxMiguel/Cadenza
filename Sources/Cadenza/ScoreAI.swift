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

    /// A score already read for this recording, if any.
    ///
    /// Recognition takes minutes of CPU. Doing it twice for the same recording
    /// would be the app wasting the user's machine on work it already did.
    func cached(for trackID: String) -> String? {
        try? String(contentsOf: cacheURL(trackID), encoding: .utf8)
    }

    func store(_ musicXML: String, for trackID: String) {
        let url = cacheURL(trackID)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? musicXML.write(to: url, atomically: true, encoding: .utf8)
    }

    private func cacheURL(_ trackID: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Cadenza/scores-ai/\(trackID).musicxml")
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
        let output = await Task.detached { [toolPath] in
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

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() } catch { return "falhou ao executar \(tool): \(error)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
