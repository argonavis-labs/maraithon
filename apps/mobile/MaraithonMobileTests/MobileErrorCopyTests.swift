import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Mobile Error Copy")
struct MobileErrorCopyTests {
    @Test
    func hidesTechnicalServerErrors() {
        let copy = MobileErrorCopy.message(
            for: MobileAPIError.server("DBConnection.ConnectionError: token abc123")
        )

        #expect(copy == "Maraithon could not complete that request. Try again.")
        #expect(!copy.contains("DBConnection"))
        #expect(!copy.contains("token"))
        #expect(!copy.contains("abc123"))
    }

    @Test
    func preservesProductServerMessages() {
        let copy = MobileErrorCopy.message(
            for: MobileAPIError.server("Message is too long. Send a shorter note.")
        )

        #expect(copy == "Message is too long. Send a shorter note.")
    }

    @Test
    func hidesCredentialLikeServerMessages() {
        let copy = MobileErrorCopy.message(
            for: MobileAPIError.server("Authorization: Bearer abc123 token=secret")
        )

        #expect(copy == "Maraithon could not complete that request. Try again.")
        #expect(!copy.lowercased().contains("authorization"))
        #expect(!copy.lowercased().contains("bearer"))
        #expect(!copy.lowercased().contains("token"))
        #expect(!copy.contains("abc123"))
    }

    @Test
    func mapsKnownServerCodes() {
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("assistant_run_in_progress")) ==
                "Maraithon is still working on the last message."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("invalid_or_expired_code")) ==
                "Sign-in code is invalid or expired."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("missing_duplicate")) ==
                "Choose the duplicate person to merge."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("message_too_long")) ==
                "Message is too long. Send a shorter note."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("empty_thread_title")) ==
                "Enter a chat name before saving."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("message_not_found")) ==
                "That message is no longer available."
        )
        #expect(
            MobileErrorCopy.message(for: MobileAPIError.server("prepared_action_expired")) ==
                "That action expired. Ask Maraithon to prepare it again."
        )
    }

    @Test
    func preservesProductCopyFromStructuredServerResponses() {
        let error = MobileAPIError.serverResponse(
            code: "not_found",
            message: "That item is no longer available."
        )

        #expect(error.isNotFound)
        #expect(MobileErrorCopy.message(for: error) == "That item is no longer available.")
    }

    @Test
    func mapsTransportAndFrameworkErrors() {
        #expect(
            MobileErrorCopy.message(for: URLError(.notConnectedToInternet)) ==
                "Connection issue. Try again when you are online."
        )
        #expect(
            MobileErrorCopy.message(for: URLError(.userAuthenticationRequired)) ==
                "Sign-in expired. Sign in again."
        )
        #expect(
            MobileErrorCopy.message(for: AuthError.restoreFailed) ==
                "Sign-in could not be restored. Sign in again."
        )

        let copy = MobileErrorCopy.message(for: TechnicalLocalizedError())
        #expect(copy == "Could not finish that request. Try again.")
    }

    @Test
    func apiErrorDescriptionsAvoidEnvironmentJargon() {
        #expect(MobileAPIError.invalidResponse.localizedDescription == "Maraithon returned an unexpected response.")
        #expect(MobileAPIError.unauthorized.localizedDescription == "Sign-in expired. Sign in again.")
        #expect(!MobileAPIError.invalidResponse.localizedDescription.localizedCaseInsensitiveContains("production"))
        #expect(!MobileAPIError.unauthorized.localizedDescription.localizedCaseInsensitiveContains("production"))
        #expect(!MobileAPIError.unauthorized.localizedDescription.localizedCaseInsensitiveContains("session"))
    }

    @Test
    func hidesCredentialLikeLocalizedErrors() {
        let copy = MobileErrorCopy.message(for: CredentialLocalizedError())

        #expect(copy == "Could not finish that request. Try again.")
        #expect(!copy.lowercased().contains("bearer"))
        #expect(!copy.lowercased().contains("secret"))
    }

    private struct TechnicalLocalizedError: LocalizedError {
        var errorDescription: String? {
            "The operation could not be completed. (MaraithonMobile.MobileAPIError error 2.)"
        }
    }

    private struct CredentialLocalizedError: LocalizedError {
        var errorDescription: String? {
            "HTTP 401 Authorization: Bearer secret"
        }
    }
}
