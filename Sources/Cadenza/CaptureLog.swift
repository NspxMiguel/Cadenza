import Foundation

/// Appends every observed Apple endpoint to a file, so the API surface of the
/// classical catalog can be studied offline and replayed from native code.
/// Playback manifests, kept apart from the API log. Their CODECS attribute is
/// what actually settles whether WebKit is a ceiling on audio quality.
final class StreamLog: @unchecked Sendable {
    static let shared = StreamLog()
    private let inner = CaptureLog(name: "streams.txt")
    func append(_ line: String) { inner.append(line) }
}

final class CaptureLog: @unchecked Sendable {
    static let shared = CaptureLog(name: "endpoints.txt")

    /// Off unless asked for.
    ///
    /// This was how the v10 surface got mapped, and it has no business running
    /// afterwards: recording Apple's traffic to disk on every launch is the
    /// definition of automated monitoring, it is the clause in Apple's terms
    /// this project fits most squarely, and it earns an ordinary user nothing.
    /// The tool stays, because the endpoints will change and will need mapping
    /// again — it just no longer runs behind anyone's back.
    private static let enabled = ProcessInfo.processInfo.environment["CADENZA_CAPTURE"] != nil

    private let queue = DispatchQueue(label: "cadenza.capture")
    private var seen = Set<String>()
    private let url: URL

    init(name: String) {
        // Under Application Support rather than a path inside one particular
        // person's home folder, which is where it used to write.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Cadenza/capture", isDirectory: true)
        if Self.enabled {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        url = dir.appendingPathComponent(name)
    }

    func append(_ line: String) {
        guard Self.enabled else { return }
        queue.async { [self] in
            // Collapse identifiers so repeated calls to the same endpoint shape
            // don't drown the log in near-duplicates.
            let shape = line.replacingOccurrences(
                of: "[0-9]{6,}", with: "{id}", options: .regularExpression)
            guard seen.insert(shape).inserted else { return }

            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
