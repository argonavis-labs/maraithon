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
/// at 10 MB × 5 files.
/// XCTest runs default to memory-only logs so fixture events do not pollute
/// the user's real companion log.
@Observable
@MainActor
final class EventLog {
    private(set) var entries: [LogEntry] = []
    private(set) var logFileURL: URL?
    private let capacity: Int
    private let maximumFileBytes: UInt64
    private let maximumRotatedFiles: Int
    private var fileHandle: FileHandle?
    private let dateFormatter: ISO8601DateFormatter
    private let loggers: [LogSource: Logger]

    private static let subsystem = "com.maraithon.companion"
    static let defaultMaximumLogFileBytes: UInt64 = 10 * 1024 * 1024
    static let defaultMaximumRotatedFiles = 5

    init(
        capacity: Int = 5_000,
        persistence: EventLogPersistence = .automatic,
        maximumFileBytes: UInt64 = EventLog.defaultMaximumLogFileBytes,
        maximumRotatedFiles: Int = EventLog.defaultMaximumRotatedFiles
    ) {
        self.capacity = capacity
        self.maximumFileBytes = maximumFileBytes
        self.maximumRotatedFiles = maximumRotatedFiles
        self.dateFormatter = ISO8601DateFormatter()
        self.dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let resolvedLogFileURL = Self.logFileURL(for: persistence)
        self.logFileURL = resolvedLogFileURL
        self.fileHandle = resolvedLogFileURL.flatMap {
            Self.openLogFile(
                at: $0,
                maximumFileBytes: maximumFileBytes,
                maximumRotatedFiles: maximumRotatedFiles
            )
        }
        self.loggers = Dictionary(
            uniqueKeysWithValues: LogSource.allCases.map { source in
                (source, Logger(subsystem: Self.subsystem, category: source.rawValue))
            }
        )
    }

