---
created_at: 2026-05-15T04:12:29Z
created_by: cybrus
cybrus_task_id: 26355FF4-5746-4CE8-8C93-F6B260C4DF33
project: Maraithon App
status: done
---
# Ship Memory primitive with model-callable read/write tools

Status: Done
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 26355FF4-5746-4CE8-8C93-F6B260C4DF33
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

Cybrus PM Summary
Make Memory a first-class runtime primitive so the assistant can learn from user corrections, store durable preferences, and steer future behavior — instead of repeating the same mistakes.

Why This Matters
The goals doc names Memory as a non-negotiable first-class primitive ("the system should learn from correction") but it's absent from the backlog. Without it, every other learning loop — relevance, interrupt budget, relationship preferences — is impossible. Building this now compounds across every assistant interaction.

## Workflow Context

Deterministic Cybrus configuration:
- Execution mode: local Codex CLI with full local workspace access.
- Task source: Orchestrator/Cybrus task queue.
- Workflow file: WORKFLOW.md
- Workflow file found: no
- Human handoff: produce proof of work, then Cybrus writes a local review packet.

Repository workflow instructions:
No repository workflow instructions were found. Use the existing codebase conventions.

The exploration revealed significant existing infrastructure: the `Memory.Item` schema, several tools (`write_memory`, `recall_memory`, `forget_memory`, `list_memories`, `record_memory_feedback`), and even an AGENTS.md instruction telling the assistant to call them. The plan below treats this as **Phase A completion** — closing the gap between what the ticket asks for and what's actually wired up — rather than a greenfield build.

---

## Objective

Complete the Memory primitive so the model can reliably **read durable steering context before answering** and **write durable corrections after them**, with conflict-aware supersession and an operator-visible audit trail. By the end of this ticket:

- Every assistant turn (Telegram + Chief of Staff skills) is given a token-budgeted slice of relevant memories before the model decides.
- User corrections ("not relevant", "Charlie prefers Slack", "never surface this again") flow through the `write_memory` tool and verifiably change the next decision.
- Contradicting memories are recorded as a supersession chain rather than overwritten in place.
- An operator LiveView at `/operator/memories` exposes the durable state for inspection, archival, and provenance review.

---

## Assumptions and Decisions

**Reuse over rebuild.** The codebase already has `Maraithon.Memory.Item`, the `memories` table, and tool modules (`Tools.WriteMemory`, `RecallMemory`, `ForgetMemory`, `ListMemories`, `RecordMemoryFeedback`). The ticket's "Initial Scope" lists schema fields and tool names that are substantially in place. This plan extends and connects them rather than re-creating them.

**Field-name reconciliation.** The ticket uses `evidence`, `decay_at`, `created_by`, `source_event_id`. The existing schema uses `metadata`, `expires_at`, `author_type`/`author_id`, `source_ref_type`/`source_ref_id`. Decisions:
- `evidence` → store as a structured key inside the existing `metadata` map (`metadata["evidence"]`) — no migration churn, validated in the changeset. Add a typed accessor.
- `decay_at` → **add as new column.** Semantically distinct from `expires_at`: `expires_at` archives the memory; `decay_at` is the timestamp after which `confidence` should be re-asked or down-weighted in ranking. Keep both.
- `created_by` → covered by `author_type` + `author_id`.
- `source_event_id` → covered by `source_ref_type="event"` + `source_ref_id`. Add an index helper to query memories by source event.

**Supersession chain.** Add a self-reference `superseded_by_id` (binary_id, nullable) and `supersedes_id` (mirror, optional — derivable but useful for ordered chains). The existing `:superseded` status becomes meaningful. Conflict resolution is **model-decided**, not heuristic: when `write_memory` receives a memory that the model believes contradicts an existing one, the model passes `supersedes_id: <existing>` and the runtime atomically inserts the new row + flips the old row's status to `:superseded` with `superseded_by_id` set.

**Recall is one centralized helper.** Build `Maraithon.Memory.Recall` as the single entry point used by the assistant harness, Chief of Staff skills, and (later) interrupt-budget logic. Ranking uses: `importance`, `confidence`, recency of `last_used_at`, scope/subject match, and `decay_at` (decayed-but-not-expired memories rank lower). Token budget enforced before injection. **Heuristic ranking is acceptable here** because the model still does the semantic work downstream — recall just narrows the candidate set.

**Telegram "remember that…" stays model-routed.** AGENTS.md already instructs the assistant to call `write_memory` when the user asks to remember. Do not add regex routing in `telegram_router.ex`. Verification is the work item: ensure the assistant prompt assembles the `write_memory` tool definition and that confirmation/echo back to the user works.

