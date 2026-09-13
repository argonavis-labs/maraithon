import SwiftUI
import PeopleNetworkKit

/// Network graph tab: the shared canvas inside a hairline card, an optional
/// connection evidence card, and the footer summary.
struct PeopleGraphTab: View {
    let store: PeopleStore
    let network: PeopleNetworkData.Network
    let select: (String) -> Void
    let inspect: (PeopleNetworkData.Edge) -> Void
    let clearConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
            if network.warnings?.contains("calendar_unavailable") == true {
                Text("A connected calendar couldn’t update. Available synced meetings are shown.")
                    .font(Tokens.Typography.small)
                    .foregroundStyle(Tokens.Palette.cautionText)
            }
            PeopleGraphCanvas(network: network, selectedID: store.selectedID, select: select, inspect: inspect)
                .frame(height: Tokens.PeopleLayout.graphHeight)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.CornerRadius.small))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.CornerRadius.small)
                        .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                }
            Text("Drag to explore · Select a person or connection")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.mutedForeground)
            if let edge = store.connection {
                PeopleSection(title: edge.kind == "direct" ? "Your communication" : "Shared context") {
                    HStack {
                        Text(peopleLabel(edge))
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                        Spacer()
                        Button("Close", action: clearConnection)
                            .buttonStyle(RunnerButtonStyle(.plain))
                    }
                    .peopleRow()
                    ForEach(edge.evidence.prefix(12)) { event in
                        PersonEvidenceRow(event: event).peopleRow()
                    }
                }
            }
        }
    }

    private func peopleLabel(_ edge: PeopleNetworkData.Edge) -> String {
        let names = [edge.from, edge.to]
            .filter { $0 != "you" }
            .map { id in network.nodes.first { $0.id == id }?.name ?? "Someone" }
        return names.isEmpty ? "You" : "You and " + names.joined(separator: ", ")
    }
}
