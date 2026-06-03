import Foundation

struct ChatMessageLayout: Equatable, Identifiable {
    let id: UUID
    let showsDateHeader: Bool
    let startsGroup: Bool
    let endsGroup: Bool
}

struct ChatTimelineRow: Identifiable {
    let message: ChatMessage
    let layout: ChatMessageLayout

    var id: UUID { message.id }
}

enum ChatMessageTimeline {
    static func layouts(
        for messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> [ChatMessageLayout] {
        let sortedMessages = sorted(messages)

        return sortedMessages.enumerated().map { index, message in
            let previous = index > 0 ? sortedMessages[index - 1] : nil
            let next = index < sortedMessages.count - 1 ? sortedMessages[index + 1] : nil
            let sameAsPrevious = isGrouped(message, with: previous, calendar: calendar)
            let sameAsNext = isGrouped(message, with: next, calendar: calendar)

            return ChatMessageLayout(
                id: message.id,
                showsDateHeader: previous.map { !calendar.isDate($0.sentAt, inSameDayAs: message.sentAt) } ?? true,
                startsGroup: !sameAsPrevious,
                endsGroup: !sameAsNext
            )
        }
    }

    static func rows(
        for messages: [ChatMessage],
        calendar: Calendar = .current
    ) -> [ChatTimelineRow] {
        let sortedMessages = sorted(messages)
        return sortedMessages.enumerated().map { index, message in
            let previous = index > 0 ? sortedMessages[index - 1] : nil
            let next = index < sortedMessages.count - 1 ? sortedMessages[index + 1] : nil
            let sameAsPrevious = isGrouped(message, with: previous, calendar: calendar)
            let sameAsNext = isGrouped(message, with: next, calendar: calendar)
            let layout = ChatMessageLayout(
                id: message.id,
                showsDateHeader: previous.map { !calendar.isDate($0.sentAt, inSameDayAs: message.sentAt) } ?? true,
                startsGroup: !sameAsPrevious,
                endsGroup: !sameAsNext
            )
            return ChatTimelineRow(message: message, layout: layout)
        }
    }

    private static func sorted(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.sorted {
            if $0.sentAt == $1.sentAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sentAt < $1.sentAt
        }
    }

    private static func isGrouped(
        _ message: ChatMessage,
        with other: ChatMessage?,
        calendar: Calendar
    ) -> Bool {
        guard let other else { return false }
        return message.role == other.role && calendar.isDate(message.sentAt, inSameDayAs: other.sentAt)
    }
}
