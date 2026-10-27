import SwiftUI
import AssistantProgressKit

struct TodoRow: View {
    let todo: TodoItem
    let onToggle: () -> Void
    let isWorking: Bool
    let isCompleting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCompleted: Bool { todo.isCompleted || isCompleting }

    /// Built once per row construction; the body reads it several times and
    /// each construction runs the copy-cleaning pipeline over ~8 fields.
    private let decisionContext: TodoDecisionContext
    private let badges: [TodoBadge]

    init(todo: TodoItem, isWorking: Bool = false, isCompleting: Bool = false, onToggle: @escaping () -> Void) {
        self.todo = todo
        self.onToggle = onToggle
        self.isWorking = isWorking
        self.isCompleting = isCompleting
        self.decisionContext = TodoDecisionContext(todo: todo)
        self.badges = TodoBadges.badges(for: todo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.snug) {
            RunnerCheckbox(
                isOn: showsCompleted,
                label: todo.isCompleted ? "Mark incomplete" : "Mark complete",
                action: onToggle,
                tint: showsCompleted ? Runner.Palette.success : Runner.Palette.accent
            )
            .disabled(isWorking)
            .overlay {
                if isWorking && !isCompleting {
                    ProgressView().controlSize(.mini).accessibilityLabel("Saving task")
                }
            }

            VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                Text(todo.title)
                    .font(Runner.Typography.bodyMedium)
                    .strikethrough(showsCompleted)
                    .foregroundStyle(showsCompleted ? Runner.Palette.mutedForeground : Runner.Palette.foreground)
                    .fixedSize(horizontal: false, vertical: true)

                if !badges.isEmpty {
                    TodoBadgeRow(badges: badges)
                }

                if let workflow = todo.workflow {
                    TodoOwnershipLine(workflow: workflow)
                }

                if todo.isActive, let next = todo.workflow?.nextAction, !next.isEmpty {
                    TodoLabeledLine(
                        label: todo.isOwnedBySomeoneElse ? "Owner’s next step:" : "Next:",
                        text: next, lineLimit: 2
                    )
                } else if let context = decisionContext.rowContext {
                    Text(context)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                }

                if sourceLabel != nil || todo.dueDate != nil {
                    HStack(spacing: Runner.Spacing.compact) {
                        if let sourceLabel {
                            ProviderMark(provider: providerKey, size: Runner.Layout.providerMark)
                            Text(sourceLabel)
                                .font(Runner.Typography.caption)
                                .foregroundStyle(Runner.Palette.mutedForeground)
                                .lineLimit(1)
                        }

                        Spacer(minLength: Runner.Spacing.small)

                        if let dueDate = todo.dueDate {
                            Text(dueText(for: dueDate))
                                .font(Runner.Typography.caption)
                                .foregroundStyle(dueTint(for: dueDate))
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, Runner.Spacing.xxsmall)
                }

                if todo.isTracking {
                    Text("Tracking progress")
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                }
            }
            // Lines the title up with the checkbox's visible box, not its 44pt touch frame.
            .padding(.top, Runner.Spacing.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : .default, value: isCompleting)
    }

    private var sourceLabel: String? {
        let label = (todo.sourceProviderLabel ?? todo.sourceSystem)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return label?.isEmpty == false ? label : nil
    }

    private var providerKey: String {
        todo.sourceProvider ?? todo.sourceProviderLabel?.lowercased() ?? todo.sourceSystem ?? ""
    }

    private func dueText(for dueDate: Date) -> String {
        TodoRowCopy.dueText(for: todo, dueDate: dueDate)
    }

    private func dueTint(for dueDate: Date) -> Color {
        guard !todo.isCompleted else { return Runner.Palette.mutedForeground }
        if TodoRowCopy.isStaleKeepClose(todo) {
            return Runner.Palette.mutedForeground
        }
        let calendar = Calendar.current
        if dueDate < Date(), !calendar.isDateInToday(dueDate) {
            return Runner.Palette.destructiveText
        }
        if calendar.isDateInToday(dueDate) {
            return Runner.Palette.infoText
        }
        return Runner.Palette.mutedForeground
    }
}

/// One workspace badge (status, decision, priority) shared by rows and the detail header.
struct TodoBadge: Identifiable, Equatable {
    let id: String
    let text: String
    let tone: RunnerBadge.Tone
}

enum TodoBadges {
    static func badges(for todo: TodoItem) -> [TodoBadge] {
        var badges: [TodoBadge] = []

        switch todo.status {
        case .open:
            break
        case .triage:
            badges.append(TodoBadge(id: "status", text: "Triage", tone: .zinc))
        case .snoozed:
            badges.append(TodoBadge(id: "status", text: todo.status.title, tone: .amber))
        case .done:
            badges.append(TodoBadge(id: "status", text: todo.status.title, tone: .blue))
        case .dismissed:
            badges.append(TodoBadge(id: "status", text: todo.status.title, tone: .zinc))
        }

        if todo.isTracking {
            badges.append(TodoBadge(id: "tracking", text: "Tracking", tone: .zinc))
        }

        if let title = TodoDecisionSignals.signalPillTitle(for: todo) {
            badges.append(TodoBadge(id: "decision", text: title, tone: .indigo))
        }

        if todo.isActive {
            switch todo.priority {
            case .high:
                badges.append(TodoBadge(id: "priority", text: todo.priority.title, tone: .amber))
            case .critical:
                badges.append(TodoBadge(id: "priority", text: todo.priority.title, tone: .red))
            case .medium, .low:
                break
            }
        }

        return badges
    }
}

struct TodoBadgeRow: View {
    let badges: [TodoBadge]

