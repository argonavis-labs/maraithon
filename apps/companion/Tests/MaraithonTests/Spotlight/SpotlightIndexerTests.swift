import CoreSpotlight
import XCTest
@testable import Maraithon

/// Verifies the indexer's facade contract: items round-trip through
/// the injected backing index with the right unique / domain
/// identifiers, deletes scope by domain, and clearAll wipes the lot.
/// Each test stubs the index closures so we never touch the real
/// `CSSearchableIndex` on the runner — the production-default path
/// is exercised by the smoke test in `SpotlightIndexerSmokeTests`.
final class SpotlightIndexerTests: XCTestCase {

    @MainActor
    func testIndexHandsItemsToBackingClosure() async throws {
        let recorder = IndexRecorder()
        let indexer = SpotlightIndexer(
            indexer: { items in
                let snapshots = items.map { IndexedItemSnapshot(item: $0) }
                await recorder.recordIndex(snapshots)
            },
            deleter: { _ in },
            clearer: { }
        )
        let note = NoteRecord(
            guid: "NOTE-1",
            localId: "p:1",
            title: "Lunch with Sam",
            snippet: "noon tomorrow",
            body: nil,
            bodyFormat: nil,
            folder: "Personal",
            isPinned: false,
            createdAt: nil,
            modifiedAt: nil
        )
        let item = SpotlightItemBuilders.item(forNote: note)
        try await indexer.index(items: [item])

        let captured = await recorder.indexedItems
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.uniqueIdentifier, "notes:NOTE-1")
        XCTAssertEqual(
            captured.first?.domainIdentifier,
            "com.maraithon.companion.notes"
        )
        XCTAssertEqual(captured.first?.title, "Lunch with Sam")
    }

    @MainActor
    func testEmptyBatchShortCircuits() async throws {
        let recorder = IndexRecorder()
        let indexer = SpotlightIndexer(
            indexer: { items in
                let snapshots = items.map { IndexedItemSnapshot(item: $0) }
                await recorder.recordIndex(snapshots)
            },
            deleter: { _ in },
            clearer: { }
        )
        try await indexer.index(items: [])
        let captured = await recorder.indexedItems
        XCTAssertTrue(captured.isEmpty, "empty batch must not hit the index")
    }

    @MainActor
    func testDeleteScopesByDomain() async throws {
        let recorder = IndexRecorder()
        let indexer = SpotlightIndexer(
            indexer: { _ in },
            deleter: { domains in await recorder.recordDelete(domains) },
            clearer: { }
        )
        try await indexer.delete(domainIdentifier: "com.maraithon.companion.notes")

        let captured = await recorder.deletedDomains
        XCTAssertEqual(captured, [["com.maraithon.companion.notes"]])
    }

    @MainActor
    func testClearAllInvokesBacking() async throws {
        let recorder = IndexRecorder()
        let indexer = SpotlightIndexer(
            indexer: { _ in },
            deleter: { _ in },
            clearer: { await recorder.recordClear() }
        )
        try await indexer.clearAll()
        let count = await recorder.clearedCount
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testDomainIdentifierShape() {
        XCTAssertEqual(
            SpotlightDomain.identifier(forSource: "notes"),
            "com.maraithon.companion.notes"
        )
        XCTAssertEqual(
            SpotlightDomain.identifier(forSource: "voice_memos"),
            "com.maraithon.companion.voice_memos"
        )
    }

    @MainActor
    func testUniqueIdentifierShape() {
        XCTAssertEqual(
            SpotlightDomain.uniqueIdentifier(source: "notes", guid: "NOTE-1"),
            "notes:NOTE-1"
        )
    }
}

/// Thread-safe accumulator for the injected backing-index closures.
/// Each closure is `@Sendable`; the actor keeps the test side
/// strict-concurrency-clean.
actor IndexRecorder {
    private(set) var indexedItems: [IndexedItemSnapshot] = []
    private(set) var deletedDomains: [[String]] = []
    private(set) var clearedCount: Int = 0

    func recordIndex(_ items: [IndexedItemSnapshot]) {
        indexedItems.append(contentsOf: items)
    }

    func recordDelete(_ domains: [String]) {
        deletedDomains.append(domains)
    }

    func recordClear() {
        clearedCount += 1
    }
}

struct IndexedItemSnapshot: Equatable, Sendable {
    let uniqueIdentifier: String
    let domainIdentifier: String?
    let title: String?

    init(item: CSSearchableItem) {
        uniqueIdentifier = item.uniqueIdentifier
        domainIdentifier = item.domainIdentifier
        title = item.attributeSet.title
    }
}
