/// Field rows inside the review card: recipient and subject for messages
/// (editable for Gmail), calendar times for events, the browser step, and the
/// draft body. Edits flow back through bindings; nothing sends from here.
import SwiftUI

struct TodoReviewFields: View {
    let draft: CompanionConversationDraft
    let editable: Bool
    @Binding var recipient: String
    @Binding var subject: String
    @Binding var cc: String
    @Binding var bcc: String
    @Binding var bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.small) {
            switch draft.provider {
            case "calendar": calendarRows
            case "browser": row("Browser", "Local Chrome · on your Mac")
            default: messageRows
            }
            bodyField
        }
    }

    @ViewBuilder private var messageRows: some View {
        if let from = draft.from, !from.isEmpty { row("From", from) }
        if editable && draft.provider == "gmail" {
            field("To", $recipient)
            field("Subject", $subject)
            field("Cc", $cc)
            field("Bcc", $bcc)
        } else {
            if !recipient.isEmpty {
                row("To", draft.recipientName.map { "\($0) · \(recipient)" } ?? recipient)
            }
            if !subject.isEmpty { row("Subject", subject) }
        }
    }

    @ViewBuilder private var calendarRows: some View {
        if let from = draft.from, !from.isEmpty { row("Calendar", from) }
        if let start = draft.startAt { row("Starts", TodoActionCopy.eventDate(start, timezone: draft.timezone)) }
        if let end = draft.endAt { row("Ends", TodoActionCopy.eventDate(end, timezone: draft.timezone)) }
        if let timezone = draft.timezone { row("Time zone", timezone) }
    }

    @ViewBuilder private var bodyField: some View {
        if draft.provider == "calendar" || draft.provider == "browser" {
            if !bodyText.isEmpty {
                Text(bodyText)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if editable {
            TextEditor(text: $bodyText)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.foreground)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Spacing.compact)
                .frame(height: Tokens.TodoLayout.reviewBodyHeight)
                .background(Tokens.Palette.background, in: RoundedRectangle(cornerRadius: Tokens.CornerRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.CornerRadius.control)
                        .stroke(Tokens.Palette.border, lineWidth: Tokens.Stroke.hairline)
                }
                .accessibilityLabel("Draft message")
        } else {
            ScrollView {
                Text(bodyText)
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Tokens.TodoLayout.reviewBodyMaxHeight)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
            Text(label)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .frame(width: Tokens.TodoLayout.fieldLabelWidth, alignment: .leading)
            Text(value)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.foreground)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.small) {
            Text(label)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.mutedForeground)
                .frame(width: Tokens.TodoLayout.fieldLabelWidth, alignment: .leading)
            TextField(label, text: text)
                .textFieldStyle(.plain)
                .font(Tokens.Typography.small)
                .foregroundStyle(Tokens.Palette.foreground)
                .labelsHidden()
                .accessibilityLabel(label)
        }
        .padding(.bottom, Tokens.Spacing.xsmall)
        .overlay(alignment: .bottom) { RunnerHairline() }
    }
}
