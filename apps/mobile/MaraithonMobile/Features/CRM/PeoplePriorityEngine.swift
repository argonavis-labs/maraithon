import Foundation
import SwiftUI

enum PeopleFocusTab: String, CaseIterable, Hashable, Identifiable {
    case suggested
    case goals
    case openWork
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggested: "Suggested"
        case .goals: "Goals"
        case .openWork: "Open Work"
        case .all: "All"
        }
    }

    var sectionTitle: String {
        switch self {
        case .suggested: "Suggested Follow-ups"
        case .goals: "Goal-Aligned People"
        case .openWork: "People With Open Work"
        case .all: "All People"
        }
    }

    var tint: Color {
        switch self {
        case .suggested: .accentColor
        case .goals: .purple
        case .openWork: .orange
        case .all: .blue
        }
    }

    func emptyState(searchText: String, hasAnyPeople: Bool) -> PeopleEmptyState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        if !query.isEmpty {
            return PeopleEmptyState(
                title: "No matching people",
                systemImage: "magnifyingglass",
                description: "No \(searchScopeLabel) match \"\(query)\". Clear search or switch tabs."
            )
        }

        if !hasAnyPeople {
            return PeopleEmptyState(
                title: "No relationships yet",
                systemImage: "person.crop.circle.badge.plus",
                description: "Add people so Maraithon can connect relationships to goals, work, and follow-up history."
            )
        }

        switch self {
        case .suggested:
            return PeopleEmptyState(
                title: "No suggested follow-ups",
                systemImage: "sparkles",
                description: "Maraithon will surface someone here when the relationship intelligence sees a useful reason to reconnect."
            )
        case .goals:
            return PeopleEmptyState(
                title: "No goal-linked people",
                systemImage: "target",
                description: "People appear here when they are explicitly linked to an active goal."
            )
        case .openWork:
            return PeopleEmptyState(
                title: "No people with open work",
                systemImage: "checklist",
                description: "People appear here when open work is linked to them."
            )
        case .all:
            return PeopleEmptyState(
                title: "No people match this view",
                systemImage: "person.2",
                description: "Switch tabs, clear search, or add a relationship Maraithon should remember."
            )
        }
    }

    init(requestedStatusFilter: CRMStatusFilter) {
        switch requestedStatusFilter {
        case .atRisk:
            self = .suggested
        case .lead, .active, .closed, .all:
            self = .all
        }
    }

    private var searchScopeLabel: String {
        switch self {
        case .suggested: "suggested follow-ups"
        case .goals: "goal-linked people"
        case .openWork: "people with open work"
        case .all: "people"
        }
    }
}

struct PeopleFocusCounts: Equatable {
    let suggested: Int
    let goals: Int
    let openWork: Int
    let all: Int

    func value(for tab: PeopleFocusTab) -> Int {
        switch tab {
        case .suggested: suggested
        case .goals: goals
        case .openWork: openWork
        case .all: all
        }
    }
}

struct PeopleContactContext: Identifiable {
    let contact: CRMContact
    let suggestion: MobileAPIClient.RemoteReconnectSuggestion?
    let goals: [MobileAPIClient.RemoteGoal]
    let openTodos: [TodoItem]
    let careSummary: RelationshipCareSummary

    var id: UUID { contact.id }

    var topOpenTodo: TodoItem? {
        openTodos.first
    }

    var hasGoalAlignment: Bool {
        !goals.isEmpty
    }

    var hasOpenWork: Bool {
        !openTodos.isEmpty
    }

    func signalLine(for tab: PeopleFocusTab) -> String {
        switch tab {
        case .suggested:
            return clean(suggestion?.reason) ?? fallbackSignal
        case .goals:
            return goalSignal ?? fallbackSignal
        case .openWork:
            return openWorkSignal ?? fallbackSignal
        case .all:
            return clean(suggestion?.reason) ?? goalSignal ?? openWorkSignal ?? fallbackSignal
        }
    }

