import Foundation
import Observation

/// Receives payloads from sources, batches them, retries on failure, and
/// pushes them to Maraithon's `/api/v1/companion/messages` endpoint.
///
/// Public surface used by `AppEnvironment` is preserved:
///   * `init(eventLog:deviceAuth:)`
///   * `push(_:) async throws -> SyncOutcome`
///
/// On top of that the engine exposes:
///   * `enqueue(_:)` — durable buffering via `SyncQueue`.
///   * `drain(source:)` — drains the persistent queue into the cloud,
///     batching at 200 and applying exponential backoff with jitter.
///   * `health` — `@Observable` status the UI surfaces in the menubar.
@Observable
@MainActor
final class SyncEngine {
    /// Three-state health the UI reads. `.needsAttention` is the failure
    /// surface after three consecutive give-ups in `push`.
    enum Health: Equatable, Sendable {
        case idle
        case syncing
        case needsAttention(reason: String)
    }

    private(set) var health: Health = .idle
    private(set) var lastSuccessAt: Date?
    private(set) var consecutiveFailures: Int = 0

    private let eventLog: EventLog
    private let deviceAuth: DeviceAuth
    private let client: MaraithonClient
    private let queue: SyncQueue
    private let backoff: Backoff
    private let batchSize: Int

    /// Designated init used by tests. The default-arg overload below keeps
    /// `AppEnvironment`'s call site (`SyncEngine(eventLog:, deviceAuth:)`)
    /// working unchanged.
    init(
        eventLog: EventLog,
        deviceAuth: DeviceAuth,
        client: MaraithonClient,
        queue: SyncQueue = SyncQueue(),
        backoff: Backoff = Backoff(),
        batchSize: Int = 200
    ) {
        self.eventLog = eventLog
        self.deviceAuth = deviceAuth
        self.client = client
        self.queue = queue
        self.backoff = backoff
        self.batchSize = batchSize
        eventLog.debug("sync_engine.init", source: .sync)
    }

    /// Back-compat init matching the existing stub. Wires up a default
    /// `MaraithonClient` that pulls the bearer from the supplied
    /// `DeviceAuth`. Kept identical to what `AppEnvironment` calls.
    convenience init(eventLog: EventLog, deviceAuth: DeviceAuth) {
        // Snapshot a closure that hops to the main actor to read the token.
        let tokenProvider: MaraithonClient.TokenProvider = { [weak deviceAuth] in
            await MainActor.run { [deviceAuth] in deviceAuth?.currentToken }
        }
        let client = MaraithonClient(tokenProvider: tokenProvider)
        self.init(
            eventLog: eventLog,
            deviceAuth: deviceAuth,
            client: client
        )
    }

    // MARK: - Public API

    /// Push a batch directly without going through the persistent queue.
    /// Sources call this when they want a synchronous "did the cloud
    /// take it?" answer (e.g. backfill paging). Anything that should
    /// survive a restart should go through `enqueue` instead.
    @discardableResult
    func push(_ batch: [SyncEnvelope], source: String = "imessage") async throws -> SyncOutcome {
        guard !batch.isEmpty else {
            return SyncOutcome(accepted: 0, duplicate: 0)
        }
        health = .syncing
        eventLog.debug(
            "sync_engine.push",
            source: .sync,
            payload: ["count": String(batch.count), "source": source]
        )

        do {
            let outcome = try await pushWithRetry(batch: batch, source: source)
            consecutiveFailures = 0
            lastSuccessAt = Date()
            health = .idle
            eventLog.info(
                "sync_engine.push_ok",
                source: .sync,
                payload: [
                    "count": String(batch.count),
                    "accepted": String(outcome.accepted),
                    "duplicate": String(outcome.duplicate)
                ]
            )
            return outcome
        } catch {
            consecutiveFailures += 1
            eventLog.error(
                "sync_engine.push_failed",
                source: .sync,
                payload: [
                    "count": String(batch.count),
                    "error": String(describing: error),
                    "consecutive_failures": String(consecutiveFailures)
                ]
            )
            if consecutiveFailures >= 3 {
                health = .needsAttention(reason: "Connection issue")
            }
            throw error
        }
    }

    /// Append envelopes to the durable queue. They will be drained on the
    /// next `drain` call.
    func enqueue(_ envelopes: [SyncEnvelope]) async throws {
        try await queue.enqueue(envelopes)
        eventLog.debug(
            "sync_engine.enqueued",
            source: .sync,
            payload: ["count": String(envelopes.count)]
        )
    }

