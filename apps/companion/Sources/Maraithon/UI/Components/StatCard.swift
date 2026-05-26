import SwiftUI

/// Single-cell rollup used in stat grids on detail panes.
///
/// Deliberately chrome-less — no borders, no shadows, no fills. Spacing
/// and type hierarchy do the visual grouping. See `AGENTS.md` rule #2.
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)

            HStack(spacing: Tokens.Spacing.xsmall) {
                if let trend, let trendDescription = trendLabel(trend) {
                    Image(systemName: trendSymbol(trend))
                        .font(.caption)
                        .foregroundStyle(trendTone(trend).color)
                    Text(trendDescription)
                        .font(.caption)
                        .foregroundStyle(trendTone(trend).color)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        StatCard(title: "Total", value: "12,408")
        StatCard(title: "Cursor", value: "p:218,402", caption: "rowid")
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 640)
}
