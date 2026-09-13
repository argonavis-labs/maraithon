import SwiftUI

/// Tasks page header: eyebrow, title with live count, subtitle, and the
/// Shortcuts and New task actions.
struct TodosHeaderView: View {
    let store: TodosStore
    let showShortcuts: () -> Void
    let createTodo: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Your workspace")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .padding(.bottom, Tokens.Spacing.small + 1)
                HStack(alignment: .center, spacing: Tokens.Spacing.tight) {
                    Text("Tasks")
                        .font(Tokens.Typography.pageTitle)
                        .tracking(Tokens.Typography.pageTitleTracking)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(store.todos.count)")
                        .font(Tokens.Typography.small)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .padding(.horizontal, Tokens.Spacing.compact)
                        .padding(.vertical, Tokens.Spacing.xxsmall + 1)
                        .background(Tokens.Palette.foreground3, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
                        .overlay {
                            RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                                .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                        }
                        .contentTransition(.numericText())
                        .accessibilityLabel(TodosCopy.resultCount(store.todos.count, filter: store.filter))
                }
                Text("A clear next step for everything on your plate.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .padding(.top, Tokens.Spacing.snug)
            }
            Spacer(minLength: Tokens.Spacing.medium)
            HStack(spacing: Tokens.Spacing.small) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing tasks")
                }
                Button(action: showShortcuts) {
                    HStack(spacing: Tokens.Spacing.compact) {
                        Image(systemName: "keyboard")
                            .accessibilityHidden(true)
                        Text("Shortcuts")
                        RunnerKeyCap(key: "?", bordered: true)
                    }
                }
                .buttonStyle(RunnerButtonStyle(.secondary))
                .accessibilityLabel("Keyboard shortcuts")

                Button(action: createTodo) {
                    HStack(spacing: Tokens.Spacing.compact) {
                        Image(systemName: "plus")
                            .accessibilityHidden(true)
                        Text("New task")
                    }
                }
                .buttonStyle(RunnerButtonStyle(.primary))
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.bottom, Tokens.Spacing.roomy)
    }
}
