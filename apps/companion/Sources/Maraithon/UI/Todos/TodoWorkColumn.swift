/// The work column: Maraithon's read, the next action (at most two cards, one
/// open), and the people involved as chips that open their details for confirmation.
import SwiftUI
import AssistantProgressKit

struct TodoWorkColumn: View {
    let store: TodoConversationStore
    @State private var person: LifeWorkContext.PersonReference?

    private var todo: CompanionTodo { store.todo }
    private var brief: CompanionTodoBrief? { todo.delegation == nil ? store.todo.brief : nil }
    private var plan: TodoActionPlan {
        TodoActionPlan.make(todo: store.todo, messages: store.thread?.messages ?? [],
                            preferredReviewID: store.preferredReviewID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
            read
            if brief == nil && todo.delegation == nil && ["triage", "open", "snoozed"].contains(todo.status) {
                ProgressView("Preparing people and next steps…")
                    .controlSize(.small)
                    .font(Tokens.Typography.small)
            }
            TodoDelegationPanel(todoID: todo.id, summary: todo.delegation,
                canDelegate: todo.canDelegate == true, proposal: todo.delegationProposal, request: store.delegationRequest,
                refreshTodo: { await store.refreshTodo() })
                .id(todo.id)
            if todo.delegation == nil && plan.primary != nil { nextAction }
            people
            TodoActivityView(entries: store.thread?.todoTimeline ?? [])
        }
        .sheet(item: $person) { reference in
            LifeContextSheet(person: reference, saved: { await store.refreshTodo() })
        }
        .padding(.horizontal, Tokens.Spacing.page)
        .padding(.vertical, Tokens.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var read: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.snug) {
            if let summary = brief?.summary ?? todo.summary, !summary.isEmpty {
                Text(summary)
                    .font(Tokens.Typography.body)
                    .lineSpacing(Tokens.TodoLayout.proseLineSpacing)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if todo.canMarkDone {
                HStack(spacing: Tokens.Spacing.small) {
                    ProgressView().controlSize(.small)
                    Text("Preparing your summary…")
                }
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .accessibilityElement(children: .combine)
            }
            if !todo.canMarkDone, let note = todo.resolutionNote {
                (Text(todo.canReopen ? "Completed: " : "Resolved: ").foregroundStyle(Tokens.Palette.foreground)
                    + Text(note).foregroundStyle(Tokens.Palette.mutedForeground))
                    .font(Tokens.Typography.small)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if todo.canMarkDone, let doneWhen = brief?.doneWhen, !doneWhen.isEmpty {
                (Text("Done when: ").foregroundStyle(Tokens.Palette.foreground)
                    + Text(doneWhen).foregroundStyle(Tokens.Palette.mutedForeground))
                    .font(Tokens.Typography.small)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if todo.canMarkDone, let questions = brief?.openQuestions, !questions.isEmpty {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                    Text("Your decision")
                        .font(Tokens.Typography.bodyMedium)
                        .foregroundStyle(Tokens.Palette.foreground)
                    ForEach(questions, id: \.self) { question in
                        Text(question)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.foreground80)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Tokens.Spacing.xsmall)
            }
            if let source = todo.actionCard?.sourceAction, let url = source.destination {
                Link(destination: url) {
                    Label(source.openLabel ?? "Open original", systemImage: "arrow.up.right")
                }
                .buttonStyle(RunnerButtonStyle(.plain))
                .padding(.top, Tokens.Spacing.xxsmall)
            }
        }
        .frame(maxWidth: Tokens.TodoLayout.readMaxWidth, alignment: .leading)
    }

    private var nextAction: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            SectionHeader("Next action")
            if let primary = plan.primary {
                TodoActionSlotView(slot: primary, store: store, isPrimary: true)
            }
            if let secondary = plan.secondary {
                TodoActionSlotView(slot: secondary, store: store, isPrimary: false)
            }
        }
        .frame(maxWidth: Tokens.TodoLayout.cardMaxWidth, alignment: .leading)
        .id("todo-review")
    }

    @ViewBuilder private var people: some View {
        if let people = brief?.people, !people.isEmpty {
            VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                SectionHeader("People")
                FlowLayout {
                    ForEach(people) { person in
                        TodoPersonChip(person: person) {
                            self.person = .init(todoID: todo.id, reference: person.id)
                        }
                    }
                }
            }
            .frame(maxWidth: Tokens.TodoLayout.cardMaxWidth, alignment: .leading)
        }
    }
}

/// One person from the brief. Clicking opens their details for confirmation;
/// the relationship and context show as help text so the row stays quiet.
private struct TodoPersonChip: View {
    let person: CompanionTodoWorkspace.Person
    let openDetails: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: openDetails) {
            HStack(spacing: Tokens.Spacing.compact) {
                Image(systemName: "person.crop.circle")
                    .font(Tokens.Typography.caption)
                    .accessibilityHidden(true)
                Text(person.name)
                    .font(Tokens.Typography.small)
                    .lineLimit(1)
                if let relationship = person.relationship, !relationship.isEmpty {
                    Text(relationship)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .lineLimit(1)
                }
            }
            .foregroundStyle(hovering ? Tokens.Palette.foreground : Tokens.Palette.foreground80)
            .padding(.horizontal, Tokens.Spacing.snug)
            .padding(.vertical, Tokens.Spacing.xsmall)
            .background(hovering ? Tokens.Palette.foreground3 : .clear, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                    .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(person.context ?? "Review and confirm details for \(person.name)")
        .accessibilityLabel("Review details for \(person.name)")
    }
}
