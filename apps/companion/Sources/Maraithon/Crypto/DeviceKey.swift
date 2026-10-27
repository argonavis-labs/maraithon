import Foundation
import CryptoKit

/// Companion device crypto root for opt-in client-side encryption.
///
/// `DeviceKey` owns a single Curve25519 keypair persisted in the
/// system Keychain. The private half never leaves Keychain in the
/// happy path; the public half is published to the server so the
/// server can record which key id ciphertext was sealed under. Per-
/// record encryption keys are derived from the private key + a
/// per-record salt via HKDF-SHA256 (see `ContentEncryption`).
///
/// We deliberately use a long-lived asymmetric keypair rather than a
/// pure symmetric "secret derived from the pairing token" because:
///
///   * The pairing token is revocable / rotatable independently of
///     the user's content key. Re-pairing should NOT force a
///     re-encrypt of everything in the cloud.
///   * Publishing the public half gives the device a stable
///     identifier (`key_id`) it can show in the UI and the user can
///     compare against the server's view via
///     `DeviceKeyClient.fetchCurrent()`.
///   * Rotation is additive: a new keypair gets a new `key_id` and
///     ships, while existing ciphertext is still decryptable through
///     the matching old private key (kept in Keychain under the
///     `key_id`-suffixed account).
///
/// `keyId` is the SHA-256 hex digest of the public key, truncated to
/// 16 hex chars. That gives a stable, deterministic, short identifier
/// without leaking any private material.
struct DeviceKey: Sendable {
    /// Short identifier the server uses to look up the matching public
    /// key. SHA-256 hex (first 16 chars) of the public-key bytes.
    let keyId: String
    /// Raw 32-byte Curve25519 private key. Kept in Keychain; never
    /// shipped over the wire.
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    /// Raw 32-byte Curve25519 public key. Published to the server.
    let publicKey: Curve25519.KeyAgreement.PublicKey

    /// Base64-encoded public key suitable for the
    /// `POST /api/v1/companion/device-keys` body.
    var publicKeyBase64: String {
        publicKey.rawRepresentation.base64EncodedString()
    }

    /// Computes the deterministic `keyId` from a Curve25519 public key.
    static func keyId(for publicKey: Curve25519.KeyAgreement.PublicKey) -> String {
        let digest = SHA256.hash(data: publicKey.rawRepresentation)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Generates a fresh keypair.
    static func generate() -> DeviceKey {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let pub = priv.publicKey
        return DeviceKey(keyId: keyId(for: pub), privateKey: priv, publicKey: pub)
    }
}

/// Errors surfaced from `DeviceKeyStore`. Distinct from KeychainError
/// because the caller may need to retry on a transient Keychain miss
/// (e.g. boot-time race) without dropping the whole crypto subsystem.
enum DeviceKeyStoreError: Error, Equatable {
    case keychainFailed(OSStatus)
    case invalidKeyBytes
    case missing
}

/// Persists a `DeviceKey` to the Keychain under a fixed service +
/// account. Pluggable to keep tests off the system Keychain.
protocol DeviceKeyStore: Sendable {
    /// Returns the loaded key, generating + persisting a new one when
    /// none exists. Idempotent across calls — subsequent calls return
    /// the same key.
    func loadOrCreate() throws -> DeviceKey
    /// Reads the persisted key (raw 32-byte private). Returns nil when
    /// none has been persisted yet.
    func load() throws -> DeviceKey?
    /// Drops the persisted key. Subsequent `loadOrCreate` calls will
    /// generate a fresh one.
    func deleteAll() throws
}

/// Production Keychain-backed store. Single account
/// (`device_private_key`) under the same service used by the bearer
/// token, so the user sees one row per app in Keychain Access.
struct KeychainDeviceKeyStore: DeviceKeyStore {
    let service: String
    let account: String

    init(
        service: String = "com.maraithon.companion",
        account: String = "device_private_key"
    ) {
        self.service = service
        self.account = account
    }

    func loadOrCreate() throws -> DeviceKey {
        if let existing = try load() {
            return existing
        }
        let fresh = DeviceKey.generate()
        try store(privateKey: fresh.privateKey.rawRepresentation)
        return fresh
    }

    func load() throws -> DeviceKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw DeviceKeyStoreError.keychainFailed(status)
        }
        guard let data = result as? Data else {
            throw DeviceKeyStoreError.invalidKeyBytes
        }
        return try decode(data)
    }

    func deleteAll() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw DeviceKeyStoreError.keychainFailed(status)
        }
    }

    private func store(privateKey data: Data) throws {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw DeviceKeyStoreError.keychainFailed(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw DeviceKeyStoreError.keychainFailed(addStatus)
        }
    }

    private func decode(_ data: Data) throws -> DeviceKey {
        do {
            let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
            let pub = priv.publicKey
            return DeviceKey(keyId: DeviceKey.keyId(for: pub), privateKey: priv, publicKey: pub)
        } catch {
            throw DeviceKeyStoreError.invalidKeyBytes
        }
    }
}

/// In-memory `DeviceKeyStore` for tests + previews. Thread-safe via a
/// lock so concurrent ingest paths don't race the store.
final class InMemoryDeviceKeyStore: DeviceKeyStore, @unchecked Sendable {
    private var current: DeviceKey?
    private let lock = NSLock()

    init(initial: DeviceKey? = nil) {
        self.current = initial
    }

    func loadOrCreate() throws -> DeviceKey {
        lock.lock(); defer { lock.unlock() }
        if let existing = current { return existing }
        let fresh = DeviceKey.generate()
        current = fresh
        return fresh
    }

    func load() throws -> DeviceKey? {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        current = nil
    }
}

/// Returns the `DeviceKeyStore` appropriate for the current build.
/// Debug builds use the in-memory store so ad-hoc-signed rebuilds
/// don't prompt for Keychain access on every relaunch.
@inline(__always)
func defaultDeviceKeyStore() -> DeviceKeyStore {
    #if DEBUG
    return InMemoryDeviceKeyStore()
    #else
    return KeychainDeviceKeyStore()
    #endif
}
