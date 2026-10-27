---
created_at: 2026-05-30T22:42:28Z
created_by: cybrus
cybrus_task_id: D0BE630D-6621-49A8-A6C8-AAC46DE0F829
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: D0BE630D-6621-49A8-A6C8-AAC46DE0F829
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

I have enough verified ground truth. Key findings that sharpen the plan:

- All 11 claimed source files + 6 test files **exist** on disk, plus the `pg_trgm` migration `20260510005233_enable_pg_trgm_for_crm_persons.exs`.
- The tracking plan file is **already `status: done`** — so the spec's closeout step 4 is complete; real remaining scope is *verification only*.
- `mix precommit` is actually: `compile --warnings-as-errors` → `deps.unlock --unused` → `format` → `test` → `maraithon.assistant.eval --fail-on-issues` (no credo, plus an assistant eval gate the spec omitted).
- Runner coverage isn't missing — it lives in `test/maraithon/telegram_assistant/{model_routing_test,liveness_session_streaming_test,context_test,delivery_planner_test}.exs`.

Here is the refined, implementation-ready plan.

---

# Fast & Context-Aware Telegram Answers — Verification & Closeout Plan

## Objective

Confirm that the eight latency/quality fixes from the original audit are correctly implemented on `main`, prove they behave as intended end-to-end, and formally close out the ticket. This is a **verification-and-closeout** task, not new construction: a codebase pass (corroborated against disk during planning) shows all eight fixes already landed, and the tracking plan file is already marked `status: done`. The coding agent's job is to *substantiate* that claim with passing checks, fill any genuine test gaps surfaced during verification, and produce reviewer-grade proof of work. If — and only if — verification reveals a fix is incomplete or wrong, it is repaired as a scoped bug fix against the existing module (never rebuilt).

---

## Assumptions and Decisions

- **Scope is verification, not rebuild.** All eight fixes are present. No new subsystems. Decision: treat any discovered defect as a narrow bug fix on the existing module; do not re-architect.
- **The plan file is already `status: done`.** The original spec's step 4 ("flip planning → done") is moot. Decision: instead of changing status, annotate the plan file with a dated verification stamp (who/what confirmed each fix and the command output reference), so the "done" claim is auditable rather than asserted.
- **`mix precommit` is the authoritative gate** and includes an assistant-eval step the original spec under-described. Decision: the full `mix precommit` must pass, and the `maraithon.assistant.eval --fail-on-issues` step is treated as a first-class acceptance gate (it can flag assistant-quality regressions the unit tests miss).
- **Runner coverage already exists**, distributed across `test/maraithon/telegram_assistant/` (`model_routing_test`, `liveness_session_streaming_test`, `context_test`, `delivery_planner_test`, etc.). Decision: do **not** create a monolithic `runner_test.exs`; add focused cases to the existing, topically-correct files only where a specific fix is found uncovered.
- **No external service calls in tests.** Use the existing `Maraithon.LLM.MockProvider` and ExUnit conventions (`start_supervised!`, no `Process.sleep`). Decision: any new test follows these patterns; trigram/CRM tests use the test Postgres with the migration applied.
- **This is a local Codex CLI run** with full workspace access at `/Users/kent/bliss/maraithon` (umbrella project). The agent runs `mix` tasks locally; no deploy, no Fly interaction.
- **Function-name drift from the original draft is accepted as resolved.** There is no `find_existing_person/2` (use `search_people/3` / `semantic_find_person/3`) and no dedicated `runner_test.exs`. Decision: trust the on-disk reality over the draft's names.

---

## Implementation Plan

Execute in order. Each fix is verified by *reading the landing point* and *running its targeted test*, then the whole thing is gated by `mix precommit`.

### Phase 0 — Environment & baseline
1. From the umbrella root `/Users/kent/bliss/maraithon`, fetch deps and prepare the test DB: `mix deps.get`, `mix ecto.create`, `mix ecto.migrate` (this applies `20260510005233_enable_pg_trgm_for_crm_persons` so trigram tests have the extension/indexes).
2. Capture a baseline by running `mix precommit` once and recording the result. If green, the bulk of closeout is already satisfied and the rest is targeted confirmation + proof capture. If red, triage failures fix-by-fix (Phase 2).

### Phase 1 — Confirm each fix at its landing point (read + targeted test)
For each, open the cited file, confirm the described behavior is actually wired (not just defined), and run the named test.

