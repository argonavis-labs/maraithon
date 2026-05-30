import Foundation

struct ChatMessageStoredMetadata: Codable, Equatable {
    var actions: [ChatMessageAction] = []
    var linkedTodo: JSONValue?
    var workSummary: ChatWorkSummary?
    var structuredData: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case actions
        case linkedTodo = "linked_todo"
        case workSummary = "work_summary"
        case structuredData = "structured_data"
    }
}

struct ChatWorkSummary: Codable, Equatable {
    var headline: String?
    var status: String?
    var summary: String?
    var toolCalls: [ChatToolCallSummary] = []
    var steps: [ChatWorkStepSummary] = []

    var hasVisibleWork: Bool {
        !(headline ?? "").isEmpty || !toolCalls.isEmpty || !steps.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case headline
        case status
        case summary
        case toolCalls = "tool_calls"
        case steps
    }

    init(
        headline: String? = nil,
        status: String? = nil,
        summary: String? = nil,
        toolCalls: [ChatToolCallSummary] = [],
        steps: [ChatWorkStepSummary] = []
    ) {
        self.headline = ChatWorkSummaryCopy.safeHeadline(headline)
        self.status = ChatWorkSummaryCopy.safeStatus(status)
        self.summary = ChatWorkSummaryCopy.safeDetail(summary)
        self.toolCalls = toolCalls
        self.steps = steps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        headline = ChatWorkSummaryCopy.safeHeadline(try container.decodeIfPresent(String.self, forKey: .headline))
        status = ChatWorkSummaryCopy.safeStatus(try container.decodeIfPresent(String.self, forKey: .status))
        summary = ChatWorkSummaryCopy.safeDetail(try container.decodeIfPresent(String.self, forKey: .summary))
        toolCalls = try container.decodeIfPresent([ChatToolCallSummary].self, forKey: .toolCalls) ?? []
        steps = try container.decodeIfPresent([ChatWorkStepSummary].self, forKey: .steps) ?? []
    }
}

