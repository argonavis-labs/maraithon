import SwiftUI

/// Page header used at the top of every tab: small eyebrow, large title with an
/// optional count chip, muted subtitle, and right-aligned actions.
struct RunnerPageHeader<Actions: View>: View {
    let eyebrow: String?
    let title: String
    var count: Int? = nil
    var subtitle: String? = nil
    @ViewBuilder let actions: () -> Actions

    init(eyebrow: String? = nil, title: String, count: Int? = nil, subtitle: String? = nil,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.eyebrow = eyebrow
        self.title = title
        self.count = count
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow {
                Text(eyebrow)
                    .font(Runner.Typography.caption)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .padding(.bottom, Runner.Spacing.compact)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Runner.Spacing.medium) {
                    titleRow
                    Spacer(minLength: Runner.Spacing.small)
                    actionsRow
                }
                VStack(alignment: .leading, spacing: Runner.Spacing.snug) {
                    titleRow
                    actionsRow
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.mutedForeground)
                    .padding(.top, Runner.Spacing.compact)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, Runner.Spacing.medium)
    }
}

extension RunnerPageHeader {
    fileprivate var titleRow: some View {
        HStack(alignment: .center, spacing: Runner.Spacing.snug) {
            Text(title)
                .font(Runner.Typography.pageTitle)
                .tracking(Runner.Typography.pageTitleTracking)
                .foregroundStyle(Runner.Palette.foreground)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if let count {
                RunnerCountChip(count: count)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    fileprivate var actionsRow: some View {
        HStack(spacing: Runner.Spacing.small) {
            actions()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct RunnerCountChip: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(Runner.Typography.caption)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Runner.Palette.mutedForeground)
            .padding(.horizontal, Runner.Spacing.compact)
            .padding(.vertical, Runner.Spacing.xxsmall + 1)
            .background(Runner.Palette.foreground3, in: RoundedRectangle(cornerRadius: Runner.Radius.badge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Runner.Radius.badge, style: .continuous)
                    .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
            }
            .contentTransition(.numericText())
    }
}
