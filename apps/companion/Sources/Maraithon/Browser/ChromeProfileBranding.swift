/// Brands only Maraithon's idle, account-scoped Chrome profile, preserving existing sessions and preferences.
import Foundation

enum ChromeProfileBranding {
    static var welcomeURL: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "RunnerChromeWelcome", withExtension: "html")
        #else
        return Bundle.main.url(forResource: "RunnerChromeWelcome", withExtension: "html")
        #endif
    }

    static func prepare(directory: URL) throws {
        let files = FileManager.default
        let marker = directory.appendingPathComponent("maraithon-runner-brand-v1")
        // Never edit preferences underneath a running Chrome, even if its DevTools endpoint is unresponsive.
        guard !files.fileExists(atPath: marker.path),
              (try? files.attributesOfItem(atPath: directory.appendingPathComponent("SingletonLock").path)) == nil,
              (try? files.destinationOfSymbolicLink(atPath: directory.appendingPathComponent("SingletonLock").path)) == nil
        else { return }
        guard let welcomeURL else { return }
        let profile = directory.appendingPathComponent("Default", isDirectory: true)
        try files.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // These are Chrome's local profile presentation keys. No authentication or sync settings are copied.
        try update(directory.appendingPathComponent("Local State"), path: ["profile", "info_cache", "Default"], values: [
            "name": "Runner", "is_using_default_name": false
        ])
        try update(profile.appendingPathComponent("Preferences"), path: ["profile"], values: [
            "name": "Runner", "using_default_name": false
        ])
        try update(profile.appendingPathComponent("Preferences"), path: [], values: [
            "homepage": welcomeURL.absoluteString, "homepage_is_newtabpage": false
        ])
        try update(profile.appendingPathComponent("Preferences"), path: ["browser"], values: ["show_home_button": true])
        try Data("1\n".utf8).write(to: marker, options: .atomic)
    }

    private static func update(_ file: URL, path: [String], values: [String: Any]) throws {
        var object: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: file.path) {
            let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: file))
            guard let existing = decoded as? [String: Any] else {
                throw BrowserFailure("Chrome's profile preferences could not be read.")
            }
            object = existing
        }
        func merge(_ object: [String: Any], _ keys: ArraySlice<String>) -> [String: Any] {
            guard let key = keys.first else { return object.merging(values) { _, new in new } }
            var result = object
            result[key] = merge(object[key] as? [String: Any] ?? [:], keys.dropFirst())
            return result
        }
        let updated = merge(object, path[...])
        try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
