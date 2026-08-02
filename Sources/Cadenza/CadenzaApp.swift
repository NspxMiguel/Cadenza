import SwiftUI

@main
struct CadenzaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Cadenza") {
            RootView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