struct ChatToolCallSummary: Codable, Equatable, Identifiable {
    var id: String
    var tool: String
    var label: String
    var status: String?
    var summary: String?
    var startedAt: Date?
    var finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tool
        case label
        case status
        case summary
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    init(
        id: String,
        tool: String,
        label: String,
        status: String? = nil,
        summary: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        let publicTool = ChatWorkSummaryCopy.publicToolKey(tool)
        let normalizedStatus = ChatWorkSummaryCopy.safeStatus(status)
        self.id = id
        self.tool = publicTool
        self.label = ChatWorkSummaryCopy.safeLabel(label, fallback: ChatWorkSummaryCopy.toolLabel(for: publicTool))
        self.status = normalizedStatus
        self.summary = ChatWorkSummaryCopy.safeDetail(summary) ?? ChatWorkSummaryCopy.fallbackToolSummary(status: normalizedStatus)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        tool = ChatWorkSummaryCopy.publicToolKey(try container.decode(String.self, forKey: .tool))
        status = ChatWorkSummaryCopy.safeStatus(try container.decodeIfPresent(String.self, forKey: .status))
        label = ChatWorkSummaryCopy.safeLabel(
            try container.decodeIfPresent(String.self, forKey: .label),
            fallback: ChatWorkSummaryCopy.toolLabel(for: tool)
        )
        summary =
            ChatWorkSummaryCopy.safeDetail(try container.decodeIfPresent(String.self, forKey: .summary)) ??
            ChatWorkSummaryCopy.fallbackToolSummary(status: status)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

struct ChatWorkStepSummary: Codable, Equatable, Identifiable {
    var id: String
    var sequence: Int?
    var type: String?
    var status: String?
    var title: String?
    var detail: String?
    var startedAt: Date?
    var finishedAt: Date?

    var displayTitle: String {
        if let title, !title.isEmpty {
            return title
        }

        return ChatWorkSummaryCopy.stepTitle(for: type)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case sequence
        case type
        case status
        case title
        case detail
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    init(
        id: String,
        sequence: Int? = nil,
        type: String? = nil,
        status: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.type = ChatWorkSummaryCopy.publicStepType(type)
        self.status = ChatWorkSummaryCopy.safeStatus(status)
        self.title = ChatWorkSummaryCopy.safeLabel(title, fallback: ChatWorkSummaryCopy.stepTitle(for: self.type))
        self.detail = ChatWorkSummaryCopy.safeDetail(detail)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence)
        type = ChatWorkSummaryCopy.publicStepType(try container.decodeIfPresent(String.self, forKey: .type))
        status = ChatWorkSummaryCopy.safeStatus(try container.decodeIfPresent(String.self, forKey: .status))
        title = ChatWorkSummaryCopy.safeLabel(
            try container.decodeIfPresent(String.self, forKey: .title),
            fallback: ChatWorkSummaryCopy.stepTitle(for: type)
        )
        detail = ChatWorkSummaryCopy.safeDetail(try container.decodeIfPresent(String.self, forKey: .detail))
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

private enum ChatWorkSummaryCopy {
    private static let maxHeadlineLength = 96
    private static let maxDetailLength = 160

    private static let technicalMarkers = [
        "authorization:",
        "bearer ",
        "clienterror(",
        "decodingerror",
        "error domain=",
        "implementation",
        "llm",
        "metadata",
        "model_",
        "mobileapierror",
        "nsurlerrordomain",
        "oauth",
        "password",
        "prompt",
        "servererror(",
        "stacktrace",
        "swift.decodingerror",
        "token",
        "tool_call",
        "traceback"
    ]

    static func publicToolKey(_ tool: String) -> String {
        switch tool {
        case "list_connected_accounts", "connected_accounts":
            "connected_accounts"
        case "list_todos", "open_work":
            "open_work"
        case "get_open_work_summary", "open_work_review":
            "open_work_review"
        case "get_open_loops", "open_loops":
            "open_loops"
        case "inspect_open_insight", "linked_item":
            "linked_item"
        case "explain_action_ledger", "action_history":
            "action_history"
        case "update_briefing_schedule", "briefing_schedule":
            "briefing_schedule"
        case "list_scheduled_tasks", "scheduled_followups":
            "scheduled_followups"
        case "pause_scheduled_task", "cancel_scheduled_task", "create_scheduled_task", "scheduled_task":
            "scheduled_task"
        case "list_preferences", "preferences":
            "preferences"
        case "remember_preferences", "forget_preference", "preference_update":
            "preference_update"
        case "preference":
            "preference"
        case "upsert_todos", "update_todo", "resolve_todo", "delete_todo", "todo_update", "work_update":
            "work_update"
        case "list_people", "get_person", "people":
            "people"
        case "upsert_person", "link_person_data", "merge_people", "delete_person", "people_update":
            "people_update"
        case "get_relationship_context", "crm_context", "relationship_context":
            "relationship_context"
        case "review_connected_context", "connected_sources":
            "connected_sources"
        case "learn_relationship_context", "relationship_learning":
            "relationship_learning"
        case "calendar_list_events", "calendar_events_for_person", "calendar_events_around", "calendar_search", "calendar_event_get", "calendar":
            "calendar"
        case "gmail_search_messages", "gmail_get_message", "gmail_drafts", "gmail":
            "gmail"
        case "slack_search_messages", "slack_get_thread", "slack_get_thread_context", "slack":
            "slack"
        case "draft_message", "draft":
            "draft"
        case "list_memories", "recall_memory", "memory_check":
            "memory_check"
        case "write_memory", "update_memory_confidence", "forget_memory", "memory_update":
            "memory_update"
        case "memory":
            "memory"
        case "record_memory_feedback", "feedback":
            "feedback"
        case "linear_list_or_lookup", "linear":
            "linear"
        case "notaui_list_tasks", "notaui":
            "notaui"
        case "list_projects", "inspect_project", "projects":
            "projects"
        case "update_project_scope", "decide_project_recommendation", "grant_project_repo_access", "prepare_project_action", "project_update":
            "project_update"
        case "start_implementation_run", "list_implementation_runs", "update_implementation_run", "project_run":
            "project_run"
        case "list_agents", "inspect_agent", "automations":
            "automations"
        case "prepare_agent_action", "automation_update":
            "automation_update"
        case "prepare_external_action", "prepared_action":
            "prepared_action"
        case "query_agent", "automation_query":
            "automation_query"
        case "notes_search", "notes_get", "notes_list_recent", "notes":
            "notes"
        case "voice_memos_search", "voice_memos_get", "voice_memos_list_recent", "voice_memos":
            "voice_memos"
        case "files_search", "files_get", "files_list_recent", "files":
            "files"
        case "messages_search", "messages_get", "messages_list_recent", "messages_chats_recent", "messages":
            "messages"
        case "reminders_open", "reminders_due_soon", "reminders_search", "reminders_get", "reminders":
            "reminders"
        case "browser_history_recent", "browser_history_by_host", "browser_history_search", "browser_history_get", "browser_history":
            "browser_history"
        case "recall_anywhere", "local_context":
            "local_context"
        default:
            "supporting_work"
        }
    }

    static func toolLabel(for tool: String) -> String {
        switch publicToolKey(tool) {
        case "connected_accounts":
            "Connected accounts"
        case "open_work", "open_work_review":
            "Open work"
        case "open_loops":
            "Follow-through"
        case "linked_item":
            "Selected item"
        case "action_history":
            "Action history"
        case "briefing_schedule":
            "Briefing schedule"
        case "scheduled_followups":
            "Scheduled follow-ups"
        case "work_update":
            "Work update"
        case "people":
            "People"
        case "people_update":
            "People update"
        case "relationship_context":
            "Relationship context"
        case "connected_sources":
            "Connected sources"
        case "relationship_learning":
            "Relationship notes"
        case "calendar":
            "Calendar"
        case "gmail":
            "Gmail"
        case "slack":
            "Slack"
        case "draft":
            "Draft"
        case "scheduled_task":
            "Scheduled task"
        case "memory_check", "memory":
            "Memory"
        case "memory_update":
            "Memory update"
        case "preferences":
            "Preferences"
        case "preference":
            "Preference"
        case "preference_update":
            "Preference update"
        case "feedback":
            "Feedback"
        case "linear":
            "Linear"
        case "notaui":
            "Notaui tasks"
        case "projects":
            "Projects"
        case "project_update":
            "Project update"
        case "project_run":
            "Project run"
        case "automations":
            "Automations"
        case "automation_update":
            "Automation update"
        case "prepared_action":
            "Prepared action"
        case "automation_query":
            "Automation answer"
        case "notes":
            "Notes"
        case "voice_memos":
            "Voice Memos"
        case "files":
            "Files"
        case "messages":
            "Messages"
        case "reminders":
            "Reminders"
        case "browser_history":
            "Browser history"
        case "local_context":
            "Local sources"
        default:
            "Supporting work"
        }
    }

    static func safeStatus(_ value: String?) -> String? {
        guard let value = cleaned(value)?.lowercased() else { return nil }

        switch value {
        case "completed", "complete", "done", "succeeded", "success":
            return "completed"
        case "failed", "error":
            return "failed"
        case "queued", "running", "in_progress", "working":
            return "running"
        default:
            return nil
        }
    }

    static func safeHeadline(_ value: String?) -> String? {
        safeText(value, maxLength: maxHeadlineLength, rejectIdentifiers: true).map { legacyProductTerms($0) }
    }

    static func safeDetail(_ value: String?) -> String? {
        guard let detail = safeText(value, maxLength: maxDetailLength, rejectIdentifiers: false) else {
            return nil
        }

        return polishLegacyDetail(detail)
    }

    static func safeLabel(_ value: String?, fallback: String) -> String {
        legacyLabel(safeText(value, maxLength: 44, rejectIdentifiers: true) ?? fallback)
    }

    static func fallbackToolSummary(status: String?) -> String? {
        switch status {
        case "failed":
            "This check could not finish."
        case "running":
            "Checking now."
        default:
            nil
        }
    }

    static func publicStepType(_ type: String?) -> String? {
        guard let type, !type.isEmpty else { return nil }

        switch type {
        case "context_fetch", "context":
            return "context"
        case "llm_request", "answer_preparation":
            return "answer_preparation"
        case "llm_response", "reply":
            return "reply"
        case "supporting_plan":
            return "supporting_plan"
        case "tool_call", "supporting_check":
            return "supporting_check"
        default:
            return "supporting_work"
        }
    }

    static func stepTitle(for type: String?) -> String {
        switch type {
        case "context":
            "Loaded context"
        case "answer_preparation":
            "Prepared the answer"
        case "supporting_plan":
            "Planned supporting checks"
        case "reply":
            "Wrote the reply"
        case "supporting_check":
            "Completed a check"
        default:
            "Updated progress"
        }
    }

    private static func safeText(_ value: String?, maxLength: Int, rejectIdentifiers: Bool) -> String? {
        guard let value = cleaned(value) else { return nil }

        if looksTechnical(value) || (rejectIdentifiers && looksLikeIdentifier(value)) {
            return nil
        }

        if value.count > maxLength {
            let end = value.index(value.startIndex, offsetBy: maxLength)
            return String(value[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
        }

        return value
    }

    private static func polishLegacyDetail(_ value: String) -> String {
        switch value.lowercased() {
        case "completed":
            return "Completed the check."
        case "running":
            return "Checking now."
        default:
            return returnedSummary(value) ?? legacyProductTerms(value)
        }
    }

    private static func returnedSummary(_ value: String) -> String? {
        let pattern = #"^Returned\s+([0-9,]+)\s+(.+?)\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges == 3,
            let countRange = Range(match.range(at: 1), in: value),
            let nounRange = Range(match.range(at: 2), in: value),
            let count = Int(value[countRange].replacingOccurrences(of: ",", with: ""))
        else {
            return nil
        }

        let rawNoun = String(value[nounRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch rawNoun {
        case "todo", "todos":
            return count == 0 ? "No open work found." : "Found \(count) open work \(displayNoun(for: count, singular: "item"))."
        case "result", "results":
            return count == 0 ? "No results found." : "Found \(count) \(displayNoun(for: count, singular: "result"))."
        case "person", "people":
            return count == 0 ? "No people found." : "Found \(count) \(displayNoun(for: count, singular: "person", plural: "people"))."
        case "message", "messages":
            return count == 0 ? "No messages found." : "Found \(count) \(displayNoun(for: count, singular: "message"))."
        case "event", "events":
            return count == 0 ? "No events found." : "Found \(count) \(displayNoun(for: count, singular: "event"))."
        default:
            let singular = rawNoun.hasSuffix("s") ? String(rawNoun.dropLast()) : rawNoun
            let plural = rawNoun.hasSuffix("s") ? rawNoun : "\(rawNoun)s"
            return count == 0 ? "No \(plural) found." : "Found \(count) \(displayNoun(for: count, singular: singular, plural: plural))."
        }
    }

    private static func displayNoun(for count: Int, singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? "\(singular)s")
    }

    private static func legacyProductTerms(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)\bcrm context\b"#, with: "relationship context", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bcrm\b"#, with: "relationship data", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\btodos\b"#, with: "work items", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\btodo\b"#, with: "work item", options: .regularExpression)
    }

    private static func legacyLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "todo update", "open work update":
            return "Work update"
        case "crm context":
            return "Relationship context"
        default:
            return legacyProductTerms(value)
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func looksTechnical(_ value: String) -> Bool {
        let lower = value.lowercased()

        if technicalMarkers.contains(where: { lower.contains($0) }) {
            return true
        }

        if value.contains("{") || value.contains("}") || value.contains("=>") {
            return true
        }

        return lower.range(of: #"(?i)\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\s*[:=]"#, options: .regularExpression) != nil
    }

    private static func looksLikeIdentifier(_ value: String) -> Bool {
        value.range(of: #"^[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)*$"#, options: .regularExpression) != nil ||
        value.range(of: #"\b[a-z]+_[a-z0-9_]+\b"#, options: .regularExpression) != nil
    }
}

struct ChatMessageAction: Codable, Equatable, Identifiable {
    let actionID: UUID
    let kind: String
    let label: String
    let decisionRawValue: String
    let style: String

    var id: String {
        "\(actionID.uuidString)-\(decisionRawValue)"
    }

    var decision: ChatActionDecision? {
        ChatActionDecision(rawValue: decisionRawValue)
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "id"
        case kind
        case label
        case decisionRawValue = "decision"
        case style
    }
}
