/// Review edits never confirm a person's contacts implicitly; each person has a separate review.
import SwiftUI

struct LifeWorkNoteReview: View {
    @State var note: LifeWorkContext.Note
    let request: LifeWorkContext.Request
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var summary = ""
    @State private var rules = ""
    @State private var busy = false
    @State private var error: String?
    @State private var person: LifeWorkContext.PersonReference?
    @State private var archiving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Your note") { Text(note.text).textSelection(.enabled) }
                if note.state == "queued" {
                    Section { ProgressView("Connecting the people and context…") }
                } else if note.state == "failed" {
                    Section {
                        Text("Your note is saved. Its interpretation couldn't finish.")
                        Button("Try again") { Task { await perform("retry") } }.disabled(busy)
                    }
                } else {
                    Section(note.state == "confirmed" ? "Confirmed guidance" : "Review the interpretation") {
                        TextField("Summary", text: $summary, axis: .vertical).lineLimit(3...8)
                        TextField("Guidance, one point per line", text: $rules, axis: .vertical).lineLimit(3...12)
                        Button(note.state == "confirmed" ? "Save guidance" : "Confirm guidance", systemImage: "checkmark") {
                            Task { await perform("confirm") }
                        }.disabled(busy || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Section("People to confirm") {
                        if note.people.isEmpty { Text("No people identified in this note.").foregroundStyle(.secondary) }
                        ForEach(note.people) { proposed in
                            Button {
                                person = .init(noteID: note.id, index: proposed.index)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(proposed.name, systemImage: proposed.confirmedAt == nil ? "person.crop.circle" : "checkmark.seal")
                                    if let relationship = proposed.relationship { Text(relationship).font(.caption).foregroundStyle(.secondary) }
                                    Text(proposed.confirmedAt == nil ? "Review relationship, phone & email" : "Details confirmed")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section { Button("Archive this context", role: .destructive) { archiving = true }.disabled(busy) }
            }
            .formStyle(.grouped)
            .navigationTitle("Life & work context")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .onAppear { fillDraft() }
            .task(id: "\(scenePhase):\(note.state)") {
                guard scenePhase == .active else { return }
                while !Task.isCancelled && note.state == "queued" {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    await reload()
                }
            }
            .sheet(item: $person) { reference in
                PersonReviewView(reference: reference, request: request, saved: { await reload() })
            }
            .confirmationDialog("Archive this context and stop using its guidance?", isPresented: $archiving) {
                Button("Archive context", role: .destructive) { Task { await perform("archive") } }
            }
            .interactiveDismissDisabled(busy)
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 640)
        #endif
    }
    private func fillDraft() { summary = note.summary ?? ""; rules = note.rules.joined(separator: "\n") }
    @MainActor private func reload() async {
        do {
            if let updated = try await request("life-context/\(note.id)", nil).note {
                let becameReady = note.state == "queued" && updated.state != "queued"
                note = updated
                if becameReady { fillDraft() }
            }
        } catch { self.error = error.localizedDescription }
    }
    @MainActor private func perform(_ action: String) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let input = LifeWorkContext.Input(summary: summary,
                rules: rules.split(separator: "\n").map(String.init))
            if let updated = try await request("life-context/\(note.id)/\(action)", input).note { note = updated }
            if action == "archive" { dismiss() }

        } catch { self.error = error.localizedDescription }
    }
}
