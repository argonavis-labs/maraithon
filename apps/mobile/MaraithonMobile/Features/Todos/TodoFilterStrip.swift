import SwiftUI

struct TodoFilterStrip: View {
    @Binding var selection: TodoFilter
    let counts: TodoFilterCounts

    var body: some View {
        FilterCountStrip(
            selection: $selection,
            options: TodoFilter.allCases.map { filter in
                FilterCountOption(
                    value: filter,
                    title: filter.title,
                    count: counts.value(for: filter),
                    tint: tint(for: filter)
                )
            },
            accessibilityNoun: "work items"
        )
        .padding(.vertical, Runner.Spacing.small)
        .background(Runner.Palette.background)
    }

    private func tint(for filter: TodoFilter) -> Color {
        switch filter {
        case .triage: .accentColor
        case .all: .accentColor
        case .open: .blue
        case .tracking: .secondary
        case .needsAction: .blue
        case .watching: .teal
        case .decisions: .purple
        case .today: .blue
        case .overdue: .orange
        case .upcoming: .indigo
        case .snoozed: .orange
        case .completed: .green
        }
    }
}
