import SwiftData
import SwiftUI

struct ContactDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Bindable var contact: CRMContact
    @State private var isEditingContact = false
    @State private var isCreatingFollowUp = false
    @State private var editingTodo: TodoItem?
    @State private var actionErrorMessage: String?

    var body: some View {
        Form {
            if let actionErrorMessage {
                Section {
                    SyncIssueBanner(
                        title: ContactDetailCopy.actionWarningTitle,
                        message: actionErrorMessage,
                        buttonTitle: nil,
                        retry: nil,
                        dismissAccessibilityLabel: ContactDetailCopy.dismissActionWarningAccessibilityLabel,
                        dismiss: { self.actionErrorMessage = nil }
                    )
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                careRecommendation
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(contactContext)
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    HStack {
                        StatusPill(title: contact.status.title, tint: contact.status.tint)
                        StatusPill(title: contact.dealStage.title, tint: contact.dealStage.tint)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(ContactDetailCopy.contactDetailsSectionTitle) {
                if !contact.email.isEmpty {
                    LabeledContent("Email", value: contact.email)
                }
                if !contact.phone.isEmpty {
                    LabeledContent("Phone", value: contact.phone)
                }
                if let lastContactedAt = contact.lastContactedAt {
                    LabeledContent(ContactDetailCopy.lastContactedLabel, value: AppFormatters.relativeString(for: lastContactedAt))
                }
            }

            Section(ContactDetailCopy.relationshipSectionTitle) {
                Picker(
                    ContactDetailCopy.statusPickerTitle,
                    selection: Binding(
                        get: { contact.status },
                        set: {
                            contact.status = $0
                            save()
                        }
                    )
                ) {
                    ForEach(ContactStatus.allCases) { status in
                        Text(status.title).tag(status)
                    }
                }

                Picker(
                    ContactDetailCopy.circlePickerTitle,
                    selection: Binding(
                        get: { contact.dealStage },
                        set: {
                            contact.dealStage = $0
                            save()
                        }
                    )
                ) {
                    ForEach(DealStage.allCases) { stage in
                        Text(stage.title).tag(stage)
                    }
                }
            }

            Section(ContactDetailCopy.notesSectionTitle) {
                TextField(ContactDetailCopy.notesPlaceholder, text: $contact.notes, axis: .vertical)
                    .lineLimit(5...10)
                    .onSubmit(save)
            }

            if !relatedWork.isEmpty {
                Section(ContactDetailCopy.relatedWorkSectionTitle) {
                    ForEach(relatedWork) { todo in
                        Button {
                            editingTodo = todo
                        } label: {
                            ContactLinkedWorkRow(todo: todo)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            if !todo.isCompleted {
                                Button {
                                    completeLinkedWork(todo)
                                } label: {
                                    Label(
                                        ContactDetailCopy.completeWorkActionLabel,
                                        systemImage: "checkmark.circle"
                                    )
                                }
                                .tint(.green)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                dismissLinkedWork(todo)
                            } label: {
                                Label(
                                    ContactDetailCopy.dismissWorkActionLabel,
                                    systemImage: "trash"
                                )
                            }

                            Button {
                                editingTodo = todo
                            } label: {
                                Label(ContactDetailCopy.editWorkActionLabel, systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle(contact.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isEditingContact = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit person")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    markContacted()
                } label: {
                    Image(systemName: "phone.arrow.up.right")
                }
                .accessibilityLabel(ContactDetailCopy.markContactedAccessibilityLabel)
            }
        }
        .sheet(isPresented: $isEditingContact) {
            ContactEditorView(contact: contact)
        }
        .sheet(isPresented: $isCreatingFollowUp) {
            TodoEditorView(
                preselectedContact: contact,
                suggestedTitle: "Follow up with \(contact.name)",
                suggestedNotes: followUpNotes,
                suggestedDueDate: followUpDueDate
            )
        }
        .sheet(item: $editingTodo) { todo in
            TodoEditorView(todo: todo)
        }
    }

    private var careRecommendation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(careSummary.title)
                        .font(.headline)
                    Text(careSummary.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: careSummary.systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(careTint)
                    .frame(width: 34, height: 34)
                    .background(careTint.opacity(0.12), in: Circle())
            }

            VStack(spacing: 1) {
                CommandRow(
                    title: careSummary.actionTitle,
                    subtitle: ContactDetailCopy.logContactSubtitle,
                    systemImage: "phone.arrow.up.right",
                    tint: .blue
                ) {
                    markContacted()
                }
                Divider().padding(.leading, 48)
                CommandRow(
                    title: ContactDetailCopy.addFollowUpTitle,
                    subtitle: ContactDetailCopy.addFollowUpSubtitle,
                    systemImage: "checklist",
                    tint: .orange
                ) {
                    isCreatingFollowUp = true
                }
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.vertical, 4)
    }

    private var careSummary: RelationshipCareSummary {
        RelationshipCareInsight.summary(for: contact)
    }

    private var careTint: Color {
        switch careSummary.level {
        case .archived: .secondary
        case .warm: .green
        case .new: .indigo
        case .due: .orange
        case .needsCare: .red
        }
    }

    private var contactContext: String {
        let value = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Relationship context not set" : value
    }

    private var relatedWork: [TodoItem] {
        contact.todos.sorted(by: relatedWorkSort)
    }

    private var followUpNotes: String {
        let notes = contact.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            return "Close the loop with \(contact.name)."
        }
        return notes
    }

    private var followUpDueDate: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }

    private func markContacted() {
        contact.lastContactedAt = Date()
        save()
    }

    private func completeLinkedWork(_ todo: TodoItem) {
        actionErrorMessage = nil
        todo.setCompleted(true)
        guard saveLocalDetailChange(failureMessage: ContactDetailCopy.localCompleteWorkFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().updateTodo(
                    sessionToken: sessionToken,
                    id: todo.id,
                    payload: ["status": "done"]
                )
                ProductionDataSync.apply(remote, to: todo)
                _ = saveLocalDetailChange(failureMessage: ContactDetailCopy.remoteCompleteWorkSaveFailedMessage)
            } catch {
                todo.setCompleted(false)
                if saveLocalDetailChange(failureMessage: ContactDetailCopy.restoreWorkFailedMessage) {
                    actionErrorMessage = workActionMessage(
                        ContactDetailCopy.remoteCompleteWorkFailedPrefix,
                        error: error
                    )
                }
            }
        }
    }

    private func dismissLinkedWork(_ todo: TodoItem) {
        actionErrorMessage = nil

        guard let sessionToken = sessionStore.user?.sessionToken else {
            modelContext.delete(todo)
            _ = saveLocalDetailChange(failureMessage: ContactDetailCopy.localDismissWorkFailedMessage)
            return
        }

        Task { @MainActor in
            do {
                _ = try await MobileAPIClient().deleteTodo(sessionToken: sessionToken, id: todo.id)
                modelContext.delete(todo)
                _ = saveLocalDetailChange(failureMessage: ContactDetailCopy.remoteDismissWorkSaveFailedMessage)
            } catch let error as MobileAPIError where error.isNotFound {
                modelContext.delete(todo)
                _ = saveLocalDetailChange(failureMessage: ContactDetailCopy.remoteDismissWorkSaveFailedMessage)
            } catch {
                actionErrorMessage = workActionMessage(
                    ContactDetailCopy.remoteDismissWorkFailedPrefix,
                    error: error
                )
            }
        }
    }

    private func workActionMessage(_ prefix: String, error: Error) -> String {
        "\(prefix) \(MobileErrorCopy.message(for: error))"
    }

    private func save() {
        actionErrorMessage = nil
        guard saveLocalDetailChange(failureMessage: ContactDetailCopy.localSaveFailedMessage) else {
            return
        }

        guard let sessionToken = sessionStore.user?.sessionToken else { return }
        let payload = ProductionDataSync.personPayload(
            name: contact.name,
            company: contact.company,
            email: contact.email,
            phone: contact.phone,
            status: contact.status,
            dealStage: contact.dealStage,
            dealValue: contact.dealValue,
            notes: contact.notes,
            lastContactedAt: contact.lastContactedAt
        )

        Task { @MainActor in
            do {
                let remote = try await MobileAPIClient().updatePerson(
                    sessionToken: sessionToken,
                    id: contact.id,
                    payload: payload
                )
                ProductionDataSync.apply(remote, to: contact)
                _ = saveLocalDetailChange(failureMessage: ContactDetailCopy.remoteSaveFailedMessage)
            } catch {
                actionErrorMessage = ContactDetailCopy.remoteUpdateFailedMessage(error: error)
            }
        }
    }

    @discardableResult
    private func saveLocalDetailChange(failureMessage: String) -> Bool {
        do {
            try modelContext.save()
            return true
        } catch {
            modelContext.rollback()
            actionErrorMessage = failureMessage
            return false
        }
    }

    private func relatedWorkSort(_ lhs: TodoItem, _ rhs: TodoItem) -> Bool {
        if lhs.isCompleted != rhs.isCompleted {
            return !lhs.isCompleted
        }

        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhs.priority != rhs.priority {
                return ContactLinkedWorkRowCopy.priorityRank(lhs.priority) >
                    ContactLinkedWorkRowCopy.priorityRank(rhs.priority)
            }

            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }
}

enum ContactDetailCopy {
    static let actionWarningTitle = "Update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss update warning"
    static let localSaveFailedMessage = "Could not save this relationship on this device. Your last change was not kept."
    static let remoteSaveFailedMessage = "Maraithon updated the relationship, but this device could not save the latest copy. Refresh people to reconcile."
    static let contactDetailsSectionTitle = "Contact details"
    static let relationshipSectionTitle = "Relationship status"
    static let notesSectionTitle = "Relationship notes"
    static let relatedWorkSectionTitle = "Related work"
    static let lastContactedLabel = "Last reached out"
    static let statusPickerTitle = "Status"
    static let circlePickerTitle = "Circle"
    static let notesPlaceholder = "Notes"
    static let logContactSubtitle = "Record that you reached out"
    static let addFollowUpTitle = "Add follow-up"
    static let addFollowUpSubtitle = "Create a linked next move"
    static let markContactedAccessibilityLabel = "Mark reached out"
    static let completeWorkActionLabel = "Done"
    static let dismissWorkActionLabel = "Dismiss"
    static let editWorkActionLabel = "Edit"
    static let localCompleteWorkFailedMessage = "Could not complete the related work on this device. The person detail stayed unchanged."
    static let localDismissWorkFailedMessage = "Could not dismiss the related work on this device. The person detail stayed unchanged."
    static let remoteCompleteWorkFailedPrefix = "Could not complete the related work."
    static let remoteDismissWorkFailedPrefix = "Could not dismiss the related work."
    static let remoteCompleteWorkSaveFailedMessage = "Maraithon completed the related work, but this device could not save the latest copy. Refresh people to reconcile."
    static let remoteDismissWorkSaveFailedMessage = "Maraithon dismissed the related work, but this device could not remove the local copy. Refresh people to reconcile."
    static let restoreWorkFailedMessage = "Could not restore the related work on this device. Refresh people to reconcile."

    static func remoteUpdateFailedMessage(error: Error) -> String {
        "Saved on this device, but Maraithon could not update it online. \(MobileErrorCopy.message(for: error))"
    }

    static var saveFailureLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            localSaveFailedMessage,
            remoteSaveFailedMessage,
            remoteUpdateFailedMessage(error: URLError(.notConnectedToInternet)),
            localCompleteWorkFailedMessage,
            localDismissWorkFailedMessage,
            remoteCompleteWorkFailedPrefix,
            remoteDismissWorkFailedPrefix,
            remoteCompleteWorkSaveFailedMessage,
            remoteDismissWorkSaveFailedMessage,
            restoreWorkFailedMessage
        ]
    }

    static var visibleLabels: [String] {
        [
            actionWarningTitle,
            dismissActionWarningAccessibilityLabel,
            contactDetailsSectionTitle,
            relationshipSectionTitle,
            notesSectionTitle,
            relatedWorkSectionTitle,
            lastContactedLabel,
            statusPickerTitle,
            circlePickerTitle,
            notesPlaceholder,
            logContactSubtitle,
            addFollowUpTitle,
            addFollowUpSubtitle,
            markContactedAccessibilityLabel,
            completeWorkActionLabel,
            dismissWorkActionLabel,
            editWorkActionLabel
        ]
    }
}

private struct ContactLinkedWorkRow: View {
    let todo: TodoItem

    private var decisionContext: TodoDecisionContext {
        TodoDecisionContext(todo: todo)
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(todo.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                    .strikethrough(todo.isCompleted)

                if let nextMove = decisionContext.rowMove {
                    Text("Next: \(nextMove)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let detail = ContactLinkedWorkRowCopy.detail(for: todo) {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(todo.isCompleted ? .green : todo.priority.tint)
        }
        .padding(.vertical, 4)
    }
}

enum ContactLinkedWorkRowCopy {
    static func detail(
        for todo: TodoItem,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        let parts = [
            statusText(for: todo),
            dueText(for: todo, now: now, calendar: calendar),
            urgencyText(for: todo)
        ].compactMap { $0 }

        return parts.joined(separator: " / ").nilIfBlank
    }

    static func priorityRank(_ priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 4
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private static func statusText(for todo: TodoItem) -> String? {
        todo.isCompleted ? "Done" : nil
    }

    private static func dueText(for todo: TodoItem, now: Date, calendar: Calendar) -> String? {
        guard !todo.isCompleted else { return nil }
        guard let dueDate = todo.dueDate else { return nil }
        return TodoRowCopy.dueText(for: todo, dueDate: dueDate, now: now, calendar: calendar)
    }

    private static func urgencyText(for todo: TodoItem) -> String? {
        guard !todo.isCompleted else { return nil }

        switch todo.priority {
        case .critical, .high:
            return "\(todo.priority.title) urgency"
        case .medium, .low:
            return nil
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
