import Foundation

struct ChatMessageStoredMetadata: Codable, Equatable, Sendable {
    var actions: [ChatMessageAction] = []
    var draftCard: ChatDraftCard?
    var linkedTodo: JSONValue?
    var workSummary: ChatWorkSummary?
    var structuredData: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey {
        case actions
        case draftCard = "draft_card"
        case linkedTodo = "linked_todo"
        case workSummary = "work_summary"
        case structuredData = "structured_data"
    }
}

struct ChatDraftCard: Codable, Equatable, Sendable {
    var provider: String
    var title: String
    var status: String?
    var from: String?
    var recipient: String?
    var cc: String?
    var bcc: String?
    var workspace: String?
    var subject: String?
    var body: String?
    var draftID: String?
    var preparedActionID: UUID?
    var sendLabel: String?
    var openLabel: String?
    var openURL: URL?

    enum CodingKeys: String, CodingKey {
        case provider
        case title
        case status
        case from
        case recipient
        case cc
        case bcc
        case workspace
        case subject
        case body
        case draftID = "draft_id"
        case preparedActionID = "prepared_action_id"
        case sendLabel = "send_label"
        case openLabel = "open_label"
        case openURL = "open_url"
    }

    init?(_ value: JSONValue?) {
        guard let object = value?.object,
              let provider = Self.clean(object["provider"]?.string),
              let title = Self.clean(object["title"]?.string)
        else {
            return nil
        }

        self.provider = provider
        self.title = title
        status = Self.clean(object["status"]?.string)
        from = Self.displayClean(object["from"]?.string)
        recipient = Self.displayClean(object["recipient"]?.string)
        cc = Self.displayClean(object["cc"]?.string)
        bcc = Self.displayClean(object["bcc"]?.string)
        workspace = Self.displayClean(object["workspace"]?.string)
        subject = Self.clean(object["subject"]?.string)
        body = Self.clean(object["body"]?.string)
        draftID = Self.clean(object["draft_id"]?.string)
        sendLabel = Self.clean(object["send_label"]?.string)
        openLabel = Self.clean(object["open_label"]?.string)

        if let idText = Self.clean(object["prepared_action_id"]?.string) {
            preparedActionID = UUID(uuidString: idText)
        }

        if let urlText = Self.clean(object["open_url"]?.string) {
            openURL = URL(string: urlText)
        }
    }

    init(
        provider: String,
        title: String,
        status: String? = nil,
        from: String? = nil,
        recipient: String? = nil,
        cc: String? = nil,
        bcc: String? = nil,
        workspace: String? = nil,
        subject: String? = nil,
        body: String? = nil,
        draftID: String? = nil,
        preparedActionID: UUID? = nil,
        sendLabel: String? = nil,
        openLabel: String? = nil,
        openURL: URL? = nil
    ) {
        self.provider = provider
        self.title = title
        self.status = status
        self.from = Self.displayClean(from)
        self.recipient = Self.displayClean(recipient)
        self.cc = Self.displayClean(cc)
        self.bcc = Self.displayClean(bcc)
        self.workspace = Self.displayClean(workspace)
        self.subject = subject
        self.body = body
        self.draftID = draftID
        self.preparedActionID = preparedActionID
        self.sendLabel = sendLabel
        self.openLabel = openLabel
        self.openURL = openURL
    }

    var providerKey: String {
        provider.lowercased()
    }

    var primaryAction: ChatMessageAction? {
        guard let preparedActionID else { return nil }
        return ChatMessageAction(
            actionID: preparedActionID,
            kind: "prepared_action_decision",
            label: sendLabel ?? "Send",
            decisionRawValue: ChatActionDecision.confirm.rawValue,
            style: "primary"
        )
    }

    var hasAction: Bool {
        primaryAction != nil || openURL != nil
    }

