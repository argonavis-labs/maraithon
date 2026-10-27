/// Presentation-only completion feedback shared by Mac and iPhone. Call
/// confirm only after a successful save; failures never show a success cue.
import Observation
import SwiftUI

@Observable
@MainActor
public final class TodoCompletionFeedback {
    public private(set) var pendingIDs: Set<String> = []
    public private(set) var confirmedIDs: Set<String> = []
    public private(set) var successCount = 0

    public init() {}

    public func begin(_ id: String) -> Bool {
        pendingIDs.insert(id).inserted
    }

    public func confirm(_ id: String, reduceMotion: Bool) async {
        withAnimation(reduceMotion ? nil : .default) {
            confirmedIDs.insert(id)
            successCount += 1
        }
        // Keep the checked row visible for a beat before closing the gap.
        // Cancellation shortens feedback; it must not discard a saved action.
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 450))
    }

    public func finish(_ id: String) {
        pendingIDs.remove(id)
        confirmedIDs.remove(id)
    }
}