**Out of scope (deferred).** Cross-user memory; full edit UI in operator (archive only); embeddings-based recall (current ranking is structured-fields-only — embeddings can be added later via `person_embeddings.ex` pattern); proactive interrupt-budget steering (this ticket only ensures memory is *available* to the decision; the decision logic is separate work).

**Encryption.** Memory content can include sensitive personal context (relationships, preferences). Per existing `Maraithon.Encrypted.Binary` pattern: convert `content`, `summary`, and `metadata` to encrypted types in this ticket. This requires a migration to widen columns and a backfill. **Decision: include in this ticket** — adding encryption later is materially harder once data accrues.

---

## Implementation Plan

### Phase 1 — Schema completion

1. Generate migration `add_decay_and_supersession_to_memory_items`:
   - Add `decay_at :utc_datetime_usec` (nullable), `superseded_by_id :binary_id` (FK to `memory_items`, nullable, `on_delete: :nilify_all`), `supersedes_id :binary_id` (mirror, nullable).
   - Add index `[:user_id, :decay_at]` (partial: `where status = 'active'`) for recall ranking.
   - Add index on `superseded_by_id`.
2. Generate migration `encrypt_memory_item_content`:
   - Alter `content`, `summary`, `metadata` to `:binary` (encrypted columns).
   - Backfill existing rows via release task or one-shot Repo migration.
3. Update `lib/maraithon/memory/item.ex`:
   - Switch field types to `Maraithon.Encrypted.Binary` / `Maraithon.Encrypted.Map`.
   - Add `decay_at`, `superseded_by_id`, `supersedes_id` fields and `belongs_to`/`has_one` relations.
   - Extend `changeset/2` to validate `metadata["evidence"]` shape (`%{"quote" => binary, "source" => binary}` when present) and ensure `decay_at > inserted_at`.
   - Keep the rule from AGENTS.md: `user_id` is **not** in `cast/3` — set explicitly when building the struct.

### Phase 2 — Recall plumbing

1. Create `lib/maraithon/memory/recall.ex` with `recall(user_id, opts)`:
   - `opts`: `:query` (string, optional), `:subject_type`, `:subject_id`, `:project_id`, `:person_id`, `:kinds` (list), `:scopes` (list), `:max_tokens` (default 1500), `:limit` (hard cap, default 25).
   - Filters: only `status: :active`, exclude superseded, exclude expired, demote past-`decay_at`.
   - Ranking score = weighted sum of `importance`, `confidence`, recency of `last_used_at`, subject match boost, decay penalty. Document weights inline.
   - Returns `{:ok, [%Item{}], %{used_tokens: n, dropped: m}}`.
   - Token estimation uses existing helper if one exists in `assistant_harness`; otherwise a simple `String.length / 4` estimate (good enough for budgeting).
2. Wire into context assembly:
   - `lib/maraithon/assistant_harness.ex`: when building the Telegram assistant context, call `Memory.Recall.recall/2` with the current conversation's subject hints (any mentioned person, project, or recent thread), inject results into the prompt under a clearly-labeled `## Relevant memories` block with provenance per item.
   - `lib/maraithon/chief_of_staff/skills.ex` (or per-skill): each skill's context builder calls `Memory.Recall.recall/2` with skill-appropriate scopes.
3. After a memory is used in a turn, the runtime increments `use_count` and updates `last_used_at`. Add `Memory.touch/2` and call it from the harness post-turn.

### Phase 3 — Tool surface gaps

1. **Audit** existing tool modules (`lib/maraithon/tools/{write,recall,forget,list,record}_memory*.ex`) and `input_schemas.ex` against the ticket's named tools:
   - `memory.write` ↔ `write_memory` — extend args to accept `supersedes_id` and `decay_at`.
   - `memory.recall(query, scope)` ↔ `recall_memory` — confirm it routes through the new `Memory.Recall` helper.
   - `memory.list_for_subject` — add a new tool **only if** `list_memories` cannot already filter by `source_ref_type` + `source_ref_id`. If it can, document the calling convention in `input_schemas.ex`.
   - `memory.forget` ↔ `forget_memory` — confirm it sets `status: :archived` (soft) rather than deleting, and writes a `Memory.Event`.
   - `memory.update_confidence` — add as a thin tool wrapping `Memory.update_confidence/3`. Distinct from `record_memory_feedback` (which is feedback-on-feedback).
