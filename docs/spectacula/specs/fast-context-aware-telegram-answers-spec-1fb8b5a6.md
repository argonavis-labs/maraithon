---
created_at: 2026-05-30T01:41:53Z
created_by: cybrus
cybrus_task_id: 1FB8B5A6-A0D5-40D5-A142-6186D75A16AC
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 1FB8B5A6-A0D5-40D5-A142-6186D75A16AC
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

No additional notes were attached to this task.

## Workflow Context

Deterministic Cybrus configuration:
- Execution mode: local Codex CLI with full local workspace access.
- Task source: Orchestrator/Cybrus task queue.
- Workflow file: WORKFLOW.md
- Workflow file found: no
- Human handoff: produce proof of work, then Cybrus writes a local review packet.

Repository workflow instructions:
No repository workflow instructions were found. Use the existing codebase conventions.

Verification complete. Every claim in the spec holds against the live codebase, and I found one important drift: the tracking plan file is **already `status: done`** (and titled "Implementation Plan," not "Spec"), so closeout step #4 is already done. That reshapes the remaining scope. Here is the refined, implementation-ready plan.

---

# Fast & Context-Aware Telegram Answers — Verification & Closeout Plan

## Objective

Cut Telegram-perceived latency and improve answer quality across the eight gaps from the latency audit. **All eight fixes are already implemented and verified present in source on the current working tree.** This ticket therefore delivers *executable proof* that the implemented behavior is correct — not new construction. The deliverable is a green `mix precommit`, targeted module-test evidence, one closed test gap, and a review packet that a human can approve with confidence.

If — and only if — verification surfaces a behavioral defect in one of the eight landing points, that defect is repaired as a scoped bug fix against the existing module (never a rebuild).

---

## Assumptions and Decisions

- **Decision — scope is verification + closeout, not construction.** A direct codebase pass (below) confirms all eight landing points exist as the spec describes. Re-implementing any of them is out of scope.
- **Finding — the tracking plan file is already `status: done`.** `.claude/plans/2026-05-09-fast-context-aware-answers.md` carries `status: done` in frontmatter and is titled "Implementation Plan." The spec's closeout step "flip `status: planning` → `status: done`" is therefore **already complete and obsolete**. Decision: do not re-edit status; instead verify each fix's annotation is accurate and leave the file authoritative.
- **Decision — the one real test gap is `runner.ex`.** There is no `test/maraithon/telegram_assistant/runner_test.exs`. Runner behavior is currently exercised indirectly via `telegram_assistant_test.exs`, plus adjacent `context_test.exs`, `model_routing_test.exs`, and `liveness_session_streaming_test.exs`. Decision: add focused runner cases **only for fix behaviors not already covered** (parallel tool ordering, `apply_delivery_mode/2` edit-vs-reply routing, `guard_tool_history/2` loop guard). Do not duplicate coverage that already passes.
- **Decision — verification authority is the existing test suite.** Per repo `CLAUDE.md`, a failing test means either real production breakage or an obsolete test; it is never worked around or gamed. Any failure is triaged to root cause.
- **Assumption — `pg_trgm` is available in all target Postgres environments.** The migration `20260510005233_enable_pg_trgm_for_crm_persons.exs` runs `CREATE EXTENSION`. Local + Fly Postgres both support it. If a CI/test DB lacks superuser to create extensions, that surfaces as a migration failure to be handled, not a code change.
- **Assumption — no production deploy is in scope.** This is verification and proof-of-work only. Merge/deploy decisions belong to the human reviewer after moving Planned → Approved.
- **Decision — `find_existing_person/2` is a phantom.** The original draft named a function that does not exist; the real fuzzy-resolve surface is `list_people/2`, `search_people/3`, and `semantic_find_person/3`. Verification targets the real functions.

---

## Implementation Plan

### Phase 0 — Codebase verification (already performed; recorded here as evidence)

Each fix was confirmed present via direct search of the working tree:

