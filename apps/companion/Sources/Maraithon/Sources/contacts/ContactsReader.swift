@preconcurrency import Contacts
import CryptoKit
import Foundation

/// Thin wrapper around `CNContactStore` for reading Contacts.app records.
///
/// `CNContactStore` is not annotated `Sendable`, but the framework is designed
/// around a store object that can enumerate contacts from background work. We
/// keep the non-Sendable contact instances inside the reader and expose only
/// value-type snapshots across actor boundaries.
struct ContactsReader: @unchecked Sendable {
    enum AuthorizationOutcome: Equatable, Sendable {
        case authorized
        case denied
        case restricted
        case notDetermined
    }

    enum ReaderError: Error, Equatable, Sendable {
        case notAuthorized
    }

    struct PostalAddress: Codable, Sendable, Equatable {
        let label: String?
        let street: String?
        let city: String?
        let state: String?
        let postalCode: String?
        let country: String?
    }

    struct Snapshot: Codable, Sendable, Equatable {
        let guid: String
        let displayName: String?
        let firstName: String?
        let middleName: String?
        let lastName: String?
        let nickname: String?
        let organizationName: String?
        let departmentName: String?
        let jobTitle: String?
        let emails: [String]
        let phones: [String]
        let urls: [String]
        let postalAddresses: [PostalAddress]

        var payloadHash: String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = (try? encoder.encode(self)) ?? Data(guid.utf8)
            return SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }

    private let store: CNContactStore
    private let authorizationProbe: @Sendable () -> CNAuthorizationStatus
    private let fetchOverride: (@Sendable () async throws -> [Snapshot])?

    init(
        store: CNContactStore = CNContactStore(),
        authorizationProbe: @escaping @Sendable () -> CNAuthorizationStatus = {
            CNContactStore.authorizationStatus(for: .contacts)
        },
        fetchOverride: (@Sendable () async throws -> [Snapshot])? = nil
    ) {
        self.store = store
        self.authorizationProbe = authorizationProbe
        self.fetchOverride = fetchOverride
    }

    func authorizationState() -> AuthorizationOutcome {
        switch authorizationProbe() {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    func requestAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            store.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    func fetchAllContacts() async throws -> [Snapshot] {
        guard authorizationState() == .authorized else {
            throw ReaderError.notAuthorized
        }
        if let fetchOverride {
            return try await fetchOverride()
        }

        let request = CNContactFetchRequest(keysToFetch: Self.keysToFetch)
        request.sortOrder = .userDefault

        var snapshots: [Snapshot] = []
        try store.enumerateContacts(with: request) { contact, _ in
            snapshots.append(Self.snapshot(from: contact))
        }
        return snapshots
    }

    private static let keysToFetch: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
    ]

    nonisolated static func snapshot(from contact: CNContact) -> Snapshot {
        Snapshot(
            guid: contact.identifier,
            displayName: displayName(for: contact),
            firstName: normalized(contact.givenName),
            middleName: normalized(contact.middleName),
            lastName: normalized(contact.familyName),
            nickname: normalized(contact.nickname),
            organizationName: normalized(contact.organizationName),
            departmentName: normalized(contact.departmentName),
            jobTitle: normalized(contact.jobTitle),
            emails: contact.emailAddresses
                .compactMap { normalized(String($0.value)) }
                .map { $0.lowercased() },
            phones: contact.phoneNumbers.compactMap { normalized($0.value.stringValue) },
            urls: contact.urlAddresses.compactMap { normalized(String($0.value)) },
            postalAddresses: contact.postalAddresses.map { labeled in
                let address = labeled.value
                return PostalAddress(
                    label: labelText(labeled.label),
                    street: normalized(address.street),
                    city: normalized(address.city),
                    state: normalized(address.state),
                    postalCode: normalized(address.postalCode),
                    country: normalized(address.country)
                )
            }
        )
    }

    private nonisolated static func displayName(for contact: CNContact) -> String? {
        if let formatted = CNContactFormatter.string(from: contact, style: .fullName),
           let normalized = normalized(formatted) {
            return normalized
        }

        let name = [contact.givenName, contact.familyName]
            .compactMap(normalized)
            .joined(separator: " ")
        if !name.isEmpty { return name }

        return normalized(contact.organizationName)
    }

    private nonisolated static func labelText(_ label: String?) -> String? {
        guard let label, !label.isEmpty else { return nil }
        return normalized(CNLabeledValue<NSString>.localizedString(forLabel: label))
    }

    private nonisolated static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
