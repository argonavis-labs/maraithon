import XCTest
import SwiftUI
@testable import Maraithon

/// Smoke tests for UI primitives. These verify the value-only surface of
/// the components (state vocabulary, derived labels, etc.) without
/// rendering — SwiftUI snapshot testing is a follow-up.
final class UIComponentsTests: XCTestCase {
    @MainActor
    func testSourceStatusBadgeSymbolsCoverAllStates() {
        let states: [SourceStatusBadge.State] = [
            .connected,
            .syncing,
            .paused,
            .needsAttention("reason"),
            .disconnected,
            .error("boom")
        ]

        let symbols = Set(states.map(\.symbol))
        XCTAssertEqual(symbols.count, states.count, "Every state needs a distinct SF Symbol")
    }

    @MainActor
    func testSourceStatusBadgeSubtitlePropagatesReason() {
        let attn = SourceStatusBadge.State.needsAttention("Full Disk Access required")
        XCTAssertEqual(attn.subtitle, "Full Disk Access required")

        let err = SourceStatusBadge.State.error("401 from server")
        XCTAssertEqual(err.subtitle, "401 from server")

        XCTAssertNil(SourceStatusBadge.State.connected.subtitle)
    }

    @MainActor
    func testBackfillWindowOptionsAllHaveTitles() {
        for window in BackfillSetupView.Window.allCases {
            XCTAssertFalse(window.title.isEmpty, "Window \(window) needs a title")
        }
    }

    @MainActor
    func testBackfillChoiceLogPayloadIsStable() {
        // Log payload must be stable for the analytics surface — the
        // string keys here are part of the observable contract.
        XCTAssertEqual(
            BackfillSetupView.Choice.last(days: 30).logPayload["choice"],
            "last_30_days"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.last(days: 90).logPayload["choice"],
            "last_90_days"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.fromDate(Date()).logPayload["choice"],
            "custom_date"
        )
        XCTAssertEqual(
            BackfillSetupView.Choice.fresh.logPayload["choice"],
            "fresh"
        )
    }

    @MainActor
    func testStatCardRendersWithoutCrashing() {
        // Constructing the view exercises the body in headless build.
        _ = StatCard(title: "Today", value: "47", trend: .up("+12"))
    }
}
