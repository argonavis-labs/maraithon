import SwiftUI
import PeopleNetworkKit

/// Network graph tab: the shared canvas inside a hairline card, a hint line,
/// and an evidence card for a tapped connection.
struct PeopleNetworkGraphTab: View {
    static let graphHeight: CGFloat = 360

    let network: PeopleNetworkData.Network
    let selectedID: String?
    let connection: PeopleNetworkData.Edge?
    let select: (String) -> Void
    let inspect: (PeopleNetworkData.Edge) -> Void
    let clearConnection: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.medium) {
            if network.warnings?.contains("calendar_unavailable") == true {
                Text("A connected calendar couldn’t update. Available synced meetings are shown.")
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.cautionText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PeopleGraphCanvas(network: network, selectedID: selectedID, select: select, inspect: inspect)
                .frame(maxWidth: .infinity)
                .frame(height: Self.graphHeight)
                .background(Runner.Palette.background)
                .clipShape(RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Runner.Radius.card, style: .continuous)
                        .stroke(Runner.Palette.border, lineWidth: Runner.Stroke.hairline)
                }

            Text("Drag to explore · Select a person or connection")
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)

            if let edge = connection {
                connectionCard(edge)
            }
        }
    }

    private func connectionCard(_ edge: PeopleNetworkData.Edge) -> some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.small) {
            RunnerSectionLabel(edge.kind == "direct" ? "Your communication" : "Shared context")
            RunnerCard {
                HStack(spacing: Runner.Spacing.small) {
                    Text(peopleLabel(edge))
                        .font(Runner.Typography.small)
                        .foregroundStyle(Runner.Palette.mutedForeground)
                        .lineLimit(2)
                    Spacer(minLength: Runner.Spacing.small)
                    Button("Close", action: clearConnection)
                        .buttonStyle(RunnerButtonStyle(.plain, compact: true))
                }
                .runnerCardRow()

                ForEach(Array(edge.evidence.prefix(12))) { event in
                    RunnerHairline()
                    PeopleEvidenceRow(event: event)
                        .runnerCardRow()
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

/// One piece of evidence: title, source and time, then the excerpt.
struct PeopleEvidenceRow: View {
    let event: PeopleNetworkData.Evidence

    var body: some View {
        VStack(alignment: .leading, spacing: Runner.Spacing.xxsmall) {
            Text(event.title ?? "\(PeopleNetworkCopy.channelName(event.source)) exchange")
                .font(Runner.Typography.bodyMedium)
                .foregroundStyle(Runner.Palette.foreground)
                .lineLimit(2)
            Text(meta)
                .font(Runner.Typography.caption)
                .foregroundStyle(Runner.Palette.mutedForeground)
                .lineLimit(1)
            if let excerpt = event.excerpt, !excerpt.isEmpty {
                Text(excerpt)
                    .font(Runner.Typography.small)
                    .foregroundStyle(Runner.Palette.foreground80)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
    }

    private var meta: String {
        var parts = [PeopleNetworkCopy.channelName(event.source), PeopleNetworkCopy.absoluteContact(event.at)]
        if event.kind == "calendar" || event.type == "calendar" {
            parts.append("On your calendar")
        } else if event.kind == "shared" || event.kind == "conversation" {
            parts.append("Shared conversation")
        }
        return parts.joined(separator: " · ")
    }
}
