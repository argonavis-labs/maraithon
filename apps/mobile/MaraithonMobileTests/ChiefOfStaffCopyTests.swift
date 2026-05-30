import Testing
@testable import MaraithonMobile

@Suite("Chief of Staff Copy")
struct ChiefOfStaffCopyTests {
    @Test
    func cleansRoleLabelsAndDropsInternalScoreLines() {
        let copy = ChiefOfStaffCopy.clean(
            """
            source_context: The user needs to approve the finance reply.
            confidence_score: 0.94
            The operator's next move is to review the todo list.
            """
        )

        #expect(copy == "You need to approve the finance reply. Your next move is to review the open work.")
        #expect(copy?.localizedCaseInsensitiveContains("the user") == false)
        #expect(copy?.localizedCaseInsensitiveContains("operator") == false)
        #expect(copy?.localizedCaseInsensitiveContains("confidence_score") == false)
        #expect(copy?.localizedCaseInsensitiveContains("todo list") == false)
    }

    @Test
    func rejectsUnsafeInternalOnlyCopy() {
        #expect(ChiefOfStaffCopy.clean("telegram_fit_score: 0.92") == nil)
        #expect(ChiefOfStaffCopy.clean("{\"metadata\":{\"score\":0.92}}") == nil)
    }

    @Test
    func preservesProductUserTerminology() {
        #expect(
            ChiefOfStaffCopy.clean("Investigate why the user interface flashes after reload.") ==
                "Investigate why the user interface flashes after reload."
        )
        #expect(
            ChiefOfStaffCopy.clean("Keep the user experience stable while updating the user's account settings.") ==
                "Keep the user experience stable while updating the user's account settings."
        )
        #expect(
            ChiefOfStaffCopy.clean("Track user response rates during onboarding.") ==
                "Track user response rates during onboarding."
        )
    }

    @Test
    func rewritesGenericUserResponseAndDecisionCopy() {
        #expect(
            ChiefOfStaffCopy.clean("This Gmail thread still needs a user response.") ==
                "This Gmail thread still needs your reply."
        )
        #expect(
            ChiefOfStaffCopy.clean("Rippling needs a user response before onboarding can continue.") ==
                "Rippling needs your reply before onboarding can continue."
        )
        #expect(
            ChiefOfStaffCopy.clean("The billing account needs a user decision.") ==
                "The billing account needs your decision."
        )
    }
}
