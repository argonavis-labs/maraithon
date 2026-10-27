import AppKit
import Foundation

/// DEBUG-only self-capture for design review. When `MARAITHON_SNAPSHOT_PATH`
/// is set, the app renders its own main window into that PNG after
/// `MARAITHON_SNAPSHOT_DELAY` seconds (default 6) using the view hierarchy,
/// so no Screen Recording permission is involved. Compiled out of release.
enum DebugSnapshot {
    @MainActor
    static func scheduleIfRequested(eventLog: EventLog) {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["MARAITHON_SNAPSHOT_PATH"], !path.isEmpty else { return }
        let delay = TimeInterval(environment["MARAITHON_SNAPSHOT_DELAY"] ?? "") ?? 6
        let quits = environment["MARAITHON_SNAPSHOT_QUIT"] == "1"
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let outcome = capture(to: URL(fileURLWithPath: path))
            eventLog.info("debug_snapshot.finished", source: .system, payload: ["path": path, "outcome": outcome])
            if quits { NSApp.terminate(nil) }
        }
        #endif
    }

    #if DEBUG
    @MainActor
    private static func capture(to url: URL) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView else { return "no_window" }
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else { return "no_bitmap" }
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else { return "no_png" }
        do {
            try data.write(to: url)
            return "written \(Int(bounds.width))x\(Int(bounds.height))"
        } catch {
            return "write_failed"
        }
    }
    #endif
}