    func append(_ entry: LogEntry) {
        let entry = Self.redacted(entry)
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
    /// "key=value" pairs; entries are centrally redacted before they reach
    /// this method.
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

    nonisolated static func redactSensitiveLogText(_ value: String) -> String {
        EventLogRedactor.redact(value)
    }

    private nonisolated static func redacted(_ entry: LogEntry) -> LogEntry {
        LogEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            level: entry.level,
            source: entry.source,
            message: redactSensitiveLogText(entry.message),
            payload: entry.payload.mapValues(redactSensitiveLogText)
        )
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
            rotatePersistedLogIfNeeded()
        }
    }

    private func rotatePersistedLogIfNeeded() {
        guard let logFileURL,
              maximumFileBytes > 0,
              let size = Self.fileSize(at: logFileURL),
              size >= maximumFileBytes else {
            return
        }

        try? fileHandle?.close()
        fileHandle = nil
        Self.rotateLog(
            at: logFileURL,
            maximumFileBytes: maximumFileBytes,
            maximumRotatedFiles: maximumRotatedFiles
        )
        fileHandle = Self.openLogFile(
            at: logFileURL,
            maximumFileBytes: maximumFileBytes,
            maximumRotatedFiles: maximumRotatedFiles
        )
    }

    private static func logFileURL(for persistence: EventLogPersistence) -> URL? {
        switch persistence {
        case .automatic:
            guard !isRunningUnderXCTest else { return nil }
            return defaultLogFileURL()
        case .disabled:
            return nil
        case .file(let url):
            return url
        }
    }

    private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
            || NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }

    private static func defaultLogFileURL() -> URL? {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Maraithon", isDirectory: true)
        else { return nil }
        return logsDir.appendingPathComponent("companion.log")
    }

    private static func openLogFile(
        at fileURL: URL,
        maximumFileBytes: UInt64,
        maximumRotatedFiles: Int
    ) -> FileHandle? {
        let fm = FileManager.default
        let logsDir = fileURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        prepareLogFiles(
            at: fileURL,
            maximumFileBytes: maximumFileBytes,
            maximumRotatedFiles: maximumRotatedFiles
        )

        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }

        let handle = try? FileHandle(forWritingTo: fileURL)
        if let handle {
            _ = try? handle.seekToEnd()
        }
        return handle
    }

    private static func prepareLogFiles(
        at fileURL: URL,
        maximumFileBytes: UInt64,
        maximumRotatedFiles: Int
    ) {
        guard maximumFileBytes > 0 else { return }

        for index in 1...max(maximumRotatedFiles, 1) {
            trimLogIfNeeded(
                at: rotatedLogURL(for: fileURL, index: index),
                maximumFileBytes: maximumFileBytes
            )
        }

        guard let activeSize = fileSize(at: fileURL),
              activeSize >= maximumFileBytes else {
            return
        }

        rotateLog(
            at: fileURL,
            maximumFileBytes: maximumFileBytes,
            maximumRotatedFiles: maximumRotatedFiles
        )
    }

    private static func rotateLog(
        at fileURL: URL,
        maximumFileBytes: UInt64,
        maximumRotatedFiles: Int
    ) {
        let fm = FileManager.default

        if maximumRotatedFiles <= 0 {
            try? fm.removeItem(at: fileURL)
            fm.createFile(atPath: fileURL.path, contents: nil)
            return
        }

        trimLogIfNeeded(at: fileURL, maximumFileBytes: maximumFileBytes)

        let oldest = rotatedLogURL(for: fileURL, index: maximumRotatedFiles)
        if fm.fileExists(atPath: oldest.path) {
            try? fm.removeItem(at: oldest)
        }

        if maximumRotatedFiles > 1 {
            for index in stride(from: maximumRotatedFiles - 1, through: 1, by: -1) {
                let source = rotatedLogURL(for: fileURL, index: index)
                guard fm.fileExists(atPath: source.path) else { continue }
                let destination = rotatedLogURL(for: fileURL, index: index + 1)
                try? fm.moveItem(at: source, to: destination)
            }
        }

        if fm.fileExists(atPath: fileURL.path) {
            try? fm.moveItem(at: fileURL, to: rotatedLogURL(for: fileURL, index: 1))
        }
        fm.createFile(atPath: fileURL.path, contents: nil)
    }

    private static func trimLogIfNeeded(at fileURL: URL, maximumFileBytes: UInt64) {
        guard maximumFileBytes > 0,
              let size = fileSize(at: fileURL),
              size > maximumFileBytes else {
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            try? Data().write(to: fileURL)
            return
        }

        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: size - maximumFileBytes)) != nil,
              let data = try? handle.readToEnd() else {
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func fileSize(at fileURL: URL) -> UInt64? {
        guard let size = try? FileManager.default
            .attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber
        else {
            return nil
        }
        return size.uint64Value
    }

    private static func rotatedLogURL(for fileURL: URL, index: Int) -> URL {
        URL(fileURLWithPath: "\(fileURL.path).\(index)")
    }
}

private enum EventLogRedactor {
    static func redact(_ value: String) -> String {
        guard !value.isEmpty else { return value }

        var result = value
        result = replace(
            pattern: #"(?i)\b(authorization\s*[:=]\s*bearer\s+)[^\s,;)\]\}"]+"#,
            in: result,
            with: "$1[redacted]"
        )
        result = replace(
            pattern: #"(?i)\b((?:x-api-key|api-key|api_key|access-token|refresh-token|token)\s*:\s*)[^\s,;)\]\}"]+"#,
            in: result,
            with: "$1[redacted]"
        )
        result = replace(
            pattern: #"(?i)\b((?:access_token|refresh_token|id_token|token|api_key|apikey|key|client_secret|secret|password|signature|sig)=)[^&\s,;)\]\}"]+"#,
            in: result,
            with: "$1[redacted]"
        )
        result = replace(
            pattern: #"(?i)("(?:access_token|refresh_token|id_token|token|api_key|apikey|key|client_secret|secret|password|signature|sig)"\s*:\s*")[^"]+""#,
            in: result,
            with: "$1[redacted]\""
        )
        result = replace(
            pattern: #"(?i)((?:device-token|access-token|refresh-token)/)[A-Za-z0-9._~+%=-]+"#,
            in: result,
            with: "$1[redacted]"
        )
        result = replace(
            pattern: #"(?m)((?:^|\s)[A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|KEY)[A-Z0-9_]*\s*=\s*)["']?[^"'\s]+"#,
            in: result,
            with: "$1[redacted]"
        )
        return result
    }

    private static func replace(pattern: String, in value: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
