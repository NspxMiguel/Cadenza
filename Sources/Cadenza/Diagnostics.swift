import Foundation

/// Appends diagnostics to a file under Caches.
///
/// Standard error goes nowhere when an app is launched from Finder or `open`,
/// which is how it is normally started — so the one moment a log matters is the
/// one moment stderr cannot be read.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "cadenza.diagnostics")

    static let fileURL: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Cadenza", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("diagnostics.log")
    }()

    static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        queue.async {
            guard let data = (message + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
