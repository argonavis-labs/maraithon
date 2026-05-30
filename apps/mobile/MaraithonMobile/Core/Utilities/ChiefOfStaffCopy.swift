import Foundation

enum ChiefOfStaffCopy {
    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }

        let lines = value
            .components(separatedBy: .newlines)
            .compactMap(cleanLine)

        let polished = lines
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .polishingChiefOfStaffRoleLabels
            .collapsingChiefOfStaffWhitespace

        guard !polished.isEmpty, !containsInternalCopy(polished) else { return nil }
        return polished
    }

    private static func cleanLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !containsInternalCopy(trimmed) else { return nil }

        let withoutLabel = strippedSafeLabel(trimmed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .polishingChiefOfStaffRoleLabels

        guard !withoutLabel.isEmpty, !containsInternalCopy(withoutLabel) else { return nil }
        return withoutLabel
    }

    private static func strippedSafeLabel(_ value: String) -> String {
        var current = value

        for _ in 0..<3 {
            let next = current.replacingChiefOfStaffMatches(
                #"^\s*(?:source[_ ]context|context[_ ]brief|context|why[_ ]now|why[_ ]it[_ ]matters|next[_ ]best[_ ]action|next[_ ]action|decision[_ ]prompt|decision|evidence[_ ]excerpt|evidence|summary|source)\s*[:=-]\s*"#,
                with: ""
            )

            if next == current { return current }
            current = next
        }

        return current
    }

    private static func containsInternalCopy(_ value: String) -> Bool {
        let lower = value.lowercased()

        let internalMarkers = [
            "assistant_cycle",
            "generation_mode",
            "quality_verification",
            "raw_prompt",
            "system_prompt",
            "tool_call",
            "tool call",
            "llm_",
            "model_name",
            "model_provider",
            "model_response",
            "source_health",
            "metadata"
        ]

        if internalMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        let patterns = [
            #"\b(?:confidence|quality|priority|urgency|relevance|interrupt|telegram_fit)_score\s*[:=]"#,
            #"\bscore\s*[:=]\s*\d"#,
            #"\bthreshold\s*[:=]\s*\d"#,
            #"\bmodel\s*[:=]"#,
            #"^\s*[\{\[]"#
        ]

        return patterns.contains { pattern in
            lower.range(of: pattern, options: .regularExpression) != nil
        }
    }
}

