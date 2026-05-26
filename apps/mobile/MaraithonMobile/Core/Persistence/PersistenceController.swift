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
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
