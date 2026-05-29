import SwiftUI

/// Placeholder detail pane for source descriptors that are listed before
/// their sync implementation is installed.
struct ComingSoonDetailView: View {
    var body: some View {
        ContentUnavailableView(
            SourceAvailabilityCopy.unavailableTitle,
            systemImage: "clock.badge.questionmark",
            description: Text(SourceAvailabilityCopy.unavailableDescription)
        )
        .navigationTitle(SourceAvailabilityCopy.unavailableNavigationTitle)
    }
}
