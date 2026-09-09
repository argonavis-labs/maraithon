/// Reviewable task actions preserve edited wording and never send on navigation.
import SwiftUI
import AppKit

struct TodoSourceActionsView: View {
    let todo: CompanionTodo
    @Environment(AppEnvironment.self) private var env
    @State private var bodyText = ""
    @State private var subject = ""
    @State private var error: String?
    @State private var isSending = false
    @State private var confirmsSend = false
    @State private var didSend = false
    @State private var copied = false

    var body: some View {
        if let action = todo.actionCard?.sourceAction {
            if todo.canMarkDone, let draft = action.draftText, !draft.isEmpty {
                Section("Suggested reply") {
                    if action.provider == "gmail" {
                        TextField("Subject", text: $subject)
                    }
                    if let recipient = action.recipient { LabeledContent("To", value: recipient) }
                    TextEditor(text: $bodyText).frame(minHeight: 120)
                    if let error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    HStack {
                        Button {
                            copyAndOpen(action)
                        } label: {
                            Label(action.provider == "slack" && action.destination != nil ? "Copy reply and open Slack" : (copied ? "Copied" : "Copy reply"), systemImage: "doc.on.doc")
                        }
                        if action.provider == "gmail" {
                            Button(didSend ? "Sent" : "Approve and send", systemImage: "paperplane") { confirmsSend = true }
                                .disabled(isSending || didSend || bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .onAppear { bodyText = draft; subject = action.subject ?? "" }
                .confirmationDialog("Send this email?", isPresented: $confirmsSend, titleVisibility: .visible) {
                    Button("Send email") { Task { await send() } }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("Send the reviewed message through your connected account.") }
            }
            if let destination = action.destination {
                Link(destination: destination) { Label(action.openLabel ?? "Open source", systemImage: "arrow.up.right") }
            }
        }
        if todo.canMarkDone, let call = todo.brief?.call, let url = call.url {
            Link(destination: url) { Label("Call " + call.label, systemImage: "phone") }
        }
    }

    private func copyAndOpen(_ action: CompanionTodoSourceAction) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(bodyText, forType: .string) else {
            error = "Could not copy the reply. Select the text and copy it."; return
        }
        copied = true
        if action.provider == "slack", let destination = action.destination {
            if !NSWorkspace.shared.open(destination) { error = "Reply copied. Slack could not open." }
        }
    }

    private func send() async {
        guard !isSending else { return }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            try await env.todos.sendReply(for: todo, body: bodyText, subject: subject)
            didSend = true
        } catch { self.error = CompanionErrorCopy.message(for: error) }
    }
}
