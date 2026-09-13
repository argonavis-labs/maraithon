import SwiftUI

/// Layout constants for the todo workspace: the work column, its action
/// cards, the chat pane, and the details sheet. Every numeric value on that
/// surface lives here so the views never spell out literal sizes.
extension Tokens {
    enum TodoLayout {
        /// Content narrower than this stacks the work column above the chat.
        static let twoColumnMinWidth: CGFloat = 900
        static let workColumnMinWidth: CGFloat = 420
        /// The chat pane takes this share of the content width, clamped below.
        static let chatPaneFraction: CGFloat = 0.38
        static let chatPaneMinWidth: CGFloat = 380
        static let chatPaneMaxWidth: CGFloat = 520
        /// Share of the height the work column takes when stacked.
        static let stackedWorkFraction: CGFloat = 0.45
        /// Maraithon's read wraps at roughly 68 characters of 13pt text.
        static let readMaxWidth: CGFloat = 560
        static let cardMaxWidth: CGFloat = 640
        static let fieldLabelWidth: CGFloat = 56
        static let reviewBodyHeight: CGFloat = 132
        static let reviewBodyMaxHeight: CGFloat = 220
        /// A user turn's bubble never spans more than this share of the pane.
        static let bubbleMaxWidthFraction: CGFloat = 0.8
        /// Runner turn rhythm: a user turn opens breathing room, replies follow tightly.
        static let turnGapBeforeUser: CGFloat = 32
        static let turnGapBeforeAssistant: CGFloat = 10
        static let proseLineSpacing: CGFloat = 4
        static let composerMinLines = 1
        static let composerMaxLines = 6
        static let activityCountMinWidth: CGFloat = 18
        static let detailsSheetWidth: CGFloat = 520
        static let detailsSheetHeight: CGFloat = 560
    }
}
