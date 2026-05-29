import Foundation

/// Detects local development app copies that cannot hold macOS privacy
/// grants reliably across rebuilds. Full Disk Access is tied to the app
/// copy macOS sees in System Settings; Xcode DerivedData and SwiftPM
/// binaries are temporary identities, so the permission can appear to
/// disappear on reload.
enum FullDiskAccessInstallHint {
    static let stableDevelopmentAppDisplayPath = "~/Applications/Maraithon.app"

    static func currentMessage(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        #if DEBUG
        return message(for: bundleURL, homeDirectory: homeDirectory)
        #else
        return nil
        #endif
    }

    static func message(for bundleURL: URL, homeDirectory: URL) -> String? {
        guard isTemporaryDevelopmentLocation(bundleURL, homeDirectory: homeDirectory) else {
            return nil
        }

        return "This is a temporary development build. Full Disk Access is tied to the exact app copy in System Settings, so it can disappear after reloads. Launch \(stableDevelopmentAppDisplayPath) with make run-companion, then grant that app once."
    }

    static func isTemporaryDevelopmentLocation(
        _ bundleURL: URL,
        homeDirectory: URL
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        let stableDevelopmentPath = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Maraithon.app", isDirectory: true)
            .standardizedFileURL
            .path

        if path == stableDevelopmentPath {
            return false
        }

        if path.hasPrefix("/Applications/") || path.hasPrefix("\(homePath)/Applications/") {
            return false
        }

        return path.contains("/DerivedData/")
            || path.contains("/.build/")
            || !path.hasSuffix(".app")
    }
}
