import SwiftUI

/// One Recall hit as a clickable card row: source glyph, title, snippet,
/// and a right-aligned source name plus relative time. Hover fills the
/// row so the click target is obvious without any button chrome.
struct RecallResultRow: View {
    let hit: RecallResult
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Tokens.Spacing.snug) {
                Image(systemName: symbol(for: hit.source))
                    .font(Tokens.Typography.navIcon)
                    .foregroundStyle(Tokens.Palette.mutedForeground)
                    .frame(width: Tokens.SourcesLayout.rowIconColumnWidth, alignment: .center)
                    .padding(.top, Tokens.Spacing.xxsmall)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Tokens.Spacing.xxsmall) {
                    Text(RecallCopy.resultTitle(for: hit))
                        .font(Tokens.Typography.bodyMedium)
                        .foregroundStyle(Tokens.Palette.foreground)
                        .lineLimit(1)
                    if let snippet = hit.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(Tokens.Typography.small)
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: Tokens.Spacing.medium)

                VStack(alignment: .trailing, spacing: Tokens.Spacing.xxsmall) {
                    Text(RecallCopy.sourceLabel(for: hit.source))
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.mutedForeground)
                    if !relativeDate.isEmpty {
                        Text(relativeDate)
                            .font(Tokens.Typography.caption)
                            .monospacedDigit()
                            .foregroundStyle(Tokens.Palette.mutedForeground)
                    }
                }
                .frame(width: Tokens.SourcesLayout.recallMetaColumnWidth, alignment: .trailing)
            }
            .runnerCardRow()
            .background(hovering ? Tokens.Palette.foreground3 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .combine)
    }

    private var relativeDate: String {
        guard let ts = hit.timestamp else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: ts, relativeTo: Date())
    }

    private func symbol(for source: String) -> String {
        switch source {
        case "local_messages": return "message"
        case "local_notes": return "note.text"
        case "local_voice_memos": return "waveform"
        case "local_calendar": return "calendar"
        case "local_reminders": return "checklist"
        case "local_files": return "doc.text"
        case "local_browser_history": return "safari"
        case "maraithon_memory": return "brain"
        case "crm_people": return "person.crop.circle"
        default: return "doc"
        }
    }
}
