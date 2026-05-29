import Foundation

/// Lightweight permission probe for macOS Full Disk Access.
///
/// Full Disk Access is app-wide, while the companion has several protected
/// local stores. A successful read of any known protected store is enough to
/// prove the current app copy has the grant; using Messages alone makes the
/// grant look missing on Macs without a readable `chat.db`.
enum FullDiskAccessProbe {
    static var protectedDatabaseURLs: [URL] {
        [
            IMessageDatabase.defaultDatabaseURL,
            NotesDatabase.defaultDatabaseURL,
            VoiceMemosDatabase.sharedContainerDatabaseURL,
            VoiceMemosDatabase.legacyDatabaseURL
        ]
    }

    static func isGranted(fileManager: FileManager = .default) -> Bool {
        isGranted(candidateURLs: protectedDatabaseURLs, fileManager: fileManager)
    }

    static func isGranted(candidateURLs: [URL], fileManager: FileManager = .default) -> Bool {
        candidateURLs.contains { canReadExistingFile($0, fileManager: fileManager) }
    }

    private static func canReadExistingFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else {
            return false
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        try? handle.close()
        return true
    }
}
