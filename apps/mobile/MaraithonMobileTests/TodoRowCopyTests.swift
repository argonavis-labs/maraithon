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
        #expect(TodoEditorCopy.decisionReviewSectionTitle == "Decision ready for review")
        #expect(TodoEditorCopy.contextSummaryLabel == "Who and thread")
        #expect(TodoEditorCopy.decisionPromptLabel == "Decision needed")
        #expect(TodoEditorCopy.whyNowLabel == "Why this matters now")
        #expect(TodoEditorCopy.sourceContextLabel == "Context checked")
        #expect(TodoEditorCopy.preparedMoveLabel == "Suggested move")
        #expect(TodoEditorCopy.evidenceLabel == "Source evidence")
        #expect(TodoEditorCopy.timingSectionTitle == "Timing")
        #expect(TodoEditorCopy.dueDateToggleTitle == "Add due date")
        #expect(TodoEditorCopy.relatedPersonSectionTitle == "Related person")
        #expect(TodoEditorCopy.noPersonLabel == "No one linked")
        #expect(TodoEditorCopy.newNavigationTitle == "New work item")
        #expect(TodoEditorCopy.editNavigationTitle == "Edit work item")
        #expect(TodoEditorCopy.reviewDecisionNavigationTitle == "Review decision")
        #expect(TodoEditorCopy.navigationTitle(isNew: true, hasDecisionContext: true) == "New work item")
        #expect(TodoEditorCopy.navigationTitle(isNew: false, hasDecisionContext: true) == "Review decision")
        #expect(TodoEditorCopy.navigationTitle(isNew: false, hasDecisionContext: false) == "Edit work item")
        #expect(!TodoEditorCopy.visibleLabels.contains("People Link"))
        #expect(!TodoEditorCopy.visibleLabels.contains("Due Date"))
        #expect(!TodoEditorCopy.visibleLabels.contains("Decision context"))
        #expect(!TodoEditorCopy.visibleLabels.contains("Prepared move"))
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

    @Test
    func decisionContextPrioritizesSourceBackedCardOverGenericNotes() {
        let todo = TodoItem(
            title: "Send Michael the campaign update",
            notes: "Michael asked for campaign status.",
            nextAction: "Reply to Michael",
            decisionPrompt: "Decide whether to send the campaign owner and ETA.",
            decisionContextSummary: "Michael · UGC campaign · Investor",
            whyNow: "Michael is waiting and no later reply was found.",
            sourceContext: "Checked Gmail",
            nextBestAction: "Approve a short reply.",
            evidenceExcerpt: "Can you send the next update?"
        )

        let context = TodoDecisionContext(todo: todo)

        #expect(context.contextSummary == "Michael · UGC campaign · Investor")
        #expect(context.rowContext == "Michael · UGC campaign · Investor")
        #expect(context.rowReason == "Send the campaign update with a clear owner and timing. Why now: Michael is waiting; no later reply is recorded. Reviewed Gmail")
        #expect(context.rowMove == "Approve a short reply.")
        #expect(context.preparedMove == "Approve a short reply.")
        #expect(context.evidence == "Can you send the next update?")
        #expect(context.hasChiefOfStaffContext)
        #expect(TodoDecisionSignals.signalPillTitle(for: todo) == "Decision")
    }

    @Test
    func genericActionCardPromptDoesNotCreateADecisionLaneItem() {
        let todo = TodoItem(
            title: "Review customer plan",
            notes: "Customer asked for the revised rollout plan.",
            nextAction: "Send revised rollout plan.",
            decisionPrompt: "Handle this now, snooze it, or dismiss it."
        )

        #expect(!TodoDecisionSignals.needsDecision(todo))
        #expect(TodoDecisionSignals.signalPillTitle(for: todo) == nil)
    }

    @Test
    func decisionContextPolishesChiefOfStaffCopyBeforeDisplay() {
        let todo = TodoItem(
            title: "Finance reply",
            notes: "The user needs to approve the finance reply.",
            nextAction: "User should send the ETA.",
            decisionPrompt: "The user needs to approve the finance reply.",
            whyNow: "This needs operator attention before noon.",
            sourceContext: "source_context: Checked Gmail\nconfidence_score: 0.94",
            nextBestAction: "User should send the ETA.",
            evidenceExcerpt: "The operator's last message asked for timing."
        )

        let context = TodoDecisionContext(todo: todo)

        #expect(context.rowContext == "You need to approve the finance reply.")
        #expect(context.rowReason == "Why now: This needs your attention before noon. Reviewed Gmail")
        #expect(context.rowMove == "You should send the ETA.")
        #expect(context.evidence == "Your last message asked for timing.")
    }

    @Test
    func decisionContextFallsBackToCleanNotesAndNextActionWithoutActionCard() {
        let todo = TodoItem(
            title: "Review customer plan",
            notes: "Customer asked for the revised rollout plan.",
            nextAction: "Send revised rollout plan."
        )

        let context = TodoDecisionContext(todo: todo)

        #expect(context.rowContext == "Customer asked for the revised rollout plan.")
        #expect(context.rowReason == nil)
        #expect(context.rowMove == "Send revised rollout plan.")
        #expect(!context.hasChiefOfStaffContext)
    }

    @Test
    func decisionContextSuppressesDuplicatePromptAndMove() {
        let todo = TodoItem(
            title: "Review customer plan",
            notes: "Review customer plan",
            nextAction: "Review customer plan",
            decisionPrompt: "Review customer plan",
            decisionContextSummary: "Review customer plan",
            nextBestAction: "Review customer plan",
            evidenceExcerpt: "Customer asked for the revised rollout plan."
        )

        let context = TodoDecisionContext(todo: todo)

        #expect(context.rowContext == nil)
        #expect(context.rowMove == nil)
        #expect(context.preparedMove == nil)
        #expect(context.evidence == "Customer asked for the revised rollout plan.")
        #expect(context.hasChiefOfStaffContext)
    }
}
