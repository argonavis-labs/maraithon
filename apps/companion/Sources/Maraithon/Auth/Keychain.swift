import Foundation
import Security

/// Minimal Keychain wrapper used to persist the device bearer token.
/// Plaintext only ever leaves Keychain when `DeviceAuth` reads it via
/// `currentToken`. All write/read/delete paths go through this protocol
/// so tests can substitute an in-memory store.
protocol KeychainStore: Sendable {
    func set(_ value: String) throws
    func get() throws -> String?
    func delete() throws
}

/// Errors from the real `SecKeychain` backend. The protocol is throwing
/// so the call site can surface a typed failure to the user.
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
    case dataDecodingFailed
}

/// Production implementation backed by `Security.framework`. The service
/// + account pair uniquely identifies the item; `kSecAttrAccessibleAfterFirstUnlock`
/// matches the access posture we want for a long-lived daemon-style app
/// (token usable as soon as the user unlocks the Mac at least once after
/// boot, but never available before then).
struct SystemKeychain: KeychainStore {
    let service: String
    let account: String

    init(
        service: String = "com.maraithon.companion",
        account: String = "device_token"
    ) {
        self.service = service
        self.account = account
    }

    func set(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataDecodingFailed
        }

        // Try update first; if no item exists, add it.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    func get() throws -> String? {
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
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.dataDecodingFailed
        }
        return value
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// `UserDefaults`-backed token store. Debug builds use this in place of
/// `SystemKeychain` so ad-hoc-signed rebuilds (which churn the binary's
/// signature each `xcodebuild`) don't trigger a macOS Keychain
/// permission prompt on every relaunch. Release builds still use the
/// real Keychain.
///
/// The persisted key is namespaced under the service name so multiple
/// stores can share a single `UserDefaults` suite cleanly.
struct UserDefaultsKeychain: KeychainStore, @unchecked Sendable {
    // `@unchecked Sendable`: `UserDefaults.standard` is documented thread-safe;
    // Swift 6 just hasn't been told.
    private let service: String
    private let account: String
    private let defaults: UserDefaults

    init(
        service: String = "com.maraithon.companion",
        account: String = "device_token",
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.account = account
        self.defaults = defaults
    }

    private var key: String { "ud_keychain.\(service).\(account)" }

    func set(_ value: String) throws {
        defaults.set(value, forKey: key)
    }

    func get() throws -> String? {
        defaults.string(forKey: key)
    }

    func delete() throws {
        defaults.removeObject(forKey: key)
    }
}

/// Returns the appropriate `KeychainStore` for the current build
/// configuration. Release: real Keychain. Debug: `UserDefaults` so devs
/// aren't prompted for their password on every rebuild.
///
/// Centralised here so callers don't sprinkle `#if DEBUG` everywhere.
@inline(__always)
func defaultKeychainStore() -> KeychainStore {
    #if DEBUG
    return UserDefaultsKeychain()
    #else
    return SystemKeychain()
    #endif
}

/// In-memory `KeychainStore` for tests and previews. Thread-safe via an
/// internal lock so it matches the real backend's call-anywhere posture.
final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private var value: String?
    private let lock = NSLock()

    init(initial: String? = nil) {
        self.value = initial
    }

    func set(_ value: String) throws {
        lock.lock(); defer { lock.unlock() }
        self.value = value
    }

    func get() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func delete() throws {
        lock.lock(); defer { lock.unlock() }
        value = nil
    }
}
