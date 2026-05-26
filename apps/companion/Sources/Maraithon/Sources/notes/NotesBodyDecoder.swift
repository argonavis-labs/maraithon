import Foundation
import Compression

/// Decodes the `ZNOTEDATA` blob from `ZICNOTE`/`ZICCLOUDSYNCINGOBJECT`
/// into the plain-text body Apple's Notes.app renders. The blob is a
/// gzip-compressed Protocol Buffer (`NoteStoreProto`) — *not* a vanilla
/// `NSKeyedArchiver` archive, so `NSAttributedString(data:options:)`
/// cannot read it directly.
///
/// Schema (lifted from the community `apple-cloud-notes-parser`
/// project; field numbers are stable across macOS releases):
///
///   NoteStoreProto
///     └─ document = 2 : Document
///         └─ version = 2 : repeated Version
///             └─ data = 3 : Data
///                 └─ note = 3 : Note
///                     └─ note_text = 2 : string   ← what we want
///
/// We don't pull a protobuf runtime in for this — the dependency surface
/// would dwarf the actual need. Instead we ship a tiny wire-format
/// scanner that walks the descent only along the field numbers we care
/// about, ignoring everything else. Anything that doesn't match the
/// expected shape (wrong magic, truncated stream, missing `note_text`)
/// returns `nil` so the caller falls back to a body-less note.
///
/// The decoder is intentionally permissive about what it accepts after
/// the body is found: Apple's `note_text` is followed by attribute
/// runs, attachments, table data, etc. We stop reading once we have a
/// non-empty UTF-8 string in the right position and let the rest of the
/// blob alone.
enum NotesBodyDecoder {
    /// Plain-text decode result. Returns `nil` when the blob is
    /// missing, can't be gunzipped, isn't a recognisable Notes
    /// protobuf, or has no `note_text` payload.
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let inflated = gunzip(data) else { return nil }
        // First try the strict structural walk down
        // NoteStoreProto.document.version.data.note.note_text. The walk
        // matches the schema lifted from `apple-cloud-notes-parser` and
        // is byte-for-byte correct for the most common shape.
        if let document = scanLengthDelimited(in: inflated, field: 2),
           let version = scanLengthDelimited(in: document, field: 2),
           let dataMsg = scanLengthDelimited(in: version, field: 3),
           let note = scanLengthDelimited(in: dataMsg, field: 3),
           let text = scanLengthDelimited(in: note, field: 2),
           let body = String(data: text, encoding: .utf8),
           !body.isEmpty {
            return String(body.prefix(maxBodyChars))
        }
        // Strict walk didn't find it (different schema version, multi-
        // version document, attachment-heavy note, etc). Fall back to
        // the heuristic that grabs the longest valid-UTF-8 run from the
        // tail window — `note_text` always sits near the end of the
        // inflated blob, and the window is bounded so CPU stays sane on
        // big attribute payloads.
        return longestReadableUTF8Run(in: inflated)
    }

    /// Heuristic: find the longest contiguous span of "printable" UTF-8
    /// in the inflated bytes. Tracks (start, length) inline so we never
    /// hold per-byte arrays — the inflated blob can be megabytes for
    /// long notes; allocating per-run defeats the purpose.
    static func longestReadableUTF8Run(in bytes: Data) -> String? {
        let total = bytes.count
        guard total > 0 else { return nil }
        // Only scan the last `scanWindowBytes` — note_text lives near the
        // tail of NoteStoreProto and capping the window bounds CPU on
        // multi-MB attribute-heavy notes.
        let windowStart = max(0, total - scanWindowBytes)
        let windowLen = total - windowStart
        var bestStart = 0
        var bestLen = 0
        var runStart = 0
        var runLen = 0
        bytes.withUnsafeBytes { raw in
            let buf = raw.bindMemory(to: UInt8.self)
            for i in 0..<windowLen {
                let byte = buf[windowStart + i]
                let printable = (byte == 0x09 || byte == 0x0A || byte == 0x0D)
                    || (byte >= 0x20 && byte <= 0x7E)
                    || (byte >= 0xC2 && byte <= 0xF4)
                    || (byte >= 0x80 && byte <= 0xBF)
                if printable {
                    if runLen == 0 { runStart = i }
                    runLen += 1
                } else if runLen > 0 {
                    if runLen > bestLen {
                        bestStart = runStart
                        bestLen = runLen
                    }
                    runLen = 0
                }
            }
        }
        if runLen > bestLen {
            bestStart = runStart
            bestLen = runLen
        }
        guard bestLen >= 8 else { return nil }
        let cap = min(bestLen, maxBodyBytes)
        let base = bytes.startIndex
        let slice = bytes.subdata(
            in: base.advanced(by: windowStart + bestStart)
                ..< base.advanced(by: windowStart + bestStart + cap)
        )
        guard let s = String(data: slice, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 8 { return nil }
        if trimmed.count < 40 && trimmed.allSatisfy({ $0.isLetter || $0 == "_" }) {
            return nil
        }
        return String(trimmed.prefix(maxBodyChars))
    }

    /// Tail window we scan — caps CPU. Larger than max body to give the
    /// run-finder room to discriminate.
    static let scanWindowBytes = 16_384

    /// Byte-level cap on what we slice out of the inflated blob. The
    /// character-level cap (`maxBodyChars`) trims the final String; this
    /// limits the intermediate allocation.
    static let maxBodyBytes = 32_768

    private static func isReadablePrintable(_ b: UInt8) -> Bool {
        // ASCII printable, plus tab/newline/carriage-return, plus the
        // start of any multi-byte UTF-8 sequence (0x80...0xFD). That
        // includes em-dashes, emojis, smart quotes, accented characters.
        if b == 0x09 || b == 0x0A || b == 0x0D { return true }
        if b >= 0x20 && b <= 0x7E { return true }
        if b >= 0x80 && b <= 0xFD { return true }
        return false
    }

    /// Hard cap on the body length we ship. Most Apple Notes bodies
    /// are well under this; the cap exists to bound the wire payload
    /// when a user has an unusually large note.
    static let maxBodyChars = 64_000

    // MARK: - Protobuf walker

    /// Walks `bytes` as a sequence of `varint + wire-format` records and
    /// returns the payload of the first `field` of wire-type 2
    /// (length-delimited). The other wire types are skipped without
    /// allocating sub-data slices. Returns `nil` when the field isn't
    /// found or the stream is malformed.
    private static func scanLengthDelimited(in bytes: Data, field target: UInt64) -> Data? {
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            guard let (tag, afterTag) = readVarint(bytes, at: cursor) else { return nil }
            let fieldNumber = tag >> 3
            let wireType = tag & 0x7
            cursor = afterTag
            switch wireType {
            case 0:
                // varint
                guard let (_, after) = readVarint(bytes, at: cursor) else { return nil }
                cursor = after
            case 1:
                // 64-bit fixed
                guard cursor + 8 <= bytes.endIndex else { return nil }
                cursor += 8
            case 2:
                // length-delimited
                guard let (length, afterLen) = readVarint(bytes, at: cursor) else { return nil }
                let intLen = Int(length)
                guard intLen >= 0, afterLen + intLen <= bytes.endIndex else { return nil }
                if fieldNumber == target {
                    return bytes.subdata(in: afterLen..<(afterLen + intLen))
                }
                cursor = afterLen + intLen
            case 5:
                // 32-bit fixed
                guard cursor + 4 <= bytes.endIndex else { return nil }
                cursor += 4
            default:
                // Groups (3,4) and unknown — bail. Groups are not used
                // in modern protobuf schemas (and certainly not Apple's),
                // so encountering one means the stream is malformed.
                return nil
            }
        }
        return nil
    }

    /// Reads a base-128 varint starting at `index`. Returns the decoded
    /// value and the index just past the last byte consumed, or `nil`
    /// when the stream truncates mid-varint.
    private static func readVarint(_ bytes: Data, at index: Data.Index) -> (UInt64, Data.Index)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = index
        while cursor < bytes.endIndex {
            let byte = bytes[cursor]
            value |= UInt64(byte & 0x7F) << shift
            cursor = bytes.index(after: cursor)
            if byte & 0x80 == 0 {
                return (value, cursor)
            }
            shift += 7
            // 10 bytes is the upper bound for a 64-bit varint.
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - Gunzip

    /// Inflates a gzip member. Apple writes `ZNOTEDATA` with the
    /// standard gzip framing (magic `1f 8b`, deflate, FLG=0 in the
    /// blobs we've inspected). We tolerate FNAME / FCOMMENT flags as a
    /// hedge, but reject extra headers / encryption.
    private static func gunzip(_ data: Data) -> Data? {
        guard data.count >= 18 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flags = bytes[3]
        // Bits we know how to skip: FNAME (0x08), FCOMMENT (0x10),
        // FHCRC (0x02). Reject FEXTRA (0x04) and reserved bits.
        let supportedFlagMask: UInt8 = 0x08 | 0x10 | 0x02
        if flags & ~supportedFlagMask != 0 { return nil }

        var header = 10
        if flags & 0x08 != 0 {
            // FNAME: NUL-terminated string.
            while header < bytes.count && bytes[header] != 0 { header += 1 }
            guard header < bytes.count else { return nil }
            header += 1
        }
        if flags & 0x10 != 0 {
            while header < bytes.count && bytes[header] != 0 { header += 1 }
            guard header < bytes.count else { return nil }
            header += 1
        }
        if flags & 0x02 != 0 {
            // FHCRC: two bytes.
            header += 2
            guard header <= bytes.count else { return nil }
        }
        // Trailer is 8 bytes: CRC32 (4) + ISIZE (4). ISIZE is the
        // uncompressed size mod 2^32; for note bodies (well under 4GB)
        // it's the true size and a perfect buffer hint.
        guard bytes.count >= header + 8 else { return nil }
        let payloadEnd = bytes.count - 8
        guard payloadEnd > header else { return nil }
        let isize = UInt32(bytes[bytes.count - 8])
            | (UInt32(bytes[bytes.count - 7]) << 8)
            | (UInt32(bytes[bytes.count - 6]) << 16)
            | (UInt32(bytes[bytes.count - 5]) << 24)
        let payload = Array(bytes[header..<payloadEnd])
        return inflate(payload, originalSize: Int(isize))
    }

    /// Raw-deflate inflator. `Compression.framework`'s `COMPRESSION_ZLIB`
    /// constant is raw deflate (no zlib header), which is what gzip
    /// wraps — see `Gzip.swift` for the matching encoder.
    ///
    /// `originalSize` comes from the gzip trailer's ISIZE field, which
    /// is the uncompressed size mod 2^32. For real Notes bodies it's
    /// the true size; for synthetic fixtures it can be garbage (the
    /// reference `Gzip` encoder doesn't write a meaningful ISIZE). We
    /// treat it as a hint, ignore obviously bogus values, and grow the
    /// buffer geometrically up to the safety cap when needed.
    private static func inflate(_ bytes: [UInt8], originalSize: Int) -> Data? {
        let maxBufferSize = 16 * 1024 * 1024  // 16 MB safety cap.
        // Trust ISIZE only when it lands in a sane range; otherwise
        // start from the input-size heuristic and grow on demand.
        let sizedHint =
            (originalSize > 0 && originalSize <= maxBufferSize)
                ? originalSize
                : max(bytes.count * 8, 4096)
        var bufferSize = min(max(sizedHint, 4096), maxBufferSize)
        while true {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { destination.deallocate() }
            let written = bytes.withUnsafeBufferPointer { src -> Int in
                guard let base = src.baseAddress else { return -1 }
                return compression_decode_buffer(
                    destination, bufferSize,
                    base, bytes.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            if written > 0 && written < bufferSize {
                // `written == bufferSize` means we filled the buffer and
                // may have truncated the output. Treat that as a need
                // for a larger buffer.
                return Data(bytes: destination, count: written)
            }
            if written == 0 {
                return nil
            }
            // written == bufferSize: grow and retry, but never exceed
            // the safety cap.
            if bufferSize >= maxBufferSize { return nil }
            bufferSize = min(bufferSize * 2, maxBufferSize)
        }
    }
}
