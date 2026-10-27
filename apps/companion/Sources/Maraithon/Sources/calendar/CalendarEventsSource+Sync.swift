/// Calendar synchronization keeps full availability separate from incremental history.
import Foundation

extension CalendarEventsSource {
    /// Single sync cycle: fetch the sliding window, diff against the
    /// cursor, batch-push, advance the cursor only on POST success.
    func runCycle() async throws {
        statusPublisher.update(state: .syncing)

        // Authorization gate. EventKit's `.notDetermined` state is the
        // one we explicitly prompt for; everything else is a terminal
        // user choice we surface to the UI without retrying.
        let auth = reader.authorizationState()
        switch auth {
        case .authorized:
            break
        case .notDetermined:
            if !didRequestAccess {
                didRequestAccess = true
                do {
                    let granted = try await reader.requestAccess()
                    eventLog.info(
                        "calendar.access_request",
                        source: .calendar,
                        payload: ["granted": String(granted)]
                    )
                } catch {
                    eventLog.error(
                        "calendar.access_request_failed",
                        source: .calendar,
                        payload: ["error": String(describing: error)]
                    )
                }
            }
            if reader.authorizationState() != .authorized {
                statusPublisher.update(
                    state: .needsAttention(reason: "calendar_not_authorized")
                )
                return
            }
        default:
            statusPublisher.update(
                state: .needsAttention(reason: "calendar_not_authorized")
            )
            eventLog.warning(
                "calendar.not_authorized",
                source: .calendar,
                payload: ["state": String(describing: auth)]
            )
            return
        }

        let now = clock()
        let start = now.addingTimeInterval(-lookbackDays * 86_400)
        let end = now.addingTimeInterval(lookaheadDays * 86_400)

        let window = try await reader.fetchWindow(start: start, end: end)
        try Task.checkCancellation()
        let snapshots = window.events
        if let availabilityOutbox,
           let snapshot = CalendarAvailabilityPayload(
               window: window, from: now.addingTimeInterval(-86_400),
               until: now.addingTimeInterval(45 * 86_400)
           ) {
            do {
                _ = try await availabilityOutbox(deviceIdProvider(), snapshot)
            } catch {
                // A stale or unavailable snapshot makes scheduling use Google.
                // Keep the independent history cursor and its sync working.
                eventLog.warning("calendar.availability_upload_failed", source: .calendar,
                                 payload: snapshot.failureMetadata(error))
            }
        }

        // Diff against the cursor: only re-push rows whose
        // lastModifiedDate is strictly newer than the persisted one.
        // Events without a modifiedAt push only on their first sighting.
        let priorSnapshot = cursor.snapshot
        let candidates = snapshots.filter { snap in
            cursor.shouldPush(guid: snap.guid, modifiedAt: snap.modifiedAt, since: priorSnapshot)
        }
        // Newest-modified first so the most relevant events ship before
        // historical ones. Events without `modifiedAt` sort to the tail;
        // tie-break by guid for stable ordering.
        let sortedCandidates = candidates.sorted { lhs, rhs in
            switch (lhs.modifiedAt, rhs.modifiedAt) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.guid < rhs.guid
            }
        }
        if sortedCandidates.isEmpty {
            eventLog.debug(
                "calendar.cycle_empty",
                source: .calendar,
                payload: [
                    "scanned": String(snapshots.count),
                    "tracked": String(cursor.trackedCount)
                ]
            )
            statusPublisher.recordHealthyCycle(at: Date())
            statusPublisher.update(state: .connected)
            return
        }

