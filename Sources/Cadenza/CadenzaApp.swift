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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NowPlayingCenter.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
