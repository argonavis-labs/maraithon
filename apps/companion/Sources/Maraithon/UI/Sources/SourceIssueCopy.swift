import Foundation

/// User-facing copy for source health reasons.
///
/// Sources and ingest clients intentionally keep diagnostic reason
/// strings stable for logs/tests. This mapper is the product boundary:
/// UI surfaces should show these strings, not raw enum dumps, HTTP
/// bodies, or macOS error domains.
struct SourceIssueCopy {
    private static let genericRecovery = "This source needs attention. Sync again when ready."

    static func status(_ reason: String) -> String {
        let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        switch normalized {
        case "calendar_not_authorized":
            return "Calendar permission is off."
        case "reminders_not_authorized":
            return "Reminders permission is off."
        case "imessage_full_disk_access_required",
             "notes_full_disk_access_required",
             "voice_memos_full_disk_access_required":
            return "Full Disk Access is required."
        case "voice_memos_speech_disabled":
            return "Siri or Dictation is off."
        case "voice_memos_speech_not_authorized":
            return "Speech Recognition permission is off."
        case "invalid_batch":
            return "Some items could not finish syncing. Maraithon will keep the last successful data until the next sync."
        case "messages_required", "notes_required", "voice_memos_required",
             "calendar_events_required", "reminders_required", "files_required",
             "visits_required":
            return "Sync data was incomplete. Maraithon will keep the last successful data until the next sync."
        case "unknown_event":
            return "This companion app needs an update before it can sync this source. Update Maraithon, then sync again."
        case "device_mismatch":
            return "This Mac is paired as a different device. Sign out and pair it again."
        case "no_token", "unauthorized":
            return "Reconnect Maraithon to resume sync."
        case "invalid_url":
            return "Maraithon is missing a valid sync address. Check the app settings, then sync again."
        case "pushTimeout", "timed_out":
            return "Connection timed out. Sync again when the network is stable."
        default:
            break
        }

        if lower.contains("unauthorized") || lower.contains("401") {
            return "Reconnect Maraithon to resume sync."
        }

        if lower.contains("invalid_batch") || lower.contains("clienterror(status: 400") {
            return "Some items could not finish syncing. Maraithon will keep the last successful data until the next sync."
        }

        if lower.contains("rejected") || lower.contains("by the server") {
            return "Some items could not finish syncing. Maraithon will keep the last successful data until the next sync."
        }

        if lower.contains("servererror") || lower.contains("status: 5") {
            return "Maraithon is temporarily unavailable. Sync again shortly."
        }

        if lower.contains("timeout") || lower.contains("timed out") {
            return "Connection timed out. Sync again when the network is stable."
        }

        if lower.contains("nsurlerrordomain")
            || lower.contains("could not connect")
            || lower.contains("network")
            || lower.contains("offline")
            || lower.contains("transport(") {
            return "Connection issue. Sync again when you are online."
        }

        if lower.contains("invalidresponse")
            || lower.contains("decodefailure")
            || lower.contains("decodingerror")
            || lower.contains("json") {
            return "Maraithon returned an unexpected response. Update the app, then sync again."
        }

        if looksTechnical(normalized) {
            return genericRecovery
        }

        return normalized.isEmpty ? genericRecovery : normalized
    }

    static func detail(_ reason: String, sourceName: String) -> String {
        let recovery = status(reason)
        let lower = recovery.lowercased()

        if lower.contains("sync again")
            || lower.contains("reconnect")
            || lower.contains("update")
            || lower.contains("sign out") {
            return "\(sourceName) could not finish its last check. \(recovery)"
        }

        return "\(sourceName) could not finish its last check. \(recovery) Sync again when ready."
    }

    static func issue(_ reason: String, failedCount _: Int) -> String {
        status(reason)
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
            "invalidresponse",
            "decodefailure",
            "{",
            "}",
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
}
