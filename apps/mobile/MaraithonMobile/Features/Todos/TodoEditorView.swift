import SwiftData
import SwiftUI

struct TodoEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \CRMContact.name) private var contacts: [CRMContact]

    private let todo: TodoItem?
    @State private var title = ""
    @State private var notes = ""
    @State private var nextAction = ""
    @State private var priority: TodoPriority = .medium
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var selectedContactID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

    private var decisionContext: TodoDecisionContext? {
        guard let todo else { return nil }
        let context = TodoDecisionContext(todo: todo)
        return context.hasChiefOfStaffContext ? context : nil
    }

    init(
        todo: TodoItem? = nil,
        preselectedContact: CRMContact? = nil,
        suggestedTitle: String? = nil,
        suggestedNotes: String = "",
        suggestedDueDate: Date? = nil
    ) {
        self.todo = todo
        _title = State(initialValue: todo?.title ?? suggestedTitle ?? "")
        _notes = State(initialValue: todo?.notes ?? suggestedNotes)
        _nextAction = State(initialValue: Self.initialNextAction(for: todo))
        _priority = State(initialValue: todo?.priority ?? .medium)
        _hasDueDate = State(initialValue: todo?.dueDate != nil || suggestedDueDate != nil)
        _dueDate = State(initialValue: todo?.dueDate ?? suggestedDueDate ?? Date())
        _selectedContactID = State(initialValue: todo?.contact?.id ?? preselectedContact?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(TodoEditorCopy.commitmentSectionTitle) {
                    TextField(TodoEditorCopy.titlePlaceholder, text: $title)
                        .accessibilityIdentifier("todo-title-field")
                    TextField(TodoEditorCopy.notesPlaceholder, text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("todo-notes-field")
                    TextField(TodoEditorCopy.nextActionPlaceholder, text: $nextAction, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityIdentifier("todo-next-action-field")

                    Picker(TodoEditorCopy.urgencyPickerTitle, selection: $priority) {
                        ForEach(TodoPriority.allCases) { priority in
                            Label(priority.title, systemImage: priority.symbolName)
                                .tag(priority)
                        }
                    }
                }

                if let decisionContext {
                    Section(TodoEditorCopy.decisionContextSectionTitle) {
                        if let contextSummary = decisionContext.contextSummary {
                            contextLine(
                                label: TodoEditorCopy.contextSummaryLabel,
                                value: contextSummary
                            )
                        }

                        if let decisionPrompt = decisionContext.decisionPrompt {
                            contextLine(
                                label: TodoEditorCopy.decisionPromptLabel,
                                value: decisionPrompt
                            )
                        }

                        if let whyNow = decisionContext.whyNow {
                            contextLine(
                                label: TodoEditorCopy.whyNowLabel,
                                value: whyNow
                            )
                        }

                        if let sourceContext = decisionContext.sourceContext {
                            contextLine(
                                label: TodoEditorCopy.sourceContextLabel,
                                value: sourceContext
                            )
                        }

                        if let preparedMove = decisionContext.preparedMove {
                            contextLine(
                                label: TodoEditorCopy.preparedMoveLabel,
                                value: preparedMove
                            )
                        }

                        if let evidence = decisionContext.evidence {
                            contextLine(
                                label: TodoEditorCopy.evidenceLabel,
                                value: evidence
                            )
                        }
                    }
                }

                Section(TodoEditorCopy.timingSectionTitle) {
                    Toggle(TodoEditorCopy.dueDateToggleTitle, isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker(TodoEditorCopy.dueDatePickerTitle, selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section(TodoEditorCopy.relatedPersonSectionTitle) {
                    Picker(TodoEditorCopy.personPickerTitle, selection: $selectedContactID) {
                        Text(TodoEditorCopy.noPersonLabel).tag(Optional<UUID>.none)
                        ForEach(contacts) { contact in
                            Text(contact.name).tag(Optional(contact.id))
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(todo == nil ? TodoEditorCopy.newNavigationTitle : TodoEditorCopy.editNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await save() }
                    }
                    .accessibilityIdentifier("todo-save-button")
                    .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func contextLine(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let contact = contacts.first { $0.id == selectedContactID }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNextAction = nextAction.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextAction = ProductionDataSync.nextActionForTodoPayload(
            title: trimmedTitle,
            notes: trimmedNotes,
            requestedNextAction: trimmedNextAction,
            existingTitle: todo?.title,
            existingNotes: todo?.notes,
            existingNextAction: todo?.nextAction
        )
        let payload = ProductionDataSync.todoPayload(
            title: trimmedTitle,
            notes: trimmedNotes,
            priority: priority,
            dueDate: hasDueDate ? dueDate : nil,
            isCompleted: todo?.isCompleted ?? false,
            nextAction: nextAction
        )

        do {
            if let sessionToken = sessionStore.user?.sessionToken {
                if let todo {
                    let remote = try await MobileAPIClient().updateTodo(
                        sessionToken: sessionToken,
                        id: todo.id,
                        payload: payload
                    )
                    ProductionDataSync.apply(remote, to: todo)
                    todo.contact = contact
                } else {
                    let remote = try await MobileAPIClient().createTodo(
                        sessionToken: sessionToken,
                        payload: payload
                    )
                    guard let id = UUID(uuidString: remote.id) else {
                        throw MobileAPIError.invalidResponse
                    }
                    let todo = ProductionDataSync.todo(from: remote, id: id)
                    todo.contact = contact
                    modelContext.insert(todo)
                }
            } else if let todo {
                todo.title = trimmedTitle
                todo.notes = trimmedNotes
                todo.nextAction = nextAction
                todo.priority = priority
                todo.dueDate = hasDueDate ? dueDate : nil
                todo.contact = contact
            } else {
                let todo = TodoItem(
                    title: trimmedTitle,
                    notes: trimmedNotes,
                    nextAction: nextAction,
                    priority: priority,
                    dueDate: hasDueDate ? dueDate : nil,
                    contact: contact
                )
                modelContext.insert(todo)
            }

            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }

    private static func initialNextAction(for todo: TodoItem?) -> String {
        todo?.displayNextAction ?? ""
    }
}

enum TodoEditorCopy {
    static let commitmentSectionTitle = "Commitment"
    static let titlePlaceholder = "What needs to happen"
    static let notesPlaceholder = "Context"
    static let nextActionPlaceholder = "Next move"
    static let decisionContextSectionTitle = "Decision context"
    static let contextSummaryLabel = "Who and context"
    static let decisionPromptLabel = "Decision"
    static let whyNowLabel = "Why now"
    static let sourceContextLabel = "Context used"
    static let preparedMoveLabel = "Prepared move"
    static let evidenceLabel = "Evidence"
    static let urgencyPickerTitle = "Urgency"
    static let timingSectionTitle = "Timing"
    static let dueDateToggleTitle = "Add due date"
    static let dueDatePickerTitle = "Due"
    static let relatedPersonSectionTitle = "Related person"
    static let personPickerTitle = "Person"
    static let noPersonLabel = "No one linked"
    static let newNavigationTitle = "New work item"
    static let editNavigationTitle = "Edit work item"

    static var visibleLabels: [String] {
        [
            commitmentSectionTitle,
            titlePlaceholder,
            notesPlaceholder,
            nextActionPlaceholder,
            decisionContextSectionTitle,
            contextSummaryLabel,
            decisionPromptLabel,
            whyNowLabel,
            sourceContextLabel,
            preparedMoveLabel,
            evidenceLabel,
            urgencyPickerTitle,
            timingSectionTitle,
            dueDateToggleTitle,
            dueDatePickerTitle,
            relatedPersonSectionTitle,
            personPickerTitle,
            noPersonLabel,
            newNavigationTitle,
            editNavigationTitle
        ]
    }
}