    func contextLine(for tab: PeopleFocusTab) -> String {
        let context = contact.company.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts: [String]

        switch tab {
        case .suggested:
            parts = [
                context,
                clean(suggestion?.headline),
                suggestion.flatMap { ReconnectPresentation.signalLine(for: $0) }
            ]
                .compactMap { $0 }
        case .goals:
            parts = [context, goalCountLine, workCountLine].compactMap { $0 }
        case .openWork:
            parts = [context, workCountLine, topOpenWorkDetail].compactMap { $0 }
        case .all:
            parts = [context, goalCountLine, workCountLine, careSummary.subtitle].compactMap { $0 }
        }

        return parts.isEmpty ? careSummary.subtitle : parts.joined(separator: " · ")
    }

    var badges: [PeopleSignalBadge] {
        var values: [PeopleSignalBadge] = []

        if suggestion != nil {
            values.append(PeopleSignalBadge(title: "Suggested", tint: .accentColor))
        }

        if !goals.isEmpty {
            values.append(PeopleSignalBadge(title: goalCountLine ?? "Goal", tint: .purple))
        }

        if !openTodos.isEmpty {
            values.append(PeopleSignalBadge(title: workCountLine ?? "Open work", tint: .orange))
        }

        values.append(PeopleSignalBadge(title: careSummary.title, tint: careTint))
        return values
    }

    private var goalSignal: String? {
        guard let goal = goals.first else { return nil }
        let title = goal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let outcome = clean(goal.desiredOutcome) {
            return "\(title): \(outcome)"
        }
        return "Aligned with \(title)"
    }

    private var openWorkSignal: String? {
        guard let todo = topOpenTodo else { return nil }
        if let nextAction = todo.displayNextAction {
            return nextAction
        }
        return todo.title.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }

    private var fallbackSignal: String {
        careSummary.subtitle
    }

    private var goalCountLine: String? {
        guard !goals.isEmpty else { return nil }
        return goals.count == 1 ? "1 goal" : "\(goals.count) goals"
    }

    private var workCountLine: String? {
        guard !openTodos.isEmpty else { return nil }
        return openTodos.count == 1 ? "1 open item" : "\(openTodos.count) open items"
    }

    private var topOpenWorkDetail: String? {
        guard let todo = topOpenTodo else { return nil }
        return ContactLinkedWorkRowCopy.detail(for: todo)
    }

    private var careTint: Color {
        switch careSummary.level {
        case .archived: .secondary
        case .warm: .green
        case .new: .indigo
        case .due: .orange
        case .needsCare: .red
        }
    }

    private func clean(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    }
}

struct PeopleSignalBadge: Identifiable {
    let title: String
    let tint: Color

    var id: String { title }
}

enum PeoplePriorityEngine {
    static func contexts(
        contacts: [CRMContact],
        todos: [TodoItem],
        goals: [MobileAPIClient.RemoteGoal],
        suggestions: [MobileAPIClient.RemoteReconnectSuggestion],
        searchText: String = "",
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PeopleContactContext] {
        let suggestionsByID = suggestionMap(suggestions)
        let goalsByPersonID = goalMap(goals)
        let openTodosByContactID = openTodoMap(todos, now: now, calendar: calendar)

        return contacts
            .map { contact in
                PeopleContactContext(
                    contact: contact,
                    suggestion: suggestionsByID[contact.id],
                    goals: sortedGoals(goalsByPersonID[contact.id] ?? []),
                    openTodos: openTodosByContactID[contact.id] ?? [],
                    careSummary: RelationshipCareSignal.summary(for: contact, now: now, calendar: calendar)
                )
            }
            .filter { matchesSearch($0, searchText: searchText) }
    }

