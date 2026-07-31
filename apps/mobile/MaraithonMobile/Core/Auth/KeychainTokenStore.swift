import Foundation
import Security

/// Abstraction over where the secret session token lives, so auth providers
/// stay testable without touching the real Keychain.
protocol SessionTokenStoring {
    func get() -> String?
    func set(_ token: String)
    func delete()
}

/// Stores the session token as a generic-password Keychain item scoped to this
/// app and device. Readable after the first unlock so launch can restore the
/// session; never synced or migrated to another device.
struct KeychainTokenStore: SessionTokenStoring {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "MaraithonMobile",
        account: String = "sessionToken"
    ) {
        self.service = service
        self.account = account
    }

    func get() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return }

        var addQuery = baseQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
