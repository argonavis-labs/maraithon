import SwiftUI

struct ChiefOfStaffPrompt: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let message: String
    let systemImage: String
    let tint: Color

    static let planDay = ChiefOfStaffPrompt(
        id: "plan-day",
        title: "Plan my day",
        subtitle: "Prioritize past-due work, people, and next actions.",
        message: "Plan my day like my chief of staff. Start with the single next move, then list the past-due work, relationship follow-ups, and anything I can safely ignore.",
        systemImage: "calendar.badge.clock",
        tint: .indigo
    )

    static let relationships = ChiefOfStaffPrompt(
        id: "relationships",
        title: "Who needs care?",
        subtitle: "Find relationships that deserve a follow-up.",
        message: "Review my people and tell me who needs attention today. Include why each person matters, what I likely owe them, and the best next follow-up.",
        systemImage: "person.crop.circle.badge.exclamationmark",
        tint: .red
    )

    static let captureTodo = ChiefOfStaffPrompt(
        id: "capture-todo",
        title: "Capture work",
        subtitle: "Turn loose context into a concrete next action.",
        message: "Help me capture a work item. Ask only for the missing details needed to make it concrete: owner, due date, person, and next action.",
        systemImage: "checklist",
        tint: .orange
    )

    static let draftFollowUp = ChiefOfStaffPrompt(
        id: "draft-follow-up",
        title: "Draft follow-up",
        subtitle: "Write a concise reply with relationship context.",
        message: "Help me draft a follow-up. Use my relationship context and open loops, then give me a ready-to-send message plus the next work item if one is needed.",
        systemImage: "square.and.pencil",
        tint: .blue
    )

    static let waitingOnMe = ChiefOfStaffPrompt(
        id: "waiting-on-me",
        title: "What do I owe?",
        subtitle: "Separate what I owe from what others owe me.",
        message: "What do I owe other people right now? Separate what is waiting on me from what I am waiting on, and recommend the smallest useful next action.",
        systemImage: "arrowshape.turn.up.left.2",
        tint: .purple
    )

    static let today: [ChiefOfStaffPrompt] = [
        .planDay,
        .relationships,
        .waitingOnMe
    ]

    static let chat: [ChiefOfStaffPrompt] = [
        .planDay,
        .draftFollowUp,
        .relationships,
        .captureTodo,
        .waitingOnMe
    ]
}
