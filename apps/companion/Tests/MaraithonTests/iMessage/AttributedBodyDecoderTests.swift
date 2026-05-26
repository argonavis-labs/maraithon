import XCTest
@testable import Maraithon

/// Small hex-to-Data helper for the production-trace fixtures below.
private extension Data {
    init(hexString: String) {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var idx = hexString.startIndex
        while idx < hexString.endIndex {
            let next = hexString.index(idx, offsetBy: 2)
            if let byte = UInt8(hexString[idx..<next], radix: 16) {
                bytes.append(byte)
            }
            idx = next
        }
        self = Data(bytes)
    }
}

final class AttributedBodyDecoderTests: XCTestCase {
    func testDecodesArchivedAttributedString() throws {
        let blob = try IMessageFixture.attributedBodyData("Hello world")
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), "Hello world")
    }

    func testReturnsNilForEmptyBlob() {
        XCTAssertNil(AttributedBodyDecoder.decode(Data()))
    }

    func testReturnsNilForGarbage() {
        let bytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03]
        XCTAssertNil(AttributedBodyDecoder.decode(Data(bytes)))
    }

    func testDecodesUnicodeBody() throws {
        let blob = try IMessageFixture.attributedBodyData("こんにちは — emoji safe 👋")
        XCTAssertEqual(AttributedBodyDecoder.decode(blob), "こんにちは — emoji safe 👋")
    }

    func testDecodesRealOutgoingTypedstreamWithTrailingContinuationByte() {
        // Hex from a real outgoing iMessage row's `attributedBody`
        // column on macOS Sequoia — a reaction message. The body
        // "Reacted 😂 to an image" sits at the end of a typedstream
        // blob and is immediately followed by `0x86` (a UTF-8
        // continuation byte without a leader). A naive byte-classifier
        // that accepts any 0x80-0xbf would read past the body and
        // emit invalid UTF-8 — the state-machine decoder stops at
        // the body boundary and returns the correct text.
        let hex = "040B73747265616D747970656481E803840140848484124E5341747472" +
            "6962757465645374" +
            "72696E67008484084E534F626A656374008592848484084E535374" +
            "72696E67019484012B185265616374656420F09F988220746F2061" +
            "6E20696D61676586"
        let data = Data(hexString: hex)
        let decoded = AttributedBodyDecoder.decode(data)
        XCTAssertEqual(decoded, "Reacted 😂 to an image")
    }

    func testStripsTypedstreamPlusLengthPrefix() {
        // Real outgoing-iMessage typedstream pattern: the body text is
        // preceded by `+` (0x2b, string type marker) followed by a
        // one-byte length, then the UTF-8 bytes. Both prefix bytes are
        // printable ASCII so a naive scanner sweeps them into the
        // captured text, producing leaks like "+jIf possible…".
        let magic: [UInt8] = [
            0x04, 0x0b,
            0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64
        ]
        let body = "Hey! What is your electricians contact?"
        let bodyBytes: [UInt8] = Array(body.utf8)
        // Synthetic frame: `+` + len + body, with framing breaks so the
        // scanner sees a contiguous run starting at `+`.
        let blob = magic + [0x81, 0xe8, 0x03, 0x00, 0x2b, UInt8(bodyBytes.count)] + bodyBytes + [0x00]
        let decoded = AttributedBodyDecoder.decode(Data(blob))
        XCTAssertEqual(decoded, body)
    }

    func testRejectsAppleAttributeNameKeys() {
        // The runs `__kIMMessagePartAttributeName` etc. are NSAttribute
        // run keys, not body text — the scanner should keep walking
        // for a real body and never return the attribute key.
        let magic: [UInt8] = [
            0x04, 0x0b,
            0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64
        ]
        let attrKey: [UInt8] = Array("__kIMMessagePartAttributeName".utf8)
        let body = "Good morning!"
        let bodyBytes: [UInt8] = Array(body.utf8)
        let blob = magic + [0x00, 0x01, UInt8(attrKey.count)] + attrKey + [0x00, 0x2b, UInt8(bodyBytes.count)] + bodyBytes + [0x00]
        let decoded = AttributedBodyDecoder.decode(Data(blob))
        XCTAssertEqual(decoded, body)
    }

    func testDecodesSyntheticTypedstreamBlob() {
        // Mimics the shape of Apple's outgoing-iMessage `attributedBody`
        // typedstream: `\x04\x0bstreamtyped` magic, a few class-name
        // markers, then the body text. The decoder's scanner should
        // pick out the body and skip the class-name fragments.
        let magic: [UInt8] = [
            0x04, 0x0b,
            0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64
        ]
        // Version-ish bytes.
        let version: [UInt8] = [0x81, 0xe8, 0x03]
        // Inline class names that should be filtered out by the scanner.
        let nsAttributed: [UInt8] = Array("NSMutableAttributedString".utf8)
        let nsString: [UInt8] = Array("NSMutableString".utf8)
        let body = "Hey Tony! Can you take away tree / branch waste?"
        let bodyBytes: [UInt8] = Array(body.utf8)
        // Mix the runs together with a few framing/separator bytes that
        // the scanner should treat as non-text breaks.
        let blob: [UInt8] = magic
            + version
            + [0x84, 0x01, 0x40, 0x84, 0x01]
            + nsAttributed
            + [0x00, 0x84, 0x05]
            + nsString
            + [0x00, 0x01, UInt8(bodyBytes.count)]
            + bodyBytes
            + [0x00, 0x86]

        let decoded = AttributedBodyDecoder.decode(Data(blob))
        XCTAssertEqual(decoded, body)
    }
}
