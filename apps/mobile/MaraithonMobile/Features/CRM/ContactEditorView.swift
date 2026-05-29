import SwiftData
import SwiftUI

struct ContactEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore

    private let contact: CRMContact?
    @State private var name = ""
    @State private var company = ""
    @State private var email = ""
    @State private var phone = ""
    @State private var status: ContactStatus = .lead
    @State private var dealStage: DealStage = .prospect
    @State private var dealValue = 0.0
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    init(contact: CRMContact? = nil) {
        self.contact = contact
        _name = State(initialValue: contact?.name ?? "")
        _company = State(initialValue: contact?.company ?? "")
        _email = State(initialValue: contact?.email ?? "")
        _phone = State(initialValue: contact?.phone ?? "")
        _status = State(initialValue: contact?.status ?? .lead)
        _dealStage = State(initialValue: contact?.dealStage ?? .prospect)
        _dealValue = State(initialValue: NSDecimalNumber(decimal: contact?.dealValue ?? 0).doubleValue)
        _notes = State(initialValue: contact?.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(ContactEditorCopy.personSectionTitle) {
                    TextField(ContactEditorCopy.namePlaceholder, text: $name)
                        .accessibilityIdentifier("contact-name-field")
                    TextField(ContactEditorCopy.contextPlaceholder, text: $company)
                        .accessibilityIdentifier("contact-company-field")
                    TextField(ContactEditorCopy.emailPlaceholder, text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("contact-email-field")
                    TextField(ContactEditorCopy.phonePlaceholder, text: $phone)
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("contact-phone-field")
                }

                Section(ContactEditorCopy.relationshipSectionTitle) {
                    Picker(ContactEditorCopy.statusPickerTitle, selection: $status) {
                        ForEach(ContactStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    Picker(ContactEditorCopy.circlePickerTitle, selection: $dealStage) {
                        ForEach(DealStage.allCases) { stage in
                            Text(stage.title).tag(stage)
                        }
                    }
                }

                Section(ContactEditorCopy.notesSectionTitle) {
                    TextField(ContactEditorCopy.notesPlaceholder, text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("contact-notes-field")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(contact == nil ? ContactEditorCopy.newNavigationTitle : ContactEditorCopy.editNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving" : "Save") {
                        Task { await save() }
                    }
                    .accessibilityIdentifier("contact-save-button")
                    .disabled(isSaving || !canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            EmailValidator.isValid(email)
    }

    private func save() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCompany = company.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = EmailValidator.normalized(email)
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = ProductionDataSync.personPayload(
            name: trimmedName,
            company: trimmedCompany,
            email: normalizedEmail,
            phone: trimmedPhone,
            status: status,
            dealStage: dealStage,
            dealValue: Decimal(dealValue),
            notes: trimmedNotes,
            lastContactedAt: contact?.lastContactedAt
        )

        do {
            if let sessionToken = sessionStore.user?.sessionToken {
                if let contact {
                    let remote = try await MobileAPIClient().updatePerson(
                        sessionToken: sessionToken,
                        id: contact.id,
                        payload: payload
                    )
                    ProductionDataSync.apply(remote, to: contact)
                } else {
                    let remote = try await MobileAPIClient().createPerson(
                        sessionToken: sessionToken,
                        payload: payload
                    )
                    guard let id = UUID(uuidString: remote.id) else {
                        throw MobileAPIError.invalidResponse
                    }
                    modelContext.insert(ProductionDataSync.contact(from: remote, id: id))
                }
            } else if let contact {
                contact.name = trimmedName
                contact.company = trimmedCompany
                contact.email = normalizedEmail
                contact.phone = trimmedPhone
                contact.status = status
                contact.dealValue = Decimal(dealValue)
                contact.dealStage = dealStage
                contact.notes = trimmedNotes
            } else {
                let contact = CRMContact(
                    name: trimmedName,
                    company: trimmedCompany,
                    email: normalizedEmail,
                    phone: trimmedPhone,
                    status: status,
                    dealValue: Decimal(dealValue),
                    dealStage: dealStage,
                    lastContactedAt: Date(),
                    notes: trimmedNotes
                )
                modelContext.insert(contact)
            }

            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = MobileErrorCopy.message(for: error)
        }
    }
}

enum ContactEditorCopy {
    static let personSectionTitle = "Person"
    static let relationshipSectionTitle = "Relationship status"
    static let notesSectionTitle = "Relationship notes"
    static let namePlaceholder = "Name"
    static let contextPlaceholder = "Company, role, or context"
    static let emailPlaceholder = "Email"
    static let phonePlaceholder = "Phone"
    static let statusPickerTitle = "Status"
    static let circlePickerTitle = "Circle"
    static let notesPlaceholder = "What matters about this relationship"
    static let newNavigationTitle = "New person"
    static let editNavigationTitle = "Edit person"

    static var visibleLabels: [String] {
        [
            personSectionTitle,
            relationshipSectionTitle,
            notesSectionTitle,
            namePlaceholder,
            contextPlaceholder,
            emailPlaceholder,
            phonePlaceholder,
            statusPickerTitle,
            circlePickerTitle,
            notesPlaceholder,
            newNavigationTitle,
            editNavigationTitle
        ]
    }
}
