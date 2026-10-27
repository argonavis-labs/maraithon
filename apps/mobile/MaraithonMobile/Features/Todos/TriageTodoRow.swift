/// Review or complete a suggestion directly. Completion stays separate from
/// the Add button and acceptance swipe, with feedback after the server saves.
import SwiftUI
import AssistantProgressKit

struct TriageTodoRow: View {
    let todo: TodoItem
    let isWorking: Bool
    var isCompleting: Bool = false
    let open: () -> Void
    let complete: () -> Void
    let accept: () -> Void
    let ignore: () -> Void

    var body: some View {
        TriageSwipeRow(isWorking: isWorking, background: Runner.Palette.background,
            accept: accept, ignore: ignore) {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                Button(action: open) {
                    Text(todo.title)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(isCompleting ? Runner.Palette.mutedForeground : Runner.Palette.foreground)
                        .strikethrough(isCompleting)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if let next = todo.displayNextAction {
                    Text(next)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                }

                HStack(spacing: Runner.Spacing.small) {
                    if let source = todo.sourceSystem {
                        ProviderMark(provider: source, size: Runner.Layout.providerMark)
                        Text(todo.sourceProviderLabel ?? source.capitalized)
                            .font(Runner.Typography.caption)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                    }
                    Spacer()
                    if isWorking && !isCompleting {
                        ProgressView().controlSize(.small).accessibilityLabel("Saving task")
                    }
                }
                if isCompleting {
                    Label("Done", systemImage: "checkmark.circle.fill")
                        .font(Runner.Typography.smallMedium)
                        .foregroundStyle(Runner.Palette.successText)
                } else {
                    TriageTodoActions(complete: complete, accept: accept, ignore: ignore)
                }
            }
            .padding(.vertical, Runner.Spacing.small)
            .disabled(isWorking)
        }
        .contextMenu {
            Button(action: complete) { Label("Done", systemImage: "checkmark.circle") }
            Button(action: accept) { Label("Add to Todos", systemImage: "plus") }
            Button(action: ignore) { Label("Ignore", systemImage: "hand.thumbsdown") }
        }
        .disabled(isWorking)
    }
}