1. **Fix 1 — Anthropic prompt caching.** In `lib/maraithon/llm/anthropic_provider.ex` confirm `build_body/1` / `split_system_messages/1` / `build_system_blocks/1` emit `cache_control: %{type: "ephemeral"}` on system blocks ≥ ~1024 chars, and that response parsing reads `cache_read_input_tokens` / `cache_creation_input_tokens`. Run `mix test test/maraithon/llm/anthropic_provider_test.exs`.
2. **Fix 2 — Parallel tool execution.** In `lib/maraithon/telegram_assistant/runner.ex` confirm `execute_tool_calls/5 → run_tool_calls_in_parallel/5` uses `Task.async_stream` with `max_concurrency: max(length(tool_calls), 1)`, that results are re-ordered to match call order, and the loop guard (`guard_tool_history/2`) prevents repeats. Run `mix test test/maraithon/telegram_assistant/toolbox_test.exs` and any runner-touching file in that dir.
3. **Fix 3 — Fast routing model.** Confirm `config/runtime.exs` defines `ANTHROPIC_ROUTING_MODEL` (default `claude-haiku-4-5-20251001`) and `OPENAI_ROUTING_MODEL`; `lib/maraithon/llm.ex` exposes `routing_model/0` + `complete_routing/1` with main-model fallback; `lib/maraithon/telegram_interpreter.ex` `default_llm_complete/1` calls `LLM.complete_routing/1`. Run `mix test test/maraithon/telegram_assistant/model_routing_test.exs test/maraithon/llm_test.exs`.
4. **Fix 4 — Today digest ETS cache.** Confirm `lib/maraithon/context_cache.ex` is in the `application.ex` supervision tree and that `context.ex build/1` reads `ContextCache.get_digest/1` non-blocking and schedules `ContextCache.Builder.maybe_refresh_async/1`; `today_digest` present among the 16 context keys. Run `mix test test/maraithon/context_cache_test.exs test/maraithon/telegram_assistant/context_test.exs`.
5. **Fix 5 — Streaming progress / edit-in-place (Liveness).** Confirm `TelegramAssistant.LivenessSupervisor` is supervised; `prepare_final_delivery/1` returns a `delivery` with `mode` + `message_id`; `runner.ex` `apply_delivery_mode/2` routes `send_mode: :edit` when a placeholder exists; `telegram_assistant.ex` `dispatch_turn/6` handles `:edit` via `TelegramResponder.edit/4` with `:reply` fallback on edit failure. Run `mix test test/maraithon/telegram_assistant/liveness_session_streaming_test.exs`.
6. **Fix 6 — Fuzzy person resolve (pg_trgm).** Confirm the migration enables `pg_trgm` + GIN trigram indexes on `crm_people.display_name` and the computed full-name expression; `lib/maraithon/crm.ex` `list_people/2` / `search_people/3` use `similarity(...) > 0.3` fragments with similarity ordering alongside ILIKE, with `semantic_find_person/3` embedding fallback. Run `mix test test/maraithon/crm_test.exs`.
7. **Fix 7 — Parallel context prefetch.** Confirm `context.ex build/1` runs the ~15 independent fetchers through `parallel_fetch/2` (`Task.async_stream`) and the output map shape is unchanged (16 keys). Covered by `context_test.exs` (run above); spot-check the key set explicitly.
8. **Fix 8 — Rolling conversation summarization.** Confirm `lib/maraithon/telegram_conversations.ex` `Conversation` schema has `summary`; `compact_old_turns/2` folds old turns into `metadata["historical_summary"]` (keeps 12 recent; triggers at >24 turns or ~30k tokens) while `recent_turns/2` still returns raw last-N. Run `mix test test/maraithon/telegram_conversations_test.exs`.

### Phase 2 — Triage any failures (scoped bug-fix only)
- For any red test or unwired behavior: apply the smallest correct change to the existing module per `AGENTS.md`. A failing test means real code is wrong or the test is obsolete — fix the code or retire the test with explicit rationale (per repo `CLAUDE.md` testing principle). Re-run that fix's targeted test, then re-run `mix precommit`.

### Phase 3 — Fill genuine test gaps (only if Phase 1 found uncovered behavior)
- Add focused cases to the **existing** topical file (e.g. a missing edit-fallback assertion → `liveness_session_streaming_test.exs`; a missing parallel-ordering assertion → the runner/toolbox test). Use `MockProvider`, `start_supervised!`, no `Process.sleep`. Do not create `runner_test.exs`.

### Phase 4 — Closeout
- Run the full `mix precommit` to green (including `maraithon.assistant.eval --fail-on-issues`).
- Annotate `.claude/plans/2026-05-09-fast-context-aware-answers.md`: under each fix add a one-line `Verified 2026-05-30: <command> green` note and the landing commit/file. Keep `status: done` (already set); the annotation converts the assertion into an audited record.

---

## Files and Interfaces

