import Foundation
import Observation

/// Rebuilds Cadenza with the MusicKit entitlement, using a signing identity the
/// user already has.
///
/// This exists because the default build cannot ship lossless: the entitlement
/// requires a provisioning profile, which requires a paid membership. Rather
/// than send the user to a terminal, the app clones its own source, builds with
/// their team, and installs the result — the only step that stays manual is
/// relaunching.
@MainActor
@Observable
final class LosslessSetup {
    static let shared = LosslessSetup()

    struct Identity: Identifiable, Hashable {
        let id: String       // certificate SHA-1
        let name: String     // "Apple Development: someone (A44CCRN8Y4)"
        /// The Team ID, read from the certificate's organisational unit. The
        /// code in the identity's own name is the *certificate* identifier, not
        /// the team — signing with it produces a profile mismatch.
        let team: String?
    }

    private(set) var identities: [Identity] = []
    private(set) var isRunning = false
    private(set) var log: [String] = []
    private(set) var finished: Bool?

    var canRun: Bool { !identities.isEmpty && !isRunning }

    /// Reads development certificates from the keychain. An empty result means
    /// the user has not signed in to Xcode with a paid account yet.
    func refreshIdentities() {
        let output = Self.run("/usr/bin/security", ["find-identity", "-v", "-p", "codesigning"])
        identities = output
            .split(separator: "\n")
            .compactMap { line in
                // "  1) A1B2C3… "Apple Development: name (TEAMID)"
                guard let firstQuote = line.firstIndex(of: "\""),
                      let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote
                else { return nil }
                let name = String(line[line.index(after: firstQuote)..<lastQuote])
                guard name.contains("Apple Development") || name.contains("Developer ID") else {
                    return nil
                }
                let hash = line.split(separator: ")").last?
                    .trimmingCharacters(in: .whitespaces).prefix(40) ?? ""
                return Identity(id: String(hash) + name, name: name,
                                team: Self.teamID(forCertificateNamed: name))
            }
    }

    /// Reads OU from the certificate subject, which is where Apple puts the
    /// Team ID.
    nonisolated private static func teamID(forCertificateNamed name: String) -> String? {
        let pem = run("/usr/bin/security", ["find-certificate", "-c", name, "-p"])
        guard !pem.isEmpty else { return nil }

        let path = NSTemporaryDirectory() + "cadenza-cert.pem"
        try? pem.write(toFile: path, atomically: true, encoding: .utf8)
        let subject = run("/usr/bin/openssl",
                          ["x509", "-in", path, "-noout", "-subject"])
        try? FileManager.default.removeItem(atPath: path)

        for field in subject.split(separator: "/") where field.hasPrefix("OU=") {
            return String(field.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for field in subject.split(separator: ",") {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("OU=") { return String(trimmed.dropFirst(3)) }
        }
        return nil
    }

    func build(with identity: Identity) {
        guard let team = identity.team else {
            log = ["Não consegui ler o Team ID desta identidade."]
            finished = false
            return
        }

        isRunning = true
        finished = nil
        log = ["Preparando…"]

        Task.detached { [weak self] in
            let script = Self.script
            let path = NSTemporaryDirectory() + "cadenza-lossless.sh"
            try? script.write(toFile: path, atomically: true, encoding: .utf8)

            let result = Self.run("/bin/bash", [path, team], streaming: { line in
                Task { @MainActor in self?.log.append(line) }
            })

            await MainActor.run {
                self?.isRunning = false
                self?.finished = result.contains("CADENZA_OK")
            }
        }
    }

    // MARK: Shell

    @discardableResult
    nonisolated private static func run(
        _ tool: String, _ arguments: [String],
        streaming: (@Sendable (String) -> Void)? = nil
    ) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // The readability handler fires on its own queue, so the transcript is
        // guarded rather than captured as a plain var.
        let transcript = Transcript()
        if let streaming {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                guard let text = String(data: handle.availableData, encoding: .utf8),
                      !text.isEmpty else { return }
                transcript.append(text)
                for line in text.split(separator: "\n") where !line.isEmpty {
                    streaming(String(line))
                }
            }
        }

        try? process.run()
        process.waitUntilExit()

        if streaming == nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return transcript.value
    }

    private final class Transcript: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""

        func append(_ chunk: String) {
            lock.lock(); defer { lock.unlock() }
            text += chunk
        }

        var value: String {
            lock.lock(); defer { lock.unlock() }
            return text
        }
    }

    /// Kept as a script rather than a chain of Process calls so the user can
    /// read exactly what runs on their machine.
    nonisolated private static let script = """
    #!/bin/bash
    set -euo pipefail
    TEAM="$1"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT

    echo "Baixando o código-fonte…"
    git clone --depth 1 https://github.com/NspxMiguel/Cadenza.git "$WORK/src" 2>&1 | tail -2

    cd "$WORK/src"
    echo "Compilando com a entitlement MusicKit (time $TEAM)…"
    CADENZA_TEAM="$TEAM" ./build.sh 2>&1 | tail -6

    DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/Cadenza.app"
    cp -R build/Cadenza.app "$DEST/Cadenza.app"

    echo "Instalado em $DEST/Cadenza.app"
    echo "CADENZA_OK"
    """
}
