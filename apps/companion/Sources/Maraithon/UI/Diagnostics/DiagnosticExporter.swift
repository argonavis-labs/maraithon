import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Builds a single zip bundle of the data a support engineer needs to
/// triage a Maraithon install — log files, source cursors, the recent
/// in-memory event log, device id, and app version — and drops it into
/// the user's Downloads folder.
///
/// Privacy invariants:
///   - Recent in-memory entries and copied log files go through the
///     central `EventLog` sensitive-token redactor before they are
///     written into the bundle.
///   - Handle-shaped payload values then go through `Redactor.redact`
///     field by field so handles in `payload` (e.g. `from`, `to`, `chat`,
///     `id`) never make it onto disk unredacted.
///   - UserDefaults cursor snapshot is restricted to a whitelist of
///     known prefixes (`com.maraithon.companion.*` and the source
///     cursor keys) — we never dump the full defaults dictionary.
///   - File names are stable and human-readable; the zip's top-level
///     folder uses a clear `Maraithon-Diagnostics-<ISO>-<hash>` shape.
///
/// Output filename:
/// `Maraithon-Diagnostics-<ISO-8601 date>-<short device hash>.zip`
/// where the hash is the first 8 chars of a SHA-256 over the device id.
@MainActor
enum DiagnosticExporter {

    /// Top-level error surface. The UI's only branch is `success` vs
    /// `failure` — the error case carries a human-readable reason for
    /// the `EventLog` entry the caller writes.
    enum ExportError: Error, Equatable {
        case noDownloadsFolder
        case zipFailed(reason: String)
        case writeFailed(reason: String)
    }

    /// Result of a successful export. The caller posts this to the
    /// `EventLog` and reveals the file in Finder.
    struct ExportResult: Equatable, Sendable {
        let bundleURL: URL
        let byteCount: Int
        let createdAt: Date
    }

