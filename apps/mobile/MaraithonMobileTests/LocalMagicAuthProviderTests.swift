import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Local Magic Auth Provider")
struct LocalMagicAuthProviderTests {
    private let magicLinkBaseURL = URL(string: "maraithon://auth/magic")!

    @Test
    @MainActor
    func validMagicLinkSignsInAndPersistsSession() async throws {
        let suiteName = "LocalMagicAuthProviderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = LocalMagicAuthProvider(
            userDefaults: defaults,
            tokenGenerator: { "token-123" },
            magicLinkBaseURL: magicLinkBaseURL,
            now: { fixedDate }
        )

        let request = try await provider.requestMagicLink(email: " Person@Example.COM ")
        #expect(request.email == "person@example.com")
        #expect(request.developmentToken == "token-123")
        #expect(request.developmentLink == "maraithon://auth/magic/token-123")

        let user = try await provider.consumeMagicLink(request.developmentLink ?? "")

        #expect(user.id == "person@example.com")
        #expect(user.email == "person@example.com")
        #expect(user.sessionExpiresAt == fixedDate.addingTimeInterval(60 * 24 * 60 * 60))

        let restored = try await provider.restoreSession()
        #expect(restored?.email == "person@example.com")
    }

    @Test
    @MainActor
    func invalidEmailIsRejected() async {
        let provider = LocalMagicAuthProvider(
            tokenGenerator: { "token-123" },
            magicLinkBaseURL: magicLinkBaseURL
        )

        do {
            _ = try await provider.requestMagicLink(email: "not-an-email")
            #expect(Bool(false), "Expected invalid email to throw")
        } catch {
            #expect(error as? AuthError == .invalidEmail)
        }
    }

    @Test
    @MainActor
    func magicLinkIsSingleUse() async throws {
        let provider = LocalMagicAuthProvider(
            tokenGenerator: { "single-use-token" },
            magicLinkBaseURL: magicLinkBaseURL
        )
        let request = try await provider.requestMagicLink(email: "person@example.com")

        _ = try await provider.consumeMagicLink(request.developmentToken ?? "")

        do {
            _ = try await provider.consumeMagicLink(request.developmentToken ?? "")
            #expect(Bool(false), "Expected reused link to throw")
        } catch {
            #expect(error as? AuthError == .invalidOrExpiredLink)
        }
    }

    @Test
    @MainActor
    func expiredMagicLinkIsRejected() async throws {
        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = LocalMagicAuthProvider(
            tokenGenerator: { "expired-token" },
            magicLinkBaseURL: magicLinkBaseURL,
            now: { currentDate }
        )
        let request = try await provider.requestMagicLink(email: "person@example.com")

        currentDate = currentDate.addingTimeInterval(16 * 60)

        do {
            _ = try await provider.consumeMagicLink(request.developmentToken ?? "")
            #expect(Bool(false), "Expected expired link to throw")
        } catch {
            #expect(error as? AuthError == .invalidOrExpiredLink)
        }
    }

    @Test
    @MainActor
    func expiredSessionIsClearedOnRestore() async throws {
        let suiteName = "LocalMagicAuthProviderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var currentDate = Date(timeIntervalSince1970: 1_800_000_000)
        let provider = LocalMagicAuthProvider(
            userDefaults: defaults,
            tokenGenerator: { "session-token" },
            magicLinkBaseURL: magicLinkBaseURL,
            now: { currentDate }
        )

        let request = try await provider.requestMagicLink(email: "person@example.com")
        _ = try await provider.consumeMagicLink(request.developmentToken ?? "")

        currentDate = currentDate.addingTimeInterval(61 * 24 * 60 * 60)

        let restored = try await provider.restoreSession()
        #expect(restored == nil)
    }
}
