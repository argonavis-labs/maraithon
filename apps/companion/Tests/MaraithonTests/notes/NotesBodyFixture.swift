import Foundation
@testable import Maraithon

/// Tiny test-only helper that synthesises a `ZICNOTEDATA.ZDATA` blob
/// whose plain-text body decodes back to the supplied string. We hand-
/// roll the protobuf wire format (rather than pull a runtime dep) and
/// reuse the production `Gzip` encoder for framing — that way the
/// `NotesBodyDecoder` exercise round-trips through the exact same gzip
/// envelope shape Apple ships.
///
/// Schema we replicate, matching `NotesBodyDecoder`'s descent:
///
///   Document(2) -> Version(2) -> Data(3) -> Note(3) -> note_text(2)
///
/// Every parent message is length-delimited; the innermost `note_text`
/// is a UTF-8 string. Field numbers are pulled from
/// `apple-cloud-notes-parser` (`NoteStoreProto.proto`).
enum NotesBodyFixture {
    /// Build a blob whose `NotesBodyDecoder` output equals `text`.
    static func blob(for text: String, attribute: String? = nil) -> Data {
        let textData = Data(text.utf8)
        var note = Data()
        note.append(lengthDelimited(field: 2, payload: textData))
        // Optional second field — gives us a knob in tests that want to
        // assert the decoder ignores trailing fields cleanly. Field 3 is
        // attribute runs in the real schema; we use a benign empty
        // submessage here.
        if let attribute {
            note.append(lengthDelimited(field: 3, payload: Data(attribute.utf8)))
        }

        let dataMsg = lengthDelimited(field: 3, payload: note)
        let version = lengthDelimited(field: 3, payload: dataMsg)
        let document = lengthDelimited(field: 2, payload: version)
        // Top-level `NoteStoreProto` carries `document` as field 2 in
        // the schema, but it's also the conventional root field number
        // (see `apple-cloud-notes-parser/NoteStoreProto.proto`).
        let root = lengthDelimited(field: 2, payload: document)

        // Force gzip — the decoder only accepts the gzip envelope.
        // `Gzip.compress` matches Apple's framing closely enough for the
        // FLG=0 path that production blobs use.
        return (try? Gzip.compress(root)) ?? Data()
    }

    /// Encode a single length-delimited (wire-type 2) record. Bottom 3
    /// bits of the tag are the wire type; the rest is the field number,
    /// LEB128-varint encoded.
    private static func lengthDelimited(field: UInt64, payload: Data) -> Data {
        var out = Data()
        let tag = (field << 3) | 2
        out.append(varint(tag))
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8((value & 0x7F) | 0x80))
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }
}
