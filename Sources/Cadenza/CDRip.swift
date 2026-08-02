import AVFoundation
import Foundation
import Observation

/// Turns an audio CD into files in the local library.
///
/// macOS mounts an audio CD as an ordinary volume whose contents are one AIFF
/// per track — `1 Audio Track.aiff`, `2 Audio Track.aiff` — alongside a
/// `.TOC.plist` describing the table of contents. Nothing here talks to the
/// drive directly: reading those files *is* reading the disc, and the system
/// handles the rest.
///
/// The disc carries no titles. CDs never did — iTunes filled them in from
/// Gracenote, which is a paid service. So the listener names the album and the
/// performers once, and the tracks are numbered from the disc. Guessing would
/// be worse than asking.
///
/// **Not tested against a real disc.** This Mac has no optical drive at all —
/// `drutil` reports nothing and the system lists no disc-burning hardware — so
/// the mounting and reading of an actual CD is the one part that has never
/// run. The ripping and importing were exercised against a folder shaped like
/// a mounted disc.
@MainActor
@Observable
final class CDRip {
    static let shared = CDRip()

    struct Disc: Identifiable, Sendable {
        let id: String
        let volume: URL
        let tracks: [URL]
        var name: String { volume.lastPathComponent }
    }

    enum State: Equatable {
        case idle
        case ripping(track: Int, of: Int)
        case done(String)
        case failed(String)
    }

    private(set) var disc: Disc?
    private(set) var state: State = .idle

    /// What the tracks will be tagged with. The disc cannot say.
    var albumName = ""
    var artistName = ""

    /// Encoding choice. Apple Lossless keeps every bit the disc had, which is
    /// the whole point of owning the disc; AAC is offered for people ripping a
    /// hundred of them.
    enum Quality: String, CaseIterable, Identifiable {
        case lossless, compressed
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lossless: "Apple Lossless (idêntico ao disco)"
            case .compressed: "AAC 256 kbps (menor)"
            }
        }
    }

    var quality: Quality = .lossless

    // MARK: Detection

    /// Looks for a mounted volume that is an audio CD.
    ///
    /// The marker is the `.TOC.plist` the system writes beside the tracks; a
    /// folder of AIFFs on a hard disk is not a disc, and treating it as one
    /// would offer to "rip" someone's own recordings back at them.
    func refresh() {
        // A folder can stand in for a disc while testing, which is the only way
        // any of this could be exercised on a Mac with no drive.
        if let stub = ProcessInfo.processInfo.environment["CADENZA_FAKE_CD"] {
            disc = describe(URL(fileURLWithPath: stub), requireTOC: false)
            return
        }

        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: nil)) ?? []
        disc = volumes.lazy.compactMap { self.describe($0, requireTOC: true) }.first
    }

    private func describe(_ volume: URL, requireTOC: Bool) -> Disc? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil)) ?? []

        if requireTOC {
            let toc = volume.appendingPathComponent(".TOC.plist")
            guard FileManager.default.fileExists(atPath: toc.path) else { return nil }
        }

        // Sorted by the leading track number rather than alphabetically, or
        // track 10 lands between 1 and 2.
        let tracks = contents
            .filter { $0.pathExtension.lowercased() == "aiff" || $0.pathExtension.lowercased() == "aif" }
            .sorted { a, b in
                (Self.leadingNumber(a) ?? .max, a.lastPathComponent)
                    < (Self.leadingNumber(b) ?? .max, b.lastPathComponent)
            }

        guard !tracks.isEmpty else { return nil }
        return Disc(id: volume.path, volume: volume, tracks: tracks)
    }

    private static func leadingNumber(_ url: URL) -> Int? {
        let name = url.lastPathComponent
        let digits = name.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    // MARK: Ripping

    /// Where ripped files live. Inside Application Support rather than a
    /// temporary directory: these are the listener's only copy once the disc
    /// goes back on the shelf.
    private var destination: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return base.appendingPathComponent("Cadenza", isDirectory: true)
    }

    func rip() async {
        guard let disc else { return }
        let album = albumName.isEmpty ? disc.name : albumName
        let folder = destination.appendingPathComponent(Self.safe(album), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var produced: [URL] = []
        for (index, track) in disc.tracks.enumerated() {
            state = .ripping(track: index + 1, of: disc.tracks.count)

            let number = String(format: "%02d", index + 1)
            let output = folder.appendingPathComponent("\(number) \(Self.safe(album)).m4a")
            try? FileManager.default.removeItem(at: output)

            let arguments = quality == .lossless
                ? ["-f", "m4af", "-d", "alac", track.path, output.path]
                : ["-f", "m4af", "-d", "aac", "-b", "256000", track.path, output.path]

            let ok = await Task.detached { Self.run("/usr/bin/afconvert", arguments) }.value
            guard ok, FileManager.default.fileExists(atPath: output.path) else {
                state = .failed("Falhou na faixa \(index + 1). O disco pode estar riscado.")
                return
            }
            await tag(output, title: "Faixa \(index + 1)", album: album, track: index + 1)
            produced.append(output)
        }

        await LocalLibrary.shared.importItems(produced)
        state = .done("\(produced.count) faixa(s) extraída(s) para \(folder.path).")
    }

    /// Writes the album and performer the listener supplied, so the files are
    /// not a folder of "Faixa 1" with nothing tying them together.
    private func tag(_ url: URL, title: String, album: String, track: Int) async {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent)

        func item(_ key: AVMetadataKey, _ value: String) -> AVMutableMetadataItem {
            let entry = AVMutableMetadataItem()
            entry.keySpace = .common
            entry.key = key as NSString
            entry.value = value as NSString
            return entry
        }

        var metadata = [item(.commonKeyTitle, title), item(.commonKeyAlbumName, album)]
        if !artistName.isEmpty { metadata.append(item(.commonKeyArtist, artistName)) }
        export.metadata = metadata

        try? await export.export(to: temporary, as: .m4a)
        if FileManager.default.fileExists(atPath: temporary.path) {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private static func safe(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
