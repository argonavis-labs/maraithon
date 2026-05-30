import Foundation

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
        let stableAppAction = stableAppInstalled ? "Use" : "Install"

        return Detail(
            message: "You're running a temporary Maraithon copy. macOS grants Full Disk Access to an exact app copy, so this one can lose access after reloads. \(stableAppAction) the stable app at \(stableDevelopmentAppDisplayPath) before granting access.",
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
}
