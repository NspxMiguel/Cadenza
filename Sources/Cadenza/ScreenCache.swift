import Foundation

/// Keeps the last response for every screen so navigation never shows a spinner
/// on a place the user has already been.
///
/// The pattern is stale-while-revalidate: the cached screen renders
/// immediately, the network request goes out behind it, and the view is
/// replaced only if something actually changed. Nothing about that is visible —
/// no spinner, no flash, no scroll position lost.
actor ScreenCache {
    static let shared = ScreenCache()

    private let directory: URL
    private var memory: [String: Data] = [:]

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Cadenza/screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Cached bytes, or nil. Raw data rather than a decoded `Screen`, so the
    /// caller can compare against a fresh response without decoding twice.
    func data(for path: String) -> Data? {
        let key = Self.key(for: path)
        if let hit = memory[key] { return hit }
        guard let disk = try? Data(contentsOf: directory.appendingPathComponent(key))
        else { return nil }
        memory[key] = disk
        return disk
    }

    func store(_ data: Data, for path: String) {
        let key = Self.key(for: path)
        memory[key] = data
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    func clear() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Size on disk, for the settings panel.
    func size() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    /// Paths carry query strings and slashes, so they are hashed rather than
    /// used as filenames directly.
    private static func key(for path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 36) + ".json"
    }
}
