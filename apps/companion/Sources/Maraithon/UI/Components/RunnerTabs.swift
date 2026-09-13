import SwiftUI

/// Underlined view switcher (Active / Snoozed…, People / Network graph) with
/// the accent bar the web tabs use. Generic over any `Hashable` selection.
struct RunnerTabs<Selection: Hashable>: View {
    struct Item: Identifiable {
        let id: Selection
        let title: String
    }

    let items: [Item]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: Tokens.Spacing.large) {
            ForEach(items) { item in
                RunnerTab(title: item.title, isActive: selection == item.id) {
                    selection = item.id
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
    }
}

private struct RunnerTab: View {
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
