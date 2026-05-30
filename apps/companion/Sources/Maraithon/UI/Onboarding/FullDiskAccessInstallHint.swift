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
    enum InstallError: Error {
        case sourceIsNotAppBundle
    }

    struct Detail: Equatable {
        let message: String
        let stableAppURL: URL
        let stableAppInstalled: Bool
        let canInstallStableApp: Bool
    }

    static let stableDevelopmentAppDisplayPath = "~/Applications/Maraithon.app"
    static let switchToStableAppButtonTitle = "Switch to stable app"
    static let installStableAppButtonTitle = "Install stable app"
    static let revealStableAppButtonTitle = "Show Maraithon app"
    static var stableGrantReminder: String? {
        #if DEBUG
        return "For local builds, keep Full Disk Access on the exact app at \(stableDevelopmentAppDisplayPath). " +
            "If Maraithon is already enabled but still blocked, remove duplicate Maraithon entries, add this app again, then click Check again."
        #else
        return nil
        #endif
    }

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
        let canInstallStableApp = bundleURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame
        let stableAppAction = stableAppInstalled ? "Switch to" : "Install"

        return Detail(
            message: "You're running a temporary Maraithon copy. macOS grants Full Disk Access to one exact app. \(stableAppAction) the stable app at \(stableDevelopmentAppDisplayPath), then grant access to that app once.",
            stableAppURL: stableAppURL,
            stableAppInstalled: stableAppInstalled,
            canInstallStableApp: canInstallStableApp
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
    static func installStableDevelopmentApp(
        from sourceAppURL: URL = Bundle.main.bundleURL,
        to stableAppURL: URL,
        eventLog: EventLog,
        eventName: String
    ) {
        do {
            try copyStableDevelopmentApp(
                from: sourceAppURL,
                to: stableAppURL,
                fileManager: .default
            )
            eventLog.info(
                eventName,
                source: .ui,
                payload: ["from": sourceAppURL.path, "path": stableAppURL.path]
            )
            switchToStableDevelopmentApp(
                stableAppURL,
                eventLog: eventLog,
                eventName: "\(eventName).open"
            )
        } catch {
            eventLog.warning(
                "\(eventName)_failed",
                source: .ui,
                payload: [
                    "from": sourceAppURL.path,
                    "path": stableAppURL.path,
                    "error": String(describing: error)
                ]
            )
            NSWorkspace.shared.activateFileViewerSelecting([sourceAppURL])
        }
    }

    static func copyStableDevelopmentApp(
        from sourceAppURL: URL,
        to stableAppURL: URL,
        fileManager: FileManager
    ) throws {
        let source = sourceAppURL.standardizedFileURL
        let target = stableAppURL.standardizedFileURL
        guard source.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
            throw InstallError.sourceIsNotAppBundle
        }

        try fileManager.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                try fileManager.removeItem(at: target)
                try fileManager.copyItem(at: source, to: target)
                return
            }

            let existingContents = try fileManager.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
            )
            for item in existingContents {
                try fileManager.removeItem(at: item)
            }

            let sourceContents = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            )
            for item in sourceContents {
                try fileManager.copyItem(
                    at: item,
                    to: target.appendingPathComponent(item.lastPathComponent)
                )
            }
        } else {
            try fileManager.copyItem(at: source, to: target)
        }
    }

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

    @MainActor
    static func revealStableDevelopmentApp(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        eventLog: EventLog,
        eventName: String
    ) {
        let appURL = stableDevelopmentAppURL(homeDirectory: homeDirectory)
        let revealURL = FileManager.default.fileExists(atPath: appURL.path)
            ? appURL
            : appURL.deletingLastPathComponent()

        eventLog.info(eventName, source: .ui, payload: ["path": appURL.path])
        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
    }
    #endif
}
