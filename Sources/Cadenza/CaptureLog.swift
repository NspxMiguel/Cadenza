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

    private let queue = DispatchQueue(label: "cadenza.capture")
    private var seen = Set<String>()
    private let url: URL

    init(name: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/Claude/Cadenza/capture", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
    }

    func append(_ line: String) {
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
