import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Compresses a chunk of user-generated text into a short search-friendly
/// summary that ships alongside (and never replaces) the original record.
///
/// We do this client-side so the cloud receives a redacted, compact
/// description that's easy to index without forcing the server to run
/// any heavyweight NLP. The raw `text_content` / `transcript` columns
/// still carry the original prose as a fallback.
///
/// The protocol is async + throwing because the generative path may
/// hit a real on-device model (`FoundationModels.LanguageModelSession`
/// on macOS 26+). The default implementation never propagates errors —
/// every failure mode degrades gracefully to a truncated input — but
/// the protocol stays throwing so test doubles can fake transient
/// failures and exercise the source-side error paths.
protocol Summarizing: Sendable {
    /// Returns a ≤ 200 character summary of `text`, redacted via
    /// ``Redactor/sanitize(_:)``. Implementations must never block the
    /// caller for more than a couple of seconds — fall back to the
    /// heuristic if the underlying generator stalls.
    func summarize(text: String, hint: SummaryHint) async throws -> String
}

/// Hard ceiling on summary length. Matches the brief: "≤ 200 character
/// summaries." Anything longer gets truncated to the nearest grapheme
/// boundary so we don't slice through a Unicode cluster.
let maxSummaryCharacters = 200

/// Default ``Summarizing`` implementation.
///
/// On macOS 26+ the implementation tries `FoundationModels` first; on
/// every other macOS version (and as a fallback when the model is
/// unavailable, denied, or throws) it uses ``KeywordSummary`` — an
/// `NLTagger`-driven heuristic that takes the first sentence plus the
/// top-N noun phrases. Both paths run through ``Redactor/sanitize(_:)``
/// and the 200-char cap before returning.
///
/// Failure modes are intentionally aggressive about graceful degradation
/// because the caller (`NotesSource`, `VoiceMemosSource`, `FilesSource`)
/// will *attach* the summary to a payload that's about to ship — we
/// never want a summarizer hiccup to block an ingest cycle.
struct OnDeviceSummarizer: Summarizing {
    /// Injection seam used by tests to force the keyword-only path even
    /// on hosts where `FoundationModels` would otherwise be tried.
    private let useGenerativeIfAvailable: Bool

    init(useGenerativeIfAvailable: Bool = true) {
        self.useGenerativeIfAvailable = useGenerativeIfAvailable
    }

