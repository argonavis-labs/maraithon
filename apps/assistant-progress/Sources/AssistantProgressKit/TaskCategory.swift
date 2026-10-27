/// Shared task categories match the server's account settings without inferring ownership.
import Foundation

public enum TaskCategory: String, CaseIterable, Identifiable, Sendable {
    case all, personal, work
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public func includes(_ category: String?) -> Bool { self == .all || category == rawValue }
}