        // Ship every candidate, chunked at `batchLimit` per POST, so a
        // burst larger than one batch drains within the cycle instead
        // of starving the oldest-modified tail. Advancing per chunk —
        // including nil-modification sightings at the sentinel — means
        // a failure mid-drain keeps earlier progress and the remainder
        // retries next cycle.
        let deviceId = deviceIdProvider()
        var pushResult = PushResult.empty
        var chunkStart = 0
        while chunkStart < sortedCandidates.count {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + batchLimit, sortedCandidates.count)
            let chunk = Array(sortedCandidates[chunkStart..<chunkEnd])
            chunkStart = chunkEnd
            let chunkResult = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: chunk
            )
            cursor.advance(chunkResult.processedSnapshots.map {
                (guid: $0.guid, modifiedAt: $0.modifiedAt)
            })
            pushResult.merge(chunkResult)
        }

        statusPublisher.recordSync(
            at: Date(),
            accepted: pushResult.outcome.accepted,
            duplicate: pushResult.outcome.duplicate
        )
        statusPublisher.update(state: .connected)

        let calendarCounts = sortedCandidates
            .compactMap(\.calendarName)
            .reduce(into: [String: Int]()) { acc, name in
                acc[name, default: 0] += 1
            }

        eventLog.info(
            "calendar.cycle_pushed",
            source: .calendar,
            payload: [
                "scanned": String(snapshots.count),
                "pushed": String(sortedCandidates.count),
                "accepted": String(pushResult.outcome.accepted),
                "duplicate": String(pushResult.outcome.duplicate),
                "invalid": String(pushResult.outcome.invalid),
                "tracked": String(cursor.trackedCount),
                "window_start": Self.isoString(from: start),
                "window_end": Self.isoString(from: end),
                "calendars": Self.calendarSummary(calendarCounts)
            ]
        )
    }

    private struct PushResult {
        var outcome: SyncOutcome
        var processedSnapshots: [CalendarEventReader.Snapshot]

        static var empty: PushResult {
            PushResult(
                outcome: SyncOutcome(accepted: 0, duplicate: 0),
                processedSnapshots: []
            )
        }

        mutating func merge(_ other: PushResult) {
            outcome = SyncOutcome(
                accepted: outcome.accepted + other.outcome.accepted,
                duplicate: outcome.duplicate + other.outcome.duplicate,
                invalid: outcome.invalid + other.outcome.invalid
            )
            processedSnapshots.append(contentsOf: other.processedSnapshots)
        }
    }

    private func pushWithInvalidBatchIsolation(
        deviceId: UUID,
        snapshots: [CalendarEventReader.Snapshot]
    ) async throws -> PushResult {
        guard !snapshots.isEmpty else { return .empty }

        do {
            let payloads = snapshots.map(Self.payload(from:))
            let outcome = try await outbox(deviceId, payloads)
            return PushResult(outcome: outcome, processedSnapshots: snapshots)
        } catch {
            guard Self.isInvalidBatchError(error) else { throw error }

            if snapshots.count == 1 {
                let snapshot = snapshots[0]
                eventLog.warning(
                    "calendar.event_skipped_invalid",
                    source: .calendar,
                    payload: [
                        "guid_prefix": Self.guidPrefix(snapshot.guid),
                        "modified_at": snapshot.modifiedAt.map(Self.isoString(from:)) ?? "<nil>",
                        "calendar": Self.redactedLogToken(snapshot.calendarName),
                        "reason": "invalid_batch"
                    ]
                )
                return PushResult(
                    outcome: SyncOutcome(accepted: 0, duplicate: 0, invalid: 1),
                    processedSnapshots: [snapshot]
                )
            }

            let midpoint = snapshots.count / 2
            var left = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: Array(snapshots[..<midpoint])
            )
            let right = try await pushWithInvalidBatchIsolation(
                deviceId: deviceId,
                snapshots: Array(snapshots[midpoint...])
            )
            left.merge(right)
            return left
        }
    }

    private nonisolated static func isInvalidBatchError(_ error: Error) -> Bool {
        guard let clientError = error as? MaraithonClientError else {
            return false
        }
        switch clientError {
        case let .clientError(status, body):
            return status == 400 && (body?.contains("invalid_batch") ?? false)
        default:
            return false
        }
    }

    // MARK: - Mapping

    /// Static mapping from reader snapshot to wire payload. Kept
    /// `nonisolated` so tests can call it without a live `EKEventStore`.
    nonisolated static func payload(
        from snapshot: CalendarEventReader.Snapshot
    ) -> CalendarEventPayload {
        CalendarEventPayload(
            guid: snapshot.guid,
            // `local_id` mirrors the other sources' "<prefix>:<id>"
            // shape. Reminders use `r:`; we use `cal:` here so a log
            // reader can tell calendar local IDs apart at a glance.
            localId: "cal:\(snapshot.masterIdentifier)",
            calendarName: snapshot.calendarName,
            calendarColor: snapshot.calendarColor,
            title: snapshot.title,
            notes: snapshot.notes,
            location: snapshot.location,
            startAt: snapshot.startAt,
            endAt: snapshot.endAt,
            isAllDay: snapshot.isAllDay,
            isRecurring: snapshot.isRecurring,
            organizerEmail: snapshot.organizerEmail,
            attendeesCount: snapshot.attendeesCount,
            attendeeEmails: snapshot.attendeeEmails,
            createdAt: snapshot.createdAt,
            modifiedAt: snapshot.modifiedAt,
            sourceState: snapshot.sourceState
        )
    }

    /// Compact "calendar_name: count" summary for log lines, sorted by
    /// count descending with redacted names so account emails don't leak
    /// into local diagnostics.
    private nonisolated static func calendarSummary(_ counts: [String: Int]) -> String {
        counts
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map { "\(Self.redactedLogToken($0.key))=\($0.value)" }
            .joined(separator: ",")
    }

    private nonisolated static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private nonisolated static func guidPrefix(_ guid: String) -> String {
        String(guid.prefix(16))
    }

    private nonisolated static func redactedLogToken(_ text: String?) -> String {
        CalendarRedactor.redact(text).replacingOccurrences(of: " ", with: "_")
    }
}
