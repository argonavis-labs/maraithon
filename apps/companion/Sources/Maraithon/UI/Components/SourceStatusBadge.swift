import SwiftUI

/// Shared status pill used in the sidebar, on the iMessage detail status
/// card, and anywhere we surface the health of a single source.
///
/// Invariant: the symbol + tone vocabulary defined here is the only
/// status vocabulary in the app. New states must extend the enum, not
/// invent ad-hoc badges elsewhere.
struct SourceStatusBadge: View {
    enum Variant {
        /// Icon-only — fits inside dense rows like the sidebar.
        case compact
        /// Icon + label + subtitle — used in the detail pane status card.
        case prominent
    }

    enum State: Hashable {
        case connected
        case syncing
        case paused
        case needsAttention(String)
        case disconnected
        case error(String)

        var symbol: String {
            switch self {
            case .connected: return "circle.fill"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .paused: return "pause.circle"
            case .needsAttention: return "exclamationmark.triangle.fill"
            case .disconnected: return "xmark.circle.fill"
            case .error: return "xmark.octagon.fill"
            }
        }

        var tone: StatusTone {
            switch self {
            case .connected: return .good
            case .syncing: return .good
            case .paused: return .muted
            case .needsAttention: return .attention
            case .disconnected: return .error
            case .error: return .error
            }
        }

        var label: String {
            switch self {
            case .connected: return "Connected"
            case .syncing: return "Syncing"
            case .paused: return "Paused"
            case .needsAttention: return "Needs attention"
            case .disconnected: return "Not syncing"
            case .error: return "Error"
            }
        }

        var subtitle: String? {
            switch self {
            case .needsAttention(let reason): return SourceIssueCopy.status(reason)
            case .error(let reason): return SourceIssueCopy.status(reason)
            default: return nil
            }
        }
    }

    let state: State
    var variant: Variant = .compact

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch variant {
        case .compact:
            compactBody
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        case .prominent:
            prominentBody
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var compactBody: some View {
        symbolImage
            .frame(width: Tokens.IconSize.inline, height: Tokens.IconSize.inline)
    }

    private var prominentBody: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.medium) {
            symbolImage
                .font(.title)
                .frame(width: Tokens.IconSize.prominent, height: Tokens.IconSize.prominent)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xsmall) {
                Text(state.label)
                    .font(.headline)
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var symbolImage: some View {
        let img = Image(systemName: state.symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(state.tone.color)
        if case .syncing = state, !reduceMotion {
            if #available(macOS 15.0, *) {
                img.symbolEffect(.rotate, options: .repeat(.continuous))
            } else {
                img.symbolEffect(.pulse, options: .repeating)
            }
        } else {
            img
        }
    }

    private var accessibilityLabel: String {
        if let subtitle = state.subtitle {
            return "\(state.label). \(subtitle)"
        }
        return state.label
    }
}

#Preview("Compact") {
    VStack(alignment: .leading, spacing: Tokens.Spacing.medium) {
        SourceStatusBadge(state: .connected)
        SourceStatusBadge(state: .syncing)
        SourceStatusBadge(state: .paused)
        SourceStatusBadge(state: .needsAttention("Full Disk Access required"))
        SourceStatusBadge(state: .disconnected)
        SourceStatusBadge(state: .error("clientError(status: 401, body: nil)"))
    }
    .padding(Tokens.Spacing.large)
}

#Preview("Prominent") {
    VStack(alignment: .leading, spacing: Tokens.Spacing.large) {
        SourceStatusBadge(state: .connected, variant: .prominent)
        SourceStatusBadge(state: .syncing, variant: .prominent)
        SourceStatusBadge(state: .needsAttention("Full Disk Access required"), variant: .prominent)
        SourceStatusBadge(state: .error("NSURLErrorDomain Code=-1009"), variant: .prominent)
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 420)
}
