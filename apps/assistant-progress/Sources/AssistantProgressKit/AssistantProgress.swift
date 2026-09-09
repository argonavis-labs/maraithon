import Foundation

/// One public wire contract for both native clients. Snapshots replace state;
/// previews are disposable and never advance the recovery cursor.
public enum AssistantProgress<Thread: Decodable & Sendable>: Sendable {
    case snapshot(Snapshot)
    case preview(Preview)

    public struct Snapshot: Decodable, Sendable {
        public let schemaVersion: Int
        public let cursor: String
        public let thread: Thread
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", cursor, thread
        }
    }

    public struct Preview: Decodable, Sendable {
        public let schemaVersion: Int
        public let threadID: String
        public let runID: String
        public let reply: String
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", threadID = "thread_id", runID = "run_id", reply
        }
    }
}
