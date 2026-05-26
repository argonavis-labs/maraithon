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
    @State private var priority: TodoPriority = .medium
    @State private var hasDueDate = false
    @State private var dueDate = Date()
    @State private var selectedContactID: UUID?
    @State private var errorMessage: String?
    @State private var isSaving = false

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
        _priority = State(initialValue: todo?.priority ?? .medium)
        _hasDueDate = State(initialValue: todo?.dueDate != nil || suggestedDueDate != nil)
        _dueDate = State(initialValue: todo?.dueDate ?? suggestedDueDate ?? Date())
        _selectedContactID = State(initialValue: todo?.contact?.id ?? preselectedContact?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Title", text: $title)
                        .accessibilityIdentifier("todo-title-field")
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("todo-notes-field")

                    Picker("Priority", selection: $priority) {
                        ForEach(TodoPriority.allCases) { priority in
                            Label(priority.title, systemImage: priority.symbolName)
                                .tag(priority)
                        }
                    }
                }

                Section("Schedule") {
                    Toggle("Due Date", isOn: $hasDueDate)
                    if hasDueDate {
                        DatePicker("Due", selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                    }
                }

                Section("People Link") {
                    Picker("Person", selection: $selectedContactID) {
                        Text("None").tag(Optional<UUID>.none)
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
            .navigationTitle(todo == nil ? "New Todo" : "Edit Todo")
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

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let contact = contacts.first { $0.id == selectedContactID }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ProductionDataSync.todoPayload(
            title: trimmedTitle,
            notes: trimmedNotes,
            priority: priority,
            dueDate: hasDueDate ? dueDate : nil,
            isCompleted: todo?.isCompleted ?? false
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
                todo.priority = priority
                todo.dueDate = hasDueDate ? dueDate : nil
                todo.contact = contact
            } else {
                let todo = TodoItem(
                    title: trimmedTitle,
                    notes: trimmedNotes,
                    priority: priority,
                    dueDate: hasDueDate ? dueDate : nil,
                    contact: contact
                )
                modelContext.insert(todo)
            }

            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
