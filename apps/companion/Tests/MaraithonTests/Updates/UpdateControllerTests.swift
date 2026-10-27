import XCTest
@testable import Maraithon

/// Tests exercise the value-only surface of `UpdateController`. We don't
/// reach into Sparkle's installer path — that's covered by Sparkle's own
/// suite — but we do verify that:
/// - construction emits a startup log,
/// - `automaticallyChecksForUpdates` round-trips and only logs on change,
/// - the SwiftPM (no-Sparkle) build path no-ops cleanly,
/// - `checkForUpdates()` in a no-Sparkle build emits a warning instead of
///   crashing.
///
/// `swift test` runs without Sparkle linked, so `isSparkleEnabled` is
/// `false` on this path. Under `xcodebuild test` the same assertions hold
/// because the controller is instantiated but no real check fires —
/// `canCheckForUpdates` reflects Sparkle's own readiness flag.
final class UpdateControllerTests: XCTestCase {
    @MainActor
    func testInitEmitsStartupLog() {
        let log = EventLog(capacity: 16)
        _ = UpdateController(eventLog: log)
        let starts = log.entries.filter {
            $0.message == "updates.controller_started" || $0.message == "updates.controller_disabled"
        }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.source, .system)
    }

    @MainActor
    func testAutomaticallyChecksToggleLogsOnlyOnChange() {
        let log = EventLog(capacity: 32)
        let controller = UpdateController(eventLog: log)

        let initial = controller.automaticallyChecksForUpdates
        controller.automaticallyChecksForUpdates = initial // no-op
        let changedAfterSameValue = log.entries
            .filter { $0.message == "updates.auto_check.changed" }
            .count
        XCTAssertEqual(
            changedAfterSameValue, 0,
            "Setting the same value should not emit a change log"
        )

        controller.automaticallyChecksForUpdates = !initial
        XCTAssertEqual(controller.automaticallyChecksForUpdates, !initial)
        let changedAfterFlip = log.entries
            .filter { $0.message == "updates.auto_check.changed" }
            .count
        XCTAssertEqual(changedAfterFlip, 1)
    }

    @MainActor
    func testCheckForUpdatesIsSafeOnSwiftPMBuild() {
        let log = EventLog(capacity: 16)
        let controller = UpdateController(eventLog: log)
        controller.checkForUpdates()
        // Either Sparkle is present (the real `updater.checkForUpdates()`
        // fires asynchronously and we log a `check_started`) or it isn't
        // (we log a `check_skipped` warning). Both are acceptable.
        let logged = log.entries.map(\.message)
        XCTAssertTrue(
            logged.contains("updates.check_started")
                || logged.contains("updates.check_skipped"),
            "Expected either a check_started or check_skipped log entry; got \(logged)"
        )
    }

    @MainActor
    func testLastUpdateCheckDateExposed() {
        let controller = UpdateController(eventLog: nil)
        // We don't assert a specific value — Sparkle may or may not have
        // run before — only that the property is reachable as `Date?`.
        let _: Date? = controller.lastUpdateCheckDate
        _ = controller.isChecking
        _ = controller.canCheckForUpdates
        _ = controller.isSparkleEnabled
    }
}
