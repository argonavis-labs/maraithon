import Foundation
import CryptoKit

/// Per-record symmetric content encryption layered on top of the
/// device's long-lived Curve25519 private key.
///
/// ## Why HKDF + a per-record salt
///
/// Using the device private key directly as the ChaChaPoly secret
/// would leak the same keystream across every record sealed under it
/// — a single nonce reuse would be catastrophic. Instead we run the
/// private key bytes through HKDF-SHA256 with a fresh 16-byte salt
/// per record, then use the derived 32-byte symmetric key with a
/// fresh ChaChaPoly nonce. The salt is recorded in the ciphertext
/// envelope so decryption is deterministic, but the derived key is
/// unique per record.
///
/// ## Envelope layout
///
/// Output bytes (base64-encoded for the wire) are:
///
///     [16 bytes salt][12 bytes nonce][N bytes ciphertext][16 bytes tag]
///
/// All produced by ChaChaPoly's `combined` representation prefixed
/// with the salt. The receiver splits the salt off, re-derives the
/// per-record symmetric key, and feeds the rest to ChaChaPoly.
///
/// `EncryptedBlob` exists as a typed wrapper so callers can't
/// accidentally double-encrypt (re-running `encrypt(plaintext:)` on
/// an `EncryptedBlob.base64` string would happily succeed and produce
/// undecryptable garbage on the server side).
struct EncryptedBlob: Hashable, Sendable {
    /// `base64(salt || nonce || ciphertext || tag)`. Ship as a String
    /// field in the existing wire shape — the server stores it
    /// verbatim in the Cloak-encrypted column.
    let base64: String
}

enum ContentEncryptionError: Error, Equatable {
    case derivationFailed
    case encryptionFailed
    case decryptionFailed
    case malformedBlob
    case unsupportedEncoding
}

/// Stateless helper: instances hold a `DeviceKey` and expose
/// `encrypt(_:)` / `decrypt(_:)`. The instance shape (rather than
/// free functions) is so tests + previews can swap in a fixed-key
/// instance and so the ingest helpers can hold a single resolved
/// crypto value rather than re-loading the keypair on every record.
struct ContentEncryption: Sendable {
    /// Info string mixed into HKDF so derived keys are bound to a
    /// purpose and can't be reused for an unrelated future scheme.
    static let hkdfInfo = Data("com.maraithon.companion.content-encryption".utf8)

    /// 16-byte per-record salt. Chosen because:
    ///   * 16 bytes > the 64-bit collision birthday bound (2^32),
    ///     which means we'd need to ship billions of records before
    ///     two records pick the same salt — practically impossible.
    ///   * Smaller than 32 because the wire savings matter at high
    ///     row counts (32 KB / 50k Notes records is meaningful).
    static let saltByteCount = 16

    let deviceKey: DeviceKey

    init(deviceKey: DeviceKey) {
        self.deviceKey = deviceKey
    }

    /// Encrypts `plaintext`. Returns an `EncryptedBlob` whose `base64`
    /// is the wire-ready opaque string. The same plaintext returns a
    /// different blob each call (per-record salt + nonce).
    func encrypt(_ plaintext: String) throws -> EncryptedBlob {
        guard let data = plaintext.data(using: .utf8) else {
            throw ContentEncryptionError.unsupportedEncoding
        }
        return try encrypt(plaintextData: data)
    }

    /// Same as `encrypt(_:)` but accepts raw bytes — used for fields
    /// that aren't UTF-8 strings (e.g. attachments).
    func encrypt(plaintextData data: Data) throws -> EncryptedBlob {
        let salt = randomSalt()
        let symmetricKey = try Self.deriveKey(
            privateKey: deviceKey.privateKey.rawRepresentation,
            salt: salt
        )
        do {
            let sealed = try ChaChaPoly.seal(data, using: symmetricKey)
            // `combined` is nonce || ciphertext || tag.
            var envelope = Data(capacity: salt.count + sealed.combined.count)
            envelope.append(salt)
            envelope.append(sealed.combined)
            return EncryptedBlob(base64: envelope.base64EncodedString())
        } catch {
            throw ContentEncryptionError.encryptionFailed
        }
    }

    /// Reverses `encrypt(_:)`. Useful for local round-trip tests and
    /// for a future "decrypt locally for display" path.
    func decrypt(_ blob: EncryptedBlob) throws -> String {
        let data = try decryptToData(blob)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ContentEncryptionError.unsupportedEncoding
        }
        return value
    }

    /// Decrypt to raw bytes (no UTF-8 assumption).
    func decryptToData(_ blob: EncryptedBlob) throws -> Data {
        guard let envelope = Data(base64Encoded: blob.base64) else {
            throw ContentEncryptionError.malformedBlob
        }
        guard envelope.count > Self.saltByteCount else {
            throw ContentEncryptionError.malformedBlob
        }
        let salt = envelope.prefix(Self.saltByteCount)
        let rest = envelope.suffix(from: Self.saltByteCount)
        let symmetricKey = try Self.deriveKey(
            privateKey: deviceKey.privateKey.rawRepresentation,
            salt: Data(salt)
        )
        do {
            let box = try ChaChaPoly.SealedBox(combined: Data(rest))
            return try ChaChaPoly.open(box, using: symmetricKey)
        } catch {
            throw ContentEncryptionError.decryptionFailed
        }
    }

    // MARK: - Internals

    private func randomSalt() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.saltByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // SecRandom should never fail in practice; falling back to
            // SystemRandomNumberGenerator keeps the API non-throwing.
            var generator = SystemRandomNumberGenerator()
            for i in 0..<bytes.count {
                bytes[i] = generator.next()
            }
        }
        return Data(bytes)
    }

    static func deriveKey(privateKey: Data, salt: Data) throws -> SymmetricKey {
        let ikm = SymmetricKey(data: privateKey)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )
    }
}
