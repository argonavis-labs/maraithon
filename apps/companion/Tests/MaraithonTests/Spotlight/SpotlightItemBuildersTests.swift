import CoreSpotlight
import XCTest
@testable import Maraithon

/// Exercises the per-source `CSSearchableItem` builders. We pull the
/// attribute-set fields back out and check the title / description /
/// dates round-trip from the typed wire payloads. Keywords aren't
/// pinned exactly (NLTagger output drifts subtly across OS versions)
/// but we sanity-check the non-empty + bounded contract.
final class SpotlightItemBuildersTests: XCTestCase {

    func testNoteRoundTripsTitleSnippetAndDates() throws {
        let note = NoteRecord(
            guid: "NOTE-7",
            localId: "p:7",
            title: "Project Beacon kickoff",
            snippet: "Discuss timeline and owner.",
            body: nil,
            bodyFormat: nil,
            folder: "Work",
            isPinned: true,
            createdAt: "2026-04-12T13:30:00Z",
            modifiedAt: "2026-04-12T14:00:00Z"
        )
        let item = SpotlightItemBuilders.item(forNote: note)
        XCTAssertEqual(item.uniqueIdentifier, "notes:NOTE-7")
        XCTAssertEqual(item.domainIdentifier, "com.maraithon.companion.notes")
        XCTAssertEqual(item.attributeSet.title, "Project Beacon kickoff")
        XCTAssertEqual(
            item.attributeSet.contentDescription,
            "Discuss timeline and owner."
        )
        XCTAssertNotNil(item.attributeSet.contentCreationDate)
        XCTAssertNotNil(item.attributeSet.contentModificationDate)
    }

    func testNoteFallsBackToBodyWhenSnippetMissing() {
        let note = NoteRecord(
            guid: "NOTE-8",
            localId: "p:8",
            title: "Body fallback",
            snippet: nil,
            body: "Longer text used as the snippet when none was set.",
            bodyFormat: "plain",
            folder: nil,
            isPinned: false,
            createdAt: nil,
            modifiedAt: nil
        )
        let item = SpotlightItemBuilders.item(forNote: note)
        XCTAssertEqual(
            item.attributeSet.contentDescription,
            "Longer text used as the snippet when none was set."
        )
    }

    func testVoiceMemoSurfacesTranscriptAsDescription() {
        let memo = VoiceMemoPayload(
            guid: "VM-9",
            localId: "p:9",
            title: "Standup",
            durationSeconds: 30,
            fileSizeBytes: 1024,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: "Discussed the release blockers and next steps."
        )
        let item = SpotlightItemBuilders.item(forVoiceMemo: memo)
        XCTAssertEqual(item.uniqueIdentifier, "voice_memos:VM-9")
        XCTAssertEqual(item.domainIdentifier, "com.maraithon.companion.voice_memos")
        XCTAssertEqual(item.attributeSet.title, "Standup")
        XCTAssertEqual(
            item.attributeSet.contentDescription,
            "Discussed the release blockers and next steps."
        )
    }

    func testReminderCarriesDueDate() {
        let due = Date(timeIntervalSince1970: 1_700_100_000)
        let reminder = ReminderPayload(
            guid: "R-1",
            localId: "r:R-1",
            title: "Pay rent",
            notes: "via the apartment portal",
            listName: "Home",
            listColor: "#FF0000",
            priority: 0,
            dueAt: due,
            completedAt: nil,
            isCompleted: false,
            hasAlarm: false,
            urlAttachment: nil,
            createdAt: nil,
            modifiedAt: nil
        )
        let item = SpotlightItemBuilders.item(forReminder: reminder)
        XCTAssertEqual(item.uniqueIdentifier, "reminders:R-1")
        XCTAssertEqual(item.attributeSet.title, "Pay rent")
        XCTAssertEqual(item.attributeSet.dueDate, due)
    }

    func testCalendarCarriesStartAndEnd() {
        let start = Date(timeIntervalSince1970: 1_700_200_000)
        let end = Date(timeIntervalSince1970: 1_700_203_600)
        let event = CalendarEventPayload(
            guid: "C-1",
            localId: "cal:C-1",
            calendarName: "Work",
            calendarColor: "#00AAFF",
            title: "Design review",
            notes: nil,
            location: "Building 3",
            startAt: start,
            endAt: end,
            isAllDay: false,
            isRecurring: false,
            organizerEmail: nil,
            attendeesCount: 0,
            attendeeEmails: [],
            createdAt: nil,
            modifiedAt: nil
        )
        let item = SpotlightItemBuilders.item(forCalendarEvent: event)
        XCTAssertEqual(item.uniqueIdentifier, "calendar:C-1")
        XCTAssertEqual(item.attributeSet.startDate, start)
        XCTAssertEqual(item.attributeSet.endDate, end)
    }

    func testFileSurfacesExtractedText() {
        let body = "The quick brown fox jumps over the lazy dog."
        let b64 = Data(body.utf8).base64EncodedString()
        let file = FilePayload(
            guid: "F-1",
            localId: "/Users/x/Documents/notes.txt",
            path: "/Users/x/Documents/notes.txt",
            filename: "notes.txt",
            extension: "txt",
            mimeType: "text/plain",
            byteSize: 44,
            textContentBase64: b64,
            textTruncated: false,
            createdAt: Date(timeIntervalSince1970: 1_700_300_000),
            modifiedAt: Date(timeIntervalSince1970: 1_700_300_500)
        )
        let item = SpotlightItemBuilders.item(forFile: file)
        XCTAssertEqual(item.uniqueIdentifier, "files:F-1")
        XCTAssertEqual(item.attributeSet.title, "notes.txt")
        XCTAssertEqual(item.attributeSet.contentDescription, body)
    }

    func testDescriptionClipsAtLimit() {
        // 800-character body should produce a clipped snippet ending
        // with an ellipsis. Keeps the indexer payload bounded.
        let long = String(repeating: "abcdefghij", count: 80)
        let note = NoteRecord(
            guid: "NOTE-LONG",
            localId: "p:99",
            title: "Long body",
            snippet: long,
            body: nil,
            bodyFormat: nil,
            folder: nil,
            isPinned: false,
            createdAt: nil,
            modifiedAt: nil
        )
        let item = SpotlightItemBuilders.item(forNote: note)
        let desc = try? XCTUnwrap(item.attributeSet.contentDescription)
        XCTAssertNotNil(desc)
        XCTAssertLessThanOrEqual(desc?.count ?? .max, SpotlightItemBuilders.descriptionLimit + 1)
        XCTAssertTrue(desc?.hasSuffix("…") ?? false)
    }

    func testKeywordsAreDedupedAndCapped() {
        let kw = SpotlightItemBuilders.keywords(
            from: "Sam Sam Sam meeting",
            body: nil,
            extra: ["Sam", "Personal"]
        )
        // Dedupes case-insensitively.
        XCTAssertEqual(Set(kw.map { $0.lowercased() }).count, kw.count)
        XCTAssertLessThanOrEqual(kw.count, 12)
        XCTAssertTrue(kw.contains("Sam"))
        XCTAssertTrue(kw.contains("Personal"))
    }
}
