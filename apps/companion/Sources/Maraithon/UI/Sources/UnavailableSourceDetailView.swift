import SwiftUI

/// Detail pane for source descriptors that are listed but unsupported in
/// this companion build.
struct UnavailableSourceDetailView: View {
    var body: some View {
        ContentUnavailableView(
            SourceAvailabilityCopy.unavailableTitle,
            systemImage: SourceAvailabilityCopy.unavailableSystemImage,
            description: Text(SourceAvailabilityCopy.unavailableDescription)
        )
        .navigationTitle(SourceAvailabilityCopy.unavailableNavigationTitle)
    }
}
