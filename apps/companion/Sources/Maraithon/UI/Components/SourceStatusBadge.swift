import SwiftUI

/// Shared status indicator used in the sidebar, on the source detail
/// status card, and anywhere we surface the health of a single source.
///
/// Invariant: the state + tone vocabulary defined here is the only
/// status vocabulary in the app. New states must extend the enum, not
/// invent ad-hoc badges elsewhere. `tone` is the traffic-light semantic
/// (good / attention / error); `dotColor` is the page-level dot color,
/// which additionally separates "checking" (info) from "paused" (muted).
struct SourceStatusBadge: View {
    enum Variant {
        /// Icon-only — fits inside dense rows like the sidebar.
        case compact
        /// Dot + label + optional issue line and detail — used on the
        /// source detail status card.
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

        /// Dot color on detail pages: ready, checking, needs attention,
        /// error, and a muted dot for paused or not-updating sources.
        var dotColor: Color {
            switch self {
            case .connected: return Tokens.Palette.success
            case .syncing: return Tokens.Palette.info
            case .paused: return Tokens.Palette.mutedForeground
            case .needsAttention: return Tokens.Palette.caution
            case .disconnected: return Tokens.Palette.mutedForeground
            case .error: return Tokens.Palette.destructive
            }
        }

        /// Text color for the issue line under the label.
        var issueTextColor: Color {
            switch self {
            case .needsAttention: return Tokens.Palette.cautionText
            case .error, .disconnected: return Tokens.Palette.destructiveText
            default: return Tokens.Palette.mutedForeground
            }
        }

        var label: String {
            switch self {
            case .connected: return "Assistant ready"
            case .syncing: return "Checking"
            case .paused: return "Paused"
            case .needsAttention: return "Needs review"
            case .disconnected: return "Not updating"
            case .error: return "Needs review"
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
    /// Extra muted line under the label on the prominent variant (for
    /// example the page headline such as "Notes context is ready").
    var detail: String? = nil

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
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
            RunnerStatusDot(color: state.dotColor, pulsing: state == .syncing)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + Tokens.Spacing.xsmall }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                Text(state.label)
                    .font(Tokens.Typography.bodyMedium)
                    .foregroundStyle(Tokens.Palette.foreground)
                if let subtitle = state.subtitle {
                    Text(subtitle)
                        .font(Tokens.Typography.small)
                        .foregroundStyle(state.issueTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
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
        var parts = [state.label]
        if let subtitle = state.subtitle { parts.append(subtitle) }
        if let detail, !detail.isEmpty { parts.append(detail) }
        return parts.joined(separator: ". ")
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
        SourceStatusBadge(state: .connected, variant: .prominent, detail: "Notes context is ready")
        SourceStatusBadge(state: .syncing, variant: .prominent)
        SourceStatusBadge(state: .needsAttention("Full Disk Access required"), variant: .prominent)
        SourceStatusBadge(state: .error("NSURLErrorDomain Code=-1009"), variant: .prominent)
    }
    .padding(Tokens.Spacing.large)
    .frame(width: 420)
    .background(Tokens.Palette.background)
}
