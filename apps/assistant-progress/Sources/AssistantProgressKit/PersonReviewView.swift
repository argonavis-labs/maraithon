/// Opens inferred people for explicit review. Saving here is the only confirmation action.
import SwiftUI

public struct PersonReviewView: View {
    let reference: LifeWorkContext.PersonReference
    let request: LifeWorkContext.Request
    let saved: @MainActor () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var person: LifeWorkContext.Person?
    @State private var details = LifeWorkContext.Details(name: "", relationship: "", notes: "", emails: "", phones: "")
    @State private var requestID = UUID().uuidString
    @State private var busy = false
    @State private var error: String?

    public init(reference: LifeWorkContext.PersonReference, request: @escaping LifeWorkContext.Request,
                saved: @escaping @MainActor () async -> Void = {}) {
        self.reference = reference; self.request = request; self.saved = saved
    }

    public var body: some View {
        NavigationStack {
            Form {
                if let person {
                    Section {
                        Label(person.confirmedAt == nil ? "Suggested details" : "Confirmed by you",
                              systemImage: person.confirmedAt == nil ? "sparkles" : "checkmark.seal")
                        TextField("Name", text: $details.name)
                        TextField("Relationship", text: $details.relationship, axis: .vertical)
                        TextField("Context", text: $details.notes, axis: .vertical).lineLimit(3...8)
                    }
                    Section("Contact details") {
                        TextField("Email addresses", text: $details.emails, axis: .vertical)
                        TextField("Phone numbers", text: $details.phones, axis: .vertical)
                        Text("One per line. Leave details you don't know blank.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let suggestion = person.suggestedRelationship, suggestion != person.relationship {
                        Section("From your note") {
                            Text(suggestion)
                            if let notes = person.suggestedNotes { Text(notes).foregroundStyle(.secondary) }
                            Button("Use this context") {
                                details.relationship = suggestion
                                if let notes = person.suggestedNotes { details.notes = notes }
                            }
                        }
                    }
                    Section {
                        Text("Confirm the relationship and the contact details you recognize.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Confirm details", systemImage: "checkmark") { Task { await confirm() } }
                            .disabled(busy || details.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else if busy {
                    ProgressView("Loading details…")
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if person == nil { Button("Try again") { Task { await load() } } }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(person?.name ?? "Person details")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .task { await load() }
            .interactiveDismissDisabled(busy)
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 600, minHeight: 560)
        #endif
    }

    @MainActor private func load() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let value = try await request(reference.path, nil).person else { throw URLError(.badServerResponse) }
            person = value
            details = .init(name: value.name, relationship: value.relationship ?? "", notes: value.notes ?? "",
                            emails: value.emails.joined(separator: "\n"), phones: value.phones.joined(separator: "\n"))
        } catch { self.error = error.localizedDescription }
    }

    @MainActor private func confirm() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            _ = try await request("person-review", .confirmation(reference, details: details, requestID: requestID))
            await saved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
