import SwiftUI
import AssistantProgressKit

/// One task table row: completion checkbox, title with badges and ownership, source
/// with the assistant's offer, compact due date, and a quiet Done action.
/// The checkbox and Done action share the same persisted status change.
/// Single click selects, double click or the title opens the workspace.
struct TodoRow: View {
    let todo: CompanionTodo
    let isActive: Bool
    let isMarked: Bool
    let isWorking: Bool
    var isCompleting: Bool = false
    let select: () -> Void
    let openAction: () -> Void
    let action: () -> Void
    let ignore: () -> Void

    @State private var hovering = false
    @State private var hoveringTitle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCompleted: Bool { isCompleting || todo.status == "done" }

    var body: some View {
        if todo.isInTriage {
            TriageSwipeRow(isWorking: isWorking, background: Tokens.Palette.background,
                accept: action, ignore: ignore) { row }
        } else { row }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            RunnerCheckbox(
                isOn: todo.canReopen || isCompleting,
                label: todo.isInTriage ? "Add \(todo.title) to Todos" : (todo.canReopen ? "Reopen \(todo.title)" : "Mark \(todo.title) done"),
                action: action,
                tint: showsCompleted ? Tokens.Palette.success : Tokens.Palette.accent
            )
                .disabled(isWorking || (!todo.isInTriage && !todo.canMarkDone && !todo.canReopen))
                .help(todo.isInTriage ? "Add to Todos" : (todo.canReopen ? "Reopen this task" : "Mark this task done"))
                .accessibilityValue(isCompleting ? "Done" : TodosCopy.statusLabel(todo.status))
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
        .animation(reduceMotion ? nil : .default, value: isCompleting)
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
        .contextMenu {
            if todo.isInTriage || todo.canMarkDone || todo.canReopen {
                Button(action: action) {
                    Label(todo.isInTriage ? "Add to Todos" : (todo.canReopen ? "Reopen" : "Done"), systemImage: todo.canReopen ? "arrow.uturn.backward" : "checkmark")
                }
                .disabled(isWorking)
            }
            if todo.canDismiss {
                Button(action: ignore) {
                    Label("Ignore", systemImage: "hand.thumbsdown")
                }
                .disabled(isWorking)
                .help("Ignore this task and show fewer like it")
                .accessibilityHint("Teaches Maraithon to show fewer tasks like this")
            }
        }
        .onTapGesture(count: 2) { openAction() }
        .onTapGesture(count: 1) { select() }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .overlay {
            if !todo.isInTriage {
                TodoRowMenu(primaryTitle: todo.canReopen ? "Reopen" : "Done",
                    primaryEnabled: !isWorking && (todo.canMarkDone || todo.canReopen),
                    ignoreEnabled: !isWorking && todo.canDismiss, primary: action, ignore: ignore)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var rowBackground: Color {
        if isCompleting { return Tokens.Palette.success.opacity(0.08) }
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
                        .foregroundStyle(showsCompleted ? Tokens.Palette.mutedForeground : (hoveringTitle ? Tokens.Palette.accent : Tokens.Palette.foreground))
                        .strikethrough(showsCompleted)
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
            if isCompleting {
                Label("Done", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Tokens.Palette.success)
                    .transition(.opacity)
            } else if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
            if !isCompleting {
                Button(todo.isInTriage ? "Add" : (todo.canReopen ? "Reopen" : "Done"), action: action)
                    .buttonStyle(RunnerButtonStyle(.plain))
                    .disabled(isWorking || (!todo.isInTriage && !todo.canMarkDone && !todo.canReopen))
                    .help(todo.isInTriage ? "Add to Todos" : (todo.canReopen ? "Reopen this task" : "Mark this task done"))
            }
        }
        .padding(.top, Tokens.Spacing.xxsmall)
    }
}
