import AsyncAlgorithms
import Foundation
import Observation

/// `SourceProtocol` implementation for browser history (Chrome, Safari,
/// Arc, Brave). Fans out per cycle to every browser that has a database
/// on disk; the unified status publisher reports the worst state across
/// the lot so the sidebar row stays a single-line summary.
///
/// Polling cadence: 5 minutes baseline, stretched 4× on Low Power Mode.
/// Browser history doesn't change as often as iMessage and we're reading
/// SQLite snapshots, so a longer cadence keeps churn low.
@MainActor
final class BrowserHistorySource: SourceProtocol {
    let id: String = "browser_history"
    let displayName: String = "Browser History"
    let symbol: String = "safari"
    let statusPublisher: SourceStatusPublisher

    /// Factory that builds a reader for a given browser. Returns `nil`
    /// when the browser is not installed on this machine. Injected so
    /// tests can hand in fixture readers without touching the user's
    /// real history files.
    typealias ReaderFactory = @Sendable (Browser) -> (any BrowserHistoryReader)?

    private let cursor: BrowserHistoryCursor
    private let eventLog: EventLog
    private let ingest: BrowserHistoryIngest
    private let deviceIdProvider: @MainActor @Sendable () -> UUID
    private let readerFactory: ReaderFactory
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    private let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?

    init(
        cursor: BrowserHistoryCursor = BrowserHistoryCursor(),
        eventLog: EventLog,
        ingest: BrowserHistoryIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        readerFactory: @escaping ReaderFactory = BrowserHistorySource.defaultReaderFactory,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 300,
        lowPowerProbe: @escaping @Sendable () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    ) {
        self.cursor = cursor
        self.eventLog = eventLog
        self.ingest = ingest
        self.deviceIdProvider = deviceIdProvider
        self.readerFactory = readerFactory
        self.pollInterval = pollInterval
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 1_800)
        self.batchLimit = batchLimit
        self.lowPowerProbe = lowPowerProbe
        self.statusPublisher = SourceStatusPublisher(sourceID: "browser_history", state: .disconnected)
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("browser_history.start", source: .browser)
        pollTask = Task { [weak self] in
            await self?.pollLoop()
        }
    }

    func pause() {
        guard !isPaused else { return }
        isPaused = true
        pollTask?.cancel()
        pollTask = nil
        statusPublisher.update(state: .paused)
        eventLog.info("browser_history.pause", source: .browser)
    }

    func syncNow() async throws {
        eventLog.info("browser_history.sync_now", source: .browser)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("browser_history.clear_local_state", source: .browser)
    }

    // MARK: - Polling

    private func pollLoop() async {
        let timer = AsyncTimerSequence(
            interval: .seconds(pollInterval),
            clock: .continuous
        )
        await tickIfNeeded(force: true)
        for await _ in timer {
            if Task.isCancelled || isPaused { break }
            await tickIfNeeded(force: false)
        }
    }

    private func tickIfNeeded(force: Bool) async {
        let lowPower = lowPowerProbe()
        if lowPower != lastLowPowerState {
            lastLowPowerState = lowPower
            eventLog.info(
                "browser_history.cadence_changed",
                source: .browser,
                payload: [
                    "low_power": String(lowPower),
                    "interval_seconds": String(
                        Int(lowPower ? lowPowerPollInterval : pollInterval)
                    )
                ]
            )
        }
        if !force, lowPower, let last = lastTickAt {
            let elapsed = ContinuousClock().now - last
            if elapsed < .seconds(lowPowerPollInterval) { return }
        }
        lastTickAt = ContinuousClock().now
        do {
            try await runCycle()
        } catch {
            statusPublisher.update(
                state: .error(reason: String(describing: error))
            )
            eventLog.error(
                "browser_history.cycle_failed",
                source: .browser,
                payload: ["error": String(describing: error)]
            )
        }
    }

    /// One sync cycle: walk every installed browser, read everything
    /// beyond its cursor, post, advance only on success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)

        var totalAccepted = 0
        var totalDuplicate = 0
        var totalFiltered = 0
        var ranAny = false

        for browser in Browser.allCases {
            guard let reader = readerFactory(browser) else {
                // Browser not installed — skip silently.
                continue
            }
            ranAny = true
            let startID = cursor.lastSyncedID(for: browser)
            let batchLimit = self.batchLimit

            let rows: [BrowserVisitRecord]
            do {
                rows = try await Task.detached(priority: .utility) {
                    try reader.visits(after: startID, limit: batchLimit)
                }.value
            } catch {
                eventLog.error(
                    "browser_history.read_failed",
                    source: .browser,
                    payload: [
                        "browser": browser.rawValue,
                        "error": String(describing: error)
                    ]
                )
                continue
            }

            if rows.isEmpty {
                eventLog.debug(
                    "browser_history.cycle_empty",
                    source: .browser,
                    payload: [
                        "browser": browser.rawValue,
                        "since_id": String(startID)
                    ]
                )
                continue
            }

            let deviceId = deviceIdProvider()
            let batch = BrowserHistoryIngestBatch(
                deviceId: deviceId,
                source: "browser_history",
                visits: rows
            )

            let outcome: BrowserHistoryIngestOutcome
            do {
                outcome = try await ingest.ingestVisits(batch: batch)
            } catch {
                eventLog.error(
                    "browser_history.push_failed",
                    source: .browser,
                    payload: [
                        "browser": browser.rawValue,
                        "error": String(describing: error)
                    ]
                )
                continue
            }

            // Advance the cursor based on the maximum native id we just
            // tried to push. Even rows the server filtered out (private
            // hosts) are "done" from the source's perspective — we
            // don't want to re-read them next cycle.
            if let maxID = rows.compactMap({ Int64($0.localId) }).max() {
                cursor.advance(browser, to: maxID)
            }

            totalAccepted += outcome.accepted
            totalDuplicate += outcome.duplicate
            totalFiltered += outcome.filtered

            eventLog.info(
                "browser_history.cycle_pushed",
                source: .browser,
                payload: [
                    "browser": browser.rawValue,
                    "count": String(rows.count),
                    "accepted": String(outcome.accepted),
                    "duplicate": String(outcome.duplicate),
                    "filtered": String(outcome.filtered),
                    "cursor": String(cursor.lastSyncedID(for: browser))
                ]
            )
        }

        if !ranAny {
            statusPublisher.update(state: .disconnected)
            eventLog.debug(
                "browser_history.no_browsers_installed",
                source: .browser
            )
            return
        }

        statusPublisher.recordSync(
            at: Date(),
            accepted: totalAccepted,
            duplicate: totalDuplicate
        )
        statusPublisher.update(state: .connected)
    }

    // MARK: - Reader factory

    /// Default factory: returns a reader for every browser whose
    /// `liveDatabaseURL` resolves on the current machine. Throwing
    /// initializers degrade to nil so a corrupt or locked database for
    /// one browser doesn't block the others.
    nonisolated static let defaultReaderFactory: ReaderFactory = { browser in
        guard let liveURL = browser.liveDatabaseURL else { return nil }
        do {
            switch browser {
            case .chrome, .arc, .brave:
                return try ChromiumHistoryReader(browser: browser, liveURL: liveURL)
            case .safari:
                return try SafariHistoryReader(liveURL: liveURL)
            }
        } catch {
            return nil
        }
    }
}
