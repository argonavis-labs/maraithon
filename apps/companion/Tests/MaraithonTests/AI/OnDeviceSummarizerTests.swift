import XCTest
@testable import Maraithon

/// Coverage for the keyword-fallback summarizer.
///
/// The generative path is exercised separately when `FoundationModels`
/// is available; these tests pin the deterministic keyword/first-
/// sentence behaviour that runs on every macOS the app supports.
final class OnDeviceSummarizerTests: XCTestCase {
    /// Default sample: a multi-sentence note with a couple of repeated
    /// nouns so the keyword ranker has something to chew on.
    private let noteFixture = """
    Lunch with Sam went well. We discussed the new product launch and the marketing budget.
    Sam mentioned that the marketing team needs more headcount before shipping the launch.
    We agreed to revisit the budget after the next product review.
    """

    func testKeywordFallbackIsDeterministic() async throws {
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let first = try await summarizer.summarize(text: noteFixture, hint: .note)
        let second = try await summarizer.summarize(text: noteFixture, hint: .note)
        XCTAssertEqual(first, second, "same input must produce the same summary")
        XCTAssertFalse(first.isEmpty)
    }

    func testNoteHintLeadsWithFirstSentence() async throws {
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: noteFixture, hint: .note)
        XCTAssertTrue(
            summary.hasPrefix("Lunch with Sam went well."),
            "note hint should prefix the first sentence; got: \(summary)"
        )
        XCTAssertTrue(
            summary.contains("keywords:"),
            "note hint should include the keyword tail; got: \(summary)"
        )
    }

    func testVoiceMemoHintPrefixesBody() async throws {
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: noteFixture, hint: .voiceMemo)
        XCTAssertTrue(
            summary.hasPrefix("Voice memo: "),
            "voice memo hint should mark the summary as transcript-derived; got: \(summary)"
        )
    }

    func testHintsProduceDifferentOutputs() async throws {
        // The hint isn't decorative — note vs voiceMemo should change
        // the rendered summary in a user-visible way.
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let asNote = try await summarizer.summarize(text: noteFixture, hint: .note)
        let asVoiceMemo = try await summarizer.summarize(text: noteFixture, hint: .voiceMemo)
        XCTAssertNotEqual(asNote, asVoiceMemo)
    }

    func testCapsAt200Characters() async throws {
        // Build a long input by repeating the fixture until the
        // un-capped summary would exceed 200 characters.
        let long = String(repeating: noteFixture + " ", count: 20)
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: long, hint: .note)
        XCTAssertLessThanOrEqual(summary.count, 200, "summaries must be ≤ 200 chars")
    }

    func testRedactsPhoneNumbersFromSummary() async throws {
        let text = """
        Call Alex at +1 (415) 555-0199 about the product roadmap and the launch budget.
        Alex prefers the product roadmap option, so we should follow up about the budget.
        """
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: text, hint: .note)
        XCTAssertFalse(
            summary.contains("0199"),
            "phone digits must be masked; got: \(summary)"
        )
        XCTAssertTrue(
            summary.contains("<phone>") || !summary.contains("415"),
            "phone match should collapse to placeholder; got: \(summary)"
        )
    }

    func testRedactsEnvSecretsFromSummary() async throws {
        let text = """
        STRIPE_KEY=sk_live_supersecret should never appear in a summary.
        Today we shipped the billing migration and discussed the next steps.
        """
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: text, hint: .file)
        XCTAssertFalse(
            summary.contains("sk_live_supersecret"),
            ".env-style values must be redacted; got: \(summary)"
        )
    }

    func testEmptyInputProducesEmptySummary() async throws {
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let summary = try await summarizer.summarize(text: "   \n\n", hint: .note)
        XCTAssertEqual(summary, "")
    }

    func testFailingSummarizerDegradesToTruncatedInput() async throws {
        // The protocol-conformant default impl never throws, but a
        // pathological input (no nouns, no sentences) should still
        // come back as the truncated input rather than blowing up.
        let summarizer = OnDeviceSummarizer(useGenerativeIfAvailable: false)
        let punctuation = String(repeating: "!", count: 300)
        let summary = try await summarizer.summarize(text: punctuation, hint: .note)
        XCTAssertLessThanOrEqual(summary.count, 200)
    }
}

/// Tests for the `KeywordSummary` building blocks. Kept separate from
/// the protocol-level tests so a future regression in just the
/// sentence-splitter or the keyword ranker has a clear failure site.
final class KeywordSummaryTests: XCTestCase {
    func testLeadingSentenceSplitsOnPunctuation() {
        let text = "Buy milk. Pick up the dry cleaning. Call Mom."
        XCTAssertEqual(KeywordSummary.leadingSentence(of: text), "Buy milk.")
    }

    func testLeadingSentenceFallsBackToFirstLine() {
        // A short transcript with no punctuation should still produce
        // something rather than the empty string.
        let text = "shipping the v2 files source\nnotes on the next launch"
        let first = KeywordSummary.leadingSentence(of: text)
        XCTAssertFalse(first.isEmpty)
    }

    func testTopKeywordsRanksByFrequency() {
        let text = """
        Project Atlas is the launch project. The Atlas team will demo Atlas next week.
        The launch demo will cover the Atlas roadmap.
        """
        let keywords = KeywordSummary.topKeywords(in: text, limit: 5)
        XCTAssertTrue(keywords.contains("atlas"), "Atlas appears most; got: \(keywords)")
    }

    func testTopKeywordsExcludesShortGlueTokens() {
        let text = "we ate the cake at the cafe near the office park."
        let keywords = KeywordSummary.topKeywords(in: text, limit: 5)
        XCTAssertFalse(keywords.contains("we"))
        XCTAssertFalse(keywords.contains("at"))
    }
}
