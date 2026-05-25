# Voice-Aware Gmail and Slack Drafts Specification

Status: Done v1
Purpose: Define a durable drafts system that learns Kent's email and Slack voice from sent-message samples, stores that voice in Memory, and uses it whenever Maraithon drafts Gmail or Slack replies.

## 1. Overview and Goals

Maraithon already has Gmail and Slack connector tools, durable Memory, and Telegram approval flows that can generate one-off reply drafts. The missing system behavior is a reusable drafting layer that:

- scans past sent Gmail and Slack messages when asked or when a voice profile is stale,
- writes channel-specific voice profiles into durable Memory,
- uses those profiles for future Gmail and Slack drafts,
- prevents drafts from sounding AI-written,
- removes em dashes from generated copy before returning or saving it,
- never sends Gmail or Slack messages without the existing explicit confirmation gates.

## 2. Current State and Problem

Existing surfaces:

| Area | Current behavior |
|---|---|
| `Maraithon.Memory` | Stores encrypted durable per-user memory items and supports prompt recall. |
| `gmail_drafts` tool | Lists, creates, updates, sends, and deletes Gmail drafts through the Gmail API. It does not generate copy or apply user voice. |
| `slack_post_message` tool | Posts Slack messages and thread replies. It has no safe "draft only" equivalent. |
| `InsightNotifications.Actions` | Generates Gmail and Slack action drafts for Telegram insight buttons, using preference/operator/user memory but not channel-specific sent-message voice memory. |
| `AssistantHarness` | Instructs the assistant to draft inline or call `gmail_drafts` when the user explicitly asks to save a Gmail draft. |

The gap: generated drafts can be generic, and the system has no first-class channel voice memory that can be refreshed from the user's own sent messages.

## 3. Scope and Non-Goals

In scope for v1:

- A reusable `Maraithon.Memory.UserVoice` module that can build or refresh `email` and `slack` voice profiles.
- A reusable `Maraithon.Drafts` module that generates Gmail and Slack drafts with channel voice memory.
- A model-call prompt contract that includes channel, purpose, recipient/context, channel voice, and hard style constraints.
- A `draft_message` tool for assistant/MCP use.
- Capability, schema, and Telegram toolbox registration for the new tool.
- Prompt updates so generic assistant drafting prefers the drafting tool and knows the no-em-dash rule.
- Insight notification drafting should use the same voice memory and sanitizer.
- Tests for voice memory writing, draft sanitization, tool registration, and prompt inclusion.

Out of scope for v1:

- A full web UI for browsing drafts.
- Sending Slack messages through `draft_message`; Slack remains draft-only in this tool.
- Gmail draft editing UI beyond the existing Gmail API draft tool.
- Perfect Slack "sent by me" coverage across every workspace; the scanner uses best-effort Slack search samples when a user token and `slack_user_id` are available.

## 4. Functional Requirements

| Requirement | Contract |
|---|---|
| Channel voice memory | Email and Slack profiles are separate Memory items with `source_ref_type: "user_voice_profile"` and dedupe keys `user_voice:gmail` / `user_voice:slack`. |
| Voice refresh | The system can refresh a profile from explicit sample text and, when available, connector searches for sent Gmail and Slack messages. |
| Draft generation | Drafts are generated through one service that accepts `channel`, `purpose`, `recipient`, `subject`, `thread_id`, `context`, `instructions`, and optional Gmail save behavior. |
| Gmail save | `draft_message` only saves to Gmail when `save_to_provider` is true. It creates a Gmail draft, not a sent email. |
| Slack safety | Slack output is returned as text with metadata. It is not posted. |
| Style guardrail | Draft output must not contain em dashes or AI-ish filler. The sanitizer replaces em dashes and trims common assistant sign-offs. |
| Memory inclusion | Draft prompts must include channel voice profile content and generic durable memory context. |
| Failure behavior | If voice refresh or LLM generation fails, return a deterministic concise fallback draft and include available voice memory. |

## 5. Data and Domain Model

No new database table is required in v1. Memory remains the source of truth.

Memory item shape:

| Field | Value |
|---|---|
| `kind` | `instruction` |
| `scope` | `user` |
| `title` | `User email voice profile` or `User Slack voice profile` |
| `content` | Concise writing guidance derived from sent messages |
| `summary` | Short summary safe for prompt inclusion |
| `source` | `user_voice` |
| `source_ref_type` | `user_voice_profile` |
| `source_ref_id` | `gmail` or `slack` |
| `tags` | `["user_voice", "drafts", channel]` |
| `metadata` | Sample count, sample source counts, refreshed timestamp, confidence, and sanitizer rules |
| `dedupe_key` | `user_voice:gmail` or `user_voice:slack` |

## 6. Backend and Tool Changes

### 6.1 `Maraithon.Memory.UserVoice`

Responsibilities:

