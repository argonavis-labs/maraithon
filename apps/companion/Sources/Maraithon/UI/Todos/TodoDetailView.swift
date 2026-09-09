import SwiftUI
import AppKit

/// Inspector for a Todo. Completed work leads with its recorded resolution,
/// while active work retains its next action and source context.
struct TodoDetailView: View {
    @State private var selectedSection = "Summary"
    let todo: CompanionTodo?
    let isWorking: Bool
    let isLoadingDetails: Bool
    let detailError: String?
    let primaryAction: () -> Void
    let dismissAction: () -> Void
    let retryDetails: () -> Void

    var body: some View {
        if let todo {
            Form {
                Picker("Todo section", selection: $selectedSection) {
                    Text("Summary").tag("Summary")
                    Text("Details").tag("Details")
                }.pickerStyle(.segmented)
                Section {
                    HStack {
                        TodoProviderMark(provider: todo.source)
                        Text(TodosCopy.sourceLabel(todo.source)).foregroundStyle(.secondary)
                    }
                    Text(todo.title).font(.title2.weight(.semibold))
                    if selectedSection == "Summary", todo.canMarkDone {
                        Text(todo.brief?.summary ?? todo.summary ?? todo.recommendedMove ?? "Preparing your summary.")
                            .textSelection(.enabled)
                    }
                }
                if selectedSection == "Summary" {
                    TodoSourceActionsView(todo: todo).id(todo.id)
                    if isLoadingDetails { ProgressView("Preparing summary").controlSize(.small) }
                    if let detailError {
                        Label(detailError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        Button("Retry", action: retryDetails)
                    }
                }
                if !todo.canMarkDone, let note = todo.resolutionNote {
                    Section(todo.canReopen ? "Completion" : "Resolution") {
                        Text(note).textSelection(.enabled)
                    }
                }

                if selectedSection == "Details" {
                Section("Details") {
                    LabeledContent("Status", value: TodosCopy.statusLabel(todo.status))
                    if todo.canReopen, let closedDate = todo.closedDate {
                        LabeledContent("Completed", value: closedDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("Source", value: TodosCopy.sourceLabel(todo.source))
                    if todo.canMarkDone {
                        LabeledContent("Attention", value: TodosCopy.attentionLabel(todo.attentionMode))
                    }
                    LabeledContent("Priority", value: TodosCopy.priorityLabel(todo.priority))
                    LabeledContent("Due", value: TodosCopy.dueLabel(todo.dueDate, active: todo.canMarkDone))
                }

                if !todo.canMarkDone, let summary = todo.summary, !summary.isEmpty {
                    Section("Original request") {
                        Text(summary).textSelection(.enabled)
                    }
                }

                if let notes = todo.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Notes") {
                        Text(notes).textSelection(.enabled)
                    }
                }

                sourceContext(for: todo)
                if let brief = todo.brief {
                    if let situation = brief.situation { Section("Context") { Text(situation).textSelection(.enabled) } }
                    if let recommendation = brief.recommendation { Section("Next move") { Text(recommendation) } }
                    if let steps = brief.steps, !steps.isEmpty { Section("Steps") { ForEach(Array(steps.enumerated()), id: \.offset) { _, step in Text(step) } } }
                    if let questions = brief.openQuestions, !questions.isEmpty { Section("Open questions") { ForEach(Array(questions.enumerated()), id: \.offset) { _, question in Text(question) } } }
                }
                }

                Section("Actions") {
                    HStack(spacing: Tokens.Spacing.small) {
                        Button {
                            primaryAction()
                        } label: {
                            Label(primaryActionTitle(todo), systemImage: primaryActionIcon(todo))
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isWorking || (!todo.canMarkDone && !todo.canReopen))

                        if todo.canDismiss {
                            Button {
                                dismissAction()
                            } label: {
                                Label("Dismiss", systemImage: "archivebox")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isWorking)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: todo.id) { _, _ in selectedSection = "Summary" }
        } else {
            ContentUnavailableView(
                "No Todo selected",
                systemImage: "checklist",
                description: Text("Choose a Todo to inspect its next move and source context.")
            )
        }
    }

    @ViewBuilder
    private func sourceContext(for todo: CompanionTodo) -> some View {
        if let card = todo.actionCard {
            if todo.canMarkDone || card.sourceAction?.destination != nil {
                Section(todo.canMarkDone ? "Source context" : "Original source") {
                    if todo.canMarkDone {
                        if let whyNow = card.whyNow, !whyNow.isEmpty {
                            Text(whyNow)
                        }
                        if let excerpt = card.evidenceExcerpt, !excerpt.isEmpty, excerpt != todo.summary {
                            Text(excerpt).textSelection(.enabled)
                        }
                        if let source = card.sourceContext, !source.isEmpty {
                            Text(source).foregroundStyle(.secondary)
                        }
                    }
                    if let action = card.sourceAction, let destination = action.destination {
                        Link(destination: destination) {
                            Label(action.openLabel ?? "Open source", systemImage: "arrow.up.right")
                        }
                    }
                }
            }
        } else if isLoadingDetails {
            Section {
                ProgressView("Loading source context").controlSize(.small)
            }
        } else if let detailError {
            Section("Source context") {
                Label(detailError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(StatusTone.attention.color)
                Button("Retry", action: retryDetails)
            }
        }
    }

    private func primaryActionTitle(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "Reopen" : "Done"
    }

    private func primaryActionIcon(_ todo: CompanionTodo) -> String {
        todo.canReopen ? "arrow.uturn.backward" : "checkmark"
    }
}