1. **Anthropic prompt caching** — `anthropic_provider.ex`: `split_system_messages/1` (L168), `build_system_blocks/1` (L221–235) emits `cache_control: %{type: "ephemeral"}`; response parsing reads `cache_read_input_tokens` (L121, L134). ✅
2. **Parallel tool execution** — `runner.ex`: `run_tool_calls_in_parallel/5` (L413/423), `guard_tool_history/2` (L451). ✅
3. **Fast routing model** — `runtime.exs`: `ANTHROPIC_ROUTING_MODEL` default `claude-haiku-4-5-20251001` (L171–176), `OPENAI_ROUTING_MODEL` (L184). ✅
4. **Today digest ETS cache** — `application.ex`: `Maraithon.ContextCache` supervised (L26); `context.ex`: `get_digest/1` (L56) + `maybe_refresh_async/1` (L57), `today_digest` key (L92). ✅
5. **Streaming progress / edit-in-place** — `application.ex`: `LivenessSupervisor` supervised (L27); `runner.ex`: `apply_delivery_mode/2` (L764), `send_mode_for_delivery/1` (L773), delivery dispatch (L619, L1039). ✅
6. **Fuzzy person resolve (pg_trgm)** — migration `20260510005233_enable_pg_trgm_for_crm_persons.exs` present; `crm.ex`: `similarity(...) > 0.3` fragments (L872, L883, L1015, L1042) + `semantic_find_person/3` embedding fallback (L126–158). ✅
7. **Parallel context prefetch** — `context.ex`: `parallel_fetch/2` (L103) → `safe_parallel_fetch/2` (L250). ✅
8. **Rolling conversation summarization** — `telegram_conversations.ex`: `compact_old_turns/2` (L347) folding into `metadata["historical_summary"]` (L404), `recent_turns/2` (L327). ✅

All six named test files exist: `llm/anthropic_provider_test.exs`, `context_cache_test.exs`, `llm_test.exs`, `crm_test.exs`, `telegram_conversations_test.exs`, `telegram_assistant_test.exs` — plus relevant `telegram_assistant/{context,model_routing,liveness_session_streaming}_test.exs`.

### Phase 1 — Behavioral verification run

Run the full quality gate, then the targeted module suites, capturing output for the proof packet:

