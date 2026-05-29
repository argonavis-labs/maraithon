import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Todo Row Copy")
struct TodoRowCopyTests {
    @Test
    func editorCopyGuidesConcreteCommitmentCapture() {
        #expect(TodoEditorCopy.commitmentSectionTitle == "Commitment")
        #expect(TodoEditorCopy.titlePlaceholder == "What needs to happen")
        #expect(TodoEditorCopy.notesPlaceholder == "Context")
        #expect(TodoEditorCopy.nextActionPlaceholder == "Next move")
        #expect(TodoEditorCopy.timingSectionTitle == "Timing")
        #expect(TodoEditorCopy.dueDateToggleTitle == "Add due date")
        #expect(TodoEditorCopy.relatedPersonSectionTitle == "Related person")
        #expect(TodoEditorCopy.noPersonLabel == "No one linked")
        #expect(TodoEditorCopy.newNavigationTitle == "New work item")
        #expect(TodoEditorCopy.editNavigationTitle == "Edit work item")
        #expect(!TodoEditorCopy.visibleLabels.contains("People Link"))
        #expect(!TodoEditorCopy.visibleLabels.contains("Due Date"))
    }

    @Test
    func overdueDueLabelMatchesWorkLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = TodoItem(title: "Send investor update")
        let dueDate = now.addingTimeInterval(-2 * 24 * 60 * 60)

        let copy = TodoRowCopy.dueText(
            for: todo,
            dueDate: dueDate,
            now: now,
            calendar: calendar
        )

        #expect(copy.hasPrefix("Past due "))
        #expect(!copy.localizedCaseInsensitiveContains("overdue"))
        #expect(!copy.localizedCaseInsensitiveContains("late"))
    }

    @Test
    func dueTodayLabelStaysCompact() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let todo = TodoItem(title: "Review customer plan")

        let copy = TodoRowCopy.dueText(
            for: todo,
            dueDate: now.addingTimeInterval(60),
            now: now,
            calendar: calendar
        )

        #expect(copy == "Today")
    }
}
