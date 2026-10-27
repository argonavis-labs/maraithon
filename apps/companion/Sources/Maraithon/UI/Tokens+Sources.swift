import SwiftUI

/// Numeric tokens introduced by the Mac sources and Recall page restyle.
/// Lives beside `Tokens.swift` so page views never spell out literal
/// paddings, dot sizes, or column widths.
extension Tokens {
    enum SourcesLayout {
        /// Status dot on source detail pages (larger than the sidebar dot).
        static let statusDotSize: CGFloat = 8
        /// Horizontal inset for a row inside a hairline card.
        static let cardRowHorizontalPadding: CGFloat = 14
        /// Letter spacing for uppercase section headings.
        static let sectionHeadingTracking: CGFloat = 0.5
        /// Width reserved for the time column at the right of an activity row.
        static let activityTimeColumnWidth: CGFloat = 96
        /// Width reserved for the source and time column at the right of a Recall row.
        static let recallMetaColumnWidth: CGFloat = 150
        /// Vertical breathing room for empty states inside a card.
        static let emptyStateVerticalPadding: CGFloat = 36
        /// Explanation copy inside issue cards wraps at this width.
        static let issueCopyMaxWidth: CGFloat = 560
        /// Icon column width in capability and folder rows.
        static let rowIconColumnWidth: CGFloat = 20
        /// Minimum height of the Recall results area so the page does not collapse.
        static let recallResultsMinHeight: CGFloat = 200
    }
}
