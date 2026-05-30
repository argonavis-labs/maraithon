import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Detects local development app copies that cannot hold macOS privacy
/// grants reliably across rebuilds. Full Disk Access is tied to the app
/// copy macOS sees in System Settings; Xcode DerivedData and SwiftPM
/// binaries are temporary identities, so the permission can appear to
/// disappear on reload.
enum FullDiskAccessInstallHint {
    struct Detail: Equatable {
        let message: String
        let stableAppURL: URL
        let stableAppInstalled: Bool
    }

    static let stableDevelopmentAppDisplayPath = "~/Applications/Maraithon.app"
    static let switchToStableAppButtonTitle = "Switch to stable app"

    static func current(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Detail? {
        #if DEBUG
        return detail(for: bundleURL, homeDirectory: homeDirectory, fileManager: fileManager)
        #else
        return nil
        #endif
    }

    static func currentMessage(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        current(bundleURL: bundleURL, homeDirectory: homeDirectory)?.message
    }

    static func message(for bundleURL: URL, homeDirectory: URL) -> String? {
        detail(for: bundleURL, homeDirectory: homeDirectory)?.message
    }

    static func detail(
        for bundleURL: URL,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Detail? {
        guard isTemporaryDevelopmentLocation(bundleURL, homeDirectory: homeDirectory) else {
            return nil
        }

        let stableAppURL = stableDevelopmentAppURL(homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        let stableAppInstalled = fileManager.fileExists(
            atPath: stableAppURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue
        let stableAppAction = stableAppInstalled ? "Switch to" : "Install"

        return Detail(
            message: "You're running a temporary Maraithon copy. Full Disk Access is granted to an exact app copy, so access can disappear after reloads. \(stableAppAction) the stable app at \(stableDevelopmentAppDisplayPath) before opening System Settings.",
            stableAppURL: stableAppURL,
            stableAppInstalled: stableAppInstalled
        )
    }

    static func stableDevelopmentAppURL(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)
            .standardizedFileURL
    }

    static func isTemporaryDevelopmentLocation(
        _ bundleURL: URL,
        homeDirectory: URL
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        let stableDevelopmentPath = stableDevelopmentAppURL(homeDirectory: homeDirectory).path

        if path == stableDevelopmentPath {
            return false
        }

        if path.hasPrefix("/Applications/") || path.hasPrefix("\(homePath)/Applications/") {
            return false
        }

        return true
    }

    #if canImport(AppKit)
    @MainActor
    static func switchToStableDevelopmentApp(
        _ stableAppURL: URL,
        eventLog: EventLog,
        eventName: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", stableAppURL.path]

        do {
            try process.run()
            eventLog.info(eventName, source: .ui, payload: ["path": stableAppURL.path])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                NSApp.terminate(nil)
            }
        } catch {
            eventLog.warning(
                "\(eventName)_failed",
                source: .ui,
                payload: ["path": stableAppURL.path, "error": String(describing: error)]
            )
            NSWorkspace.shared.activateFileViewerSelecting([stableAppURL])
        }
    }
    #endif
}
