import Foundation

/// Parsed `maraithon://device-token/<plain>` deep link. Keeping it a small
/// value type lets us unit-test the parsing in isolation and gives the
/// state machine a non-string handle to pass around.
struct DeviceToken: Equatable, Sendable {
    let plain: String

    /// Parse a deep-link URL of the form `maraithon://device-token/<plain>`.
    /// Returns `nil` if the URL is not in that shape; callers should treat
    /// `nil` as "ignore — not for us" rather than as an error.
    init?(url: URL) {
        guard url.scheme == "maraithon" else { return nil }
        // host carries the action ("device-token") and the first path
        // component is the token. We tolerate any number of leading
        // slashes in case the browser introduces them.
        guard url.host == "device-token" else { return nil }
        let token = url.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        guard !token.isEmpty else { return nil }
        self.plain = token
    }

    /// Direct init for tests / boot from Keychain.
    init(plain: String) {
        self.plain = plain
    }
}
