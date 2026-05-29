import Foundation

/// User-facing copy for non-source companion app failures.
///
/// Network clients and server endpoints keep diagnostic errors precise for
/// logs and tests. This mapper is the UI boundary for Recall, Settings, and
/// other companion-level views: no HTTP bodies, enum dumps, or transport
/// domains should reach the screen.
struct CompanionErrorCopy {
    static func message(for error: Error) -> String {
        switch error {
        case MaraithonClientError.unauthorized:
            return "Reconnect Maraithon to continue."
        case MaraithonClientError.invalidResponse:
            return "Maraithon returned an unexpected response. Try again."
        case let MaraithonClientError.clientError(status, body):
            if let serverMessage = serverBodyMessage(from: body) {
                return serverMessage
            }
            return clientMessage(status: status)
        case let MaraithonClientError.serverError(status):
            return serverMessage(status: status)
        case MaraithonClientError.transport:
            return "Connection issue. Try again when you are online."
        default:
            return "Could not finish that request. Try again."
        }
    }

    static func message(for reason: String) -> String {
        let lower = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if lower.isEmpty {
            return "Could not finish that request. Try again."
        }

        if lower.contains("unauthorized") || lower.contains("401") || lower == "no_token" {
            return "Reconnect Maraithon to continue."
        }

        if lower.contains("timeout") || lower.contains("timed out") {
            return "Connection timed out. Try again."
        }

        if lower.contains("servererror") || lower.contains("status: 5") {
            return "Maraithon is temporarily unavailable. Try again shortly."
        }

        if lower.contains("nsurlerrordomain")
            || lower.contains("could not connect")
            || lower.contains("network")
            || lower.contains("offline")
            || lower.contains("transport(") {
            return "Connection issue. Try again when you are online."
        }

        if lower.contains("invalidresponse")
            || lower.contains("decodefailure")
            || lower.contains("decodingerror")
            || lower.contains("json") {
            return "Maraithon returned an unexpected response. Try again."
        }

        if looksTechnical(reason) {
            return "Could not finish that request. Try again."
        }

        return reason
    }

    private static func clientMessage(status: Int) -> String {
        switch status {
        case 401:
            return "Reconnect Maraithon to continue."
        case 404:
            return "That item is no longer available. Refresh and try again."
        case 408:
            return "Connection timed out. Try again."
        case 409:
            return "The request was out of date. Refresh and try again."
        case 413:
            return "That request was too large. Sync fewer items and try again."
        case 429:
            return "Maraithon is busy right now. Try again shortly."
        default:
            return "Maraithon could not complete that request. Try again."
        }
    }

    private static func serverMessage(status: Int) -> String {
        if status >= 500 {
            return "Maraithon is temporarily unavailable. Try again shortly."
        }

        return "Maraithon could not complete that request. Try again."
    }

    private static func looksTechnical(_ value: String) -> Bool {
        if value.range(of: #"^[a-z0-9_]+$"#, options: .regularExpression) != nil {
            return true
        }

        let lower = value.lowercased()
        let markers = [
            "optional(",
            "error domain=",
            "clienterror(",
            "servererror(",
            "status:",
            "status=",
            "http ",
            "{",
            "}",
            "[",
            "]",
            "=>",
            "stacktrace",
            "token=",
            "token:",
            "token ",
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
            "postgrex",
            "phoenix",
            "exception"
        ]

        return markers.contains { lower.contains($0) }
    }

    private static func serverBodyMessage(from body: String?) -> String? {
        guard
            let body,
            let data = body.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(ServerErrorEnvelope.self, from: data)
        else {
            return nil
        }

        for candidate in [envelope.message, envelope.error] {
            if let safe = safeServerText(candidate) {
                return safe
            }
        }

        return nil
    }

    private static func safeServerText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty, !looksTechnical(trimmed) else {
            return nil
        }

        return trimmed
    }
}

private struct ServerErrorEnvelope: Decodable {
    let error: String?
    let message: String?
}
