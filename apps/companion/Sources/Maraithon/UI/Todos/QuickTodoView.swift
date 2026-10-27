/// A fleeting capture surface. Drafts keep their request identity on retry,
/// and the success beat appears only after the server has saved the todo.
import SwiftUI

struct QuickTodoView: View {
    let store: TodosStore
    let close: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var title = ""
    @State private var requestID = UUID()
    @State private var working = false
    @State private var saved = false
    @State private var error: String?

    private var canSubmit: Bool {
        !working && !saved && title.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            HStack(spacing: Tokens.Spacing.medium) {
                Image(systemName: saved ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(saved ? Color.green : Color.accentColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffectsRemoved(reduceMotion)
                    .accessibilityHidden(true)

                if saved {
                    Text("Got it.")
                        .font(.title2.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityAddTraits(.updatesFrequently)
                } else {
                    TextField("What’s on your mind?", text: $title)
                        .font(.title2)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .accessibilityLabel("New todo title")
                        .onSubmit(submit)
                        .disabled(working)
                        .onChange(of: title) { _, value in
                            if value.count > 240 { title = String(value.prefix(240)) }
                            requestID = UUID()
                            error = nil
                        }
                }
            }
            .frame(height: Tokens.Layout.controlHeight)

            Divider()

            HStack(spacing: Tokens.Spacing.small) {
                Text(error ?? (saved ? "On your list. Off your mind." : "I’ll fill in the details."))
                    .font(.caption)
                    .foregroundStyle(error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                Spacer(minLength: Tokens.Spacing.small)
                if !saved {
                    Button("Esc", action: close)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Close quick capture")
                        .keyboardShortcut(.cancelAction)

                    if working {
                        ProgressView("Adding…")
                            .controlSize(.small)
                            .font(.caption)
                    } else {
                        Button(action: submit) {
                            Label("Add", systemImage: "return")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!canSubmit)
                    }
                }
            }
            .frame(minHeight: Tokens.Layout.controlHeight)
        }
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.vertical, Tokens.Spacing.medium)
        .frame(width: Tokens.Layout.quickTodoWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand(perform: close)
        .task { focused = true }
    }

    private func submit() {
        guard canSubmit else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = requestID
        working = true
        error = nil

        Task { @MainActor in
            do {
                _ = try await store.create(CompanionTodoDraft(requestID: id,
                    title: value, notes: nil, nextAction: value, priority: 50, dueAt: nil),
                    stayInTriage: true)
                withAnimation(reduceMotion ? nil : .default) { saved = true }
                try? await Task.sleep(for: .milliseconds(700))
                close()
            } catch {
                working = false
                self.error = "Couldn’t add it. Try again."
                focused = true
            }
        }
    }
}
