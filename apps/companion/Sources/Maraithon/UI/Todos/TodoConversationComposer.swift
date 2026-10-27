/// Bottom composer: Return sends, Shift-Return starts a new line, Command-
/// Return also sends. The text stays editable while a run is active; the store
/// queues such a send until the run settles.
import SwiftUI

struct TodoConversationComposer: View {
    @Bindable var store: TodoConversationStore
    var focused: FocusState<Bool>.Binding

    private var canSend: Bool {
        store.thread != nil && !store.composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hint: String {
        store.isThinking ? TodoActionCopy.composerBusyHint : TodoActionCopy.composerHint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            TextField(TodoActionCopy.composerPlaceholder, text: $store.composer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
                .lineLimit(Tokens.TodoLayout.composerMinLines...Tokens.TodoLayout.composerMaxLines)
                .focused(focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                    guard canSend else { return .ignored }
                    Task { await store.send() }
                    return .handled
                }
                .accessibilityLabel("Message Maraithon about this todo")
            HStack(spacing: Tokens.Spacing.small) {
                Text(hint)
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: Tokens.Spacing.small)
                Button("Send", systemImage: "arrow.up") { Task { await store.send() } }
                    .buttonStyle(RunnerButtonStyle(.primary, compact: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSend)
            }
        }
        .padding(Tokens.Spacing.tight)
        .background(Tokens.Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                .stroke(focused.wrappedValue ? Tokens.Palette.accent : Tokens.Palette.border,
                        lineWidth: focused.wrappedValue ? Tokens.Stroke.control : Tokens.Stroke.hairline)
        }
        .animation(.easeOut(duration: 0.12), value: focused.wrappedValue)
        .padding(.horizontal, Tokens.Spacing.large)
        .padding(.top, Tokens.Spacing.small)
        .padding(.bottom, Tokens.Spacing.large)
        .onTapGesture { focused.wrappedValue = true }
    }
}
