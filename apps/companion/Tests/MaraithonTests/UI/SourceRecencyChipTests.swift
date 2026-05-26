import XCTest
@testable import Maraithon

/// Covers the abbreviation buckets the sidebar's recency chip uses:
/// `now` < 1m, `Nm` < 1h, `Nhr` < 1d, `Nd` < 1w, then `Nw`.
@MainActor
final class SourceRecencyChipTests: XCTestCase {
    func testUnderOneMinuteReadsAsNow() {
        XCTAssertEqual(SourceRecencyChip.format(interval: 0), "now")
        XCTAssertEqual(SourceRecencyChip.format(interval: 59), "now")
    }

    func testMinutesBucket() {
        XCTAssertEqual(SourceRecencyChip.format(interval: 60), "1m")
        XCTAssertEqual(SourceRecencyChip.format(interval: 5 * 60), "5m")
        XCTAssertEqual(SourceRecencyChip.format(interval: 59 * 60), "59m")
    }

    func testHoursBucket() {
        XCTAssertEqual(SourceRecencyChip.format(interval: 60 * 60), "1hr")
        XCTAssertEqual(SourceRecencyChip.format(interval: 23 * 60 * 60), "23hr")
    }

    func testDaysBucket() {
        XCTAssertEqual(SourceRecencyChip.format(interval: 24 * 60 * 60), "1d")
        XCTAssertEqual(SourceRecencyChip.format(interval: 6 * 24 * 60 * 60), "6d")
    }

    func testWeeksBucket() {
        XCTAssertEqual(SourceRecencyChip.format(interval: 7 * 24 * 60 * 60), "1w")
        XCTAssertEqual(SourceRecencyChip.format(interval: 4 * 7 * 24 * 60 * 60), "4w")
    }

    func testNegativeIntervalsClampToNow() {
        XCTAssertEqual(SourceRecencyChip.format(interval: -120), "now")
    }
}
