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

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NowPlayingCenter.shared.activate()
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

    /// With window restoration off, relaunching an already-running app would
    /// otherwise leave it with no window at all. Clicking the Dock icon — or
    /// opening the app again — always brings a window back.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if let window = sender.windows.first(where: { !$0.isVisible }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
