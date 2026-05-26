import Foundation

/// Origin marker passed to ``Summarizing`` so the summarizer can tune
/// its output to the kind of text it's looking at.
///
/// The hint informs both prompt selection (when the generative path is
/// available) and the keyword-extraction heuristic in the fallback. A
/// note benefits from emphasising its first sentence, a voice-memo
/// transcript from extracting actions, an iMessage thread from
/// extracting topical nouns, and a file from a leading-prose summary.
///
/// Kept as a plain enum (no associated values, `Sendable` by default)
/// so the summarizer protocol stays cleanly `Sendable` and the hint
/// can ride across the actor boundary without ceremony.
enum SummaryHint: String, Sendable, Equatable, CaseIterable {
    /// Apple Notes body. Usually prose; lean on the first sentence and
    /// extracted noun phrases.
    case note
    /// Voice memo transcript. Often action-oriented; favour verbs and
    /// proper nouns.
    case voiceMemo
    /// iMessage text. Short and conversational; kept here for completeness
    /// even though iMessage doesn't currently route through the summarizer.
    case message
    /// Extracted text from a file under `~/Documents`, `~/Desktop`, or
    /// `~/Downloads`. Could be anything — fall back to a generic prose
    /// summary.
    case file
}
