import SwiftUI
import AssistantProgressKit

struct TodoWorkspaceHeader: View {
    let todo: TodoItem
    let summary: String
    let actionsDisabled: Bool
    let isUpdating: Bool
    var isCompleting: Bool = false
    let send: (String) -> Void
    let complete: () -> Void
    let accept: () -> Void
    let ignore: () -> Void
    let reopen: () -> Void
    let showPeople: () -> Void
    let showWorkflow: () -> Void
    let sourceSend: (String, String?) async throws -> Void
    @State private var showsFullSummary = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsCompleted: Bool { todo.isCompleted || isCompleting }

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
            sourceRow
            titleBlock
            summarySection

            if showsCompleted {
                completedActions
            } else if todo.isInTriage {
                TriageTodoActions(addTitle: "Add to Todos", complete: complete, accept: accept, ignore: ignore)
                    .disabled(isUpdating)
            } else if todo.isActive && todo.delegation == nil {
                activeActions
            }

            DisclosureGroup("Task details") {
                VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
                    if let workflow = todo.workflow, !todo.isInTriage {
                        TodoLabeledLine(label: "Outcome:", text: workflow.outcome)
                        if let next = workflow.nextAction {
                            TodoLabeledLine(label: "Next:", text: next, textColor: Runner.Palette.foreground)
                        }
                    }
                    if todo.isActive && todo.delegation == nil {
                        if let outcome = todo.todoBrief?.doneWhen {
                            TodoLabeledLine(label: "Done when:", text: outcome)
                                .textSelection(.enabled)
                        }
                        decisionSection
                        suggestedActionsSection
                    }

                    if todo.delegation == nil, let action = todo.sourceAction {
                        DisclosureGroup {
                            SourceActionCardView(action: action, showsContext: false, onSend: sourceSend)
                                .padding(.top, Runner.Spacing.small)
                        } label: {
                            Label("Source and suggested reply", systemImage: "text.bubble")
                                .font(Runner.Typography.smallMedium)
                                .foregroundStyle(Runner.Palette.foreground)
                        }
                    }
                }
                .padding(.top, Runner.Spacing.small)
            }
            .font(Runner.Typography.small)

            RunnerHairline()
            RunnerSectionLabel("Conversation")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Runner.Spacing.xsmall)
        .padding(.top, Runner.Spacing.small)
        .animation(reduceMotion ? nil : .default, value: showsCompleted)
    }

    private var sourceRow: some View {
        HStack(spacing: Runner.Spacing.small) {
            ProviderMark(provider: todo.sourceProviderLabel?.lowercased() ?? todo.sourceProvider ?? todo.sourceSystem ?? "")
            Text(todo.sourceProviderLabel ?? todo.sourceSystem ?? "Todo")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
            Spacer()
            if let people = todo.todoBrief?.people, !people.isEmpty {
                Button(action: showPeople) {
                    Label("\(people.count) people", systemImage: "person.2")
                }
                .buttonStyle(RunnerButtonStyle(.plain, compact: true))
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            Text(todo.title)
                .font(Runner.Typography.pageTitle)
                .tracking(Runner.Typography.pageTitleTracking)
                .foregroundStyle(showsCompleted ? Runner.Palette.mutedForeground : Runner.Palette.foreground)
                .strikethrough(showsCompleted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            let badges = TodoBadges.badges(for: todo)
            if !badges.isEmpty {
                TodoBadgeRow(badges: badges)
            }

            if let workflow = todo.workflow {
                HStack(alignment: .firstTextBaseline, spacing: Runner.Spacing.small) {
                    TodoOwnershipLine(workflow: workflow)
                    Spacer(minLength: Runner.Spacing.small)
                    Button("Change", action: showWorkflow)
                        .buttonStyle(RunnerButtonStyle(.plain, compact: true))
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            RunnerSectionLabel("Summary")
            RunnerCard {
                VStack(alignment: .leading, spacing: Runner.Spacing.compact) {
                    Text(summary)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.foreground80)
                        .lineLimit(showsFullSummary ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if summary.count > 150 {
                        Button(showsFullSummary ? "Less context" : "More context") { showsFullSummary.toggle() }
                            .buttonStyle(RunnerButtonStyle(.plain, compact: true))
                    }
                }
                .runnerCardRow()
            }
        }
    }

    private var activeActions: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            HStack(spacing: Runner.Spacing.small) {
                Button("Mark done", systemImage: "checkmark.circle", action: complete)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .disabled(isUpdating)
                if let call = todo.todoBrief?.call, let url = call.url {
                    Link(destination: url) { Label("Call " + call.label, systemImage: "phone") }
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                }
            }
        }
    }

    private var completedActions: some View {
        HStack(spacing: Runner.Spacing.tight) {
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(Runner.Typography.smallMedium)
                .foregroundStyle(Runner.Palette.successText)
            if !isCompleting {
                Button("Reopen", action: reopen)
                    .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                    .disabled(isUpdating)
            }
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var decisionSection: some View {
        if let questions = todo.todoBrief?.openQuestions, !questions.isEmpty {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                RunnerSectionLabel("Your decision")
                RunnerCard {
                    ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                        if index > 0 { RunnerHairline() }
                        Text(question)
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .runnerCardRow()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var suggestedActionsSection: some View {
        if let actions = todo.todoBrief?.suggestedActions, !actions.isEmpty {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                RunnerSectionLabel("Suggested next actions")
                RunnerCard {
                    ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                        if index > 0 { RunnerHairline() }
                        Button { send(action.request) } label: {
                            HStack(spacing: Runner.Spacing.snug) {
                                ProviderMark(provider: action.provider)
                                Text(action.label)
                                    .font(Runner.Typography.small)
                                    .foregroundStyle(Runner.Palette.foreground)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: Runner.Spacing.small)
                                Image(systemName: "chevron.right")
                                    .font(Runner.Typography.caption)
                                    .foregroundStyle(Runner.Palette.mutedForeground)
                                    .accessibilityHidden(true)
                            }
                            .runnerCardRow()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(actionsDisabled)
                        .accessibilityIdentifier("todo-next-action-\(action.id)")
                    }
                }
            }
        }
    }
}
