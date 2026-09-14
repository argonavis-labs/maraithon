import SwiftUI
import AssistantProgressKit

/// One task table row: checkbox, title with badges and ownership, source
/// with the assistant's offer, compact due date, and a quiet Done action.
/// Single click selects, double click or the title opens the workspace.
struct TodoRow: View {
    let todo: CompanionTodo
    let isActive: Bool
    let isMarked: Bool
    let isWorking: Bool
    let select: () -> Void
    let toggleMark: () -> Void
    let openAction: () -> Void
    let action: () -> Void

    @State private var hovering = false
    @State private var hoveringTitle = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RunnerCheckbox(isOn: isMarked, label: "Select \(todo.title)", action: toggleMark)
                .padding(.leading, Tokens.Spacing.tight)
                .padding(.top, Tokens.Spacing.roomy + Tokens.Spacing.xxsmall)
                .frame(width: Tokens.Layout.taskCheckboxColumn, alignment: .leading)

            titleCell
                .padding(.horizontal, Tokens.Spacing.tight)
                .padding(.vertical, Tokens.Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)

            sourceCell
                .padding(.horizontal, Tokens.Spacing.tight)
                .padding(.vertical, Tokens.Spacing.medium)
                .frame(width: Tokens.Layout.taskSourceColumn, alignment: .leading)

            Text(TodosCopy.compactDue(todo.dueDate))
                .font(Tokens.Typography.small)
                .foregroundStyle(TodosCopy.dueColor(todo.dueDate, active: todo.canMarkDone))
                .help(TodosCopy.dueLabel(todo.dueDate, active: todo.canMarkDone))
                .padding(.horizontal, Tokens.Spacing.tight)
                .padding(.vertical, Tokens.Spacing.medium)
                .frame(width: Tokens.Layout.taskDueColumn, alignment: .leading)

            actionCell
                .padding(.horizontal, Tokens.Spacing.tight)
                .padding(.vertical, Tokens.Spacing.medium)
                .frame(width: Tokens.Layout.taskActionColumn, alignment: .trailing)
        }
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isActive {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.hairline)
                    .fill(Tokens.Palette.selectedBar)
                    .frame(width: Tokens.Stroke.activeBar)
                    .padding(.vertical, Tokens.Spacing.small)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: Tokens.Stroke.hairline)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { openAction() }
        .onTapGesture(count: 1) { select() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isActive || isMarked { return Tokens.Palette.selected }
        return hovering ? Tokens.Palette.foreground3 : .clear
    }

    private var titleCell: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.compact) {
            FlowLayout {
                Button(action: openAction) {
                    Text(todo.title)
                        .font(Tokens.Typography.bodyMedium)
                        .lineSpacing(Tokens.Typography.titleLineSpacing)
                        .foregroundStyle(hoveringTitle ? Tokens.Palette.accent : Tokens.Palette.foreground)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
                .onHover { hoveringTitle = $0 }
                .help("Open this task and work on it with Maraithon")
                .accessibilityHint("Opens the task workspace")

                if todo.status != "open" {
                    RunnerBadge(text: TodosCopy.statusLabel(todo.status), tone: TodosCopy.statusTone(todo.status))
                }
                if todo.isTracking {
                    RunnerBadge(text: "Tracking", tone: .zinc)
                }
                if todo.needsDecision {
                    RunnerBadge(text: "Decision", tone: .indigo)
                }
                if todo.priority >= 75 {
                    RunnerBadge(text: TodosCopy.priorityLabel(todo.priority), tone: TodosCopy.priorityTone(todo.priority))
                }
            }

            if let workflow = todo.workflow, let ownerLabel = TodosCopy.ownershipLabel(todo) {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "person.2")
                        .font(Tokens.Typography.caption)
                        .accessibilityHidden(true)
                    Text(ownerLabel)
                        .foregroundStyle(todo.isOwnedBySomeoneElse ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
                    Text("·")
                    Text(workflow.label)
                }
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(ownerLabel). State: \(workflow.label)")
            }

            if let move = nextMove {
                (Text("\(TodosCopy.nextActionLabel(todo)): ").foregroundStyle(Tokens.Palette.foreground80)
                    + Text(move).foregroundStyle(Tokens.Palette.mutedForeground))
                    .font(Tokens.Typography.small)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var nextMove: String? {
        if todo.canMarkDone, let move = todo.recommendedMove { return move }
        if !todo.canMarkDone, let note = todo.resolutionNote { return note }
        if let summary = todo.summary, !summary.isEmpty { return summary }
        return nil
    }

    private var sourceCell: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.snug) {
            HStack(spacing: Tokens.Spacing.compact + 1) {
                TodoProviderMark(provider: todo.source, size: Tokens.IconSize.providerMark)
                Text(TodosCopy.sourceLabel(todo.source))
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .lineLimit(1)
            }
            if let offer = TodosCopy.agentOfferLabel(todo) {
                RunnerBadge(text: offer, tone: TodosCopy.agentOfferTone(todo), wraps: true)
            }
        }
    }

    private var actionCell: some View {
        HStack(spacing: Tokens.Spacing.small) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            Button(todo.canReopen ? "Reopen" : "Done", action: action)
                .buttonStyle(RunnerButtonStyle(.plain))
                .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))
                .help(todo.canReopen ? "Reopen this task" : "Mark this task done")
        }
        .padding(.top, Tokens.Spacing.xxsmall)
    }
}