**Source (read to confirm; modify only on a found defect):**
- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1`, `split_system_messages/1`, `build_system_blocks/1`; usage parsing of cache tokens.
- `lib/maraithon/llm.ex` — `routing_model/0`, `complete_routing/1`, `chat_model/0`, `complete_chat/1`.
- `lib/maraithon/telegram_interpreter.ex` — `default_llm_complete/1`.
- `lib/maraithon/telegram_assistant/runner.ex` — `execute_tool_calls/5`, `run_tool_calls_in_parallel/5`, `guard_tool_history/2`, `apply_delivery_mode/2`, `send_mode_for_delivery/1`.
- `lib/maraithon/telegram_assistant/context.ex` — `build/1`, `parallel_fetch/2`; `ContextCache.get_digest/1` + `Builder.maybe_refresh_async/1` calls; 16-key output.
- `lib/maraithon/context_cache.ex` + `lib/maraithon/context_cache/builder.ex` — ETS digest cache.
- `lib/maraithon/telegram_assistant/liveness_supervisor.ex`, `telegram_assistant.ex` (`prepare_final_delivery/1`, `dispatch_turn/6`).
- `lib/maraithon/crm.ex` — `list_people/2`, `search_people/3`, `semantic_find_person/3`.
- `lib/maraithon/telegram_conversations.ex` — `Conversation` schema (`summary`), `compact_old_turns/2`, `recent_turns/2`.
- `lib/maraithon/application.ex` — supervision tree (`ContextCache`, `LivenessSupervisor`).
- `config/runtime.exs` — `ANTHROPIC_ROUTING_MODEL`, `OPENAI_ROUTING_MODEL`.
- `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`.

**Tests (run; extend only on a found gap):**
- `test/maraithon/llm/anthropic_provider_test.exs`, `test/maraithon/llm_test.exs`
- `test/maraithon/context_cache_test.exs`, `test/maraithon/crm_test.exs`, `test/maraithon/telegram_conversations_test.exs`, `test/maraithon/telegram_assistant_test.exs`
- `test/maraithon/telegram_assistant/{model_routing_test,liveness_session_streaming_test,context_test,delivery_planner_test,toolbox_test}.exs`

**Build interface:** `mix precommit` = `compile --warnings-as-errors` · `deps.unlock --unused` · `format` · `test` · `maraithon.assistant.eval --fail-on-issues`.

**Artifact to update:** `.claude/plans/2026-05-09-fast-context-aware-answers.md` (annotate; status stays `done`).

---

## Acceptance Checks

- `mix precommit` passes from a clean tree, including `compile --warnings-as-errors` and `maraithon.assistant.eval --fail-on-issues`.
- Each fix's targeted test command passes (listed per-fix in Phase 1).
- Each of the eight landing points is confirmed *wired*, not merely defined: `ContextCache` and `LivenessSupervisor` appear in the supervision tree; `default_llm_complete/1` routes through `complete_routing/1`; `build/1` reads the digest cache and runs `parallel_fetch/2`; `crm.ex` queries use trigram `similarity > 0.3`; `compact_old_turns/2` triggers at the stated thresholds.
- Context output map remains exactly 16 keys (no shape regression from Fix 4/7).
- pg_trgm migration applies cleanly on a fresh test DB and trigram queries return similarity-ordered results.
- The plan file carries a dated verification annotation per fix; no fix was rebuilt.
- Any change made is a scoped fix to an existing module with no new subsystem introduced.

---

## Proof of Work Expectations

Cybrus will assemble a local review packet; provide the raw evidence for it:

- **Full `mix precommit` transcript** (final green run), with the assistant-eval step visible.
- **Per-fix targeted test output** — the eight (or fewer, where shared) `mix test <path>` runs, each showing pass counts.
- **Confirmation notes per fix** — for each, the file:line of the key construct (e.g. `cache_control` emission, `Task.async_stream` concurrency, `complete_routing/1` call site, supervision-tree child, `similarity(...) > 0.3` fragment, `compact_old_turns/2` thresholds) so a reviewer can jump straight to it.
- **Diff (if any)** — minimal, scoped, with rationale tying each hunk to a specific failing check; or an explicit "no production changes required; verification only" statement if Phase 1 was clean.
- **Migration proof** — output showing `20260510005233_enable_pg_trgm_for_crm_persons` applied and a trigram query returning ranked results.
- **Updated plan file** showing the dated verification annotations.
- A short summary: which fixes were confirmed untouched vs. which required a scoped repair, and any test cases added (with the file they joined).

---

## Risks

- **False-green from stale state.** A previously-green `precommit` cached locally could mask a real regression. Mitigation: run from a clean tree with a freshly migrated test DB; don't trust prior runs.
- **Assistant-eval flakiness / cost.** `maraithon.assistant.eval --fail-on-issues` may hit a provider or be non-deterministic. Mitigation: ensure it runs against `MockProvider`/eval fixtures, not live APIs; if it's genuinely flaky, capture the failure and treat it as a scoped finding rather than silencing the gate.
- **pg_trgm absent in test DB.** Trigram tests fail if the extension/migration isn't applied. Mitigation: explicit `mix ecto.migrate` in Phase 0; verify `CREATE EXTENSION pg_trgm` succeeded (needs DB privileges).
- **Verification reveals a fix is wired but subtly wrong** (e.g. parallel results not re-ordered, edit-fallback not triggered, digest read path never populated). Mitigation: Phase 2 scoped fix + a regression test in the correct existing file; do not expand scope into a rebuild.
- **Context-shape drift.** Adding/altering a fetcher could silently change the 16-key contract downstream consumers rely on. Mitigation: assert the exact key set in `context_test.exs`.
- **Over-testing temptation.** Creating a broad new `runner_test.exs` would duplicate existing coverage and add maintenance load. Mitigation: extend the topical files only where a specific gap is proven.
- **"Done" without evidence.** The plan file already says `status: done`; closing without running the gates would make the claim unverifiable. Mitigation: the dated per-fix annotation + saved transcripts are required deliverables, not optional.