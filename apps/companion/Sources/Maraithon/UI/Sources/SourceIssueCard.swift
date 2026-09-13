import SwiftUI

/// Card used by every non-healthy source state (blocked, permission,
/// error, waiting for first check): a status dot and title, the
/// explanation copy, optional muted notes and extra content, then a
/// hairline and the action buttons.
///
/// Invariant: copy wraps at `Tokens.SourcesLayout.issueCopyMaxWidth` so
/// long permission instructions stay readable on wide windows.
struct SourceIssueCard<Extra: View, Actions: View>: View {
    var dotColor: Color? = nil
    let title: String
    let message: String
    var notes: [String] = []
    @ViewBuilder let extra: Extra
    @ViewBuilder let actions: Actions

    init(
        dotColor: Color? = nil,
        title: String,
        message: String,
        notes: [String] = [],
        @ViewBuilder extra: () -> Extra,
        @ViewBuilder actions: () -> Actions
    ) {
        self.dotColor = dotColor
        self.title = title
        self.message = message
        self.notes = notes
        self.extra = extra()
        self.actions = actions()
    }

    var body: some View {
        RunnerCard {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
                    HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
                        if let dotColor {
                            RunnerStatusDot(color: dotColor)
                                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Tokens.Spacing.xsmall }
                        }
                        Text(title)
                            .font(Tokens.Typography.bodyMedium)
                            .foregroundStyle(Tokens.Palette.foreground)
                            .accessibilityAddTraits(.isHeader)
                    }
                    Text(message)
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    extra
                }
                .frame(maxWidth: Tokens.SourcesLayout.issueCopyMaxWidth, alignment: .leading)
                .padding(.vertical, Tokens.Spacing.medium)
                .padding(.horizontal, Tokens.SourcesLayout.cardRowHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)

                RunnerHairline()

                HStack(spacing: Tokens.Spacing.small) {
                    actions
                }
                .runnerCardRow()
            }
        }
    }
}

extension SourceIssueCard where Extra == EmptyView {
    init(
        dotColor: Color? = nil,
        title: String,
        message: String,
        notes: [String] = [],
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(dotColor: dotColor, title: title, message: message, notes: notes, extra: { EmptyView() }, actions: actions)
    }
}
