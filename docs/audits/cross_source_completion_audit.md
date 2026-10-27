# Audit: Cross-Source Todo Completion Sweep

**Module:** `Maraithon.Todos.CrossSourceCompletion` (`lib/maraithon/todos/cross_source_completion.ex`)
**Driver:** `Maraithon.Runtime.TodoCompletionSweep` (runs every 30 min, up to 100 users/cycle)
**Sibling:** `Maraithon.Todos.CompletionSweep` (deterministic, runs first each tick)
**Date:** 2026-06-27
**Reviewer:** Principal-engineer audit (hardening + intelligence focus)

---

## TL;DR

The cross-source pass is the right idea — an LLM that closes a Gmail todo when the user
clearly handled it over Slack/iMessage/Calendar. It has good *closing-side* discipline
(strict prompt, confidence floor, evidence-quote requirement, "when unsure leave open").

But the uncommitted change under review **swapped a cheap, side-effect-free, persisted-data
pass for an aggressive live-connector pass**, and the trust model around the LLM's output is
weaker than the stakes deserve. Auto-closing real user work is the single worst failure this
system can produce, and several paths let a hallucinated or mistimed "completion" silently
delete work that then **can't come back** (`preserve_closed_synced_todo?`).

The headline issues, in priority order:

1. **C1 — Unbounded, uncached live API fan-out** every 30 min for every user (cost + rate-limit + latency blast radius).
2. **C2 — The LLM's evidence quote and timing are never verified against the corpus** before closing — the model is fully trusted.
3. **C3 — Wrongly-closed work is unrecoverable and untracked** (no provenance tag, no reopen feedback loop).
4. **H-series** — prompt size unbounded, GenServer-blocking serial loop, brittle JSON extraction, thin tests, window inconsistencies, no per-user isolation.

"More intelligence, fewer heuristics" cuts both ways here: the *retrieval* side is a brute-force
dump (a real heuristic weakness), and the *trust* side leans on a self-reported `confidence`
float (a pseudo-heuristic dressed as intelligence). Both are addressed below.

---

## What the change did (context)

The previous module docstring promised: *"Evidence comes exclusively from data already
persisted server-side … so the pass makes no connector API calls."* The diff
(`lib/maraithon/todos/cross_source_completion.ex`) **removed that guarantee** and added
`live_source_evidence/4 → fetch_live_source_bundle/4 → Acquisition.build/4`, which makes
real-time Gmail / Calendar / Slack calls. Everything below flows from that shift.

---

## Critical findings

### C1 — Live `Acquisition.build/4` per user, every cycle, with no caching

`fetch_live_source_bundle/4` (lines 235-257) calls `Acquisition.build/4` with the
`commitment_tracker` skill. Confirmed behavior of `Acquisition.build/4`:

- Makes **live** Gmail (query + up to 4 concurrent body fetches/msg), Google Calendar, and
  Slack calls. Slack alone is **17+ API calls per workspace** (channel histories + thread
  replies + mention searches + self-authored searches).
- **No caching of any kind** — no request dedup, no time-based "skip if fresh," no memoization.

Driver math (`TodoCompletionSweep`, `@default_batch_size 100`, `@default_interval_ms 30 min`):

> 100 users × (Gmail + Calendar + 17+ Slack calls) **every 30 minutes** ≈ **1,700+ Slack
> API calls + ~hundreds of Gmail/Calendar calls per cycle**, purely to *check completion*.

This work is **redundant**: the `commitment_tracker` skill already pulls the same bundle
during normal ingestion, and the deterministic `CompletionSweep` (which runs first in the same
tick) *also* makes live Gmail calls. So a single tick can fetch the same user's Gmail thread
three times. Then `@max_live_evidence_per_source 120` throws away most of what was fetched
(skill config asks for 300 local messages / 220 Slack but only 120 survive `evidence_bucket/2`).

**Impact:** API quota burn, Slack/Google rate-limit risk (no backoff at the Acquisition layer),
real $ cost, and latency that compounds with C4.

