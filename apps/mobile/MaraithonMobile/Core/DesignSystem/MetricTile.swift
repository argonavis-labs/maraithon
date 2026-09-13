import SwiftUI

struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            Label(title, systemImage: systemImage)
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .lineLimit(1)

            Text(value)
                .font(Runner.Typography.sectionTitle)
                .foregroundStyle(Runner.Palette.foreground)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Runner.Spacing.tight)
        .background(Runner.Palette.background, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous)
                .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
        }
    }
}
