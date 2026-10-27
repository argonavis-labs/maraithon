import SwiftUI

/// Single-cell rollup used in stat grids on detail panes.
///
/// Deliberately chrome-less — no borders, no shadows, no fills. Spacing
/// and type hierarchy do the visual grouping, using the workspace
/// type scale and palette so the tile matches the rest of the theme.
struct StatCard: View {
    enum Trend {
        case up(String)
        case down(String)
        case flat
    }

    let title: String
    let value: String
    var caption: String? = nil
    var trend: Trend? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
            Text(title)
                .sectionHeaderStyle()

            Text(value)
                .font(Tokens.Typography.pageTitle)
                .tracking(Tokens.Typography.pageTitleTracking)
                .monospacedDigit()
                .foregroundStyle(Tokens.Palette.foreground)

            HStack(spacing: Tokens.Spacing.xsmall) {
                if let trend, let trendDescription = trendLabel(trend) {
                    Image(systemName: trendSymbol(trend))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(trendTone(trend).color)
                    Text(trendDescription)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(trendTone(trend).color)
                }
                if let caption {
                    Text(caption)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Tokens.Spacing.medium)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)\(caption.map { ". \($0)" } ?? "")")
    }

    private func trendSymbol(_ trend: Trend) -> String {
        switch trend {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        }
    }

    private func trendTone(_ trend: Trend) -> StatusTone {
        switch trend {
        case .up: return .good
        case .down: return .attention
        case .flat: return .muted
        }
    }

    private func trendLabel(_ trend: Trend) -> String? {
        switch trend {
        case .up(let s), .down(let s): return s
        case .flat: return nil
        }
    }
}

#Preview("Grid") {
    let columns = [GridItem(.adaptive(minimum: 140), spacing: Tokens.Spacing.medium)]
    return LazyVGrid(columns: columns, spacing: Tokens.Spacing.medium) {
        StatCard(title: "Today", value: "47", trend: .up("+12"))
        StatCard(title: "This week", value: "318", caption: "across 14 chats")
        StatCard(title: "Assistant context", value: "12,408")
        StatCard(title: "Last checked", value: "2m", caption: "successful check")
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 640)
    .background(Tokens.Palette.background)
}
