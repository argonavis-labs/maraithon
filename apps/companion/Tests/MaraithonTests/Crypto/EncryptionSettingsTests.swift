import XCTest
@testable import Maraithon

final class EncryptionSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.maraithon.companion.tests.encryption"

    override func setUpWithError() throws {
        // Use a fresh suite so each test starts clean and tests don't
        // contaminate the user's real preferences.
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsToOffForEverySource() {
        let settings = EncryptionSettings(defaults: defaults)
        for source in EncryptableSource.allCases {
            XCTAssertFalse(settings.isEnabled(for: source), "expected default off for \(source)")
        }
        XCTAssertFalse(settings.isAnyEnabled)
    }

    func testSetAndReadEachSource() {
        let settings = EncryptionSettings(defaults: defaults)
        settings.set(true, for: .notes)
        XCTAssertTrue(settings.isEnabled(for: .notes))
        XCTAssertFalse(settings.isEnabled(for: .files))
        XCTAssertTrue(settings.isAnyEnabled)

        settings.set(false, for: .notes)
        XCTAssertFalse(settings.isEnabled(for: .notes))
        XCTAssertFalse(settings.isAnyEnabled)
    }

    func testDefaultsKeyIsStable() {
        // Locked-in keys: ingest helpers and tests rely on these
        // strings, so the suite catches accidental renames.
        XCTAssertEqual(
            EncryptionSettings.defaultsKey(for: .notes),
            "com.maraithon.companion.encryption.notes.enabled"
        )
        XCTAssertEqual(
            EncryptionSettings.defaultsKey(for: .messages),
            "com.maraithon.companion.encryption.imessage.enabled"
        )
    }

    func testEncryptableSourceCoversTheUserContentSurface() {
        let names = Set(EncryptableSource.allCases.map(\.rawValue))
        XCTAssertEqual(
            names,
            ["notes", "voice_memos", "imessage", "calendar", "reminders", "files"]
        )
    }
}
