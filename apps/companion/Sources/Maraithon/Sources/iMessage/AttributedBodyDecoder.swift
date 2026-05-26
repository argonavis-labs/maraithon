import Foundation

/// Decodes the `message.attributedBody` column from `chat.db`. macOS
/// stores the rendered message body two different ways depending on
/// version and direction:
///
/// 1. **`NSKeyedArchiver`** (modern, often for incoming messages) —
///    `NSKeyedUnarchiver` reads it cleanly.
/// 2. **`typedstream`** (legacy `NSArchiver` format, often for outgoing
///    messages and reactions) — `NSKeyedUnarchiver` rejects it. We
///    fall back to a small typedstream scanner that extracts the
///    longest body-text candidate from the blob.
///
/// Any failure is swallowed and surfaces as `nil` so the source can
/// fall back to the legacy `text` column.
enum AttributedBodyDecoder {
    /// Returns the plain-text body of an archived `NSAttributedString`,
    /// or `nil` when the blob can't be decoded.
    ///
    /// Picks a path by the blob's leading magic bytes — `bplist00` →
    /// NSKeyedArchiver; `\x04\x0bstreamtyped` → typedstream. Crucially,
    /// the two paths are mutually exclusive: if the keyed-archiver
    /// header is present but the unarchive fails, we DON'T fall through
    /// to the typedstream scanner. That fallback would mis-identify the
    /// binary-plist's key strings (e.g. `X$versionY$archiverT$topX$objects`)
    /// as the body text.
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if isKeyedArchiver(data) {
            return decodeViaKeyedArchiver(data)
        }
        if isTypedstream(data) {
            return decodeViaTypedstream(data)
        }
        return nil
    }

    private static let bplistMagic: [UInt8] = [
        0x62, 0x70, 0x6c, 0x69, 0x73, 0x74, 0x30, 0x30 // "bplist00"
    ]

    private static func isKeyedArchiver(_ data: Data) -> Bool {
        data.starts(with: bplistMagic)
    }

    private static func isTypedstream(_ data: Data) -> Bool {
        data.starts(with: typedstreamMagic)
    }

    // MARK: - NSKeyedArchiver path (modern)

    private static func decodeViaKeyedArchiver(_ data: Data) -> String? {
        // Modern, lenient path first — `unarchivedObject(ofClass:from:)`
        // handles Apple's private NSConcrete* subclasses by mapping
        // them to the requested superclass during decode.
        if let attr = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self, from: data
        ) {
            let s = attr.string
            if !s.isEmpty { return s }
        }
        // Fallback: the permissive, deprecated accessor with a wide
        // class allow-list and a recursive walk for archives that wrap
        // the body in an NSDictionary / NSArray.
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            let root = unarchiver.decodeObject(
                of: [
                    NSAttributedString.self,
                    NSMutableAttributedString.self,
                    NSString.self,
                    NSMutableString.self,
                    NSDictionary.self,
                    NSMutableDictionary.self,
                    NSArray.self,
                    NSMutableArray.self
                ],
                forKey: NSKeyedArchiveRootObjectKey
            )
            unarchiver.finishDecoding()
            if let text = stringFromKeyedArchiverRoot(root), !text.isEmpty {
                return text
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Recursively pull a `String` out of whatever shape the root
    /// object happens to take. Outgoing iMessage payloads sometimes
    /// nest the body under a wrapper dict or array.
    private static func stringFromKeyedArchiverRoot(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let attributed = value as? NSAttributedString {
            let s = attributed.string
            return s.isEmpty ? nil : s
        }
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let dict = value as? [AnyHashable: Any] {
            for v in dict.values {
                if let s = stringFromKeyedArchiverRoot(v) { return s }
            }
        }
        if let array = value as? [Any] {
            // Return the longest plausible text candidate from the array.
            var best: String? = nil
            for v in array {
                if let s = stringFromKeyedArchiverRoot(v) {
                    if best == nil || s.count > best!.count { best = s }
                }
            }
            return best
        }
        return nil
    }

    // MARK: - typedstream path (legacy, outgoing iMessages on Sequoia+)

    /// Magic bytes at the start of every typedstream blob.
    private static let typedstreamMagic: [UInt8] = [
        0x04, 0x0b, // version+kind framing
        // "streamtyped"
        0x73, 0x74, 0x72, 0x65, 0x61, 0x6d, 0x74, 0x79, 0x70, 0x65, 0x64
    ]

    /// Known class-name strings that show up inline in the typedstream
    /// archive; the scanner skips these so the longest "text-looking"
    /// substring is the body, not a class label.
    private static let knownClassNames: Set<String> = [
        "NSAttributedString",
        "NSMutableAttributedString",
        "NSString",
        "NSMutableString",
        "NSObject",
        "NSDictionary",
        "NSMutableDictionary",
        "NSArray",
        "NSMutableArray",
        "NSValue",
        "NSNumber",
        "NSColor",
        "NSFont",
        "NSURL"
    ]

    /// Walks the blob looking for valid UTF-8 runs and returns the
    /// longest one that isn't an Obj-C class name. Tracks the proper
    /// UTF-8 continuation-byte state so we don't read past the body
    /// into the typedstream's trailing framing bytes (which would turn
    /// the otherwise-decodable string into invalid UTF-8 and the whole
    /// candidate gets dropped).
    static func decodeViaTypedstream(_ data: Data) -> String? {
        guard data.starts(with: typedstreamMagic) else { return nil }
        let bytes = [UInt8](data)
        var longest: String? = nil
        var i = typedstreamMagic.count
        while i < bytes.count {
            // Walk a state-machine-correct UTF-8 run.
            var j = i
            var continuationsNeeded = 0
            scan: while j < bytes.count {
                let b = bytes[j]
                if continuationsNeeded > 0 {
                    if (0x80...0xbf).contains(b) {
                        continuationsNeeded -= 1
                    } else {
                        break scan
                    }
                } else {
                    switch b {
                    case 0x09, 0x0a, 0x0d, 0x20...0x7e:
                        break // single-byte ASCII / whitespace
                    case 0xc2...0xdf:
                        continuationsNeeded = 1
                    case 0xe0...0xef:
                        continuationsNeeded = 2
                    case 0xf0...0xf4:
                        continuationsNeeded = 3
                    default:
                        break scan
                    }
                }
                j += 1
            }
            // If the scan ended mid-codepoint (continuation bytes
            // missing or a leader unmatched), back off to the last
            // complete codepoint.
            if continuationsNeeded > 0 {
                // Walk back past the partial leader bytes.
                j -= (1 + 0) // The leader byte itself
                // Also skip any continuations we did read for this leader.
                // (1 leader byte already advanced j; rewind it now.)
            }
            if j - i >= 2 {
                let slice = Array(bytes[i..<j])
                var trimmed = slice
                // typedstream string type marker `+` (0x2b) followed by a
                // 1-byte length, then the UTF-8 bytes. Both can be
                // printable ASCII (length byte is 0x00-0xff) so my
                // scanner sweeps them into the candidate — strip if the
                // shape matches `+${len}${body}`.
                if trimmed.count >= 3, trimmed[0] == 0x2b,
                   Int(trimmed[1]) == trimmed.count - 2 {
                    trimmed = Array(trimmed.dropFirst(2))
                }
                // Short-string length-byte prefix (1 byte).
                if let first = trimmed.first, Int(first) == trimmed.count - 1 {
                    trimmed = Array(trimmed.dropFirst())
                }
                if let candidate = String(bytes: trimmed, encoding: .utf8),
                   !knownClassNames.contains(candidate),
                   isPlausibleBody(candidate) {
                    if longest == nil || candidate.count > longest!.count {
                        longest = candidate
                    }
                }
            }
            i = max(j + 1, i + 1)
        }
        return longest
    }

    /// Filters out runs that decode cleanly but aren't message text —
    /// e.g. single-character noise, format markers, or class-name
    /// fragments that escaped the explicit deny list.
    private static func isPlausibleBody(_ candidate: String) -> Bool {
        guard candidate.count >= 2 else { return false }
        // Reject Apple's private attribute-name keys ("__kIM..." etc.)
        // — they're metadata strings on the NSAttributedString runs, not
        // the body text. They always start with the `__k` prefix in the
        // archives I've seen.
        if candidate.hasPrefix("__k") || candidate.hasPrefix("NSAttachment") {
            return false
        }
        // Reject runs that look like Obj-C identifiers (no spaces, all
        // alnum, leading uppercase like "NSMutableDictionary" or
        // "iI") — body text essentially always has either whitespace,
        // punctuation that's not bracket-only, or non-ASCII characters.
        let isIdentifier = candidate.allSatisfy { ch in
            ch.isLetter || ch.isNumber || ch == "_"
        }
        if isIdentifier, candidate.count <= 24 {
            return false
        }
        return true
    }
}
