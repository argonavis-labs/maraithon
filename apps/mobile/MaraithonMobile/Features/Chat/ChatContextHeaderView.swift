import SwiftUI

struct ChatContextHeaderView: View {
    let header: ChatContextHeader

    var body: some View {
        RunnerCard {
            HStack(alignment: .top, spacing: Runner.Spacing.snug) {
                Image(systemName: header.systemImage)
                    .font(Runner.Typography.smallMedium)
                    .foregroundStyle(Runner.Palette.accent)
                    .frame(width: Runner.Spacing.large + Runner.Spacing.xsmall, height: Runner.Spacing.large + Runner.Spacing.xsmall)
                    .background(Runner.Palette.selected, in: RoundedRectangle(cornerRadius: Runner.Radius.control, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                    Text(header.title)
                        .font(Runner.Typography.bodyMedium)
                        .foregroundStyle(Runner.Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)

                    if let subtitle = header.subtitle {
                        Text(subtitle)
                            .font(Runner.Typography.small)
                            .foregroundStyle(Runner.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Runner.Spacing.small)

                if let status = header.status {
                    StatusPill(title: status.title, tint: status.tint)
                }
            }
            .runnerCardRow()

            ForEach(header.items) { item in
                RunnerHairline()

                VStack(alignment: .leading, spacing: Runner.Spacing.xsmall) {
                    Label(item.title, systemImage: item.systemImage)
                        .font(Runner.Typography.captionMedium)
                        .foregroundStyle(Runner.Palette.mutedForeground)

                    Text(item.body)
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .runnerCardRow()
            }
        }
    }
}
