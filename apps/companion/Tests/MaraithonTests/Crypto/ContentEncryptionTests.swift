import XCTest
@testable import Maraithon

final class ContentEncryptionTests: XCTestCase {
    func testRoundTripUTF8String() throws {
        let key = DeviceKey.generate()
        let crypto = ContentEncryption(deviceKey: key)
        let plaintext = "Coffee tomorrow?"
        let sealed = try crypto.encrypt(plaintext)
        let recovered = try crypto.decrypt(sealed)
        XCTAssertEqual(recovered, plaintext)
    }

    func testEncryptionIsNonDeterministic() throws {
        let key = DeviceKey.generate()
        let crypto = ContentEncryption(deviceKey: key)
        let a = try crypto.encrypt("same plaintext")
        let b = try crypto.encrypt("same plaintext")
        // Per-record salt + nonce should make the ciphertext distinct.
        XCTAssertNotEqual(a.base64, b.base64)
        // ... but both decrypt back to the same value.
        XCTAssertEqual(try crypto.decrypt(a), "same plaintext")
        XCTAssertEqual(try crypto.decrypt(b), "same plaintext")
    }

    func testDecryptWithWrongKeyFails() throws {
        let aKey = DeviceKey.generate()
        let bKey = DeviceKey.generate()
        let a = ContentEncryption(deviceKey: aKey)
        let b = ContentEncryption(deviceKey: bKey)

        let sealed = try a.encrypt("secret")
        XCTAssertThrowsError(try b.decrypt(sealed)) { error in
            XCTAssertEqual(error as? ContentEncryptionError, .decryptionFailed)
        }
    }

    func testDecryptOnMalformedBlobThrows() throws {
        let crypto = ContentEncryption(deviceKey: DeviceKey.generate())
        let bogus = EncryptedBlob(base64: "not-base64!!")
        XCTAssertThrowsError(try crypto.decrypt(bogus))
    }

    func testEnvelopeStartsWithSalt() throws {
        let crypto = ContentEncryption(deviceKey: DeviceKey.generate())
        let sealed = try crypto.encrypt("hi")
        let raw = Data(base64Encoded: sealed.base64)!
        XCTAssertGreaterThan(raw.count, ContentEncryption.saltByteCount)
    }
}