**Recommendations:**
- **Do not fetch live in this pass.** Reuse the bundle the ingestion/`commitment_tracker` run
  already produced (cache it on the user with a short TTL and read it here), or pass it in via
  the existing `:source_bundle` opt from the orchestrator that already has it in hand.
- If live fetch must stay, add a **per-user freshness gate**: skip the build entirely when the
  last bundle is < N minutes old, and skip users with **no candidate todos** *before* fetching
  (today `candidate_todos` is checked first — good — but verify no user with 0 candidates ever
  reaches `Acquisition.build`).
- Align scan limits with `@max_live_evidence_per_source` so you don't fetch 300 to keep 120.

---

### C2 — The LLM's evidence is trusted without structural verification

`apply_resolutions/3` (lines 639-676) gates on: `todo_id` is in the set, `completed == true`,
`confidence >= 0.8`, and `evidence_quote` is a non-empty string. That's it. It then closes the
todo. **Nothing checks that the quote is real or that the timing is valid.**

Two prompt rules are *stated* but **never enforced in code**:

- *"Evidence must be AFTER the item's captured_at timestamp."* — not validated. Evidence is
  collected globally for all todos (not per-todo), so a quote from **before** the todo was
  captured can close it if the model slips. Closing on pre-capture evidence is logically
  guaranteed to be wrong (the work can't have been "already done" before it was created).
- *"the exact activity text that proves completion"* — `evidence_quote` is never checked for
  existence in the supplied evidence corpus. A **hallucinated** quote passes every guard.

`confidence >= 0.8` is the weakest part of the trust model: it's a **self-reported float**. The
model emits whatever number rationalizes its answer; the threshold gives false comfort. This is
the "heuristic masquerading as intelligence" the goal warns about.

**Recommendations (defense in depth, all cheap and deterministic):**
1. **Verify the quote exists.** Before closing, require `evidence_quote` to be a substring (or
   high-overlap fuzzy match) of some item in the evidence actually sent for this run. Carry the
   evidence corpus into `apply_resolutions` and reject quotes that don't ground out.
2. **Enforce timestamp ordering in code.** Resolve the matched evidence item, parse its `at`,
   and require `at > todo.source_occurred_at (|| inserted_at)`. Reject otherwise. This makes the
   prompt's strongest rule a hard invariant instead of a suggestion.
3. **Make `evidence_channel` consistent with the matched item's channel** (catches the model
   citing "slack" while quoting a Gmail line).
4. **Treat self-reported confidence as a tiebreaker, not a gate.** The real gate should be the
   structural checks in 1-3. Optionally add a second, independent verifier LLM call ("here is the
   todo and the *single* quoted evidence item — does this prove completion? yes/no") for
   high-value todos; that's genuine added intelligence, not a bigger number.

---

### C3 — Wrongly-closed work is unrecoverable and the system never learns from it

Three compounding gaps:

- **No provenance.** Closure writes only a free-text `resolution_note` via
  `Todos.mark_done(user_id, id, note: note)` (line 652). It does **not** stamp metadata like
  `completed_by: "cross_source_llm"`, the `confidence`, the `evidence_channel`, or a reference to
  the evidence item. You cannot later query "which todos did the LLM auto-close?" to measure
  false-positive rate or roll them back. The deterministic sweep has the same gap but its closures
  are provable; the LLM's are probabilistic and need the audit trail more.
- **Unrecoverable.** `preserve_closed_synced_todo?/2` (`todos.ex:1100-1108`) keeps a todo
  `done` when the source re-ingests it as `open`, unless the incoming source is strictly newer.
  So if the LLM wrongly closes a still-open commitment, the normal ingestion path **will not
  bring it back** — the work silently disappears.
- **No feedback loop.** `dismiss/3` records a `not_helpful` signal and trains
  `PreferenceMemory`; **`mark_done` records nothing**, and there is no capture when a user
  *reopens* an auto-closed todo. A reopen is the highest-signal false-positive label available,
  and it's dropped on the floor. (`false_positive_risk` exists in `signal_gate`/`surface_quality`
  for *creation*, but nothing closes the loop for *completion*.)