    /// Build + write the bundle. Returns the URL the bundle was written
    /// to. Logs every step through the passed-in `EventLog`.
    @discardableResult
    static func export(
        log: EventLog,
        deviceId: UUID,
        appVersion: String,
        recentEntries: [LogEntry],
        downloadsDirectory: URL? = defaultDownloadsDirectory(),
        defaults: UserDefaults = .standard,
        sourceLogsDirectory: URL? = defaultLogsDirectory(),
        revealInFinder: Bool = true
    ) throws -> ExportResult {
        guard let downloadsDirectory else {
            log.error("diagnostics.export.no_downloads", source: .system)
            throw ExportError.noDownloadsFolder
        }

        let isoTimestamp = Self.filenameTimestampFormatter.string(from: Date())
        let deviceHash = Self.shortDeviceHash(deviceId)
        let bundleStem = "Maraithon-Diagnostics-\(isoTimestamp)-\(deviceHash)"
        let bundleURL = downloadsDirectory.appendingPathComponent("\(bundleStem).zip")

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("maraithon-diagnostics-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let stagingRoot = staging.appendingPathComponent(bundleStem, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        // 1. Copy log files (companion.log + rotated companion.log.1 ... .5).
        if let sourceLogsDirectory {
            try copyLogFiles(from: sourceLogsDirectory, into: stagingRoot, log: log)
        }

        // 2. Cursor snapshot. Whitelisted prefixes only.
        let cursorJSON = cursorSnapshotJSON(defaults: defaults)
        try cursorJSON.write(
            to: stagingRoot.appendingPathComponent("cursors.json"),
            options: .atomic
        )

        // 3. Redacted recent events.
        let eventsJSON = try redactedEventsJSON(recentEntries)
        try eventsJSON.write(
            to: stagingRoot.appendingPathComponent("recent-events.json"),
            options: .atomic
        )

        // 4. Manifest with device id + version.
        let manifestJSON = try manifestJSON(
            deviceId: deviceId,
            appVersion: appVersion,
            entryCount: recentEntries.count
        )
        try manifestJSON.write(
            to: stagingRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        // 5. Zip the staged root into the user's Downloads folder.
        try writeZip(from: stagingRoot, to: bundleURL, log: log)

        let byteCount = (try? FileManager.default.attributesOfItem(atPath: bundleURL.path)[.size] as? Int) ?? 0

        if revealInFinder {
            #if canImport(AppKit)
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
            #endif
        }

        log.info(
            "diagnostics.export.completed",
            source: .system,
            payload: [
                "path": bundleURL.lastPathComponent,
                "bytes": String(byteCount),
                "entries": String(recentEntries.count)
            ]
        )

        return ExportResult(bundleURL: bundleURL, byteCount: byteCount, createdAt: Date())
    }

    // MARK: - Helpers

    /// Defaults keys this exporter is allowed to copy. Restricting the
    /// dump to known prefixes keeps unrelated state (e.g. Safari cookies
    /// other apps wrote into shared defaults) out of the bundle.
    static let allowedDefaultsPrefixes: [String] = [
        "com.maraithon.companion."
    ]

    /// Build the cursor-snapshot JSON. Public so tests can drive it with
    /// an injected `UserDefaults` suite.
    static func cursorSnapshotJSON(defaults: UserDefaults) -> Data {
        let snapshot = defaults.dictionaryRepresentation()
            .filter { entry in
                allowedDefaultsPrefixes.contains { entry.key.hasPrefix($0) }
            }
        // Map every value to a string so the JSON doesn't choke on
        // values that aren't naturally JSON-encodable (e.g., Data).
        var stringified: [String: String] = [:]
        for (key, value) in snapshot {
            stringified[key] = String(describing: value)
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: stringified,
            options: [.prettyPrinted, .sortedKeys]
        )) ?? Data("{}".utf8)
        return data
    }

    /// Build the redacted recent-events JSON. Public so tests can assert
    /// on the output shape directly.
    static func redactedEventsJSON(_ entries: [LogEntry]) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let serialised = entries.map { entry -> [String: Any] in
            var dict: [String: Any] = [
                "timestamp": formatter.string(from: entry.timestamp),
                "level": entry.level.rawValue,
                "source": entry.source.rawValue,
                "message": EventLog.redactSensitiveLogText(entry.message)
            ]
            if !entry.payload.isEmpty {
                dict["payload"] = redactPayload(entry.payload)
            }
            return dict
        }
        return try JSONSerialization.data(
            withJSONObject: serialised,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// Apply sensitive-token redaction to every payload value, then apply
    /// `Redactor.redact` to known handle fields. Non-handle values such
    /// as counts pass through unless they contain secrets.
    static func redactPayload(_ payload: [String: String]) -> [String: String] {
        let handleKeys: Set<String> = [
            "from", "to", "chat", "handle", "handles", "guid", "id", "email", "url"
        ]
        var redacted: [String: String] = [:]
        for (key, value) in payload {
            let tokenRedacted = EventLog.redactSensitiveLogText(value)
            if handleKeys.contains(key) {
                redacted[key] = Redactor.redact(tokenRedacted)
            } else {
                redacted[key] = tokenRedacted
            }
        }
        return redacted
    }

    static func redactDiagnosticLogText(_ text: String) -> String {
        EventLog.redactSensitiveLogText(text)
    }

    /// Build the manifest JSON the bundle root carries. Captures a
    /// short device hash (not the raw id), version, generation
    /// timestamp, and how many in-memory log entries we exported.
    static func manifestJSON(
        deviceId: UUID,
        appVersion: String,
        entryCount: Int
    ) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload: [String: Any] = [
            "device_hash": shortDeviceHash(deviceId),
            "app_version": appVersion,
            "generated_at": formatter.string(from: Date()),
            "entry_count": entryCount,
            "schema_version": 1
        ]
        return try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    /// First eight hex chars of a SHA-256 over the device UUID. We avoid
    /// shipping the raw `device_id` in support bundles so the receiving
    /// engineer can correlate without learning the install's identity.
    static func shortDeviceHash(_ deviceId: UUID) -> String {
        let bytes = withUnsafeBytes(of: deviceId.uuid) { Array($0) }
        let hash = SimpleSHA256.hash(bytes)
        return String(hash.prefix(8))
    }

    private static func copyLogFiles(
        from sourceDir: URL,
        into stagingRoot: URL,
        log: EventLog
    ) throws {
        let fm = FileManager.default
        let destination = stagingRoot.appendingPathComponent("logs", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        guard fm.fileExists(atPath: sourceDir.path) else { return }
        let contents = (try? fm.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: nil)) ?? []
        for entry in contents where entry.lastPathComponent.hasPrefix("companion") {
            let target = destination.appendingPathComponent(entry.lastPathComponent)
            do {
                if fm.fileExists(atPath: target.path) {
                    try fm.removeItem(at: target)
                }
                let data = try Data(contentsOf: entry)
                if let text = String(data: data, encoding: .utf8) {
                    let redacted = redactDiagnosticLogText(text)
                    try Data(redacted.utf8).write(to: target, options: .atomic)
                } else {
                    try data.write(to: target, options: .atomic)
                }
            } catch {
                log.warning(
                    "diagnostics.export.log_copy_failed",
                    source: .system,
                    payload: ["file": entry.lastPathComponent, "error": String(describing: error)]
                )
            }
        }
    }

    /// `Process` to `/usr/bin/zip`. We don't pull `ZIPFoundation` in for
    /// a single zip operation — `zip` is universally present and we
    /// already require macOS 14.
    private static func writeZip(
        from root: URL,
        to bundleURL: URL,
        log: EventLog
    ) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root.deletingLastPathComponent()
        process.arguments = ["-r", "-q", bundleURL.path, root.lastPathComponent]

        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw ExportError.zipFailed(reason: String(describing: error))
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            let reason = String(data: data, encoding: .utf8) ?? "exit \(process.terminationStatus)"
            log.error(
                "diagnostics.export.zip_failed",
                source: .system,
                payload: ["reason": reason]
            )
            throw ExportError.zipFailed(reason: reason)
        }
    }

    private static let filenameTimestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func defaultDownloadsDirectory() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    static func defaultLogsDirectory() -> URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Maraithon", isDirectory: true)
    }
}

/// Bare-bones SHA-256 used by `DiagnosticExporter.shortDeviceHash`. We
/// avoid pulling in `CryptoKit` for a single 8-character hash so the
/// exporter remains a single dependency-free file. Output is the lower-
/// case hex string of the digest.
enum SimpleSHA256 {
    static func hash(_ bytes: [UInt8]) -> String {
        var h: [UInt32] = [
            0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
            0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
        ]
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
        ]

        var message = bytes
        let originalBitLength = UInt64(bytes.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((originalBitLength >> UInt64(shift)) & 0xff))
        }

        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(message[base]) << 24)
                    | (UInt32(message[base + 1]) << 16)
                    | (UInt32(message[base + 2]) << 8)
                    | UInt32(message[base + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3]
            var e = h[4], f = h[5], g = h[6], hh = h[7]

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj

                hh = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }

            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }

        return h.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        return (value >> count) | (value << (32 - count))
    }
}
