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
                Section("Person") {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("contact-name-field")
                    TextField("Context", text: $company)
                        .accessibilityIdentifier("contact-company-field")
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("contact-email-field")
                    TextField("Phone", text: $phone)
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("contact-phone-field")
                }

                Section("Relationship") {
                    Picker("Status", selection: $status) {
                        ForEach(ContactStatus.allCases) { status in
                            Text(status.title).tag(status)
                        }
                    }
                    Picker("Circle", selection: $dealStage) {
                        ForEach(DealStage.allCases) { stage in
                            Text(stage.title).tag(stage)
                        }
                    }
                }

                Section("Notes") {
                    TextField("Relationship notes", text: $notes, axis: .vertical)
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
            .navigationTitle(contact == nil ? "New Person" : "Edit Person")
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
            errorMessage = error.localizedDescription
        }
    }
}