**Recommendations:**
- Stamp closure metadata: `completed_by`, `confidence`, `evidence_channel`,
  `evidence_source_item_id`, `swept_at`. Cheap, and unlocks everything below.
- Consider a **soft-close / "looks done — confirm?"** state for LLM closures (especially
  high-value or `i_owe` commitments) instead of a hard `done`, so the user confirms before the
  item leaves their world. At minimum, ensure auto-closures are visibly surfaced (activity feed
  is recorded as `marked_done` by actor `agent` — verify the user actually *sees* it).
- Capture reopen-after-auto-close as a `false_positive` training signal and feed
  `PreferenceMemory` / tune the threshold, mirroring the dismiss path.
- Re-examine `preserve_closed_synced_todo?` for LLM-closed items: a fresh same-source signal
  should be allowed to resurrect an LLM-closed todo even if not strictly "newer."

---

## High-severity findings

### H1 — Prompt payload is unbounded
`build_prompt/3` JSON-encodes **all** candidate todos (≤40) plus **all** evidence in one blob.
Evidence has per-source caps (`@max_live_evidence_per_source 120` × ~12 sources) plus 120
observations + 80 outgoing — **up to ~1,640 items**, each with text ≤280 + subject ≤180 +
metadata. Worst case is ~hundreds of thousands of tokens at `reasoning_effort: high`. There is
**no global evidence cap and no token budget**. Risks: silent provider truncation, cost spikes,
and signal dilution (the needle lost in a 1,400-item haystack hurts recall, not just cost).
**Fix:** add a global evidence cap and, better, **retrieve per-todo** (see "Intelligence" below).

### H2 — Serial loop blocks the GenServer and can outrun its own interval
`run_for_all_users/1` is a synchronous `Enum.reduce` over up to 100 users; each does a live
bundle fetch + a 60 s-timeout LLM call (lines 58-85, 596-606). Worst case ≫ 30 min, all inside
`TodoCompletionSweep.handle_info/2`. The next tick can't start until this returns (so no overlap,
but the deterministic sweep and everything else in that GenServer are blocked, and cadence
drifts). **Fix:** bounded-concurrency `Task.async_stream` with per-user timeout, or move
cross-source to its own supervised worker so it can't starve the deterministic sweep.

### H3 — No per-user error isolation in the batch
`run_for_all_users` only handles the documented return shapes. If `run_for_user` *raises*
(e.g. `candidate_todos`/`Todos.list_for_user` blows up for one user), the whole batch dies; the
only rescue is at `run_cross_source_pass` in the driver, which aborts the **entire remaining
cycle**. `live_source_evidence` is rescued, but the LLM call and DB writes are not.
**Fix:** wrap each `run_for_user` in try/rescue, count it as an error, and continue.

