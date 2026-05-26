import XCTest
@testable import Maraithon

/// Round-trip and corruption tests for `NotesBodyDecoder`. We don't
/// commit a real `.note` blob because the production database is
/// per-machine; instead `NotesBodyFixture` synthesises a wire-faithful
/// `NoteStoreProto` body whose plain text equals a known string. Every
/// assertion here is a property the decoder must hold against the real
/// blobs too.
final class NotesBodyDecoderTests: XCTestCase {
    func testDecodesPlainBody() {
        let body = "Buy milk.\nPick up dry cleaning."
        let blob = NotesBodyFixture.blob(for: body)
        XCTAssertEqual(NotesBodyDecoder.decode(blob), body)
    }

    func testDecodesMultilineUTF8Body() {
        let body = "Café list:\n- ☕️ espresso\n- 🥐 croissant\n中文也可以"
        let blob = NotesBodyFixture.blob(for: body)
        XCTAssertEqual(NotesBodyDecoder.decode(blob), body)
    }

    func testIgnoresTrailingFields() {
        // The real Apple blob carries attribute runs after `note_text`.
        // Our decoder must still surface the text cleanly when those
        // trailing fields are present.
        let body = "Meeting notes for Tuesday."
        let blob = NotesBodyFixture.blob(for: body, attribute: "attr-run-data")
        XCTAssertEqual(NotesBodyDecoder.decode(blob), body)
    }

    func testReturnsNilOnEmptyData() {
        XCTAssertNil(NotesBodyDecoder.decode(Data()))
    }

    func testReturnsNilOnNonGzipData() {
        XCTAssertNil(NotesBodyDecoder.decode(Data([0x00, 0x01, 0x02])))
    }

    func testRecoversReadableTextFromGzippedNonProtobuf() throws {
        // Valid gzip envelope but the payload isn't a NoteStoreProto.
        // The strict NoteStoreProto walk fails, then the heuristic
        // fallback grabs the longest readable UTF-8 run — so we still
        // recover something for the agent / inference layer rather
        // than throwing away the entire body.
        let bogus = Data("not a protobuf, but real text we can still use".utf8)
        let gzipped = try Gzip.compress(bogus)
        XCTAssertEqual(
            NotesBodyDecoder.decode(gzipped),
            "not a protobuf, but real text we can still use"
        )
    }

    func testReturnsNilOnTruncatedGzip() throws {
        let body = "Truncated"
        let blob = NotesBodyFixture.blob(for: body)
        // Lop the trailer off — must surface as a decode failure.
        let truncated = blob.prefix(blob.count - 4)
        XCTAssertNil(NotesBodyDecoder.decode(truncated))
    }

    func testReturnsNilOnEmptyBodyString() {
        let blob = NotesBodyFixture.blob(for: "")
        XCTAssertNil(NotesBodyDecoder.decode(blob))
    }

    func testDecodesLargeBody() {
        // Stress the inflate buffer growth path with a body larger than
        // our default 4 KB seed.
        let body = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 200)
        let blob = NotesBodyFixture.blob(for: body)
        XCTAssertEqual(NotesBodyDecoder.decode(blob), body)
    }
}
