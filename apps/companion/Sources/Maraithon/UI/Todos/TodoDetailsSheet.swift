/// Quiet reference for a todo: status, timing, and source in key/value rows,
/// notes and source context as short sections, and the secondary status
/// actions. Opened from the workspace header; nothing here starts work.
import SwiftUI

struct TodoDetailsSheet: View {
    let store: TodoConversationStore
    let isWorking: Bool
    let changeStatus: () -> Void
    let dismissTodo: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var todo: CompanionTodo { store.todo }

    private var rows: [(label: String, value: String)] {
        var values: [(String, String)] = [("Status", TodosCopy.statusLabel(todo.status))]
        if todo.canReopen, let closed = todo.closedDate {
            values.append(("Completed", closed.formatted(date: .abbreviated, time: .shortened)))
        }
        values.append(("Source", TodosCopy.sourceLabel(todo.source)))
        if todo.canMarkDone {
            values.append(("Attention", TodosCopy.attentionLabel(todo.attentionMode)))
        }
        values.append(("Priority", TodosCopy.priorityLabel(todo.priority)))
        values.append(("Due", TodosCopy.dueLabel(todo.dueDate, active: todo.canMarkDone)))
        return values.map { (label: $0.0, value: $0.1) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details")
                    .font(Tokens.Typography.bodySemibold)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Tokens.Spacing.medium)
            RunnerHairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
                    RunnerCard {
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                                if index > 0 { RunnerHairline() }
                                RunnerKeyValueRow(label: row.label, value: row.value)
                            }
                        }
                    }
                    if let notes = todo.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                        section("Notes", notes)
                    }
                    if !todo.canMarkDone, let summary = todo.summary, !summary.isEmpty {
                        section("Original request", summary)
                    }
                    sourceContext
                    actions
                }
                .padding(Tokens.Spacing.medium)
            }
        }
        .frame(width: Tokens.TodoLayout.detailsSheetWidth, height: Tokens.TodoLayout.detailsSheetHeight)
        .background(Tokens.Palette.background)
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
            Text(text)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var sourceContext: some View {
        if let card = todo.actionCard {
            let lines = [card.whyNow, card.evidenceExcerpt, card.sourceContext]
                .compactMap { $0 }
                .filter { !$0.isEmpty && $0 != todo.summary }
            if !lines.isEmpty || card.sourceAction?.destination != nil {
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    SectionHeader("Source context")
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.foreground80)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let action = card.sourceAction, let url = action.destination {
                        Link(destination: url) {
                            Label(action.openLabel ?? "Open source", systemImage: "arrow.up.right")
                        }
                        .buttonStyle(RunnerButtonStyle(.plain))
                    }
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Tokens.Spacing.small) {
            Button(todo.canReopen ? "Reopen" : "Done", action: changeStatus)
                .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))
            if todo.canDismiss {
                Button("Dismiss") { dismissTodo() }
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .disabled(isWorking)
                    .help("Dismiss this task without completing it")
            }
            if isWorking {
                ProgressView().controlSize(.small).accessibilityLabel("Working")
            }
        }
    }
}
