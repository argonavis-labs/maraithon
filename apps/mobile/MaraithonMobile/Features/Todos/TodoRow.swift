import SwiftUI

struct TodoRow: View {
    let todo: TodoItem
    let onToggle: () -> Void

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

                if !todo.notes.isEmpty {
                    Text(todo.notes)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if let nextAction = todo.displayNextAction {
                    Label(nextAction, systemImage: "arrow.turn.down.right")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
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
