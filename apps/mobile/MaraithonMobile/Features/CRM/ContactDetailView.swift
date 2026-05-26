import SwiftData
import SwiftUI

struct ContactDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Bindable var contact: CRMContact
    @State private var isEditingContact = false
    @State private var isCreatingFollowUp = false

    var body: some View {
        Form {
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

            Section("Reach") {
                if !contact.email.isEmpty {
                    LabeledContent("Email", value: contact.email)
                }
                if !contact.phone.isEmpty {
                    LabeledContent("Phone", value: contact.phone)
                }
                if let lastContactedAt = contact.lastContactedAt {
                    LabeledContent("Last Contacted", value: AppFormatters.relativeString(for: lastContactedAt))
                }
            }

            Section("Relationship") {
                Picker(
                    "Status",
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
                    "Circle",
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

            Section("Notes") {
                TextField("Notes", text: $contact.notes, axis: .vertical)
                    .lineLimit(5...10)
                    .onSubmit(save)
            }

            if !contact.todos.isEmpty {
                Section("Linked Todos") {
                    ForEach(contact.todos) { todo in
                        Label(todo.title, systemImage: todo.isCompleted ? "checkmark.circle.fill" : "circle")
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
                .accessibilityLabel("Edit Person")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    markContacted()
                } label: {
                    Image(systemName: "phone.arrow.up.right")
                }
                .accessibilityLabel("Mark Contacted")
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
                    subtitle: "Update the relationship timestamp",
                    systemImage: "phone.arrow.up.right",
                    tint: .blue
                ) {
                    markContacted()
                }
                Divider().padding(.leading, 48)
                CommandRow(
                    title: "Create Follow-up",
                    subtitle: "Add a linked todo for this person",
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

    private func save() {
        try? modelContext.save()
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
        Task {
            let remote = try? await MobileAPIClient().updatePerson(
                sessionToken: sessionToken,
                id: contact.id,
                payload: payload
            )
            if let remote {
                ProductionDataSync.apply(remote, to: contact)
                try? modelContext.save()
            }
        }
    }
}