    static func contexts(
        for tab: PeopleFocusTab,
        contexts: [PeopleContactContext],
        suggestions: [MobileAPIClient.RemoteReconnectSuggestion],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PeopleContactContext] {
        let suggestionOrder = suggestionOrder(suggestions)

        let values =
            switch tab {
            case .suggested:
                contexts.filter { $0.suggestion != nil }
            case .goals:
                contexts.filter(\.hasGoalAlignment)
            case .openWork:
                contexts.filter(\.hasOpenWork)
            case .all:
                contexts
            }

        return values.sorted {
            comesBefore($0, $1, tab: tab, suggestionOrder: suggestionOrder, now: now, calendar: calendar)
        }
    }

    static func counts(from contexts: [PeopleContactContext]) -> PeopleFocusCounts {
        PeopleFocusCounts(
            suggested: contexts.filter { $0.suggestion != nil }.count,
            goals: contexts.filter(\.hasGoalAlignment).count,
            openWork: contexts.filter(\.hasOpenWork).count,
            all: contexts.count
        )
    }

    private static func suggestionMap(
        _ suggestions: [MobileAPIClient.RemoteReconnectSuggestion]
    ) -> [UUID: MobileAPIClient.RemoteReconnectSuggestion] {
        suggestions.reduce(into: [:]) { result, suggestion in
            guard let id = UUID(uuidString: suggestion.person.id) else { return }
            result[id] = suggestion
        }
    }

    private static func suggestionOrder(_ suggestions: [MobileAPIClient.RemoteReconnectSuggestion]) -> [UUID: Int] {
        suggestions.enumerated().reduce(into: [:]) { result, item in
            guard let id = UUID(uuidString: item.element.person.id) else { return }
            result[id] = item.offset
        }
    }

    private static func goalMap(_ goals: [MobileAPIClient.RemoteGoal]) -> [UUID: [MobileAPIClient.RemoteGoal]] {
        var result: [UUID: [MobileAPIClient.RemoteGoal]] = [:]

        for goal in goals where goal.status == "active" {
            for link in goal.links where link.resourceType == "person" {
                guard let id = UUID(uuidString: link.resourceID) else { continue }
                result[id, default: []].append(goal)
            }
        }

        return result
    }

    private static func openTodoMap(
        _ todos: [TodoItem],
        now: Date,
        calendar: Calendar
    ) -> [UUID: [TodoItem]] {
        var result: [UUID: [TodoItem]] = [:]

        for todo in todos where !todo.isCompleted {
            guard let contactID = todo.contact?.id else { continue }
            result[contactID, default: []].append(todo)
        }

        return result.mapValues {
            $0.sorted { openTodoComesBefore($0, $1, now: now, calendar: calendar) }
        }
    }