    var body: some View {
        HStack(spacing: Runner.Spacing.compact) {
            ForEach(badges) { badge in
                RunnerBadge(text: badge.text, tone: badge.tone)
            }
        }
    }
}

/// Names another person's ownership explicitly, while preserving user follow-up states.
struct TodoOwnershipLine: View {
    let workflow: TodoWorkflow

    private var ownerLabel: String {
        workflow.owner.kind == "person" ? "Owned by \(workflow.owner.displayName)" : workflow.ballLabel
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.xsmall) {
            Image(systemName: "person.2")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .accessibilityHidden(true)
            Text("\(Text(ownerLabel).foregroundStyle(workflow.owner.kind == "person" ? Runner.Palette.foreground : Runner.Palette.mutedForeground)) · \(workflow.label)")
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ownerLabel). State: \(workflow.label)")
    }
}

/// "Label: text" as one run of small type: label in foreground80, text in `textColor`.
struct TodoLabeledLine: View {
    let label: String
    let text: String
    var lineLimit: Int? = nil
    var textColor: Color = Runner.Palette.mutedForeground

    var body: some View {
        (Text(label).foregroundStyle(Runner.Palette.foreground80)
            + Text(" ")
            + Text(text).foregroundStyle(textColor))
            .font(Runner.Typography.small)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct TodoDecisionContext: Equatable {
    let contextSummary: String?
    let decisionPrompt: String?
    let notesContext: String?
    let whyNow: String?
    let sourceContext: String?
    let preparedMove: String?
    let draftPreview: String?
    let rowMove: String?
    let evidence: String?

    init(todo: TodoItem) {
        if !todo.isActive {
            contextSummary = todo.resolutionNote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            decisionPrompt = nil
            notesContext = nil
            whyNow = nil
            sourceContext = nil
            preparedMove = nil
            draftPreview = nil
            rowMove = nil
            evidence = nil
            return
        }

        let brief = todo.todoBrief
        let title = Self.cleanedText(todo.title)
        let notes = Self.cleanedText(todo.notes)
        let nextAction = Self.cleanedText(todo.displayNextAction)
        let contextSummary = Self.uniqueText(
            brief?.situation ?? todo.decisionContextSummary,
            excludingCleaned: [title, notes, nextAction]
        )
        let decisionPrompt = Self.uniqueText(
            todo.decisionPrompt,
            excludingCleaned: [title, notes, nextAction, contextSummary]
        )
        let preparedMove = Self.uniqueText(
            brief?.recommendation ?? todo.nextBestAction,
            excludingCleaned: [title, notes, nextAction, contextSummary, decisionPrompt]
        )

        self.contextSummary = contextSummary
        self.decisionPrompt = decisionPrompt
        self.notesContext = Self.uniqueCleanedText(
            notes,
            excludingCleaned: [title, nextAction, contextSummary, decisionPrompt]
        )
        self.whyNow = Self.cleanedText(brief?.whyItMatters ?? todo.whyNow)
        self.sourceContext = Self.cleanedText(todo.sourceContext)
        self.preparedMove = preparedMove
        self.draftPreview = Self.uniqueText(
            todo.draftPreview,
            excludingCleaned: [title, notes, nextAction, contextSummary, decisionPrompt, preparedMove]
        )
        self.rowMove = preparedMove ?? nextAction
        self.evidence = Self.cleanedText(todo.evidenceExcerpt)
    }

    var rowContext: String? {
        contextSummary ?? decisionPrompt ?? notesContext
    }

    var rowReason: String? {
        let rowDecisionPrompt = contextSummary == nil ? nil : decisionPrompt

        let reason = [rowDecisionPrompt, whyNow, sourceContext]
            .compactMap { $0 }
            .joined(separator: " ")

        return reason.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    var hasChiefOfStaffContext: Bool {
        contextSummary != nil ||
            decisionPrompt != nil ||
            whyNow != nil ||
            sourceContext != nil ||
            preparedMove != nil ||
            draftPreview != nil ||
            evidence != nil
    }

    private static func uniqueText(_ value: String?, excludingCleaned values: [String?]) -> String? {
        uniqueCleanedText(cleanedText(value), excludingCleaned: values)
    }

    private static func uniqueCleanedText(_ cleaned: String?, excludingCleaned values: [String?]) -> String? {
        guard let cleaned else { return nil }
        let isDuplicate = values.contains { other in
            guard let other else { return false }
            return cleaned.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return isDuplicate ? nil : cleaned
    }

    private static func cleanedText(_ value: String?) -> String? {
        ChiefOfStaffCopy.clean(value)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum TodoRowCopy {
    static func dueText(
        for todo: TodoItem,
        dueDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        guard !todo.isCompleted else {
            return dueDate.formatted(AppFormatters.shortDate)
        }

        if todo.status == .snoozed, let snoozedUntil = todo.snoozedUntil {
            return "Snoozed until \(snoozedUntil.formatted(AppFormatters.shortDate))"
        }

        // Stale keep/close cards should not scream "Past due" urgency — the
        // product ask is keep-or-dismiss, and due dates on those rows are often
        // older than the saved open-work age.
        if isStaleKeepClose(todo) {
            return "Needs keep/close"
        }

        if dueDate < now, !calendar.isDate(dueDate, inSameDayAs: now) {
            return "Past due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
        }

        if calendar.isDate(dueDate, inSameDayAs: now) {
            return "Today"
        }

        return dueDate.formatted(AppFormatters.shortDate)
    }

    static func isStaleKeepClose(_ todo: TodoItem) -> Bool {
        guard let prompt = ChiefOfStaffCopy.clean(todo.decisionPrompt)?.lowercased() else {
            return false
        }

        return prompt.contains("keep it active if it still matters")
            || prompt.contains("dismiss it so it stops resurfacing")
            || prompt.contains("should this older")
    }
}