    func summarize(text: String, hint: SummaryHint) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }

        // Generative path (macOS 26+, when the framework is present).
        // Guarded by both compile-time `canImport` and a runtime
        // availability check so a build for an older deployment target
        // never touches the symbols.
        #if canImport(FoundationModels)
        if useGenerativeIfAvailable, let summary = await tryGenerative(text: trimmed, hint: hint) {
            return finalize(summary)
        }
        #endif

        // Keyword + first-sentence fallback. Works on every macOS the
        // app supports.
        let heuristic = KeywordSummary.build(text: trimmed, hint: hint)
        if !heuristic.isEmpty {
            return finalize(heuristic)
        }

        // Last-resort graceful degradation: hand back the input itself,
        // capped at the same 200 characters. The spec specifically asks
        // for this so ingest never blocks on a summarizer failure.
        return finalize(trimmed)
    }

    // MARK: - Generative path

    #if canImport(FoundationModels)
    /// Stub for the macOS 26+ `FoundationModels` integration. The real
    /// call site will materialise a `LanguageModelSession` and request
    /// a structured summary; for now we just return `nil` so the
    /// keyword fallback runs. Kept here so the activation diff in the
    /// future is a small surgical change — protocol, callers, and
    /// fallback are all already wired.
    private func tryGenerative(text: String, hint: SummaryHint) async -> String? {
        return nil
    }
    #endif

    // MARK: - Output shaping

    /// Sanitise, cap, and tidy a candidate summary. Splitting this out
    /// keeps every code path (generative, heuristic, truncated input)
    /// running through the same redaction + cap rules.
    private func finalize(_ candidate: String) -> String {
        let redacted = Redactor.sanitize(candidate)
        return Self.cap(redacted, to: maxSummaryCharacters)
    }

    /// Truncate to `limit` characters at a grapheme-cluster boundary.
    /// `String.prefix(_:)` already respects grapheme clusters, so this
    /// is just a thin wrapper that also collapses trailing whitespace.
    static func cap(_ text: String, to limit: Int) -> String {
        if text.count <= limit {
            return text
        }
        let prefix = text.prefix(limit)
        return String(prefix).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Pure heuristic summarizer: first sentence + top-5 noun phrases.
///
/// Used as the fallback (and the only) summarizer on macOS versions
/// without `FoundationModels`. Deterministic — given the same input
/// it always yields the same output, which is what the tests assert.
///
/// Hints tune the shape:
///   * `.note` / `.file` → "<first sentence> · keywords: …"
///   * `.voiceMemo` → "Voice memo: <first sentence> · keywords: …"
///   * `.message` → keywords only (messages are usually too short for
///     a first-sentence summary to be useful).
enum KeywordSummary {
    /// Build a summary string from `text` and `hint`. Returns the empty
    /// string when both extraction paths come up empty — the caller
    /// then falls back to the raw input.
    static func build(text: String, hint: SummaryHint) -> String {
        let firstSentence = leadingSentence(of: text)
        let keywords = topKeywords(in: text, limit: 5)
        let keywordTail = keywords.isEmpty ? "" : "keywords: \(keywords.joined(separator: ", "))"

        switch hint {
        case .note, .file:
            return join(firstSentence, keywordTail)
        case .voiceMemo:
            let body = join(firstSentence, keywordTail)
            return body.isEmpty ? "" : "Voice memo: \(body)"
        case .message:
            return keywordTail
        }
    }

    /// Join two non-empty fragments with the spec's middle-dot separator,
    /// dropping either side when it's empty. Centralised so every hint
    /// path agrees on the joiner.
    private static func join(_ lhs: String, _ rhs: String) -> String {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return ""
        case (true, false): return rhs
        case (false, true): return lhs
        case (false, false): return "\(lhs) · \(rhs)"
        }
    }

    /// First sentence by `NLTokenizer`'s `.sentence` unit. Falls back to
    /// the first newline-separated line when the tokenizer doesn't find
    /// any sentence boundary (short transcripts, etc.).
    static func leadingSentence(of text: String) -> String {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var first: String?
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            first = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
        if let first, !first.isEmpty {
            return first
        }
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }

    /// Top-N noun phrases ranked by frequency. We use `NLTagger` with
    /// the `.lexicalClass` scheme and pick out tokens tagged as `.noun`
    /// or `.otherWord` (proper nouns / hashtag-style tokens). Stop
    /// words and 2-letter glue are filtered out so the tail stays
    /// signal-heavy.
    static func topKeywords(in text: String, limit: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var counts: [String: Int] = [:]
        // Preserve first-seen order for deterministic output when
        // multiple keywords tie on frequency.
        var order: [String] = []
        let options: NLTagger.Options = [
            .omitWhitespace, .omitPunctuation, .omitOther, .joinNames
        ]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            guard let tag else { return true }
            guard tag == .noun || tag == .otherWord else { return true }
            let token = String(text[range]).lowercased()
            guard token.count > 2 else { return true }
            guard !Self.stopWords.contains(token) else { return true }
            if counts[token] == nil {
                order.append(token)
            }
            counts[token, default: 0] += 1
            return true
        }
        // Stable sort by descending count, then by first-seen order.
        let ranked = order.sorted { lhs, rhs in
            let lc = counts[lhs] ?? 0
            let rc = counts[rhs] ?? 0
            if lc != rc { return lc > rc }
            return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
        }
        return Array(ranked.prefix(limit))
    }

    /// Common English stop words / glue tokens that the lexical-class
    /// tagger sometimes labels as nouns (e.g. "thing", "stuff"). Kept
    /// small on purpose — the tagger does most of the heavy lifting.
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "from", "this", "that", "thing",
        "stuff", "today", "yesterday", "tomorrow", "have", "has", "had",
        "are", "was", "were", "you", "your", "our", "their", "they",
        "them", "his", "her", "him", "its", "one", "two", "three"
    ]
}
