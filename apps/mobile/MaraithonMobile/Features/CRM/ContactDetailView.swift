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
        // Sorted once per body pass; the section reads it twice.
        let relatedWork = contact.todos.sorted(by: relatedWorkSort)
        List {
            if let actionErrorMessage {
                SyncIssueBanner(
                    title: ContactDetailCopy.actionWarningTitle,
                    message: actionErrorMessage,
                    buttonTitle: nil,
                    retry: nil,
                    dismissAccessibilityLabel: ContactDetailCopy.dismissActionWarningAccessibilityLabel,
                    dismiss: { self.actionErrorMessage = nil }
                )
                .crmListRow(insets: EdgeInsets(), separator: .hidden)
            }

            header
                .crmListBlock(top: Runner.Spacing.small, bottom: Runner.Spacing.medium)

            careRecommendation
                .crmListBlock(bottom: Runner.Spacing.xsmall)

            RunnerSectionLabel(ContactDetailCopy.contactDetailsSectionTitle)
                .crmSectionLabelRow()
            if !contact.email.isEmpty {
                ContactFactRow(label: "Email", value: contact.email)
                    .crmListRow()
            }
            if !contact.phone.isEmpty {
                ContactFactRow(label: "Phone", value: contact.phone)
                    .crmListRow()
            }
            if let lastContactedAt = contact.lastContactedAt {
                ContactFactRow(label: ContactDetailCopy.lastContactedLabel, value: AppFormatters.relativeString(for: lastContactedAt))
                    .crmListRow()
            }

            RunnerSectionLabel(ContactDetailCopy.relationshipSectionTitle)
                .crmSectionLabelRow()
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
            .pickerStyle(.menu)
            .font(Runner.Typography.body)
            .foregroundStyle(Runner.Palette.foreground)
            .crmListRow()

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
            .pickerStyle(.menu)
            .font(Runner.Typography.body)
            .foregroundStyle(Runner.Palette.foreground)
            .crmListRow()

            RunnerSectionLabel(ContactDetailCopy.notesSectionTitle)
                .crmSectionLabelRow()
            TextField(ContactDetailCopy.notesPlaceholder, text: $contact.notes, axis: .vertical)
                .lineLimit(5...10)
                .onSubmit(save)
                .font(Runner.Typography.body)
                .foregroundStyle(Runner.Palette.foreground)
                .crmListRow()

            if !relatedWork.isEmpty {
                RunnerSectionLabel(ContactDetailCopy.relatedWorkSectionTitle)
                    .crmSectionLabelRow()
                ForEach(relatedWork) { todo in
                    Button {
                        editingTodo = todo
                    } label: {
                        ContactLinkedWorkRow(todo: todo)
                    }
                    .buttonStyle(.plain)
                    .crmListRow()
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
                            .tint(Runner.Palette.success)
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
                        .tint(Runner.Palette.info)
                    }
                }
            }
        }
        .listStyle(.plain)
        .runnerPage()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
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

    private var header: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.medium) {
            PeopleAvatar(initials: PeopleAvatar.initials(for: contact.name), size: PeopleAvatar.detailSize)
            VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                Text(contact.name)
                    .font(Runner.Typography.pageTitle)
                    .tracking(Runner.Typography.pageTitleTracking)
                    .foregroundStyle(Runner.Palette.foreground)
                    .accessibilityAddTraits(.isHeader)
                Text(contactContext)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                HStack(spacing: Runner.Spacing.compact) {
                    StatusPill(title: contact.status.title, tint: contact.status.tint)
                    StatusPill(title: contact.dealStage.title, tint: contact.dealStage.tint)
                }
                .padding(.top, Runner.Spacing.xsmall)
            }
        }
    }

    private var careRecommendation: some View {
        // Computed once per render; the layout reads several fields and the
        // care signal walks the contact's history each time it is evaluated.
        let careSummary = RelationshipCareSignal.summary(for: contact)
        let tone = careTone(for: careSummary.level)

        return RunnerCard {
            HStack(alignment: .center, spacing: Runner.Spacing.tight) {
                Image(systemName: careSummary.systemImage)
                    .font(Runner.Typography.icon)
                    .foregroundStyle(tone.text)
                    .frame(width: Runner.Layout.compactControlHeight, height: Runner.Layout.compactControlHeight)
                    .background(tone.fill, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                    Text(careSummary.title)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(Runner.Palette.foreground)
                    Text(careSummary.subtitle)
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                }
            }
            .runnerCardRow()

            RunnerHairline()
            CommandRow(
                title: careSummary.actionTitle,
                subtitle: ContactDetailCopy.logContactSubtitle,
                systemImage: "phone.arrow.up.right",
                tint: Runner.Palette.accent
            ) {
                markContacted()
            }
            RunnerHairline()
            CommandRow(
                title: ContactDetailCopy.addFollowUpTitle,
                subtitle: ContactDetailCopy.addFollowUpSubtitle,
                systemImage: "checklist",
                tint: Runner.Palette.accent
            ) {
                isCreatingFollowUp = true
            }
        }
    }

    private func careTone(for level: RelationshipCareLevel) -> RunnerBadge.Tone {
        switch level {
        case .archived: .zinc
        case .warm: .emerald
        case .new: .indigo
        case .due: .amber
        case .needsCare: .red
        }
    }

    private var contactContext: String {
        let value = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Relationship context not set" : value
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
                    payload: ["status": .string("done")]
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
        if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

enum ContactDetailCopy {
    static let actionWarningTitle = "Update was not saved"
    static let dismissActionWarningAccessibilityLabel = "Dismiss update warning"
    static let localSaveFailedMessage = "Could not save this relationship on this device. Your last change was not kept."
    static let remoteSaveFailedMessage = "Maraithon updated the relationship. Refresh people to show the latest state on this device."
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
    static let remoteCompleteWorkSaveFailedMessage = "Maraithon completed the related work. Refresh people to show the latest state on this device."
    static let remoteDismissWorkSaveFailedMessage = "Maraithon dismissed the related work. Refresh people to remove it from this device."
    static let restoreWorkFailedMessage = "Could not restore the related work after the update failed. Refresh people to show the latest state."

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

/// Label on the left, value on the right; the value is selectable so an
/// email or phone number can be copied.
private struct ContactFactRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.small) {
            Text(label)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.mutedForeground)
            Spacer(minLength: Runner.Spacing.small)
            Text(value)
                .font(Runner.Typography.small)
                .foregroundStyle(Runner.Palette.foreground)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct ContactLinkedWorkRow: View {
    let todo: TodoItem

    /// Built once per row construction; each construction runs the
    /// copy-cleaning pipeline over ~8 fields.
    private let decisionContext: TodoDecisionContext

    init(todo: TodoItem) {
        self.todo = todo
        self.decisionContext = TodoDecisionContext(todo: todo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: Runner.Spacing.tight) {
            Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(Runner.Typography.icon)
                .foregroundStyle(todo.isCompleted ? Runner.Palette.success : RunnerBadge.Tone.from(tint: todo.priority.tint).text)
                .frame(width: Runner.Spacing.roomy)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
                Text(todo.title)
                    .font(Runner.Typography.bodyMedium)
                    .foregroundStyle(todo.isCompleted ? Runner.Palette.mutedForeground : Runner.Palette.foreground)
                    .strikethrough(todo.isCompleted)

                if let nextMove = decisionContext.rowMove {
                    Text("Next: \(nextMove)")
                        .font(Runner.Typography.caption)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                }

                if let detail = ContactLinkedWorkRowCopy.detail(for: todo) {
                    Text(detail)
                        .font(Runner.Typography.micro)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, Runner.Spacing.xxsmall)
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
