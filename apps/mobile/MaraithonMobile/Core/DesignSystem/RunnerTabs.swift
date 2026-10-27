import SwiftUI

/// Underlined view switcher (Active / Snoozed / …) with the accent bar the web
/// tabs use. Scrolls horizontally when the titles do not fit.
struct RunnerTabs<Selection: Hashable>: View {
    struct Item: Identifiable {
        let id: Selection
        let title: String
        var count: Int? = nil
    }

    let items: [Item]
    @Binding var selection: Selection

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Runner.Spacing.large) {
                ForEach(items) { item in
                    RunnerTab(title: item.title, count: item.count, isActive: selection == item.id) {
                        withAnimation(.snappy(duration: 0.2)) { selection = item.id }
                    }
                }
            }
            .padding(.horizontal, Runner.Layout.pageInset)
        }
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) { RunnerHairline() }
        .accessibilityElement(children: .contain)
    }
}

private struct RunnerTab: View {
    let title: String
    let count: Int?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Runner.Spacing.compact) {
                Text(title)
                    .font(isActive ? Runner.Typography.smallMedium : Runner.Typography.small)
                if let count {
                    Text(count.formatted())
                        .font(Runner.Typography.micro.monospacedDigit())
                        .padding(.horizontal, Runner.Spacing.xsmall + 1)
                        .padding(.vertical, 1)
                        .background(Runner.Palette.foreground5, in: Capsule())
                }
            }
            .foregroundStyle(isActive ? Runner.Palette.foreground : Runner.Palette.mutedForeground)
            .padding(.top, Runner.Spacing.snug)
            .padding(.bottom, Runner.Spacing.tight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? Runner.Palette.selectedBar : .clear)
                    .frame(height: Runner.Stroke.activeBar)
                    .offset(y: Runner.Stroke.hairline)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityLabel(count.map { "\(title), \($0.formatted())" } ?? title)
    }
}
