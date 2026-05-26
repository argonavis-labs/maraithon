import XCTest
import CryptoKit
@testable import Maraithon

final class DeviceKeyTests: XCTestCase {
    func testGenerateProducesUniqueKeysWithDeterministicKeyId() throws {
        let a = DeviceKey.generate()
        let b = DeviceKey.generate()

        XCTAssertNotEqual(
            a.publicKey.rawRepresentation,
            b.publicKey.rawRepresentation
        )
        XCTAssertNotEqual(a.keyId, b.keyId)

        // keyId is deterministic from the public key
        XCTAssertEqual(a.keyId, DeviceKey.keyId(for: a.publicKey))
        // Short identifier: 16 hex chars
        XCTAssertEqual(a.keyId.count, 16)
    }

    func testInMemoryStoreLoadOrCreateIsIdempotent() throws {
        let store = InMemoryDeviceKeyStore()
        let first = try store.loadOrCreate()
        let second = try store.loadOrCreate()

        XCTAssertEqual(first.keyId, second.keyId)
        XCTAssertEqual(
            first.privateKey.rawRepresentation,
            second.privateKey.rawRepresentation
        )
    }

    func testInMemoryStoreDeleteAllAllowsRegeneration() throws {
        let store = InMemoryDeviceKeyStore()
        let first = try store.loadOrCreate()
        try store.deleteAll()
        XCTAssertNil(try store.load())

        let second = try store.loadOrCreate()
        XCTAssertNotEqual(first.keyId, second.keyId)
    }

    func testInMemoryStoreSeededValue() throws {
        let seed = DeviceKey.generate()
        let store = InMemoryDeviceKeyStore(initial: seed)
        let loaded = try store.loadOrCreate()
        XCTAssertEqual(loaded.keyId, seed.keyId)
    }

    func testPublicKeyBase64Roundtrips() throws {
        let key = DeviceKey.generate()
        let bytes = Data(base64Encoded: key.publicKeyBase64)
        XCTAssertEqual(bytes, key.publicKey.rawRepresentation)
    }
}
