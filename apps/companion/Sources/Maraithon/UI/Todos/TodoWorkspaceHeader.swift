/// Workspace header: a way back to the list, the title, one meta line, the
/// owner when a workflow exists, and the two actions that matter (Details,
/// Done). Everything else lives in the details sheet or the conversation.
import SwiftUI

struct TodoWorkspaceHeader: View {
    let store: TodoConversationStore
    let isChangingStatus: Bool
    var isCompleting: Bool = false
    let back: () -> Void
    let changeStatus: () -> Void
    let ignore: () -> Void
    let showDetails: () -> Void
    let editWorkflow: () -> Void

    private var todo: CompanionTodo { store.todo }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCompleted: Bool { isCompleting || todo.status == "done" }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            Button(action: back) {
                Label("Tasks", systemImage: "chevron.left")
            }
            .buttonStyle(RunnerButtonStyle(.plain))
            .help("Back to the task list")

            HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
                Text(todo.title)
                    .font(Tokens.Typography.pageTitle)
                    .tracking(Tokens.Typography.pageTitleTracking)
                    .foregroundStyle(showsCompleted ? Tokens.Palette.mutedForeground : Tokens.Palette.foreground)
                    .strikethrough(showsCompleted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Tokens.Spacing.medium)
                HStack(spacing: Tokens.Spacing.small) {
                    Button("Details", action: showDetails)
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    if showsCompleted {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Tokens.Palette.success)
                            .transition(.opacity)
                    }
                    if todo.isInTriage {
                        Button("Ignore", action: ignore)
                            .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                            .disabled(isChangingStatus)
                    }
                    if !isCompleting {
                        Button(todo.isInTriage ? "Add to Todos" : (todo.canReopen ? "Reopen" : "Done"), action: changeStatus)
                            .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                            .disabled(isChangingStatus || (!todo.isInTriage && !todo.canMarkDone && !todo.canReopen))
                            .help(todo.isInTriage ? "Add to Todos" : (todo.canReopen ? "Reopen this task" : "Mark this task done"))
                    }
                }
                .padding(.top, Tokens.Spacing.xsmall)
            }

            HStack(spacing: Tokens.Spacing.compact) {
                TodoProviderMark(provider: todo.source, size: Tokens.IconSize.providerMark)
                Text(TodosCopy.sourceLabel(todo.source))
                Text("·")
                Text(todo.workflow?.label ?? TodosCopy.statusLabel(todo.status))
                Text("·")
                Text(TodosCopy.dueLabel(todo.dueDate, active: todo.canMarkDone))
                    .foregroundStyle(TodosCopy.dueColor(todo.dueDate, active: todo.canMarkDone))
                if todo.needsDecision {
                    RunnerBadge(text: "Decision", tone: .indigo)
                }
            }
            .font(Tokens.Typography.small)
            .foregroundStyle(Tokens.Palette.mutedForeground)

            if let workflow = todo.workflow, !todo.isInTriage {
                HStack(spacing: Tokens.Spacing.compact) {
                    Image(systemName: "person.2")
                        .font(Tokens.Typography.caption)
                        .accessibilityHidden(true)
                    Text(workflow.ballLabel)
                    Text("·")
                    Text(workflow.outcome)
                        .lineLimit(1)
                    Button("Change", action: editWorkflow)
                        .buttonStyle(RunnerButtonStyle(.plain))
                        .help("Change the state or owner")
                }
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.horizontal, Tokens.Spacing.page)
        .padding(.top, Tokens.Spacing.roomy)
        .padding(.bottom, Tokens.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .default, value: showsCompleted)
    }
}
