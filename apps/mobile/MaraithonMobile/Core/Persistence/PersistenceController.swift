import Foundation
import SwiftData

enum PersistenceController {
    @MainActor
    static func makeModelContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([
            TodoItem.self,
            CRMContact.self,
            ChatThread.self,
            ChatMessage.self
        ])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // Opening the on-disk store failed — most often an incompatible schema
            // migration or a corrupt store. Crashing here strands the user in a launch
            // loop. The server is the source of truth and re-syncs on launch, so rebuild
            // the local store instead of taking down the app.
            guard !inMemory else { throw error }

            destroyStore(at: configuration.url)

            if let recovered = try? ModelContainer(for: schema, configurations: [configuration]) {
                return recovered
            }

            // Last resort: launch with an ephemeral store rather than crashing.
            let fallback = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try ModelContainer(for: schema, configurations: [fallback])
        }
    }

    /// Removes the SQLite store and its write-ahead-log siblings so a fresh container
    /// can be created from the current schema.
    private static func destroyStore(at url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = url.path + suffix
            guard fileManager.fileExists(atPath: path) else { continue }
            try? fileManager.removeItem(atPath: path)
        }
    }
}
