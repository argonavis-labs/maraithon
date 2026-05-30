import Foundation

enum MobileErrorCopy {
    private static let requestFallback = "Request did not complete. Refresh before continuing."
    private static let assistantFallback =
        "Maraithon could not finish that response. Ask for a narrower check or refresh the conversation before continuing."
    private static let unexpectedResponseFallback =
        "Maraithon returned an unexpected response. Update the app, then refresh."

    static func message(for error: Error) -> String {
        switch error {
        case MobileAPIError.unauthorized:
            return "Sign-in expired. Sign in again."
        case MobileAPIError.invalidResponse:
            return unexpectedResponseFallback
        case let MobileAPIError.server(message):
            return serverMessage(for: message)
        case let MobileAPIError.serverResponse(code, message):
            return serverResponseMessage(code: code, message: message)
        case AuthError.invalidEmail:
            return "Enter a valid email address."
        case AuthError.magicLinkNotFound:
            return "Request a new sign-in code."
        case AuthError.invalidOrExpiredLink:
            return "Sign-in code is invalid or expired."
        case AuthError.restoreFailed:
            return "Sign-in could not be restored. Sign in again."
        case let urlError as URLError:
            return message(forURLError: urlError)
        case is DecodingError:
            return unexpectedResponseFallback
        default:
            let description = error.localizedDescription
            if looksTechnical(description) {
                return requestFallback
            }
            return description
        }
    }

    static func serverMessage(for message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return requestFallback
        }

        switch trimmed {
        case "not_found":
            return "That item is no longer available. Refresh to see current work."
        case "missing_duplicate":
            return "Choose the duplicate person to merge."
        case "unsupported_todo_action":
            return "That work item action is not available from mobile."
        case "invalid_email":
            return "Enter a valid email address."
        case "invalid_or_expired_code", "invalid_or_expired_link":
            return "Sign-in code is invalid or expired."
        case "assistant_run_in_progress":
            return "Maraithon is still working on the last message."
        case "message_not_found":
            return "That message is no longer available. Refresh the conversation before continuing."
        case "message_too_long":
            return "Message is too long. Send a shorter note."
        case "missing_client_message_id":
            return "Message could not be sent. Retry from the latest conversation."
        case "empty_message":
            return "Enter a message before sending."
        case "empty_thread_title":
            return "Enter a chat name before saving."
        case "thread_title_too_long":
            return "Keep the chat name shorter."
        case "invalid_decision":
            return "Choose confirm or cancel before continuing."
        case "prepared_action_expired":
            return "That action expired. Ask Maraithon to prepare it again."
        default:
            break
        }

        if looksTechnical(trimmed) {
            return requestFallback
        }

        return trimmed
    }

    static func assistantRunFailureMessage(for message: String?) -> String {
        guard let message else { return assistantFallback }

        let publicMessage = serverMessage(for: message)
        if publicMessage == requestFallback {
            return assistantFallback
        }

        return publicMessage
    }

    private static func serverResponseMessage(code: String, message: String) -> String {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmedCode {
        case "not_found", "invalid_decision":
            return serverMessage(for: trimmedCode)
        default:
            return serverMessage(for: message)
        }
    }

    private static func message(forURLError error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost:
            return "Connection issue. Retry when you are online."
        case .timedOut:
            return "Connection timed out. Retry when the network is stable."
        case .userAuthenticationRequired, .userCancelledAuthentication:
            return "Sign-in expired. Sign in again."
        default:
            return "Connection issue. Refresh when the network is stable."
        }
    }

    private static func looksTechnical(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        if trimmed.isEmpty {
            return true
        }

        if trimmed.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
            return true
        }

        let markers = [
            "error domain=",
            "nsurlerrordomain",
            "decodingerror",
            "swift.decodingerror",
            "mobileapierror",
            "clienterror(",
            "servererror(",
            "status:",
            "status=",
            "http ",
            "the operation couldn",
            "dbconnection",
            "postgrex",
            "ecto.",
            "phoenix.",
            "req.transporterror",
            "stacktrace",
            "token ",
            "token:",
            "token=",
            "access_token",
            "refresh_token",
            "authorization",
            "bearer",
            "secret",
            "password",
            "api_key",
            "apikey",
            "client_secret",
            "private_key",
            "{",
            "}",
            "=>"
        ]

        return markers.contains { lower.contains($0) }
    }
}
