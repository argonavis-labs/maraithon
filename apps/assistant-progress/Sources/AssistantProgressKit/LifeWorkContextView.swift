/// Captures life/work notes and shows the system's interpretation before it becomes guidance.
import SwiftUI

public struct LifeWorkContextView: View {
    let request: LifeWorkContext.Request
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var notes: [LifeWorkContext.Note] = []
    @State private var text = ""
    @State private var domain = "both"
    @State private var requestID = UUID().uuidString
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var selected: LifeWorkContext.Note?
    @State private var dictation = ContextDictation()
    @State private var beforeDictation = ""
    @State private var usedVoice = false

    public init(request: @escaping LifeWorkContext.Request) { self.request = request }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Your life & work") {
                    Text("Tell me about the people, responsibilities, and routines that matter to you.")
                        .foregroundStyle(.secondary)
                    Picker("Context", selection: $domain) {
                        Text("Life & work").tag("both")
                        Text("Life").tag("life")
                        Text("Work").tag("work")
                    }
                    TextField("Family, school, partners, close associates, team members…", text: $text, axis: .vertical)
                        .lineLimit(5...12)
                        .disabled(dictation.recording || busy)
                    Button(dictation.recording ? "Stop recording" : "Record a voice note",
                           systemImage: dictation.recording ? "stop.circle" : "mic") {
                        if dictation.recording { dictation.stop() }
                        else {
                            beforeDictation = text
                            usedVoice = true
                            Task { await dictation.start() }
                        }
                    }
                    .disabled(busy || dictation.starting)
                    Text(dictation.recording ? "Listening… up to 55 seconds. You can add another recording." :
                         "Voice becomes editable text on this device. Review it before saving.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = dictation.error { Text(error).font(.callout).foregroundStyle(.red) }
                    Button("Make sense of this", systemImage: "sparkles") { Task { await capture() } }
                        .disabled(busy || dictation.recording || dictation.starting || !validText)
                    if busy { ProgressView("Saving…") }
                }
                Section("Context you've shared") {
                    if !loaded { ProgressView("Loading context…") }
                    else if notes.isEmpty { Text("Your notes and confirmed guidance will appear here.").foregroundStyle(.secondary) }
                    ForEach(notes) { note in
                        Button { selected = note } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(note.summary ?? note.text).lineLimit(3).foregroundStyle(.primary)
                                Label(stateLabel(note.state), systemImage: note.state == "confirmed" ? "checkmark.seal" : "sparkles")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red); Button("Reload") { Task { await reload() } } } }
            }
            .formStyle(.grouped)
            .navigationTitle("Life & work")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { dictation.stop(); return }
                await reload()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    if notes.contains(where: { $0.state == "queued" }) { await reload() }
                }
            }
            .onChange(of: dictation.transcript) { _, value in
                guard !value.isEmpty else { return }
                text = [beforeDictation, value].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            .onChange(of: text) { _, _ in requestID = UUID().uuidString }
            .onChange(of: domain) { _, _ in requestID = UUID().uuidString }
            .onDisappear { dictation.stop() }
            .sheet(item: $selected, onDismiss: { Task { await reload() } }) { note in
                LifeWorkNoteReview(note: note, request: request)
            }
            .interactiveDismissDisabled(busy || dictation.recording)
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 640)
        #endif
    }

    private var validText: Bool { (10...10_000).contains(text.trimmingCharacters(in: .whitespacesAndNewlines).count) }
    private func stateLabel(_ state: String) -> String {
        switch state {
        case "confirmed": "Confirmed guidance"
        case "review": "Ready to review"
        case "failed": "Needs another try"
        default: "Making sense of your note…"
        }
    }
    @MainActor private func reload() async {
        do { notes = try await request("life-context", nil).notes ?? []; loaded = true; error = nil }
        catch { self.error = error.localizedDescription; loaded = true }
    }
    @MainActor private func capture() async {
        guard !busy, validText else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let response = try await request("life-context", .init(text: text, domain: domain,
                inputMode: usedVoice ? "voice" : "text", requestID: requestID))
            text = ""; usedVoice = false; requestID = UUID().uuidString
            if let note = response.note { notes.insert(note, at: 0); selected = note }
        } catch { self.error = error.localizedDescription }
    }
}