    /// Drain the persistent queue in batches of `batchSize` until empty.
    /// Returns aggregate counts across all batches.
    @discardableResult
    func drain(source: String = "imessage") async throws -> SyncOutcome {
        var aggregate = SyncOutcome(accepted: 0, duplicate: 0)
        while true {
            let next = try await queue.peek(limit: batchSize)
            if next.isEmpty { break }
            let outcome = try await push(next, source: source)
            try await queue.acknowledge(count: next.count)
            aggregate = SyncOutcome(
                accepted: aggregate.accepted + outcome.accepted,
                duplicate: aggregate.duplicate + outcome.duplicate,
                invalid: aggregate.invalid + outcome.invalid
            )
        }
        return aggregate
    }

    // MARK: - Retry loop

    /// Push a single batch, with exponential backoff on transient
    /// failures. Non-retriable errors (401, 4xx, decode failures)
    /// propagate immediately so the caller can surface the right state.
    private func pushWithRetry(batch: [SyncEnvelope], source: String) async throws -> SyncOutcome {
        let envelope = IngestBatch(
            deviceId: deviceAuth.deviceId,
            source: source,
            messages: batch
        )
        var attempt = 0
        while true {
            do {
                return try await client.ingest(batch: envelope)
            } catch let err as MaraithonClientError where err.isRetriable {
                attempt += 1
                let delay = backoff.delay(for: attempt)
                eventLog.warning(
                    "sync_engine.retry",
                    source: .sync,
                    payload: [
                        "attempt": String(attempt),
                        "delay_ms": String(Int(delay * 1000)),
                        "error": String(describing: err)
                    ]
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if attempt >= backoff.maxAttempts {
                    throw err
                }
            } catch {
                throw error
            }
        }
    }
}

/// Exponential backoff with jitter, capped at 5 minutes. Default schedule:
/// 1s, 2s, 4s, 8s, 16s, 32s, 64s, 128s, 256s, 300s, 300s … with up to
/// 20% jitter on each delay so concurrent clients don't synchronize.
struct Backoff: Sendable {
    let initial: TimeInterval
    let multiplier: Double
    let cap: TimeInterval
    let maxAttempts: Int
    let jitter: Double
    let randomSource: @Sendable () -> Double

    init(
        initial: TimeInterval = 1,
        multiplier: Double = 2,
        cap: TimeInterval = 300,
        maxAttempts: Int = 10,
        jitter: Double = 0.2,
        randomSource: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.initial = initial
        self.multiplier = multiplier
        self.cap = cap
        self.maxAttempts = maxAttempts
        self.jitter = jitter
        self.randomSource = randomSource
    }

    func delay(for attempt: Int) -> TimeInterval {
        guard attempt >= 1 else { return 0 }
        let raw = initial * pow(multiplier, Double(attempt - 1))
        let bounded = min(raw, cap)
        let jitterRange = bounded * jitter
        let offset = (randomSource() * 2 - 1) * jitterRange
        return max(0, bounded + offset)
    }
}

// MARK: - Wire types preserved for source code

/// Per-batch payload as accepted by the server. Sources prepare these and
/// hand them to the engine; the engine never inspects the body beyond
/// counting it.
struct SyncEnvelope: Codable, Sendable, Equatable {
    let source: String
    let localId: String
    let guid: String
    let payload: [String: AnyCodable]
}

struct SyncOutcome: Codable, Sendable, Equatable {
    let accepted: Int
    let duplicate: Int
    let invalid: Int

    init(accepted: Int, duplicate: Int, invalid: Int = 0) {
        self.accepted = accepted
        self.duplicate = duplicate
        self.invalid = invalid
    }
}

/// Minimal type-erasing codable for the envelope's `payload` dictionary.
/// Replace with a server-shaped struct once the contract stabilises.
struct AnyCodable: Codable, Sendable, Equatable {
    let value: any Sendable

    init(_ value: any Sendable) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let v = try? container.decode(String.self) {
            value = v
        } else if let v = try? container.decode(Int.self) {
            value = v
        } else if let v = try? container.decode(Double.self) {
            value = v
        } else if let v = try? container.decode(Bool.self) {
            value = v
        } else {
            value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let v as String: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as Bool: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l as String, r as String): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as Bool, r as Bool): return l == r
        default: return false
        }
    }
}
