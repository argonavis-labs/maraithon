import Foundation

/// Bridge between the source-level ingest helpers and the
/// `ContentEncryption` primitive. Hides the "do I encrypt this row?"
/// decision so each ingest helper can stay one-liner: build the
/// payload, run it through `applyEncryption`, ship.
///
/// Notably this type is plain-`struct` (no `@MainActor`) so detached
/// build tasks (the way `NotesSource.buildRecords` runs) can call
/// into it without touching the main actor.
struct IngestEncryption: Sendable {
    let source: EncryptableSource
    /// `nil` means the user hasn't enabled encryption for this source
    /// or hasn't yet published a public key — in either case ingest
    /// helpers should skip the seal step and ship plaintext.
    let crypto: ContentEncryption?
    /// `keyId` recorded on each encrypted row so the server can pair
    /// the ciphertext with a published public-key row.
    var keyId: String? { crypto?.deviceKey.keyId }

    /// Convenience: returns `true` when the helper is configured to
    /// encrypt outgoing records.
    var isEnabled: Bool { crypto != nil }

    /// Apply encryption to a single optional string. Returns the
    /// original value untouched when encryption isn't enabled. When
    /// enabled, returns the base64 ciphertext (or nil if the input
    /// was nil — we don't seal an empty field, that'd just shrink the
    /// metadata surface for no gain).
    func encryptField(_ value: String?) -> String? {
        guard let value, !value.isEmpty, let crypto else { return value }
        do {
            return try crypto.encrypt(value).base64
        } catch {
            // Fail-closed: if encryption fails we'd rather ship
            // nothing for that field than silently leak plaintext.
            return nil
        }
    }

    /// Build a fresh `IngestEncryption` configured against the
    /// caller's source-toggle state. Returns a "disabled" instance
    /// (i.e. `crypto == nil`) when the user hasn't opted into
    /// encryption for the given source, so callers can always wrap
    /// their payload-builder in `encryptField(_:)` without an
    /// explicit branch.
    static func resolve(
        source: EncryptableSource,
        settings: EncryptionSettings,
        keyStore: DeviceKeyStore
    ) -> IngestEncryption {
        guard settings.isEnabled(for: source) else {
            return IngestEncryption(source: source, crypto: nil)
        }
        do {
            let deviceKey = try keyStore.loadOrCreate()
            return IngestEncryption(source: source, crypto: ContentEncryption(deviceKey: deviceKey))
        } catch {
            // Fail-closed: if we can't read the device key, treat
            // encryption as off (caller will skip the encryption
            // path entirely rather than ship half-encrypted rows).
            return IngestEncryption(source: source, crypto: nil)
        }
    }
}
