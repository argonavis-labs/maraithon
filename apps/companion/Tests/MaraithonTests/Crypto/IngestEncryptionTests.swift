import XCTest
@testable import Maraithon

final class IngestEncryptionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.maraithon.companion.tests.ingest-encryption"

    override func setUpWithError() throws {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testResolveReturnsDisabledWhenToggleOff() {
        let settings = EncryptionSettings(defaults: defaults)
        let store = InMemoryDeviceKeyStore()

        let ingest = IngestEncryption.resolve(
            source: .notes,
            settings: settings,
            keyStore: store
        )

        XCTAssertFalse(ingest.isEnabled)
        XCTAssertNil(ingest.keyId)
        XCTAssertEqual(ingest.encryptField("hello"), "hello")
    }

    func testResolveProducesEncryptedFieldsWhenToggleOn() throws {
        let settings = EncryptionSettings(defaults: defaults)
        settings.set(true, for: .notes)
        let store = InMemoryDeviceKeyStore()

        let ingest = IngestEncryption.resolve(
            source: .notes,
            settings: settings,
            keyStore: store
        )

        XCTAssertTrue(ingest.isEnabled)
        XCTAssertNotNil(ingest.keyId)

        let plain = "Project Phoenix kickoff at 3pm"
        let encrypted = ingest.encryptField(plain)
        XCTAssertNotNil(encrypted)
        XCTAssertNotEqual(encrypted, plain)

        // Round-trip through ContentEncryption: the encrypted output
        // should decrypt cleanly with the same device key.
        let key = try store.loadOrCreate()
        let crypto = ContentEncryption(deviceKey: key)
        let recovered = try crypto.decrypt(EncryptedBlob(base64: encrypted!))
        XCTAssertEqual(recovered, plain)
    }

    func testEncryptFieldPassesThroughEmpty() {
        let settings = EncryptionSettings(defaults: defaults)
        settings.set(true, for: .notes)
        let ingest = IngestEncryption.resolve(
            source: .notes,
            settings: settings,
            keyStore: InMemoryDeviceKeyStore()
        )

        XCTAssertEqual(ingest.encryptField(""), "")
        XCTAssertNil(ingest.encryptField(nil))
    }

    func testEachSourceHasIndependentToggle() {
        let settings = EncryptionSettings(defaults: defaults)
        settings.set(true, for: .notes)
        let store = InMemoryDeviceKeyStore()

        let notes = IngestEncryption.resolve(source: .notes, settings: settings, keyStore: store)
        let files = IngestEncryption.resolve(source: .files, settings: settings, keyStore: store)

        XCTAssertTrue(notes.isEnabled)
        XCTAssertFalse(files.isEnabled)
    }
}
