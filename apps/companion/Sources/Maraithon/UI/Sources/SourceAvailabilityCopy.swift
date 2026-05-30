import Foundation

/// User-facing copy for sources that are listed but not available in the
/// current companion app.
enum SourceAvailabilityCopy {
    static let unavailableTitle = "Source unavailable"
    static let unavailableDescription = "Choose a supported source from the sidebar to view assistant context and recent checks. This source is not included in this companion app."
    static let unavailableNavigationTitle = "Unavailable"
    static let unavailableBadge = "Unavailable"
    static let unavailableAccessibilityState = "unavailable"
    static let unavailableSystemImage = "xmark.circle"
}
