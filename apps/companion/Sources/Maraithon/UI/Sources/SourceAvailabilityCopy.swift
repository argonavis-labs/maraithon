import Foundation

/// User-facing copy for sources that are listed but not available in the
/// current companion app.
enum SourceAvailabilityCopy {
    static let unavailableTitle = "Source not available yet"
    static let unavailableDescription = "Choose a supported source from the sidebar to view sync status. This source is not available yet."
    static let unavailableNavigationTitle = "Not available yet"
    static let unavailableBadge = "Soon"
    static let unavailableAccessibilityState = "not available yet"
}
