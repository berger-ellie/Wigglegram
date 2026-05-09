import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WigglegramApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("Wigglegram") {
            ContentView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await appState.warmUpModel()
                }
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1100, height: 740)
    }
}
