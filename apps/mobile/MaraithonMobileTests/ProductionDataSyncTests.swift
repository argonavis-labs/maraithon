import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Production Data Sync")
@MainActor
struct ProductionDataSyncTests {
    @Test
    func personPayloadUsesPersonalFallbackForEmptyRelationshipContext() {
        let payload = ProductionDataSync.personPayload(
            name: "Alex",
            company: " ",
            email: "alex@example.com",
            phone: "",
            status: .active,
            dealStage: .qualified,
            dealValue: 0,
            notes: ""
        )

        #expect(payload["relationship"] as? String == "Personal")
    }

    @Test
    func personPayloadCanPersistLastContactedAt() {
        let date = Date(timeIntervalSince1970: 1_779_800_000)
        let payload = ProductionDataSync.personPayload(
            name: "Alex",
            company: "Friend",
            email: "alex@example.com",
            phone: "",
            status: .active,
            dealStage: .qualified,
            dealValue: 0,
            notes: "",
            lastContactedAt: date
        )

        #expect(payload["last_interaction_at"] as? String == ISO8601DateFormatter().string(from: date))
    }
}
