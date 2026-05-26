import XCTest
@testable import Maraithon

/// Verifies the per-source "Surface in Mac Spotlight" toggle store
/// rounds through `UserDefaults` and honours the privacy defaults
/// table in the v6 brief.
@MainActor
final class SpotlightTogglesStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.maraithon.spotlight-toggle-tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultEnabledFollowsPrivacyTable() {
        XCTAssertTrue(SpotlightTogglesStore.defaultEnabled(forSource: "notes"))
        XCTAssertTrue(SpotlightTogglesStore.defaultEnabled(forSource: "voice_memos"))
        XCTAssertTrue(SpotlightTogglesStore.defaultEnabled(forSource: "reminders"))
        XCTAssertTrue(SpotlightTogglesStore.defaultEnabled(forSource: "calendar"))
        XCTAssertTrue(SpotlightTogglesStore.defaultEnabled(forSource: "files"))
        XCTAssertFalse(SpotlightTogglesStore.defaultEnabled(forSource: "imessage"))
        XCTAssertFalse(SpotlightTogglesStore.defaultEnabled(forSource: "browser_history"))
        // Unknown sources fail closed.
        XCTAssertFalse(SpotlightTogglesStore.defaultEnabled(forSource: "future_source"))
    }

    func testToggleRoundTripsThroughUserDefaults() {
        let store = SpotlightTogglesStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled(source: "notes"))
        store.setEnabled(false, source: "notes")
        XCTAssertFalse(store.isEnabled(source: "notes"))

        XCTAssertFalse(store.isEnabled(source: "imessage"))
        store.setEnabled(true, source: "imessage")
        XCTAssertTrue(store.isEnabled(source: "imessage"))
    }

    func testResetReturnsToDefaults() {
        let store = SpotlightTogglesStore(defaults: defaults)
        store.setEnabled(false, source: "notes")
        store.setEnabled(true, source: "imessage")
        XCTAssertFalse(store.isEnabled(source: "notes"))
        XCTAssertTrue(store.isEnabled(source: "imessage"))
        store.reset()
        XCTAssertTrue(store.isEnabled(source: "notes"))
        XCTAssertFalse(store.isEnabled(source: "imessage"))
    }

    /// The integration shape the ingest hook uses: ask the store
    /// whether to emit a `CSSearchableItem` at all. When the toggle is
    /// off, we filter the batch to empty before handing it to the
    /// indexer.
    func testFilteringSkipsDisabledSources() {
        let store = SpotlightTogglesStore(defaults: defaults)
        store.setEnabled(false, source: "files")

        let sources = ["notes", "files", "calendar", "imessage"]
        let enabled = sources.filter { store.isEnabled(source: $0) }
        // notes + calendar are default-on, files was just turned off,
        // imessage is default-off.
        XCTAssertEqual(Set(enabled), Set(["notes", "calendar"]))
    }
}
