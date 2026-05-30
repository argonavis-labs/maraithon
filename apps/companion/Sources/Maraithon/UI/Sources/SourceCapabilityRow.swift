import SwiftUI

/// Native list row for one source capability in a detail pane.
struct SourceCapabilityRow: View {
    let capability: SourceCapability

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.small) {
            Image(systemName: capability.systemImage)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: Tokens.IconSize.inline, alignment: .center)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(capability.title)
                    .font(.headline)
                Text(capability.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
