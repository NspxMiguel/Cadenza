import SwiftUI

@main
struct CadenzaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Cadenza") {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
                .tint(.cadenzaAccent)
                // Google hands the sign-in back through the app's own URL
                // scheme rather than a local web server.
                .onOpenURL { url in
                    if url.scheme == GoogleCredentials.urlScheme {
                        GoogleAuth.shared.handleCallback(url)
                    }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Importar músicas…") { LocalLibrary.shared.promptForFiles() }
                    .keyboardShortcut("i", modifiers: .command)
            }

            // A music app should answer the space bar and the arrow keys
            // without the pointer having to find a button first.
            CommandMenu("Reproduzir") {
                Button("Reproduzir/Pausar") {
                    Playback.shared.active.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Próxima") { Playback.shared.active.skipForward() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Anterior") { Playback.shared.active.skipBackward() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)

                Divider()

                Button("Avançar 15s") {
                    let engine = Playback.shared.active
                    engine.seek(to: engine.position + 15)
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .shift])
                Button("Voltar 15s") {
                    let engine = Playback.shared.active
                    engine.seek(to: max(0, engine.position - 15))
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .shift])
            }
        }

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Score matching and local import have no interface to inspect: a
        // wrong score renders as convincingly as a right one. This runs both
        // against known cases and reports, then leaves.
        if ProcessInfo.processInfo.environment["CADENZA_SELFTEST"] != nil {
            Task {
                await SelfTest.run()
                exit(0)
            }
            return
        }

        // The published copies of the legal documents are generated from the
        // same strings the app displays, so the website and the app can never
        // say different things.
        if let target = ProcessInfo.processInfo.environment["CADENZA_EMIT_LEGAL"] {
            LegalDocument.emit(to: URL(fileURLWithPath: target))
            exit(0)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NowPlayingCenter.shared.activate()
        ensureWindowAppears()
    }

    /// Makes sure something is actually on screen a moment after launch.
    ///
    /// AppKit autosaves each window's frame under a key derived from the view
    /// hierarchy's type name, and restores it before the app has any say. One
    /// bad entry — a frame from a display that is no longer attached, a stale
    /// key left by an older version of the view tree — and the window is
    /// restored somewhere it cannot be seen. The app then runs perfectly, with
    /// nothing visible and no way to get it back: the Dock icon does nothing,
    /// because there is a window and AppKit considers the job done.
    ///
    /// This happened, repeatedly, and the only cure was deleting the saved
    /// frame from the defaults by hand. Nobody should have to know that. If two
    /// seconds after launch nothing is showing, the window is put back at a
    /// sane size in the middle of the screen.
    private func ensureWindowAppears() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))

            let candidates = NSApp.windows.filter(\.canBecomeMain)
            guard !candidates.isEmpty else { return }
            if candidates.contains(where: { $0.isVisible && $0.frame.width > 400 }) { return }

            guard let window = candidates.first else { return }
            Diagnostics.log("[janela] nenhuma janela visível ao abrir — recolocando")
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A player should keep playing with its window closed, the way Music does.
    /// It also avoids a subtler failure: with window restoration disabled,
    /// declining the reopen prompt leaves SwiftUI with no window, and quitting
    /// on "no windows" made the app exit the instant it launched.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Required on modern macOS; without it the system falls back to insecure
    /// restoration, which is where the "quit unexpectedly while reopening
    /// windows" loop comes from.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Clicking the Dock icon must always end with a window on screen.
    ///
    /// The previous version answered `true` unconditionally, which tells AppKit
    /// "handled, do nothing further". When the app had a hidden window that was
    /// fine. When it had *no* window — which happens, since the app deliberately
    /// survives its last one closing — it was a dead end: the process stayed
    /// alive, the Dock icon did nothing, and the only way back was to force-quit.
    ///
    /// Answering `false` hands the question back to AppKit, which asks the
    /// `WindowGroup` for a new window. That is the only path that recovers from
    /// having none.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if hasVisibleWindows { return true }

        // A window that exists but is hidden only needs bringing forward.
        // `canBecomeMain` skips the panels and helpers SwiftUI keeps around,
        // which are not what the user is asking for.
        if let window = sender.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return true
        }
        return false
    }
}
