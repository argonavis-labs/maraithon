import SwiftUI

/// Page header shared by operational pages: muted eyebrow, page title,
/// optional subtitle, and right-aligned actions. Ends with 20pt of
/// padding and a hairline so the first section starts on a rule.
struct RunnerPageHeader<Actions: View>: View {
    let eyebrow: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let actions: Actions

    init(eyebrow: String, title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Tokens.Spacing.medium) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(eyebrow)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .padding(.bottom, Tokens.Spacing.small + 1)
                    Text(title)
                        .font(Tokens.Typography.pageTitle)
                        .tracking(Tokens.Typography.pageTitleTracking)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Tokens.Typography.body)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, Tokens.Spacing.snug)
                    }
                }
                Spacer(minLength: Tokens.Spacing.medium)
                HStack(spacing: Tokens.Spacing.small) {
                    actions
                }
                .padding(.top, Tokens.Spacing.roomy)
            }
            .padding(.bottom, Tokens.Spacing.roomy)
            RunnerHairline()
        }
    }
}

extension RunnerPageHeader where Actions == EmptyView {
    init(eyebrow: String, title: String, subtitle: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, subtitle: subtitle) { EmptyView() }
    }
}
