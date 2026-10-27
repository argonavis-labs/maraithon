import Foundation

/// Persistent retry queue for sync envelopes. Buffers anything the engine
/// could not deliver yet to a small JSON file in the app sandbox so a
/// crash, restart, or sandbox eviction can resume mid-flight.
///
/// Format: a top-level `{ "envelopes": [ ... ] }` object so we can grow
/// metadata (e.g. attempt counts per envelope) later without breaking
/// on-disk compat.
actor SyncQueue {
    private let storageURL: URL
    private var pending: [SyncEnvelope] = []
    private var loaded = false

    /// `storageURL` defaults to the app sandbox's Application Support
    /// directory. Tests inject a temp URL.
    init(storageURL: URL = SyncQueue.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    /// Append envelopes and persist. Order is preserved so the engine
    /// drains FIFO.
    func enqueue(_ envelopes: [SyncEnvelope]) async throws {
        try loadIfNeeded()
        pending.append(contentsOf: envelopes)
        try persist()
    }

    /// Returns the next chunk of up to `limit` envelopes without removing
    /// them. Removal happens via `acknowledge` after a successful push so
    /// we never lose work mid-network-round-trip.
    func peek(limit: Int) async throws -> [SyncEnvelope] {
        try loadIfNeeded()
        return Array(pending.prefix(limit))
    }

    /// Drop the first `count` envelopes after a successful push. Safe to
    /// pass `count > pending.count` — callers may have peeked and then
    /// had the queue shrink concurrently in theory; in practice this is
    /// serialized by the actor.
    func acknowledge(count: Int) async throws {
        try loadIfNeeded()
        let drop = min(count, pending.count)
        if drop > 0 {
            pending.removeFirst(drop)
            try persist()
        }
    }

    func count() async throws -> Int {
        try loadIfNeeded()
        return pending.count
    }

    func clear() async throws {
        pending.removeAll()
        loaded = true
        try persist()
    }

    // MARK: - Storage

    private func loadIfNeeded() throws {
        guard !loaded else { return }
        loaded = true
        let fm = FileManager.default
        guard fm.fileExists(atPath: storageURL.path) else {
            pending = []
            return
        }
        let data = try Data(contentsOf: storageURL)
        guard !data.isEmpty else {
            pending = []
            return
        }
        let decoded = try JSONDecoder().decode(StorageEnvelope.self, from: data)
        pending = decoded.envelopes
    }

    private func persist() throws {
        let fm = FileManager.default
        let dir = storageURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let data = try JSONEncoder().encode(StorageEnvelope(envelopes: pending))
        try data.write(to: storageURL, options: .atomic)
    }

    private struct StorageEnvelope: Codable {
        var envelopes: [SyncEnvelope]
    }

    static func defaultStorageURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("Maraithon", isDirectory: true)
            .appendingPathComponent("sync-queue.json", isDirectory: false)
    }
}
