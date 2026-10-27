/// Calendar source lifecycle. Polls every three minutes; history advances only after upload.
import AsyncAlgorithms
import Foundation
import Observation

@MainActor
final class CalendarEventsSource: SourceProtocol {
    let id: String = "calendar"
    let displayName: String = "Calendar"
    let symbol: String = "calendar"
    let statusPublisher: SourceStatusPublisher

    /// Outbox closure — same shape as the other sources, so tests can
    /// capture payloads without going through HTTP.
    typealias Outbox = @Sendable (UUID, [CalendarEventPayload]) async throws -> SyncOutcome

    /// Days of past events to mirror. A full year so "what did I do
    /// last quarter?" works and — since edits are only observed while
    /// an event is inside the fetch window — reschedules or renames of
    /// months-old events still propagate instead of leaving the server
    /// copy stale. A busy corporate calendar is still only a few
    /// thousand rows per year, and the cursor diff keeps re-pushes to
    /// actual changes.
    static let defaultLookbackDays: TimeInterval = 365

    /// Days of upcoming events to mirror. A full year covers annual
    /// recurrences (birthdays, renewals, yearly planning) that a
    /// six-month horizon silently dropped until they drifted close.
    static let defaultLookaheadDays: TimeInterval = 365

    let cursor: CalendarCursor
    let eventLog: EventLog
    let outbox: Outbox
    var availabilityOutbox: (@Sendable (UUID, CalendarAvailabilityPayload) async throws -> SyncOutcome)?
    let deviceIdProvider: @MainActor @Sendable () -> UUID
    let reader: CalendarEventReader
    private let pollInterval: TimeInterval
    private let lowPowerPollInterval: TimeInterval
    let batchLimit: Int
    private let lowPowerProbe: @Sendable () -> Bool
    let lookbackDays: TimeInterval
    let lookaheadDays: TimeInterval
    let clock: @Sendable () -> Date

    private var pollTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var lastLowPowerState: Bool = false
    private var lastTickAt: ContinuousClock.Instant?
    var didRequestAccess: Bool = false

    init(
        reader: CalendarEventReader = CalendarEventReader(),
        cursor: CalendarCursor = CalendarCursor(),
        eventLog: EventLog,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lookbackDays: TimeInterval = CalendarEventsSource.defaultLookbackDays,
        lookaheadDays: TimeInterval = CalendarEventsSource.defaultLookaheadDays,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        },
        clock: @escaping @Sendable () -> Date = { Date() },
        outbox: @escaping Outbox
    ) {
        self.reader = reader
        self.cursor = cursor
        self.eventLog = eventLog
        self.outbox = outbox
        self.deviceIdProvider = deviceIdProvider
        self.pollInterval = pollInterval
        // 4× base cadence under Low Power Mode, capped at 30 minutes.
        self.lowPowerPollInterval = lowPowerPollInterval ?? min(pollInterval * 4, 1800)
        self.batchLimit = batchLimit
        self.lookbackDays = lookbackDays
        self.lookaheadDays = lookaheadDays
        self.lowPowerProbe = lowPowerProbe
        self.clock = clock
        self.statusPublisher = SourceStatusPublisher(sourceID: "calendar", state: .disconnected)
    }

    /// Convenience init wiring the outbox to a `CalendarIngest`. The
    /// designated init stays available for tests that want to capture
    /// payloads directly.
    convenience init(
        reader: CalendarEventReader = CalendarEventReader(),
        cursor: CalendarCursor = CalendarCursor(),
        eventLog: EventLog,
        ingest: CalendarIngest,
        deviceIdProvider: @escaping @MainActor @Sendable () -> UUID,
        pollInterval: TimeInterval = 180,
        lowPowerPollInterval: TimeInterval? = nil,
        batchLimit: Int = 200,
        lookbackDays: TimeInterval = CalendarEventsSource.defaultLookbackDays,
        lookaheadDays: TimeInterval = CalendarEventsSource.defaultLookaheadDays,
        lowPowerProbe: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.init(
            reader: reader,
            cursor: cursor,
            eventLog: eventLog,
            deviceIdProvider: deviceIdProvider,
            pollInterval: pollInterval,
            lowPowerPollInterval: lowPowerPollInterval,
            batchLimit: batchLimit,
            lookbackDays: lookbackDays,
            lookaheadDays: lookaheadDays,
            lowPowerProbe: lowPowerProbe,
            outbox: { deviceId, events in
                try await ingest.push(deviceId: deviceId, events: events)
            }
        )
        availabilityOutbox = { deviceID, snapshot in
            try await ingest.pushAvailability(deviceId: deviceID, snapshot: snapshot)
        }
    }

    // MARK: - SourceProtocol

    func start() {
        guard pollTask == nil else { return }
        isPaused = false
        statusPublisher.update(state: .connected)
        eventLog.info("calendar.start", source: .calendar)
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
        eventLog.info("calendar.pause", source: .calendar)
    }

    func syncNow() async throws {
        eventLog.info("calendar.sync_now", source: .calendar)
        try await runCycle()
    }

    func clearLocalState() {
        cursor.reset()
        statusPublisher.update(state: .disconnected)
        eventLog.info("calendar.clear_local_state", source: .calendar)
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
                "calendar.cadence_changed",
                source: .calendar,
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
                "calendar.cycle_failed",
                source: .calendar,
                payload: ["error": String(describing: error)]
            )
        }
    }

}