### H4 — Brittle JSON extraction
`extract_json/1` (lines 629-637) takes everything from the **first `{` to the last `}`**. Any
prose containing a brace, a fenced ```` ```json ```` block plus commentary, or two JSON objects
yields a malformed span and silently fails (`:cross_source_completion_invalid_response`). With a
reasoning model this is a real recall leak. **Fix:** request structured/JSON output mode from the
provider where available, or parse balanced braces / strip code fences, and log decode failures
with a sample so you can see how often the model is being misread.

### H5 — Thin test coverage for a destructive operation
Only **two** tests, both happy-path (lines 33, 132). No coverage for: hallucinated quote not in
corpus, evidence-before-`captured_at`, confidence exactly at/below 0.8, malformed JSON, multiple
resolutions, todo_id not in set, dedupe, or scale/size limits. For an action that auto-closes
real work, the failure modes are exactly what needs locking down. **Fix:** add negative/boundary
tests, especially the C2 validation invariants once implemented (per project policy, harden — do
not weaken — tests).

---

## Medium / low findings

- **M1 — Inconsistent evidence windows.** Live bundle lookback is **14 days**
  (`lookback_hours => @evidence_window_days * 24 * 2`), but observations/outgoing use
  `@evidence_window_days` = **7 days** (line 130). Pick one rationale; the asymmetry is silent.
- **M2 — `mark_done` re-closes already-closed todos.** `update_status` doesn't guard on current
  status; during the 60 s LLM window a user could mark a todo done in-app and the pass would
  re-`mark_done` it (re-stamping `closed_at`, possibly emitting a duplicate activity event path).
  Low impact but worth a status guard.
- **M3 — `read_value/2` uses `String.to_existing_atom` with rescue.** Works, but relies on the
  atom already existing; fragile if upstream bundle keys ever arrive as atoms not seen elsewhere.
  Bundle is `stringify_keys`-normalized today, so mostly latent — note it.
- **M4 — `source_health` freshness is raw `Jason.encode!`** into one evidence item (line 291).
  Fine, but it counts against the prompt budget and the model rarely needs the full blob; a
  compact "ready/partial/unavailable per source" line would be cheaper and clearer.
- **L1 — `candidate_todos` silently caps at 40** (`@max_todos`), oldest-updated first. A user
  with >40 open todos never gets the newest checked. Acceptable, but log when truncating.
- **L2 — Privacy/compliance surface.** This pass ships the user's Gmail bodies, Slack messages,
  iMessages, notes, and **browser history** to the LLM provider every 30 min. Given the recent
  App-Review AI-data-sharing disclosure work (commit `5498acf`), confirm this background,
  high-frequency egress is covered by that consent and the provider's retention terms — browser
  history in particular is sensitive.

---

## On "intelligence, not heuristics"

The system *does* use an LLM, but two layers are still crude:

1. **Retrieval is a brute-force dump, not intelligent matching.** Evidence is gathered globally
   and handed over wholesale; the model must find which of ~1,400 items matches which of 40
   todos. That is the heuristic weakness — it's expensive (H1) *and* lowers recall. The
   intelligent version is **per-todo candidate retrieval**: for each todo, select the top-k
   evidence items by entity/counterparty match + semantic similarity (embeddings) + same
   thread/`source_item_id`, then ask the model to judge a *focused* set. Smaller prompts, higher
   precision and recall, far lower cost.
2. **The closing gate is a self-reported float.** `confidence >= 0.8` is a number the model
   makes up. Replace it with **grounded verification** (C2): quote-exists, timestamp-after,
   channel-consistent, optional second-pass verifier. That is real intelligence — the model
   reasons, but the *decision to mutate user data* is backed by deterministic invariants.

Net: keep the LLM for judgment, but (a) feed it focused, retrieved evidence, and (b) never let
its raw output mutate a todo without structural proof.

---

## What's already good (keep)

- Strict, well-written closing prompt; "when unsure, leave open" bias is correct for the risk.
- `@min_todo_age_minutes 30` avoids closing freshly-captured items.
- `temperature: 0.1` + `reasoning_effort: intelligence()` is the right dial for a judgment task.
- `live_source_evidence/4` is fully rescued (rescue + catch) so source failures degrade to "no
  evidence" rather than crashing — extend this same isolation to the per-user loop (H3).
- Clear separation from the deterministic `CompletionSweep` (hard evidence) vs. this LLM pass
  (cross-channel reasoning) is a sound architecture.
- `:source_bundle` / `:llm_complete` injection points make the module testable — lean on them
  to add the C2/H5 tests.

---

## Suggested priority order

1. **C2** — add quote-exists + timestamp-after + channel-consistent validation in
   `apply_resolutions` (highest safety win, small, deterministic).
2. **C1** — stop live-fetching here; reuse the ingestion bundle / add freshness gate (highest cost win).
3. **C3** — stamp closure provenance + capture reopen-as-false-positive (+ consider soft-close).
4. **H1/H2/H3** — global evidence cap → per-todo retrieval; bounded concurrency; per-user rescue.
5. **H4/H5/M-series** — robust JSON parsing, negative/boundary tests, window alignment.
