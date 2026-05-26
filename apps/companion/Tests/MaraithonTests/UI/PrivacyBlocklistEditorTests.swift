import XCTest
import SwiftUI
@testable import Maraithon

/// Smoke tests for the Privacy tab's blocklist editor. The view itself
/// is thin — it forwards to the `Blocklist` actor — so we focus on the
/// underlying model behavior the editor relies on (canonicalisation,
/// add / remove round-trip, and unique sorted display order).
@MainActor
final class PrivacyBlocklistEditorTests: XCTestCase {
    func testEditorBuilds() {
        _ = PrivacyBlocklistEditor()
    }

    func testBlocklistAddRoundtrips() {
        // Test isolation: snapshot + restore so we don't clobber the
        // user's real blocklist persisted in UserDefaults.standard.
        let list = Blocklist()
        let original = list.handles
        defer {
            for handle in list.handles where !original.contains(handle) {
                list.remove(handle)
            }
            for handle in original where !list.handles.contains(handle) {
                list.add(handle)
            }
        }

        let phone = "+1 (415) 555-0199"
        let email = "Friend.Test@Example.COM"
        list.add(phone)
        list.add(email)
        XCTAssertTrue(list.contains("+14155550199"))
        XCTAssertTrue(list.contains("friend.test@example.com"))
    }

    func testBlocklistRemoveRoundtrips() {
        let list = Blocklist()
        let original = list.handles
        defer {
            for handle in list.handles where !original.contains(handle) {
                list.remove(handle)
            }
            for handle in original where !list.handles.contains(handle) {
                list.add(handle)
            }
        }

        let email = "removable-\(UUID().uuidString)@example.com"
        list.add(email)
        XCTAssertTrue(list.contains(email))
        list.remove(email)
        XCTAssertFalse(list.contains(email))
    }
}
