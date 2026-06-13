import Foundation
import Testing
@testable import MaraithonMobile

@Suite("Reconnect Presentation")
struct ReconnectPresentationTests {
    private func suggestion(from json: String) throws -> MobileAPIClient.RemoteReconnectSuggestion {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            MobileAPIClient.RemoteReconnectSuggestion.self,
            from: Data(json.utf8)
        )
    }

    private func json(
        category: String,
        daysSinceLast: String = "null",
        cadenceDays: String = "null"
    ) -> String {
        """
        {
          "person": {"id": "11111111-1111-1111-1111-111111111111", "display_name": "Jane Thuet", "status": "active"},
          "category": "\(category)",
          "headline": "Open work",
          "reason": "1 open item with Jane.",
          "suggested_action": "Reach out to Jane.",
          "days_since_last": \(daysSinceLast),
          "cadence_days": \(cadenceDays),
          "communication_score": 60,
          "overdue": true,
          "open_work": [{"id": "22222222-2222-2222-2222-222222222222", "title": "Reply about Team plan"}]
        }
        """
    }

    @Test
    func mapsKnownCategories() throws {
        #expect(ReconnectPresentation.category(for: try suggestion(from: json(category: "open_work"))) == .openWork)
        #expect(ReconnectPresentation.category(for: try suggestion(from: json(category: "overdue"))) == .overdue)
        #expect(ReconnectPresentation.category(for: try suggestion(from: json(category: "going_quiet"))) == .goingQuiet)
    }

    @Test
    func unknownCategoryFallsBackGracefully() throws {
        let mapped = ReconnectPresentation.category(for: try suggestion(from: json(category: "mystery")))
        #expect(mapped == .unknown)
        #expect(mapped.label == "Reconnect")
    }

    @Test
    func signalLineCombinesRecencyAndCadence() throws {
        let withCadence = try suggestion(from: json(category: "overdue", daysSinceLast: "24", cadenceDays: "7"))
        #expect(ReconnectPresentation.signalLine(for: withCadence) == "24d quiet · usually every 7d")
    }

    @Test
    func signalLineFallsBackToRecencyOnly() throws {
        let recencyOnly = try suggestion(from: json(category: "going_quiet", daysSinceLast: "30"))
        #expect(ReconnectPresentation.signalLine(for: recencyOnly) == "30d since last contact")
    }

    @Test
    func signalLineIsNilWithoutRecency() throws {
        let none = try suggestion(from: json(category: "open_work"))
        #expect(ReconnectPresentation.signalLine(for: none) == nil)
    }

    @Test
    func cadenceLabelBuckets() {
        #expect(ReconnectPresentation.cadenceLabel(1) == "day")
        #expect(ReconnectPresentation.cadenceLabel(7) == "7d")
        #expect(ReconnectPresentation.cadenceLabel(12) == "week or two")
        #expect(ReconnectPresentation.cadenceLabel(30) == "month")
        #expect(ReconnectPresentation.cadenceLabel(90) == "few months")
    }

    @Test
    func decodesOpenWorkItems() throws {
        let decoded = try suggestion(from: json(category: "open_work"))
        #expect(decoded.openWork.count == 1)
        #expect(decoded.openWork.first?.title == "Reply about Team plan")
        #expect(decoded.person.displayName == "Jane Thuet")
    }
}