2. Register any new tool in `lib/maraithon/capabilities.ex`.
3. Add the new/updated tool definitions to the assistant prompt assembly so the model actually sees them.

### Phase 4 — Supersession chain

1. `Maraithon.Memory.supersede(user_id, new_attrs, supersedes_id)`:
   - Inside a `Repo.transaction`: insert new item with `supersedes_id` set, update old item to `status: :superseded`, `superseded_by_id: <new>`.
   - Emits a `Memory.Event{kind: :superseded, ...}`.
2. `write_memory` tool: when args include `supersedes_id`, route through `supersede/3`.
3. `Memory.Recall` excludes `:superseded` rows by default; add `include_superseded: true` opt for audit views.

### Phase 5 — Operator LiveView

1. Add `lib/maraithon_web/live/memories_live.ex` mounted at `/operator/memories`.
2. Catalyst-aligned, row-oriented (per DESIGN.md):
   - Top filter row: kind, scope, subject (person/project picker), status (active/superseded/archived), text search.
   - Table columns: kind badge, content (truncated), subject link, importance/confidence, source, last_used_at, status badge, action (archive).
   - Detail drawer/modal: full content, evidence, supersession chain (rendered as a vertical list with `supersedes`/`superseded_by` traversal), provenance metadata, `Memory.Event` history.
3. Use existing `core_components.ex` primitives — no new UI system.

### Phase 6 — Telegram verification (no new code expected)

1. Confirm `assistant_harness` includes `write_memory`, `recall_memory`, `forget_memory`, `update_confidence` in the tool catalog presented to the model.
2. Confirm AGENTS.md guidance ("If the user asks Maraithon to remember a durable fact…") is preserved in whichever prompt Telegram uses.
3. Manual smoke (recorded in proof of work): "Remember that I prefer Slack for Charlie" → assistant calls `write_memory` → next turn that mentions Charlie demonstrably surfaces it.

### Phase 7 — Tests

Mirror the existing `test/maraithon/memory_test.exs` and `test/maraithon/tools/memory_tools_test.exs` style:

1. Schema/changeset: new fields validated, evidence shape enforced, encrypted round-trip works.
2. `Memory.Recall` unit tests: ranking respects subject match, decayed memories demoted, superseded excluded, token budget enforced.
3. Supersession transaction: old marked superseded, new linked, event emitted, atomicity on failure.
4. Tool execute paths: happy + error per tool; `supersedes_id` flow through `write_memory`.
5. LiveView smoke test: index renders, filter works, archive button transitions status, supersession chain displays.
6. Integration: assistant harness invocation includes a `## Relevant memories` block when matching memories exist.

---

## Files and Interfaces

**Migrations (new)**
- `priv/repo/migrations/<ts>_add_decay_and_supersession_to_memory_items.exs`
- `priv/repo/migrations/<ts>_encrypt_memory_item_content.exs` (+ backfill)

**Schema / domain (edit)**
- `lib/maraithon/memory/item.ex` — new fields, encrypted types, `evidence` validation, supersession assocs.
- `lib/maraithon/memory.ex` — add `supersede/3`, `update_confidence/3`, `touch/2`.
- `lib/maraithon/memory/event.ex` — add `:superseded`, `:confidence_updated`, `:recalled` event kinds if missing.

**Recall (new)**
- `lib/maraithon/memory/recall.ex` — `recall/2`, ranking helpers, token budget.

**Tools (edit; possibly one new)**
- `lib/maraithon/tools/write_memory.ex` — accept `supersedes_id`, `decay_at`.
- `lib/maraithon/tools/recall_memory.ex` — delegate to `Memory.Recall`.
- `lib/maraithon/tools/forget_memory.ex` — confirm soft-archive + event.
- `lib/maraithon/tools/list_memories.ex` — confirm subject filter.
- `lib/maraithon/tools/update_memory_confidence.ex` — **new** if missing.
- `lib/maraithon/tools/memory_helpers.ex` — `serialize_item/1` exposes new fields.
- `lib/maraithon/tools/input_schemas.ex` — schemas for new args / new tool.
- `lib/maraithon/capabilities.ex` — register new tool.

**Harness wiring (edit)**
- `lib/maraithon/assistant_harness.ex` — call `Memory.Recall.recall/2`, inject `## Relevant memories` block, post-turn `Memory.touch/2`.
- `lib/maraithon/context_engine/telegram.ex` — pass subject hints into recall.
- Each Chief of Staff skill in `lib/maraithon/chief_of_staff/skills/` that builds prompts — add recall step.

