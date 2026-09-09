/// Keeps native source syncing in its existing app identity behind Electron.
/// Source permission prompts, credentials, cursors and queues remain untouched.
import AppKit

@MainActor
final class CompanionLifecycle: NSObject, NSApplicationDelegate {
    static var isSyncHelper: Bool {
        ProcessInfo.processInfo.arguments.contains("--sync-helper")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard Self.isSyncHelper else { return }
        NSApp.setActivationPolicy(.accessory)
        guard !ProcessInfo.processInfo.arguments.contains("--show-sources") else { return }
        // SwiftUI creates the initial Window on the next main-loop turn.
        DispatchQueue.main.async {
            for window in NSApp.windows where window.title == "Maraithon" {
                window.orderOut(nil)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard Self.isSyncHelper, !flag else { return true }
        if let window = sender.windows.first(where: { $0.title == "Maraithon" }) {
            window.makeKeyAndOrderFront(nil)
            sender.activate(ignoringOtherApps: true)
        }
        return true
    }
}
