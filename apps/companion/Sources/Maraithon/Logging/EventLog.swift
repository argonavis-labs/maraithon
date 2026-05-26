import Foundation
import Observation
import OSLog

/// Levels mirror server-side log levels so cross-system reasoning stays
/// consistent.
enum LogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}

/// Logical sources of log entries. Adding a new long-lived module typically
/// means adding a case here.
enum LogSource: String, Codable, CaseIterable, Sendable {
    case system
    case auth
    case imessage
    case notes
    case voiceMemos = "voice_memos"
    case reminders
    case calendar
    case browser
    case files
    case sync
    case realtime
    case cloud
    case ui
}

struct LogEntry: Identifiable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: LogLevel
    let source: LogSource
    let message: String
    let payload: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        source: LogSource,
        message: String,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
        self.payload = payload
    }
}

/// In-memory ring buffer of `LogEntry`s with a persistent file backing.
/// UI observes `entries` directly; non-UI code calls the level-specific
/// helpers (`info`, `warning`, …) which never block.
///
/// Persistence target: `~/Library/Logs/Maraithon/companion.log`, rotated
/// at 10MB × 5 files (rotation is a follow-up; v1 ships append-only).
@Observable
@MainActor
final class EventLog {
    private(set) var entries: [LogEntry] = []
    private let capacity: Int
    private let fileHandle: FileHandle?
    private let dateFormatter: ISO8601DateFormatter
    private let loggers: [LogSource: Logger]

    private static let subsystem = "com.maraithon.companion"

    init(capacity: Int = 5_000) {
        self.capacity = capacity
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.fileHandle = Self.openLogFile()
        self.loggers = Dictionary(
            uniqueKeysWithValues: LogSource.allCases.map { source in
                (source, Logger(subsystem: Self.subsystem, category: source.rawValue))
            }
        )
    }

    deinit {
        try? fileHandle?.close()
    }

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
        persist(entry)
        emitToUnifiedLog(entry)
    }

    /// Tee every entry into the unified logging system so it's visible in
    /// Console.app and `log stream --predicate
    /// 'subsystem == "com.maraithon.companion"'` without anyone having to
    /// load our app to read it. Structured payload is rendered as
    /// "key=value" pairs; sensitive values must already be redacted by the
    /// caller (see `Redactor`).
    private func emitToUnifiedLog(_ entry: LogEntry) {
        guard let logger = loggers[entry.source] else { return }
        let payload = entry.payload.isEmpty
            ? ""
            : " " + entry.payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        let line = "\(entry.message)\(payload)"
        switch entry.level {
        case .debug:   logger.debug("\(line, privacy: .public)")
        case .info:    logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error:   logger.error("\(line, privacy: .public)")
        }
    }

    func debug(_ message: String, source: LogSource, payload: [String: String] = [:]) {
        append(LogEntry(level: .debug, source: source, message: message, payload: payload))
    }

    func info(_ message: String, source: LogSource, payload: [String: String] = [:]) {
        append(LogEntry(level: .info, source: source, message: message, payload: payload))
    }

    func warning(_ message: String, source: LogSource, payload: [String: String] = [:]) {
        append(LogEntry(level: .warning, source: source, message: message, payload: payload))
    }

    func error(_ message: String, source: LogSource, payload: [String: String] = [:]) {
        append(LogEntry(level: .error, source: source, message: message, payload: payload))
    }

    private func persist(_ entry: LogEntry) {
        guard let handle = fileHandle else { return }
        let ts = dateFormatter.string(from: entry.timestamp)
        let payload = entry.payload.isEmpty
            ? ""
            : " " + entry.payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
        let line = "[\(ts)] [\(entry.level.rawValue)] [\(entry.source.rawValue)] \(entry.message)\(payload)\n"
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }

    private static func openLogFile() -> FileHandle? {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Maraithon", isDirectory: true)
        else { return nil }

        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let fileURL = logsDir.appendingPathComponent("companion.log")
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try? FileHandle(forWritingTo: fileURL)
        if let handle {
            _ = try? handle.seekToEnd()
        }
        return handle
    }
}