private extension String {
    var polishingChiefOfStaffRoleLabels: String {
        var text = self
        let productUserContextPattern = #"account|accounts|dashboard|dashboards|data|email|emails|event|events|experience|feedback|flow|flows|interface|journey|journeys|list|lists|login|message|messages|name|names|onboarding|page|pages|permission|permissions|persona|personas|plan|plans|preference|preferences|profile|profiles|record|records|research|response|responses|role|roles|screen|screens|segment|segments|session|sessions|setting|settings|sign-up|signup|story|stories|test|tests|testing"#

        let replacements = [
            (#"^\s*The user's\b(?![-\s]+(?:\#(productUserContextPattern))\b)"#, "Your"),
            (#"\bthe user's\b(?![-\s]+(?:\#(productUserContextPattern))\b)"#, "your"),
            (#"^\s*User's\b(?![-\s]+(?:\#(productUserContextPattern))\b)"#, "Your"),
            (#"\bUser's\b(?![-\s]+(?:\#(productUserContextPattern))\b)"#, "your"),
            (#"\bDecide whether to send the ([^.,;]+?) owner and ETA\.?"#, "Send the $1 update with a clear owner and timing."),
            (#"\bReply now with owner, ETA, and the exact artifact or update you committed to\.?"#, "Reply with the promised update, current status, and timing you can stand behind."),
            (#"\bReply now with owner and ETA\.?"#, "Reply with a clear owner and timing."),
            (#"\bwith owner, ETA, and\b"#, "with a clear owner, timing, and"),
            (#"\bwith owner and ETA\b"#, "with a clear owner and timing"),
            (#"\bwith the owner and ETA\b"#, "with a clear owner and timing"),
            (#"\bNo later reply or follow[- ]?through was found in the conversation\.?"#, "No later reply or delivery clearly closes the loop."),
            (#"\bNo later reply or delivery was found\.?"#, "No later reply or delivery clearly closes the loop."),
            (#"\s+and no later reply was found\.?"#, "; no later reply clearly closes the loop."),
            (#"\bNo later reply was found\.?"#, "No later reply clearly closes the loop."),
            (#"\bneeds a user response\b"#, "needs your reply"),
            (#"\bneeds user response\b"#, "needs your reply"),
            (#"\brequires a user response\b"#, "needs your reply"),
            (#"\bwaiting for a user response\b"#, "waiting on your reply"),
            (#"\bawaiting a user response\b"#, "waiting on your reply"),
            (#"\bneeds a user decision\b"#, "needs your decision"),
            (#"\bneeds user decision\b"#, "needs your decision"),
            (#"\brequires a user decision\b"#, "needs your decision"),
            (#"^\s*The user committed\b"#, "You committed"),
            (#"\bthe user committed\b"#, "you committed"),
            (#"^\s*The user wants\b"#, "You want"),
            (#"\bthe user wants\b"#, "you want"),
            (#"^\s*The user needs\b"#, "You need"),
            (#"\bthe user needs\b"#, "you need"),
            (#"^\s*The user has\b"#, "You have"),
            (#"\bthe user has\b"#, "you have"),
            (#"^\s*The user is\b"#, "You are"),
            (#"\bthe user is\b"#, "you are"),
            (#"^\s*The user should\b"#, "You should"),
            (#"\bthe user should\b"#, "you should"),
            (#"^\s*The user asked\b"#, "You asked"),
            (#"\bthe user asked\b"#, "you asked"),
            (#"^\s*The user owes\b"#, "You owe"),
            (#"\bthe user owes\b"#, "you owe"),
            (#"^\s*User committed\b"#, "You committed"),
            (#"\bUser committed\b"#, "you committed"),
            (#"^\s*User wants\b"#, "You want"),
            (#"\bUser wants\b"#, "you want"),
            (#"^\s*User needs\b"#, "You need"),
            (#"\bUser needs\b"#, "you need"),
            (#"^\s*User has\b"#, "You have"),
            (#"\bUser has\b"#, "you have"),
            (#"^\s*User is\b"#, "You are"),
            (#"\bUser is\b"#, "you are"),
            (#"^\s*User should\b"#, "You should"),
            (#"\bUser should\b"#, "you should"),
            (#"^\s*User asked\b"#, "You asked"),
            (#"\bUser asked\b"#, "you asked"),
            (#"^\s*User owes\b"#, "You owe"),
            (#"\bUser owes\b"#, "you owe"),
            (#"\bthe user\b(?!'s)(?![-\s]+(?:\#(productUserContextPattern))\b)"#, "you"),
            (#"\boperator attention\b"#, "your attention"),
            (#"^\s*The operator's\b"#, "Your"),
            (#"\bthe operator's\b"#, "your"),
            (#"^\s*Operator's\b"#, "Your"),
            (#"\boperator's\b"#, "your"),
            (#"\bthe operator\b"#, "you"),
            (#"\bKent's\b"#, "your"),
            (#"^\s*Kent needs\b"#, "You need"),
            (#"\bKent needs\b"#, "you need"),
            (#"^\s*Kent should\b"#, "You should"),
            (#"\bKent should\b"#, "you should"),
            (#"^\s*Kent has\b"#, "You have"),
            (#"\bKent has\b"#, "you have"),
            (#"^\s*Kent asked\b"#, "You asked"),
            (#"\bKent asked\b"#, "you asked"),
            (#"\btodo list\b"#, "open work"),
            (#"\btodos\b"#, "work items"),
            (#"\btodo\b"#, "work item"),
            (#"\bchief_of_staff_morning_briefing\b"#, "morning briefing"),
            (#"\bchief_of_staff_commitment_tracker\b"#, "commitment tracker")
        ]

        for (pattern, replacement) in replacements {
            text = text.replacingChiefOfStaffMatches(pattern, with: replacement)
        }

        return text
    }

    var collapsingChiefOfStaffWhitespace: String {
        replacingChiefOfStaffMatches(#"[ \t]{2,}"#, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func replacingChiefOfStaffMatches(_ pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return self
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.stringByReplacingMatches(in: self, options: [], range: range, withTemplate: replacement)
    }
}
