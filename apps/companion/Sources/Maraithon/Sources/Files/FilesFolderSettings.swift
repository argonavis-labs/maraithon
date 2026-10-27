import Foundation

/// User-chosen folders for the Files source.
///
/// When the user has never customized the list, scanning sticks to
/// `FilesScanner.defaultRoots` (Documents, Desktop, Downloads). Once the
/// user edits the list, the stored paths are the complete scan set — no
/// implicit extras. Overly broad roots (the volume root, the home folder)
/// are rejected so the source never walks the whole computer.
enum FilesFolderSettings {
    static let defaultsKey = "com.maraithon.companion.files.folders"

    /// Paths the user explicitly saved, or empty when using defaults.
    static func storedPaths(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    /// The roots the scanner should walk right now.
    static func effectiveRoots(defaults: UserDefaults = .standard) -> [URL] {
        let stored = storedPaths(defaults: defaults)
        guard !stored.isEmpty else { return FilesScanner.defaultRoots }
        return stored.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func isCustomized(defaults: UserDefaults = .standard) -> Bool {
        !storedPaths(defaults: defaults).isEmpty
    }

    /// Adds a folder. Returns false when the folder is rejected (too broad,
    /// not a directory, or already present).
    @discardableResult
    static func add(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        let path = normalizedPath(url)
        guard isAllowedRoot(path) else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return false
        }

        var paths = currentEditablePaths(defaults: defaults)
        guard !paths.contains(path) else { return false }
        paths.append(path)
        defaults.set(paths, forKey: defaultsKey)
        return true
    }

    @discardableResult
    static func remove(path: String, defaults: UserDefaults = .standard) -> Bool {
        var paths = currentEditablePaths(defaults: defaults)
        guard let index = paths.firstIndex(of: path) else { return false }
        paths.remove(at: index)
        defaults.set(paths, forKey: defaultsKey)
        return true
    }

    /// Back to the built-in Documents/Desktop/Downloads set.
    static func resetToDefaults(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    /// Rejects roots that would effectively scan the whole computer.
    static func isAllowedRoot(_ path: String) -> Bool {
        let home = normalizedPath(FileManager.default.homeDirectoryForCurrentUser)
        let blocked = ["/", "/Users", "/System", "/Volumes", "/private", home]
        return !blocked.contains(path)
    }

    /// The first customization starts from the current defaults so adding a
    /// folder reads as "defaults plus this one", not a silent replacement.
    private static func currentEditablePaths(defaults: UserDefaults) -> [String] {
        let stored = storedPaths(defaults: defaults)
        if !stored.isEmpty { return stored }
        return FilesScanner.defaultRoots.map(normalizedPath)
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
