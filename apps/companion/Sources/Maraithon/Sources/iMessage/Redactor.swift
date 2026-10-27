import Foundation

/// Masks phone numbers and email addresses for log output so neither the
/// ring buffer nor the on-disk log file ever contains a fully-qualified
/// handle. Pushed payloads carry the full handle — only logging is
/// redacted.
///
/// Examples:
///   * `+14165550199`         → `+1416***0199`
///   * `kent@example.com`     → `k***@example.com`
///   * `joe.user@example.com` → `j***@example.com`
///   * `unknown`              → `unknown` (untouched)
enum Redactor {
    /// Redact a single handle. If the input doesn't look like a phone or
    /// email, the input is returned unchanged — the caller is expected to
    /// only pass handle-shaped strings.
    static func redact(_ handle: String) -> String {
        if handle.contains("@") {
            return redactEmail(handle)
        }
        if isPhoneLike(handle) {
            return redactPhone(handle)
        }
        return handle
    }

    /// Redact a list of handles into a comma-joined string. Useful when
    /// building log payload values for group chats.
    static func redactAll(_ handles: [String]) -> String {
        handles.map(redact).joined(separator: ",")
    }

    /// Sanitise free-form prose (a summary, a snippet, etc.) by masking
    /// every embedded phone number, email address, and `KEY=value`
    /// secret-style pair. Unlike `redact(_:)` which expects a single
    /// handle, `sanitize(_:)` walks the entire string and rewrites
    /// every match in-place. Tokens we cannot classify pass through
    /// unchanged.
    ///
    /// Used by ``OnDeviceSummarizer`` before attaching a summary to a
    /// payload bound for the wire — the brief is explicit that summaries
    /// must not include any redaction target.
    static func sanitize(_ text: String) -> String {
        var result = text
        for pattern in sanitizePatterns {
            result = pattern.apply(to: result)
        }
        return result
    }

    /// Patterns we strip from summary text. Ordered: secret pairs first
    /// (they take whole lines), then emails, then phone numbers (the
    /// most permissive matcher, which can otherwise eat parts of an
    /// email's local-part).
    private static let sanitizePatterns: [SanitizePattern] = [
        // KEY=value or KEY="value" or KEY='value'. Whole pair gets
        // collapsed to the key + a placeholder so the summary still
        // tells the reader "this contained a secret" without leaking
        // its contents. Anchored to a line start (or whitespace) so
        // a normal `x = 3` in prose isn't caught.
        SanitizePattern.make(
            pattern: #"(?m)((?:^|\s)[A-Z][A-Z0-9_]{2,})\s*=\s*["']?[^"'\s][^\n]*"#,
            replacement: "$1=[redacted]"
        ),
        // Email addresses. Replaced with `<email>` so the surrounding
        // sentence still reads naturally.
        SanitizePattern.make(
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
            replacement: "<email>"
        ),
        // Phone numbers — at least 7 digits, optional `+`, with
        // separators. Replaced with `<phone>`.
        SanitizePattern.make(
            pattern: #"(?<!\d)\+?\d[\d\s().-]{6,}\d(?!\d)"#,
            replacement: "<phone>"
        )
    ].compactMap { $0 }

    private static func redactEmail(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@") else { return email }
        let local = email[..<atIndex]
        let domain = email[atIndex...]
        guard let first = local.first else { return email }
        return "\(first)***\(domain)"
    }

    private static func redactPhone(_ phone: String) -> String {
        // Keep leading "+" + first three digits and trailing four digits.
        // Anything in between collapses to "***".
        let digits = phone.filter { $0.isNumber }
        guard digits.count >= 7 else { return phone }
        let prefixLen = min(4, digits.count - 4)
        let prefix = String(digits.prefix(prefixLen))
        let suffix = String(digits.suffix(4))
        let plus = phone.hasPrefix("+") ? "+" : ""
        return "\(plus)\(prefix)***\(suffix)"
    }

    private static func isPhoneLike(_ s: String) -> Bool {
        // Phone-like = mostly digits with optional +, -, spaces, parens.
        let phoneChars: Set<Character> = ["+", "-", " ", "(", ")"]
        let digitsAndSeps = s.allSatisfy { $0.isNumber || phoneChars.contains($0) }
        return digitsAndSeps && s.contains(where: \.isNumber)
    }
}

/// Compiled regex + replacement pair, used by ``Redactor/sanitize(_:)``.
/// Each pattern is compiled once at startup so the per-summary cost
/// stays at the apply-regex level — important because summaries get
/// generated on the source's polling loop.
///
/// Construct via ``SanitizePattern/make(pattern:replacement:)`` so the
/// regex-compile failure path stays explicit; a malformed pattern is a
/// build-time bug that surfaces as a `nil` and gets filtered out of
/// the pattern list (with an assertion failure in debug builds).
private struct SanitizePattern {
    let regex: NSRegularExpression
    let replacement: String

    static func make(pattern: String, replacement: String) -> SanitizePattern? {
        do {
            let regex = try NSRegularExpression(pattern: pattern)
            return SanitizePattern(regex: regex, replacement: replacement)
        } catch {
            assertionFailure("malformed Redactor pattern: \(pattern) (\(error))")
            return nil
        }
    }

    func apply(to input: String) -> String {
        let range = NSRange(input.startIndex..., in: input)
        return regex.stringByReplacingMatches(
            in: input,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}