    private static func sortedGoals(_ goals: [MobileAPIClient.RemoteGoal]) -> [MobileAPIClient.RemoteGoal] {
        goals.sorted {
            let lhsPriority = $0.priority ?? 50
            let rhsPriority = $1.priority ?? 50
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private static func matchesSearch(_ context: PeopleContactContext, searchText: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }

        let contactValues: [String] = [
            context.contact.name,
            context.contact.company,
            context.contact.email,
            context.contact.phone,
            context.contact.status.title,
            context.contact.dealStage.title,
            context.contact.notes,
            context.suggestion?.headline ?? "",
            context.suggestion?.reason ?? "",
            context.suggestion?.suggestedAction ?? ""
        ]
        let goalValues: [String] = context.goals.flatMap { goal in
            [goal.title, goal.desiredOutcome ?? "", goal.why ?? ""]
        }
        let todoValues: [String] = context.openTodos.flatMap { todo in
            [todo.title, todo.notes, todo.nextAction ?? ""]
        }
        let values = contactValues + goalValues + todoValues

        return values.contains { value in
            value.lowercased().contains(query)
        }
    }

    private static func comesBefore(
        _ lhs: PeopleContactContext,
        _ rhs: PeopleContactContext,
        tab: PeopleFocusTab,
        suggestionOrder: [UUID: Int],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch tab {
        case .suggested:
            let lhsOrder = suggestionOrder[lhs.contact.id] ?? Int.max
            let rhsOrder = suggestionOrder[rhs.contact.id] ?? Int.max
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return nameComesBefore(lhs.contact, rhs.contact)

        case .goals:
            let lhsPriority = lhs.goals.map { $0.priority ?? 50 }.max() ?? 0
            let rhsPriority = rhs.goals.map { $0.priority ?? 50 }.max() ?? 0
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            if lhs.goals.count != rhs.goals.count { return lhs.goals.count > rhs.goals.count }
            return allTabComesBefore(lhs, rhs, suggestionOrder: suggestionOrder, now: now, calendar: calendar)

        case .openWork:
            let lhsRank = openWorkRank(lhs.openTodos, now: now, calendar: calendar)
            let rhsRank = openWorkRank(rhs.openTodos, now: now, calendar: calendar)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.openTodos.count != rhs.openTodos.count { return lhs.openTodos.count > rhs.openTodos.count }
            return allTabComesBefore(lhs, rhs, suggestionOrder: suggestionOrder, now: now, calendar: calendar)

        case .all:
            return allTabComesBefore(lhs, rhs, suggestionOrder: suggestionOrder, now: now, calendar: calendar)
        }
    }

    private static func allTabComesBefore(
        _ lhs: PeopleContactContext,
        _ rhs: PeopleContactContext,
        suggestionOrder: [UUID: Int],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        if CRMFiltering.isArchived(lhs.contact) != CRMFiltering.isArchived(rhs.contact) {
            return !CRMFiltering.isArchived(lhs.contact)
        }

        let lhsSuggestion = suggestionOrder[lhs.contact.id] ?? Int.max
        let rhsSuggestion = suggestionOrder[rhs.contact.id] ?? Int.max
        if lhsSuggestion != rhsSuggestion {
            return lhsSuggestion < rhsSuggestion
        }

        if lhs.hasGoalAlignment != rhs.hasGoalAlignment {
            return lhs.hasGoalAlignment
        }

        if lhs.hasOpenWork != rhs.hasOpenWork {
            return lhs.hasOpenWork
        }

        if lhs.careSummary.level != rhs.careSummary.level {
            return lhs.careSummary.level > rhs.careSummary.level
        }

        let lhsRank = openWorkRank(lhs.openTodos, now: now, calendar: calendar)
        let rhsRank = openWorkRank(rhs.openTodos, now: now, calendar: calendar)
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }

        return nameComesBefore(lhs.contact, rhs.contact)
    }

    private static func openWorkRank(_ todos: [TodoItem], now: Date, calendar: Calendar) -> Int {
        guard let top = todos.first else { return 0 }
        let timing = timingRank(top, now: now, calendar: calendar)
        return timing + priorityRank(top.priority) * 100 + min(todos.count, 9)
    }

    private static func openTodoComesBefore(
        _ lhs: TodoItem,
        _ rhs: TodoItem,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        let lhsTiming = timingRank(lhs, now: now, calendar: calendar)
        let rhsTiming = timingRank(rhs, now: now, calendar: calendar)
        if lhsTiming != rhsTiming { return lhsTiming > rhsTiming }

        switch (lhs.dueDate, rhs.dueDate) {
        case (.some(let lhsDate), .some(let rhsDate)) where lhsDate != rhsDate:
            return lhsDate < rhsDate
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            let lhsPriority = priorityRank(lhs.priority)
            let rhsPriority = priorityRank(rhs.priority)
            if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func timingRank(_ todo: TodoItem, now: Date, calendar: Calendar) -> Int {
        guard let dueDate = todo.dueDate else { return 0 }
        if dueDate < now && !calendar.isDate(dueDate, inSameDayAs: now) {
            return 1_000
        }
        if calendar.isDate(dueDate, inSameDayAs: now) {
            return 750
        }
        return 250
    }

    private static func priorityRank(_ priority: TodoPriority) -> Int {
        switch priority {
        case .critical: 4
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }

    private static func nameComesBefore(_ lhs: CRMContact, _ rhs: CRMContact) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

private extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
