import XCTest
@testable import Maraithon

/// State machine tests for `OnboardingFlow`. The flow is pure value
/// transitions — these tests stay off SwiftUI and only exercise the
/// model. UI rendering correctness is left to manual verification.
@MainActor
final class OnboardingFlowTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "onboarding-flow-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func makeFlow() -> OnboardingFlow {
        OnboardingFlow(defaults: defaults, eventLog: nil)
    }

    func testStartsAtConnectWhenNotComplete() {
        let flow = makeFlow()
        XCTAssertEqual(flow.current, .connect)
        XCTAssertFalse(flow.isComplete)
    }

    func testAdvanceWalksThroughEveryStep() {
        let flow = makeFlow()
        XCTAssertEqual(flow.current, .connect)
        flow.advance()
        XCTAssertEqual(flow.current, .whatWeSync)
        flow.advance()
        XCTAssertEqual(flow.current, .fullDiskAccess)
        flow.advance()
        XCTAssertEqual(flow.current, .backfill)
        flow.advance()
        XCTAssertEqual(flow.current, .done)
    }

    func testAdvanceFromDoneIsNoop() {
        let flow = makeFlow()
        flow.advance() // -> whatWeSync
        flow.advance() // -> fda
        flow.advance() // -> backfill
        flow.advance() // -> done
        flow.advance() // no-op
        XCTAssertEqual(flow.current, .done)
    }

    func testBackBoundedByConnect() {
        let flow = makeFlow()
        flow.back()
        XCTAssertEqual(flow.current, .connect)
        flow.advance()
        flow.back()
        XCTAssertEqual(flow.current, .connect)
    }

    func testBackFromBackfillReturnsToFullDiskAccess() {
        let flow = makeFlow()
        flow.advance() // -> whatWeSync
        flow.advance() // -> fda
        flow.advance() // -> backfill
        XCTAssertEqual(flow.current, .backfill)
        flow.back()
        XCTAssertEqual(flow.current, .fullDiskAccess)
    }

    func testBackFromWhatWeSyncReturnsToConnect() {
        let flow = makeFlow()
        flow.advance() // -> whatWeSync
        XCTAssertEqual(flow.current, .whatWeSync)
        flow.back()
        XCTAssertEqual(flow.current, .connect)
    }

    func testMarkCompletePersistsFlag() {
        let flow = makeFlow()
        flow.markComplete()
        XCTAssertTrue(flow.isComplete)
        XCTAssertTrue(defaults.bool(forKey: OnboardingFlow.completedDefaultsKey))
    }

    func testMarkCompleteIsIdempotent() {
        let flow = makeFlow()
        flow.markComplete()
        flow.markComplete()
        XCTAssertTrue(flow.isComplete)
    }

    func testRehydratesAsDoneWhenFlagPersists() {
        defaults.set(true, forKey: OnboardingFlow.completedDefaultsKey)
        let flow = makeFlow()
        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.isComplete)
    }

    func testResetReturnsToConnectMidFlow() {
        let flow = makeFlow()
        flow.advance() // -> whatWeSync
        flow.advance() // -> fda
        flow.advance() // -> backfill
        flow.reset()
        XCTAssertEqual(flow.current, .connect)
        XCTAssertFalse(flow.isComplete)
    }

    func testResetDoesNotReplayCompletedOnboarding() {
        defaults.set(true, forKey: OnboardingFlow.completedDefaultsKey)
        let flow = makeFlow()
        XCTAssertEqual(flow.current, .done)
        flow.reset()
        // Reset must NOT clobber the completed flag — sign-out / sign-in
        // by a user who's already onboarded should keep them out of the
        // flow.
        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.isComplete)
    }

    func testProgressIncreasesMonotonicallyAcrossSteps() {
        let flow = makeFlow()
        var previous = flow.progress
        for _ in 0..<4 {
            flow.advance()
            XCTAssertGreaterThan(flow.progress, previous)
            previous = flow.progress
        }
        XCTAssertEqual(flow.progress, 1.0, accuracy: 0.0001)
    }

    func testProgressStepsCoverAllVisibleSteps() {
        XCTAssertEqual(OnboardingFlow.Step.progressSteps,
                       [.connect, .whatWeSync, .fullDiskAccess, .backfill])
    }

    func testFullHappyPathPersistsCompletion() {
        let flow = makeFlow()
        flow.advance() // connect -> whatWeSync
        flow.advance() // whatWeSync -> fda
        flow.advance() // fda -> backfill
        flow.markComplete()
        flow.advance() // backfill -> done

        XCTAssertEqual(flow.current, .done)
        XCTAssertTrue(flow.isComplete)

        // A fresh flow constructed against the same defaults should
        // start in .done — the user has already onboarded.
        let revisit = OnboardingFlow(defaults: defaults, eventLog: nil)
        XCTAssertEqual(revisit.current, .done)
    }

    func testSignOutMidFlowResetsButPreservesCompletionWhenAlreadyDone() {
        // Simulate sign-out mid-flow before completion: reset moves
        // back to .connect.
        let flow = makeFlow()
        flow.advance()
        flow.reset()
        XCTAssertEqual(flow.current, .connect)

        // Now complete the flow.
        flow.advance() // -> whatWeSync
        flow.advance() // -> fda
        flow.advance() // -> backfill
        flow.markComplete()
        flow.advance() // -> done

        // Simulate later sign-out: reset is called but the user already
        // completed onboarding, so the flow stays in .done.
        flow.reset()
        XCTAssertEqual(flow.current, .done)
    }

    func testMarkFullDiskAccessSkippedPersists() {
        let flow = makeFlow()
        XCTAssertFalse(flow.isFullDiskAccessSkipped)
        flow.markFullDiskAccessSkipped()
        XCTAssertTrue(flow.isFullDiskAccessSkipped)
        // Independent of the "complete" flag.
        XCTAssertFalse(flow.isComplete)
    }

    func testMarkFullDiskAccessSkippedIsIdempotent() {
        let flow = makeFlow()
        flow.markFullDiskAccessSkipped()
        flow.markFullDiskAccessSkipped()
        XCTAssertTrue(flow.isFullDiskAccessSkipped)
    }

    func testClearFullDiskAccessSkippedFlipsBack() {
        let flow = makeFlow()
        flow.markFullDiskAccessSkipped()
        XCTAssertTrue(flow.isFullDiskAccessSkipped)
        flow.clearFullDiskAccessSkipped()
        XCTAssertFalse(flow.isFullDiskAccessSkipped)
    }

    func testRecordFullDiskAccessGrantedClearsSkippedFlag() {
        let flow = makeFlow()
        flow.markFullDiskAccessSkipped()
        XCTAssertTrue(flow.isFullDiskAccessSkipped)

        flow.recordFullDiskAccessGranted()

        XCTAssertFalse(flow.isFullDiskAccessSkipped)
    }

    func testFreshFlowReadsPersistedFDASkipFlag() {
        defaults.set(true, forKey: OnboardingFlow.fullDiskAccessSkippedDefaultsKey)
        let flow = makeFlow()
        XCTAssertTrue(flow.isFullDiskAccessSkipped)
    }
}
