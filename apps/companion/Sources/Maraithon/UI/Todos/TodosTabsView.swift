import SwiftUI

/// Active / Snoozed / Completed / All tasks view switcher with the accent
/// underline the web tabs use. Switching a tab reloads the store.
struct TodosTabsView: View {
    @Bindable var store: TodosStore

    var body: some View {
        HStack(spacing: Tokens.Spacing.large) {
            ForEach(TodoListFilter.allCases) { filter in
                TodosTab(title: filter.title, isActive: store.filter == filter) {
                    guard store.filter != filter else { return }
                    store.filter = filter
                    Task { await store.load() }
                }
            }
            Spacer()
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Tokens.Palette.border)
                .frame(height: Tokens.Stroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Task views")
    }
}

private struct TodosTab: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(isActive ? Tokens.Typography.bodyMedium : Tokens.Typography.body)
                .foregroundStyle(isActive || hovering ? Tokens.Palette.foreground : Tokens.Palette.mutedForeground)
                .padding(.top, Tokens.Spacing.snug)
                .padding(.bottom, Tokens.Spacing.tight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isActive ? Tokens.Palette.selectedBar : .clear)
                        .frame(height: Tokens.Stroke.activeBar)
                        .offset(y: Tokens.Stroke.hairline)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}