1. `mix precommit` (formatter + credo + full test suite — the repo's canonical gate).
2. Targeted runs (faster signal, isolate any failure):
   - `mix test test/maraithon/llm/anthropic_provider_test.exs`
   - `mix test test/maraithon/llm_test.exs`
   - `mix test test/maraithon/context_cache_test.exs`
   - `mix test test/maraithon/crm_test.exs`
   - `mix test test/maraithon/telegram_conversations_test.exs`
   - `mix test test/maraithon/telegram_assistant_test.exs`
   - `mix test test/maraithon/telegram_assistant/context_test.exs test/maraithon/telegram_assistant/model_routing_test.exs test/maraithon/telegram_assistant/liveness_session_streaming_test.exs`

### Phase 2 — Triage any failure to root cause

For each failure, apply systematic debugging: identify what the test protects, determine whether production code is wrong or the test is obsolete, then fix the underlying code or retire the test with explicit rationale. **No skips, no `@tag :skip`, no green-washing** (repo `CLAUDE.md`).

### Phase 3 — Close the one real test gap

Add `test/maraithon/telegram_assistant/runner_test.exs` (or extend `telegram_assistant_test.exs` if runner setup is too heavy to isolate) covering only uncovered fix behaviors:

- **Parallel tool ordering** — multiple tool calls run via `Task.async_stream` return results in request order and thread `sequence`/`tool_steps` correctly.
- **Loop guard** — `guard_tool_history/2` blocks a repeated identical tool call.
- **Delivery mode routing** — `apply_delivery_mode/2` + `send_mode_for_delivery/1` select `:edit` with a `message_id` when liveness produced a placeholder, and fall back to `:reply`/`:send` otherwise.

Use `Maraithon.LLM.MockProvider` and `start_supervised!`; **no `Process.sleep`** (repo ExUnit convention).

### Phase 4 — Reconcile the tracking plan file

`.claude/plans/2026-05-09-fast-context-aware-answers.md` is already `status: done`. Read it end-to-end and confirm each fix's annotation matches the verified landing points above. Correct only stale references (e.g., any lingering mention of the non-existent `find_existing_person/2`). Do not change `status`.

---

## Files and Interfaces

**Verified (read-only unless a defect is found):**
- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1`, `split_system_messages/1`, `build_system_blocks/1`
- `lib/maraithon/llm.ex` — `routing_model/0`, `complete_routing/1`, `chat_model/0`, `complete_chat/1`
- `lib/maraithon/telegram_interpreter.ex` — `default_llm_complete/1`
- `config/runtime.exs` — routing-model env wiring
- `lib/maraithon/context_cache.ex` + `ContextCache.Builder`
- `lib/maraithon/application.ex` — `ContextCache`, `LivenessSupervisor` in supervision tree
- `lib/maraithon/telegram_assistant/context.ex` — `build/1`, `parallel_fetch/2`, `safe_parallel_fetch/2`
- `lib/maraithon/telegram_assistant/runner.ex` — `run_tool_calls_in_parallel/5`, `guard_tool_history/2`, `apply_delivery_mode/2`, `send_mode_for_delivery/1`
- `lib/maraithon/telegram_assistant.ex` — `prepare_final_delivery/1`, `dispatch_turn/6`
- `lib/maraithon/crm.ex` — `list_people/2`, `search_people/3`, `semantic_find_person/3`
- `lib/maraithon/telegram_conversations.ex` — `Conversation` schema (`summary`), `compact_old_turns/2`, `recent_turns/2`
- `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`

**To be created or extended:**
- `test/maraithon/telegram_assistant/runner_test.exs` (new) — or targeted additions to `test/maraithon/telegram_assistant_test.exs`

**To be reconciled (no status change):**
- `.claude/plans/2026-05-09-fast-context-aware-answers.md`

---

## Acceptance Checks

- `mix precommit` exits 0 (formatter clean, credo clean, full suite green).
- All seven targeted module/suite runs in Phase 1 pass.
- New runner coverage exists and passes for: parallel tool ordering, loop guard, and `:edit` vs `:reply` delivery routing — with no `Process.sleep` and using `MockProvider` + `start_supervised!`.
- No fix was re-implemented; any change is a scoped repair traceable to a specific failing assertion.
- The tracking plan file's per-fix annotations match the verified landing points; no stale `find_existing_person/2` reference remains; `status: done` unchanged.
- pg_trgm migration applies cleanly in the test environment (or its failure is explicitly diagnosed and resolved).

---

## Proof of Work Expectations

Cybrus review packet should include:

- **Verification log** — full `mix precommit` output plus each targeted `mix test` invocation and its summary line (tests/failures/excluded), timestamped.
- **Landing-point evidence table** — the eight fixes mapped to `file:line` (as in Phase 0), confirming each is present on the reviewed tree.
- **New-test diff** — the `runner_test.exs` additions, with a one-line rationale per case naming the fix behavior it protects.
- **Defect ledger** — for every failure encountered: the failing assertion, root-cause finding (production bug vs. obsolete test), and the resolution. Empty ledger is a valid, explicitly-stated outcome.
- **Plan-file reconciliation note** — what was corrected (or "annotations already accurate; status already done").
- **Git diff summary** — `git -C /Users/kent/bliss/maraithon diff --stat` for the working tree, so the reviewer sees the full surface of change before Approved.

---

## Risks

- **"Already done" risk (highest).** Both the code and the tracking plan are already complete; the most likely failure mode is the agent inventing rework. Mitigation: hard scope to verification; treat any edit beyond the new test + stale-reference cleanup as requiring an explicit failing-assertion justification.
- **pg_trgm extension privileges.** `CREATE EXTENSION` may fail in a CI/test DB without superuser. Mitigation: confirm the test DB role can create extensions; if not, this is an environment fix, not a code change — document it in the defect ledger.
- **Flaky async tests.** Parallel tool execution, liveness streaming, and async cache refresh are timing-sensitive. Mitigation: deterministic synchronization via `MockProvider` and `start_supervised!`; never `Process.sleep`. A flake is triaged, not retried-until-green.
- **Indirect runner coverage masking a regression.** Because runner behavior is tested through `telegram_assistant_test.exs`, a parallel-ordering or delivery-mode regression could pass at the integration level while the unit contract drifts. Mitigation: the new focused runner cases assert the contract directly.
- **Verification scope creep into the eight modules.** Reading for correctness can tempt opportunistic refactors. Mitigation: changes restricted to defects with a failing test behind them.