**Operator UI (new)**
- `lib/maraithon_web/live/memories_live.ex`
- Route entry in `lib/maraithon_web/router.ex` under the operator scope.

**Tests (new + edit)**
- `test/maraithon/memory_test.exs` — extend.
- `test/maraithon/memory/recall_test.exs` — new.
- `test/maraithon/tools/memory_tools_test.exs` — extend.
- `test/maraithon_web/live/memories_live_test.exs` — new.
- `test/maraithon/assistant_harness_test.exs` — assert recall block injected.

---

## Acceptance Checks

1. **Migration cleanly applies forward and rollback** on a fresh DB and on a copy of prod schema. Encrypted backfill verified on a seeded row.
2. `mix test` is green, including the new tests above.
3. **Recall integration**: with a seeded memory `{kind: :preference, subject: <Charlie>, content: "Prefers Slack"}`, an assistant turn that mentions Charlie includes that memory text in the assembled prompt (assertable via the harness test).
4. **Write-back loop**: a Telegram message "Remember that newsletters from X are not relevant" results in an active `Memory.Item` with `kind: :relevance_feedback`, `polarity: :negative`, subject linked to source X, evidence populated. Recorded in proof-of-work transcript.
5. **Supersession**: writing a contradicting memory with `supersedes_id` produces two rows linked in both directions; old row is `:superseded`; recall excludes the old row by default and surfaces only the new one.
6. **Operator LiveView**: `/operator/memories` renders, filters by kind/scope/subject, archive button flips status, supersession chain renders for a chained pair.
7. **Tool surface**: `Capabilities.list()` includes `write_memory`, `recall_memory`, `forget_memory`, `list_memories`, `update_memory_confidence`. Each has a JSON schema in `input_schemas.ex` and an `execute/1` smoke test.
8. **Decay behavior**: a memory with `decay_at < now` ranks below an equivalent fresh memory in `Memory.Recall.recall/2` output (assertable in the recall test).

---

## Proof of Work Expectations

A Cybrus review packet should include:

1. **Migration evidence**: output of `mix ecto.migrate` and `mix ecto.rollback` on both directions, plus a `\d memory_items` snapshot before/after.
2. **Test output**: full `mix test` log, plus targeted runs for the new test files showing each acceptance check covered.
3. **Manual Telegram transcript** (or Chief of Staff dry-run log): three flows captured end-to-end —
   - Write: "Remember that I prefer Slack for Charlie" → `write_memory` tool call payload + DB row.
   - Recall: a follow-up turn referencing Charlie → assembled prompt excerpt showing the `## Relevant memories` block containing the prior memory.
   - Supersede: a follow-up "Actually, Charlie now prefers email" → both DB rows with `superseded`/`superseded_by_id` linkage shown.
4. **Operator screenshot**: `/operator/memories` index with at least one filter applied and a detail drawer open on a superseded chain.
5. **Diff summary**: list of changed files grouped by phase, with line counts; flag any file that isn't covered by the plan above.
6. **Risk note**: explicit confirmation that the encryption migration backfill ran on representative seed data without truncation or character-set issues.

---

## Risks

- **Encryption migration on existing prod data.** Cloak column conversions on populated tables are the highest-risk step. Mitigation: run on a Fly volume snapshot first; backfill in chunks; verify a `Repo.get` round-trip before flipping reads.
- **Recall ranking is heuristic in a model-first system.** The goals doc forbids semantic heuristics where the model should decide. Mitigation framing: ranking is *candidate selection under a token budget*, not semantic relevance — the model still chooses what to use. Document this distinction in `recall.ex` moduledoc to prevent drift toward keyword filtering.
- **Token budget eats other context.** Injecting memories into every turn can crowd out source context. Mitigation: default `max_tokens: 1500`, exposed as a config knob; harness logs `used_tokens` per turn for tuning.
- **Supersession storms.** A skill that re-derives the same memory each wakeup could create runaway chains. Mitigation: require `supersedes_id` to be model-supplied (no auto-supersede), and the existing semantic dedupe key on `(user_id, dedupe_key) where status='active'` already blocks dupes at the DB layer.
- **Telegram "remember that…" relies on the assistant prompt continuing to include the AGENTS.md guidance.** Drift here silently breaks the write loop. Mitigation: add an assistant-harness test asserting that the rendered prompt contains the literal `write_memory` tool name when the user message includes "remember".
- **Existing `Memory.Intelligence` async extractor** may write rows that don't yet know about `supersedes_id`. Audit during Phase 4 and update if needed; otherwise schedule as an immediate follow-up ticket.
