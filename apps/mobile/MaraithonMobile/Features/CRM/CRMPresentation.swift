import SwiftUI

/// Shared People presentation pieces: the initials avatar every people row
/// and person header uses, and plain-list row chrome so CRM lists sit on the
/// workspace ground with hairline separators.
struct PeopleAvatar: View {
    let initials: String
    var size: CGFloat = Runner.Layout.avatarSize

    static let detailSize: CGFloat = 56

    var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(size > Runner.Layout.avatarSize ? Runner.Typography.bodySemibold : Runner.Typography.captionMedium)
            .foregroundStyle(Runner.Palette.foreground80)
            .frame(width: size, height: size)
            .background(Runner.Palette.foreground5, in: Circle())
            .accessibilityHidden(true)
    }

    static func initials(for name: String) -> String {
        name
            .split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
            .uppercased()
    }
}

private struct CRMListRowChrome: ViewModifier {
    let insets: EdgeInsets
    let separator: Visibility

    func body(content: Content) -> some View {
        content
            .listRowBackground(Runner.Palette.background)
            .listRowSeparatorTint(Runner.Palette.border)
            .listRowSeparator(separator)
            .listRowInsets(insets)
    }
}

extension View {
    /// Plain-list row on the workspace ground: page insets and hairline separators.
    func crmListRow(
        insets: EdgeInsets = EdgeInsets(
            top: Runner.Spacing.tight,
            leading: Runner.Layout.pageInset,
            bottom: Runner.Spacing.tight,
            trailing: Runner.Layout.pageInset
        ),
        separator: Visibility = .visible
    ) -> some View {
        modifier(CRMListRowChrome(insets: insets, separator: separator))
    }

    /// Non-row content inside a plain list (headers, labels, cards): page
    /// insets, no separator.
    func crmListBlock(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        crmListRow(
            insets: EdgeInsets(top: top, leading: Runner.Layout.pageInset, bottom: bottom, trailing: Runner.Layout.pageInset),
            separator: .hidden
        )
    }

    /// Section label row inside a plain list.
    func crmSectionLabelRow() -> some View {
        crmListBlock(top: Runner.Spacing.roomy, bottom: Runner.Spacing.xsmall)
    }
}
