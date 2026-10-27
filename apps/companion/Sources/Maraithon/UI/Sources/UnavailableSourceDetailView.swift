import SwiftUI

/// Page for source descriptors that are listed but unsupported in this
/// companion build: the shared sources header and one empty-state card.
struct UnavailableSourceDetailView: View {
    var body: some View {
        RunnerPage {
            RunnerPageHeader(
                eyebrow: SourceDetailCopy.sourcesEyebrow,
                title: SourceAvailabilityCopy.unavailableNavigationTitle
            )
            .padding(.bottom, Tokens.Spacing.large)

            RunnerCard {
                RunnerEmptyState(
                    title: SourceAvailabilityCopy.unavailableTitle,
                    description: SourceAvailabilityCopy.unavailableDescription
                )
            }
        }
    }
}
