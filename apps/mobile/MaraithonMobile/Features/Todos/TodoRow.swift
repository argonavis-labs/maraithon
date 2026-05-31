import SwiftUI

struct TodoRow: View {
    let todo: TodoItem
    let onToggle: () -> Void

    private var decisionContext: TodoDecisionContext {
        TodoDecisionContext(todo: todo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(todo.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(todo.isCompleted ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 6) {
                Text(todo.title)
                    .font(.headline)
                    .strikethrough(todo.isCompleted)
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)

                if let rowContext = decisionContext.rowContext {
                    Text(rowContext)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let rowReason = decisionContext.rowReason {
                    Text(rowReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let nextAction = decisionContext.rowMove {
                    Label(nextAction, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let signal = TodoDecisionSignals.signalPillTitle(for: todo) {
                        StatusPill(title: signal, tint: .purple)
                    }

                    StatusPill(title: todo.priority.title, tint: todo.priority.tint)

                    if let dueDate = todo.dueDate {
                        Label(dueText(for: dueDate), systemImage: dueSystemImage(for: dueDate))
                            .font(.caption)
                            .foregroundStyle(dueTint(for: dueDate))
                            .lineLimit(1)
                    }

                    if let contact = todo.contact {
                        Label(contact.name, systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func dueText(for dueDate: Date) -> String {
        TodoRowCopy.dueText(for: todo, dueDate: dueDate)
    }

    private func dueSystemImage(for dueDate: Date) -> String {
        guard !todo.isCompleted else { return "calendar" }
        let calendar = Calendar.current
        if dueDate < Date(), !calendar.isDateInToday(dueDate) {
            return "clock.badge.exclamationmark"
        }
        if calendar.isDateInToday(dueDate) {
            return "calendar.badge.clock"
        }
        return "calendar"
    }

    private func dueTint(for dueDate: Date) -> Color {
        guard !todo.isCompleted else { return .secondary }
        let calendar = Calendar.current
        if dueDate < Date(), !calendar.isDateInToday(dueDate) {
            return .orange
        }
        if calendar.isDateInToday(dueDate) {
            return .blue
        }
        return .secondary
    }
}

struct TodoDecisionContext: Equatable {
    let contextSummary: String?
    let decisionPrompt: String?
    let notesContext: String?
    let whyNow: String?
    let sourceContext: String?
    let preparedMove: String?
    let rowMove: String?
    let evidence: String?

    init(todo: TodoItem) {
        let title = Self.cleanedText(todo.title)
        let notes = Self.cleanedText(todo.notes)
        let nextAction = Self.cleanedText(todo.displayNextAction)
        let contextSummary = Self.uniqueText(
            todo.decisionContextSummary,
            excluding: [title, notes, nextAction]
        )
        let decisionPrompt = Self.uniqueText(
            todo.decisionPrompt,
            excluding: [title, notes, nextAction, contextSummary]
        )
        let preparedMove = Self.uniqueText(
            todo.nextBestAction,
            excluding: [title, notes, nextAction, contextSummary, decisionPrompt]
        )

        self.contextSummary = contextSummary
        self.decisionPrompt = decisionPrompt
        self.notesContext = Self.uniqueText(notes, excluding: [title, nextAction, contextSummary, decisionPrompt])
        self.whyNow = Self.cleanedText(todo.whyNow)
        self.sourceContext = Self.cleanedText(todo.sourceContext)
        self.preparedMove = preparedMove
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
            evidence != nil
    }

    private static func uniqueText(_ value: String?, excluding values: [String?]) -> String? {
        guard let cleaned = cleanedText(value) else { return nil }
        let isDuplicate = values.contains { other in
            guard let other = cleanedText(other) else { return false }
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

        if dueDate < now, !calendar.isDate(dueDate, inSameDayAs: now) {
            return "Past due \(AppFormatters.relativeString(for: dueDate, relativeTo: now))"
        }

        if calendar.isDate(dueDate, inSameDayAs: now) {
            return "Today"
        }

        return dueDate.formatted(AppFormatters.shortDate)
    }
}