    var normalizedStatus: String {
        (status ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var isSent: Bool {
        normalizedStatus == "sent"
    }

    var isTerminal: Bool {
        ["sent", "cancelled", "expired", "could not send"].contains(normalizedStatus)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayClean(_ value: String?) -> String? {
        guard let cleaned = clean(value) else { return nil }

        if let email = prefixedEmail(in: cleaned) {
            return email
        }

        let lowercased = cleaned.lowercased()

        if ["imessage", "message", "messages", "sms"].contains(lowercased) {
            return "Messages"
        }

        if lowercased == "whatsapp" {
            return "WhatsApp"
        }

        if ["google", "gmail", "email"].contains(lowercased) {
            return nil
        }

        if lowercased.hasPrefix("slack:") ||
            lowercased.hasPrefix("whatsapp:") ||
            lowercased.hasPrefix("google:") ||
            lowercased.hasPrefix("gmail:") ||
            lowercased.hasPrefix("email:")
        {
            return nil
        }

        if isIdentifierLike(cleaned) {
            return nil
        }

        return cleaned
    }

    private static func prefixedEmail(in value: String) -> String? {
        let lowercased = value.lowercased()

        for prefix in ["google:", "gmail:", "email:"] where lowercased.hasPrefix(prefix) {
            let rest = String(value.dropFirst(prefix.count))
            return emailAddress(in: rest)
        }

        return nil
    }

    private static func emailAddress(in value: String) -> String? {
        let pattern = #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#

        guard let range = value.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }

        return String(value[range]).lowercased()
    }

    private static func isIdentifierLike(_ value: String) -> Bool {
        if value.range(of: #"^[A-Z][A-Z0-9]{6,}$"#, options: .regularExpression) != nil {
            return true
        }

        return value.range(of: #"^[-_a-z0-9]{18,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

struct ChatWorkSummary: Codable, Equatable, Sendable {
    var headline: String?
    var status: String?
    var summary: String?
    var toolCalls: [ChatToolCallSummary] = []
    var steps: [ChatWorkStepSummary] = []

    var hasVisibleWork: Bool {
        !(headline ?? "").isEmpty || !(summary ?? "").isEmpty || !toolCalls.isEmpty || !steps.isEmpty
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

struct ChatToolCallSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var tool: String
    var label: String
    var status: String?
    var summary: String?
    var detail: String?
    var startedAt: Date?
    var finishedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case tool
        case label
        case status
        case summary
        case detail
        case startedAt = "started_at"
        case finishedAt = "finished_at"
    }

    init(
        id: String,
        tool: String,
        label: String,
        status: String? = nil,
        summary: String? = nil,
        detail: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        let publicTool = ChatWorkSummaryCopy.publicToolKey(tool)
        let normalizedStatus = ChatWorkSummaryCopy.safeStatus(status)
        let displayLabel = ChatWorkSummaryCopy.safeLabel(label, fallback: ChatWorkSummaryCopy.toolLabel(for: publicTool))
        self.id = id
        self.tool = publicTool
        self.label = displayLabel
        self.status = normalizedStatus
        self.summary =
            ChatWorkSummaryCopy.safeToolSummary(summary, tool: publicTool, label: displayLabel) ??
            ChatWorkSummaryCopy.fallbackToolSummary(status: normalizedStatus, label: displayLabel)
        self.detail = ChatWorkSummaryCopy.safeDetail(detail)
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let publicTool = ChatWorkSummaryCopy.publicToolKey(try container.decode(String.self, forKey: .tool))
        let normalizedStatus = ChatWorkSummaryCopy.safeStatus(try container.decodeIfPresent(String.self, forKey: .status))
        let displayLabel = ChatWorkSummaryCopy.safeLabel(
            try container.decodeIfPresent(String.self, forKey: .label),
            fallback: ChatWorkSummaryCopy.toolLabel(for: publicTool)
        )
        tool = publicTool
        status = normalizedStatus
        label = displayLabel
        summary =
            ChatWorkSummaryCopy.safeToolSummary(
                try container.decodeIfPresent(String.self, forKey: .summary),
                tool: publicTool,
                label: displayLabel
            ) ??
            ChatWorkSummaryCopy.fallbackToolSummary(status: normalizedStatus, label: displayLabel)
        detail = ChatWorkSummaryCopy.safeDetail(try container.decodeIfPresent(String.self, forKey: .detail))
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}

struct ChatWorkStepSummary: Codable, Equatable, Identifiable, Sendable {
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
    private static let legacySelectedItemTool = ["inspect", "open", "in" + "sight"].joined(separator: "_")

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
        case legacySelectedItemTool, "linked_item":
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
        safeText(value, maxLength: maxHeadlineLength, rejectIdentifiers: true).map { headlineProductTerms($0) }
    }

    static func safeDetail(_ value: String?) -> String? {
        guard let detail = safeText(value, maxLength: maxDetailLength, rejectIdentifiers: false) else {
            return nil
        }

        return polishLegacyDetail(detail)
    }

    static func safeToolSummary(_ value: String?, tool: String, label: String) -> String? {
        guard let detail = safeText(value, maxLength: maxDetailLength, rejectIdentifiers: false) else {
            return nil
        }

        return polishLegacyToolDetail(detail, tool: tool, label: label)
    }

    static func safeLabel(_ value: String?, fallback: String) -> String {
        legacyLabel(safeText(value, maxLength: 44, rejectIdentifiers: true) ?? fallback)
    }

    static func fallbackToolSummary(status: String?, label: String) -> String? {
        switch status {
        case "failed":
            failedToolSummary(for: label)
        case "running":
            "Checking now."
        default:
            nil
        }
    }

    private static func failedToolSummary(for label: String) -> String {
        switch label {
        case "Supporting work":
            return "Supporting work could not finish."
        case "Work update":
            return "Work update could not finish."
        case "Scheduled task":
            return "Scheduled task could not finish."
        case "Draft":
            return "Draft could not finish."
        case "Memory update", "Memory":
            return "Memory update could not finish."
        case "Preference update", "Preference":
            return "Preference update could not finish."
        case "Preferences":
            return "Preferences could not finish."
        case "Feedback":
            return "Feedback update could not finish."
        default:
            return "\(label) could not finish."
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
            "Choosing next action"
        case "supporting_plan":
            "Planned supporting checks"
        case "reply":
            "Drafted reply"
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
            return "Completed."
        case "running":
            return "Checking now."
        default:
            return returnedSummary(value) ?? prioritySummary(value) ?? legacyProductTerms(value)
        }
    }

    private static func polishLegacyToolDetail(_ value: String, tool: String, label: String) -> String {
        switch value.lowercased() {
        case "completed":
            return "Completed."
        case "running":
            return "Checking now."
        default:
            return returnedSummary(value, tool: tool) ??
                foundResultsSummary(value, tool: tool, label: label) ??
                prioritySummary(value) ??
                legacyProductTerms(value)
        }
    }

    private static func prioritySummary(_ value: String) -> String? {
        let pattern = #"^([0-9,]+)\s+priorit(?:y|ies)\s+found\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges == 2,
            let countRange = Range(match.range(at: 1), in: value),
            let count = Int(value[countRange].replacingOccurrences(of: ",", with: ""))
        else {
            return nil
        }

        return count == 0
            ? "No priorities matched this request."
            : "Found \(count) \(displayNoun(for: count, singular: "priority", plural: "priorities"))."
    }

    private static func returnedSummary(_ value: String, tool: String? = nil) -> String? {
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
            return count == 0 ? "No open work matched this request." : "Reviewed \(count) open work \(displayNoun(for: count, singular: "item"))."
        case "result", "results":
            if let tool {
                return toolCountSummary(count: count, tool: tool)
            }
            return count == 0 ? "No relevant items matched this request." : "Reviewed \(count) relevant \(displayNoun(for: count, singular: "item"))."
        case "person", "people":
            return count == 0 ? "No people matched this request." : "Reviewed \(count) \(displayNoun(for: count, singular: "person", plural: "people"))."
        case "message", "messages":
            return count == 0 ? "No messages matched this request." : "Reviewed \(count) \(displayNoun(for: count, singular: "message"))."
        case "event", "events":
            if tool == "calendar" {
                return count == 0 ? "No calendar events matched this request." : "Reviewed \(count) calendar \(displayNoun(for: count, singular: "event"))."
            }
            return count == 0 ? "No events matched this request." : "Reviewed \(count) \(displayNoun(for: count, singular: "event"))."
        default:
            let singular = rawNoun.hasSuffix("s") ? String(rawNoun.dropLast()) : rawNoun
            let plural = rawNoun.hasSuffix("s") ? rawNoun : "\(rawNoun)s"
            return count == 0 ? "No \(plural) matched this request." : "Reviewed \(count) \(displayNoun(for: count, singular: singular, plural: plural))."
        }
    }

    private static func foundResultsSummary(_ value: String, tool: String, label: String) -> String? {
        if value.range(of: #"(?i)^No results? found\.?$"#, options: .regularExpression) != nil {
            return toolCountSummary(count: 0, tool: tool)
        }

        let pattern = #"^Found\s+([0-9,]+)\s+results?\.?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard
            let match = regex.firstMatch(in: value, options: [], range: range),
            match.numberOfRanges == 2,
            let countRange = Range(match.range(at: 1), in: value),
            let count = Int(value[countRange].replacingOccurrences(of: ",", with: ""))
        else {
            return nil
        }

        if tool == "supporting_work" {
            return count == 0
                ? "\(label) returned no relevant items."
                : "\(label) reviewed \(count) relevant \(displayNoun(for: count, singular: "item"))."
        }

        return toolCountSummary(count: count, tool: tool)
    }

    private static func toolCountSummary(count: Int, tool: String) -> String {
        switch publicToolKey(tool) {
        case "connected_accounts":
            return count == 0
                ? "No connected accounts were available for this request."
                : "\(count) connected \(displayNoun(for: count, singular: "account")) available."
        case "connected_sources":
            return count == 0
                ? "No connected sources were available for this request."
                : "\(count) connected \(displayNoun(for: count, singular: "source")) available."
        case "open_work", "open_work_review":
            return count == 0
                ? "No open work matched this request."
                : "Reviewed \(count) open work \(displayNoun(for: count, singular: "item"))."
        case "people", "people_update", "relationship_context", "relationship_learning":
            return count == 0
                ? "No people matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "person", plural: "people"))."
        case "gmail":
            return count == 0
                ? "No Gmail messages matched this request."
                : "Reviewed \(count) Gmail \(displayNoun(for: count, singular: "message"))."
        case "slack":
            return count == 0
                ? "No Slack messages matched this request."
                : "Reviewed \(count) Slack \(displayNoun(for: count, singular: "message"))."
        case "messages":
            return count == 0
                ? "No Messages matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "message"))."
        case "calendar":
            return count == 0
                ? "No calendar events matched this request."
                : "Reviewed \(count) calendar \(displayNoun(for: count, singular: "event"))."
        case "notes":
            return count == 0
                ? "No Notes matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "note"))."
        case "voice_memos":
            return count == 0
                ? "No Voice Memos matched this request."
                : "Reviewed \(count) voice \(displayNoun(for: count, singular: "memo"))."
        case "files":
            return count == 0
                ? "No Files matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "file"))."
        case "reminders":
            return count == 0
                ? "No Reminders matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "reminder"))."
        case "browser_history":
            return count == 0
                ? "No browser history matched this request."
                : "Reviewed \(count) browser history \(displayNoun(for: count, singular: "item"))."
        case "preferences", "preference":
            return count == 0
                ? "No preferences matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "preference"))."
        case "memory_check", "memory":
            return count == 0
                ? "No memories matched this request."
                : "Reviewed \(count) \(displayNoun(for: count, singular: "memory", plural: "memories"))."
        default:
            return count == 0
                ? "No relevant items matched this request."
                : "Reviewed \(count) relevant \(displayNoun(for: count, singular: "item"))."
        }
    }

    private static func displayNoun(for count: Int, singular: String, plural: String? = nil) -> String {
        count == 1 ? singular : (plural ?? "\(singular)s")
    }

    private static func legacyProductTerms(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)^No open work found\.?$"#, with: "No open work matched this request.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^This check surfaced no open work\.?$"#, with: "No open work matched this request.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^No connected accounts found\.?$"#, with: "No connected accounts were available for this request.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^No connected sources found\.?$"#, with: "No connected sources were available for this request.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bcrm context\b"#, with: "relationship context", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bcrm\b"#, with: "relationship data", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\btodos\b"#, with: "work items", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\btodo\b"#, with: "work item", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^checked\b"#, with: "Reviewed", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^checking\b"#, with: "Reviewing", options: .regularExpression)
    }

    private static func headlineProductTerms(_ value: String) -> String {
        let headline = value
            .replacingOccurrences(
                of: #"(?i)^Checked people, updated memory, checked Messages, and ([0-9,]+) more checks before replying\.?$"#,
                with: "Used people, memory, Messages, and $1 more sources before replying",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)^Checked preferences, checked memory, and replied\.?$"#,
                with: "Reviewed preferences and memory before replying",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)^Checked open work and replied\.?$"#,
                with: "Reviewed open work before replying",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b([0-9,]+)\s+more checks\b"#,
                with: "$1 more sources",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"(?i)^checked\b"#, with: "Reviewed", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bchecked\b"#, with: "reviewed", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)^checking\b"#, with: "Reviewing", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bchecking\b"#, with: "reviewing", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\band replied\.?$"#, with: "before replying", options: .regularExpression)

        return legacyProductTerms(headline)
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

struct ChatMessageAction: Codable, Equatable, Identifiable, Sendable {
    let actionID: UUID
    let kind: String
    let label: String
    let decisionRawValue: String
    let style: String
    let draftEdits: [String: JSONValue]?

    var id: String {
        "\(actionID.uuidString)-\(decisionRawValue)"
    }

    var decision: ChatActionDecision? {
        ChatActionDecision(rawValue: decisionRawValue)
    }

    init(
        actionID: UUID,
        kind: String,
        label: String,
        decisionRawValue: String,
        style: String,
        draftEdits: [String: JSONValue]? = nil
    ) {
        self.actionID = actionID
        self.kind = kind
        self.label = label
        self.decisionRawValue = decisionRawValue
        self.style = style
        self.draftEdits = draftEdits
    }

    enum CodingKeys: String, CodingKey {
        case actionID = "id"
        case kind
        case label
        case decisionRawValue = "decision"
        case style
        case draftEdits = "draft_edits"
    }

    func withDraftEdits(_ draftEdits: [String: JSONValue]) -> ChatMessageAction {
        ChatMessageAction(
            actionID: actionID,
            kind: kind,
            label: label,
            decisionRawValue: decisionRawValue,
            style: style,
            draftEdits: draftEdits
        )
    }
}
