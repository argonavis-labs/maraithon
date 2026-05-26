import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Chat Message Timeline")
struct ChatMessageTimelineTests {
    @Test
    func groupsAdjacentMessagesFromSameRoleOnSameDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let first = message(id: "00000000-0000-0000-0000-000000000001", sentAt: baseDate, role: .assistant)
        let second = message(id: "00000000-0000-0000-0000-000000000002", sentAt: baseDate.addingTimeInterval(30), role: .assistant)
        let third = message(id: "00000000-0000-0000-0000-000000000003", sentAt: baseDate.addingTimeInterval(60), role: .user)

        let layouts = ChatMessageTimeline.layouts(for: [third, first, second], calendar: calendar)

        #expect(layouts.map(\.id) == [first.id, second.id, third.id])
        #expect(layouts[0] == ChatMessageLayout(id: first.id, showsDateHeader: true, startsGroup: true, endsGroup: false))
        #expect(layouts[1] == ChatMessageLayout(id: second.id, showsDateHeader: false, startsGroup: false, endsGroup: true))
        #expect(layouts[2] == ChatMessageLayout(id: third.id, showsDateHeader: false, startsGroup: true, endsGroup: true))
    }

    @Test
    func startsNewGroupAcrossCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let first = message(id: "00000000-0000-0000-0000-000000000004", sentAt: baseDate, role: .assistant)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: baseDate)!
        let second = message(id: "00000000-0000-0000-0000-000000000005", sentAt: nextDay, role: .assistant)

        let layouts = ChatMessageTimeline.layouts(for: [first, second], calendar: calendar)

        #expect(layouts[0].endsGroup)
        #expect(layouts[1].showsDateHeader)
        #expect(layouts[1].startsGroup)
    }

    private func message(id: String, sentAt: Date, role: ChatRole) -> ChatMessage {
        ChatMessage(
            id: UUID(uuidString: id)!,
            body: "Message",
            sentAt: sentAt,
            role: role
        )
    }
}
