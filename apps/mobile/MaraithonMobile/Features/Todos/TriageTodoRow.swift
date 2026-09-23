/// Review a suggestion without completing it. Buttons and horizontal pulls
/// share the same server-backed acceptance and relevance feedback actions.
import SwiftUI
import AssistantProgressKit

struct TriageTodoRow: View {
    let todo: TodoItem
    let isWorking: Bool
    let open: () -> Void
    let accept: () -> Void
    let ignore: () -> Void

    var body: some View {
        TriageSwipeRow(isWorking: isWorking, background: Runner.Palette.background,
            accept: accept, ignore: ignore) {
            VStack(alignment: .leading, spacing: Runner.Spacing.small) {
                Button(action: open) {
                    Text(todo.title)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(Runner.Palette.foreground)
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
                    if isWorking { ProgressView().controlSize(.small) }
                    Button(action: ignore) { Label("Ignore", systemImage: "hand.thumbsdown") }
                        .buttonStyle(RunnerButtonStyle(.plain, compact: true))
                    Button(action: accept) { Label("Add", systemImage: "plus") }
                        .buttonStyle(RunnerButtonStyle(.secondary, compact: true))
                        .accessibilityLabel("Add to Todos")
                }
            }
            .padding(.vertical, Runner.Spacing.small)
            .disabled(isWorking)
        }
        .contextMenu {
            Button(action: accept) { Label("Add to Todos", systemImage: "plus") }
            Button(action: ignore) { Label("Ignore", systemImage: "hand.thumbsdown") }
        }
    }
}