- `get_profile/2`: read the active Memory item for a user/channel.
- `prompt_context/2`: return compact prompt-safe voice context.
- `refresh_profile/3`: build a channel profile from samples and write it to Memory.
- `refresh_from_connectors/3`: collect Gmail/Slack samples with existing connector helpers, then refresh Memory.

Refresh inputs:

- `sample_texts`: caller-provided examples.
- Gmail: `from:me newer_than:<N>d`, max 50, body/snippet extraction.
- Slack: best-effort `from:me` search with a user token, max 50, text extraction.

### 6.2 `Maraithon.Drafts`

Responsibilities:

- Generate draft JSON for `gmail` and `slack`.
- Load channel voice memory and general drafting memory.
- Optionally refresh voice memory before drafting.
- Sanitize generated copy.
- Return provider-save results only when requested.

Primary API:

```elixir
Maraithon.Drafts.create(user_id, attrs, opts \\ [])
```

`attrs` includes:

| Field | Required | Notes |
|---|---:|---|
| `channel` | yes | `gmail`, `email`, or `slack` |
| `purpose` | yes | What the draft should accomplish |
| `recipient` | no | Human recipient name or address |
| `subject` | Gmail | Existing subject or requested subject |
| `to` | Gmail save | Required only for saving a Gmail draft |
| `context` | no | Source-grounded context |
| `instructions` | no | Additional user constraints |
| `save_to_provider` | no | Only meaningful for Gmail |
| `refresh_voice` | no | Forces profile refresh before drafting |
| `sample_texts` | no | Explicit samples for voice refresh |

### 6.3 `draft_message` Tool

Tool behavior:

- validates `user_id`, `channel`, and `purpose`;
- calls `Maraithon.Drafts.create/3`;
- returns a structured draft:
  - Gmail: `subject`, `body`, optional `provider_draft`
  - Slack: `text`
  - `voice_profile`: status and Memory id when available
  - `warnings`: connector or LLM fallbacks

Policy:

- `write` side effect because it may write Memory and may create Gmail drafts.
- not `external_send`.
- confirmation not required for draft creation, matching existing Gmail draft behavior.

## 7. Prompt and Style Contract

All draft generation prompts must include:

- "Write as Kent, not as Maraithon or an assistant."
- "Do not use em dashes. Use commas, periods, or parentheses."
- "Do not include AI-ish filler like 'I hope this finds you well', 'circling back', 'just wanted to', or assistant sign-offs."
- "Use the user voice profile when it is relevant, but do not copy sample text verbatim."
- "Keep the draft direct, useful, and source-grounded."
- "Do not claim work is done, attached, delivered, or approved unless context proves it."

The sanitizer enforces the no-em-dash rule after model output.

## 8. Failure Modes and Edge Cases

| Failure | Expected behavior |
|---|---|
| No LLM provider | Return fallback draft and warning. |
| Voice scan fails | Continue with existing voice memory or empty voice context, include warning. |
| No voice profile exists | Draft still works, and refresh can be retried later. |
| Gmail draft save missing `to` or `subject` | Return validation error before provider call. |
| Gmail API error | Return generated draft text plus provider error warning. |
| Slack save requested | Ignore provider save and return draft-only warning. |
| Model returns invalid JSON | Use deterministic fallback draft. |
| Model emits em dashes | Replace before returning or saving. |

## 9. Test Plan and Validation Matrix

| Behavior | Validation |
|---|---|
| UserVoice writes Memory | Unit test refresh from explicit samples writes instruction memory with expected dedupe and tags. |
| Draft generation uses voice | Unit test captures prompt and asserts channel voice JSON is included. |
| Sanitizer removes em dashes | Unit test with model response containing em dashes verifies no output em dashes. |
| Tool registered | Capability and input schema tests include `draft_message`. |
| Telegram toolbox exposes tool | Assistant prompt/toolbox tests include `draft_message`. |
| Insight drafts use voice/sanitizer | Existing insight action tests continue to pass; add prompt assertion for no-em-dash instruction where practical. |
| Project gate | Run `mix precommit` after implementation. |

## 10. Definition of Done

- `docs/spectacula/inprogress/voice-aware-gmail-slack-drafts.json` tracks the implementation.
- `Maraithon.Memory.UserVoice` exists and stores channel-specific profiles in Memory.
- `Maraithon.Drafts` exists and generates sanitized Gmail/Slack drafts.
- `draft_message` is registered as a first-party tool with schema, capability metadata, and toolbox exposure.
- Draft prompts and insight notification prompts include channel voice memory and no-em-dash constraints.
- Focused tests pass.
- `mix precommit` is run and any failures are fixed or explicitly recorded.

## 11. Assumptions

- "file that gets created and used in Memory" means a new application module dedicated to user voice memory plus durable Memory items, not a local plaintext file containing personal message samples.
- Slack has no provider-side draft primitive in this app, so Slack v1 returns approval-ready text and never posts.
- Gmail draft creation remains non-confirmation-gated, while Gmail sending remains confirmation-gated through existing policy.
- Explicit sample text provided by a caller is acceptable for tests and manual bootstrap when remote connectors are not available.
