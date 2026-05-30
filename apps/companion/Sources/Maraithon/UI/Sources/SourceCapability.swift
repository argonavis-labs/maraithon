import Foundation

/// User-facing outcome unlocked by a synced source.
struct SourceCapability: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String
    let systemImage: String

    init(id: String, title: String, description: String, systemImage: String) {
        self.id = id
        self.title = title
        self.description = description
        self.systemImage = systemImage
    }
}
