---
created_at: 2026-05-14T18:45:16Z
created_by: cybrus
cybrus_task_id: 7526B4EC-37D7-4E03-838E-1E43DA303702
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 7526B4EC-37D7-4E03-838E-1E43DA303702
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

Verified against the repo: the plan file at `.claude/plans/2026-05-09-fast-context-aware-answers.md` is still `status: planning`, the pg_trgm migration and `context_cache.ex` exist as the audit claims, and there is **no** `test/maraithon/telegram_assistant/runner_test.exs` (confirming the named test gap). Here is the refined, execution-ready plan.

---

# Fast & Context-Aware Telegram Answers — Implementation Plan

## Objective

Close out the **Fast & Context-Aware Telegram Answers** ticket. A codebase audit established that all eight latency/quality fixes from the original draft plan are **already implemented and committed** on `main` (two explicitly: `ed86f0a`, `1a43a67`; the other six present). The remaining work is therefore **verification, test-gap closure, and closeout** — not new construction.

Concretely, this task must:
1. Verify each of the eight fixes behaves as intended end-to-end at its landing point.
2. Run `mix precommit` plus targeted module tests; fix any failures.
3. Add focused test coverage only where verification finds a fix uncovered.
4. Flip the tracking plan file `status: planning` → `status: done` and annotate each fix with its landing point/commit.

This is a closeout task. Do **not** re-implement any fix. If verification shows a fix is incomplete or incorrect, treat it as a **scoped bug fix** against the existing module, not a rebuild.

---

## Assumptions and Decisions

- **Assumption — audit is accurate.** The eight-fix audit in the spec is treated as the source of truth for *where* code lives. The executing agent must still confirm *behavior*, but is not expected to re-discover landing points from scratch. Spot-confirmed: `context_cache.ex`, the `20260510005233_enable_pg_trgm_for_crm_persons.exs` migration, and the absence of a dedicated `runner_test.exs` all match the audit.
- **Decision — verification is read-first.** Each fix is verified by reading its landing point and running the relevant test, before any edit. Edits are made only to fix a confirmed defect or a confirmed missing test.
- **Decision — minimal test additions.** New tests are added only for a fix that has *no* coverage of its behavior. Runner coverage currently lives inside `telegram_assistant_test.exs`; a new `runner_test.exs` is created only if a Fix 2 / Fix 5 behavior is genuinely untested there. Prefer extending existing test files over creating new ones.
- **Decision — test conventions.** Follow existing repo conventions: `Maraithon.LLM.MockProvider` for LLM stubbing, `start_supervised!` for processes, no `Process.sleep`. Match the style already in `anthropic_provider_test.exs` / `context_cache_test.exs`.
- **Assumption — environment.** `mix precommit` (formatter + credo + full test suite) is runnable locally; Postgres is available with the `pg_trgm` extension installable (the migration enables it). Anthropic/OpenAI keys are not required because tests use `MockProvider`.
- **Decision — no scope creep.** No new subsystems. The "future direction" items in the project goals (iMessage/WhatsApp, OmniFocus sync, calendar mirroring) are explicitly out of scope.
- **Decision — closeout commit.** A single closeout commit flips the plan file to `done` and includes any bug-fix/test-gap changes found during verification. Branch from `main` if currently on `main`; do not push or open a PR unless asked.

---

## Implementation Plan

### Phase 0 — Setup
- Confirm working branch. If on `main`, create `closeout/fast-context-aware-answers`.
- Run `mix deps.get` and `mix ecto.migrate` (ensures the `pg_trgm` migration is applied locally) so the test DB matches `main`.

### Phase 1 — Per-fix verification (read landing point, then run its test)

For each fix: read the cited module, confirm the behavior described, run the targeted test, record a one-line PASS/FAIL with evidence.

1. **Fix 1 — Anthropic prompt caching.** In `lib/maraithon/llm/anthropic_provider.ex`, confirm `build_body/1` + `split_system_messages/1` + `build_system_blocks/1` emit `cache_control: %{type: "ephemeral"}` on system text ≥ ~1024 chars, and that response parsing reads `cache_read_input_tokens` / `cache_creation_input_tokens`. Run `anthropic_provider_test.exs`.
2. **Fix 2 — Parallel tool execution.** In `lib/maraithon/telegram_assistant/runner.ex`, confirm `execute_tool_calls/5` → `run_tool_calls_in_parallel/5` uses `Task.async_stream` with `max_concurrency: max(length(tool_calls), 1)`, that result ordering is preserved, and that `guard_tool_history/2` loop-guards repeats. Confirm state threads `sequence`, `tool_steps`, `tool_history`, `iteration`, `llm_turns`. Covered by `telegram_assistant_test.exs`.
3. **Fix 3 — Fast routing model (Haiku).** In `config/runtime.exs` confirm `ANTHROPIC_ROUTING_MODEL` (default `claude-haiku-4-5-20251001`) and `OPENAI_ROUTING_MODEL` (default `gpt-4o-mini`). In `lib/maraithon/llm.ex` confirm `routing_model/0` and `complete_routing/1` (with fallback to main model). In `lib/maraithon/telegram_interpreter.ex` confirm `default_llm_complete/1` calls `LLM.complete_routing/1`. Run `llm_test.exs` and `telegram_interpreter` tests if present.
4. **Fix 4 — Today digest ETS cache.** Confirm `Maraithon.ContextCache` is in the `application.ex` supervision tree; in `lib/maraithon/telegram_assistant/context.ex` confirm `build/1` calls `ContextCache.get_digest/1` (non-blocking) and `ContextCache.Builder.maybe_refresh_async/1`, and that `today_digest` is one of the 16 output keys. Run `context_cache_test.exs`.
5. **Fix 5 — Streaming progress / edit-in-place.** Confirm `TelegramAssistant.LivenessSupervisor` is in the supervision tree; `prepare_final_delivery/1` returns a `delivery` with `mode` (`:edit` | `:reply`/`:send`) and `message_id`; `runner.ex` `apply_delivery_mode/2` + `send_mode_for_delivery/1` route the final turn through `send_mode: :edit` when liveness produced a placeholder; `telegram_assistant.ex` `dispatch_turn/6` handles `:edit` via `TelegramResponder.edit/4` and falls back to `:reply` on edit failure. Covered by `telegram_assistant_test.exs`.
6. **Fix 6 — Fuzzy person resolve (pg_trgm).** Confirm migration `20260510005233_enable_pg_trgm_for_crm_persons.exs` enables `pg_trgm` and creates GIN trigram indexes on `crm_people.display_name` and the computed full-name expression. In `lib/maraithon/crm.ex` confirm `list_people/2` / `search_people/3` use `similarity(..., ?) > 0.3` fragments with similarity-ordered results alongside ILIKE, and that `semantic_find_person/3` provides the embedding fallback. Run `crm_test.exs`.
7. **Fix 7 — Parallel context prefetch.** In `lib/maraithon/telegram_assistant/context.ex` confirm `build/1` runs the independent fetchers through `parallel_fetch/2` (`Task.async_stream`) and that the output shape is unchanged (16 keys). Covered by `context_cache_test.exs` / `telegram_assistant_test.exs`.
8. **Fix 8 — Rolling conversation summarization.** In `lib/maraithon/telegram_conversations.ex` confirm the `Conversation` schema has a `summary` field; `compact_old_turns/2` folds old turns into `metadata["historical_summary"]` (keeps 12 recent; triggers at >24 turns or ~30k tokens); `recent_turns/2` still returns the last N raw turns. Run `telegram_conversations_test.exs`.

### Phase 2 — Full verification run
- Run `mix precommit` (formatter + credo + full suite).
- Run the targeted subset explicitly: `mix test test/maraithon/llm/anthropic_provider_test.exs test/maraithon/llm_test.exs test/maraithon/telegram_assistant_test.exs test/maraithon/context_cache_test.exs test/maraithon/crm_test.exs test/maraithon/telegram_conversations_test.exs`.
- Triage any failure: if it's a real defect in a fix, apply a **scoped** fix to the existing module; if it's a flaky/env issue, document it.

### Phase 3 — Test-gap closure (only if Phase 1 found uncovered behavior)
- For any fix whose behavior is not exercised by an existing test, add focused cases. Most likely candidate: a `test/maraithon/telegram_assistant/runner_test.exs` covering parallel tool ordering (Fix 2) and `:edit` vs `:reply` delivery routing (Fix 5) — **only if** those paths are not already exercised in `telegram_assistant_test.exs`.
- Keep additions minimal and convention-aligned; re-run `mix precommit`.

### Phase 4 — Closeout
- Edit `.claude/plans/2026-05-09-fast-context-aware-answers.md`: change frontmatter `status: planning` → `status: done`, and annotate each of the eight fixes with its landing point and commit hash where known (`ed86f0a` for Fix 1, `1a43a67` for Fix 2).
- Commit on the closeout branch with a message summarizing: verified 8 fixes, ran precommit, listing any bug fixes or tests added. End the commit message with the required `Co-Authored-By` trailer.
- Produce the proof-of-work artifacts for the Cybrus review packet.

---

## Files and Interfaces

**Verified (read-only unless a defect is found):**
- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1`, `split_system_messages/1`, `build_system_blocks/1`
- `lib/maraithon/telegram_assistant/runner.ex` — `execute_tool_calls/5`, `run_tool_calls_in_parallel/5`, `apply_delivery_mode/2`, `send_mode_for_delivery/1`
- `lib/maraithon/llm.ex` — `routing_model/0`, `complete_routing/1`, `chat_model/0`, `complete_chat/1`
- `lib/maraithon/telegram_interpreter.ex` — `default_llm_complete/1`
- `lib/maraithon/context_cache.ex` (+ `ContextCache.Builder`) — `get_digest/1`, `maybe_refresh_async/1`
- `lib/maraithon/telegram_assistant/context.ex` — `build/1`, `parallel_fetch/2`
- `lib/maraithon/telegram_assistant.ex` — `prepare_final_delivery/1`, `dispatch_turn/6`
- `lib/maraithon/crm.ex` — `list_people/2`, `search_people/3`, `semantic_find_person/3`
- `lib/maraithon/telegram_conversations.ex` — `Conversation` schema, `compact_old_turns/2`, `recent_turns/2`
- `config/runtime.exs` — `ANTHROPIC_ROUTING_MODEL`, `OPENAI_ROUTING_MODEL`
- `lib/maraithon/application.ex` — supervision tree (`ContextCache`, `LivenessSupervisor`)
- `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`

**Tests run / possibly extended:**
- `test/maraithon/llm/anthropic_provider_test.exs`
- `test/maraithon/llm_test.exs`
- `test/maraithon/telegram_assistant_test.exs`
- `test/maraithon/context_cache_test.exs`
- `test/maraithon/crm_test.exs`
- `test/maraithon/telegram_conversations_test.exs`
- `test/maraithon/telegram_assistant/runner_test.exs` — **create only if** Fix 2/Fix 5 behavior is uncovered

**Edited for closeout:**
- `.claude/plans/2026-05-09-fast-context-aware-answers.md` — frontmatter status + per-fix annotations

---

## Acceptance Checks

- [ ] All eight fixes verified at their landing points with a recorded PASS and concrete evidence (e.g., the emitted request body shows `cache_control`; trigram query returns similarity-ordered results).
- [ ] `mix precommit` passes (formatter clean, credo clean, full test suite green).
- [ ] The six targeted module test files pass when run explicitly.
- [ ] Any defect found is fixed as a scoped change to the existing module — no fix re-implemented or rebuilt.
- [ ] Any genuinely uncovered fix behavior has a focused new test; coverage gaps from Phase 1 are closed or explicitly justified as already-covered.
- [ ] `.claude/plans/2026-05-09-fast-context-aware-answers.md` frontmatter reads `status: done` and each fix is annotated with its landing point/commit.
- [ ] Closeout commit exists on a non-`main` branch with an accurate message; no push/PR unless requested.

---

## Proof of Work Expectations

For the Cybrus local review packet, produce:
- **Verification log** — a per-fix table (Fix #, landing point, PASS/FAIL, evidence: test name + key assertion or observed behavior).
- **`mix precommit` output** — full output showing formatter, credo, and test suite results (test count, 0 failures).
- **Targeted test output** — the explicit six-file `mix test` run output.
- **Diff summary** — `git diff --stat` plus the full diff of any bug fixes, new tests, and the plan-file status change. If no code changes were needed beyond the plan file, state that explicitly.
- **Closeout commit** — hash and message.
- **Residual notes** — anything deferred, any flaky test observed, or any audit claim that did not match reality (with the correction made).

---

## Risks

- **Audit drift.** The audit may name a function or path that has since changed (the spec itself notes the draft plan referenced a non-existent `find_existing_person/2`). Mitigation: verification is read-first; treat any mismatch as a finding to document and correct, not a blocker.
- **Hidden defect in a "done" fix.** A fix may be present but subtly wrong (e.g., cache_control on the wrong block, tool results returned out of order, trigram threshold mis-tuned). Mitigation: behavior-level verification, not just existence checks; scoped bug fix if found.
- **Test environment / `pg_trgm`.** Fix 6 verification depends on the extension being installed in the test DB. Mitigation: run `mix ecto.migrate` in Phase 0; if the extension can't be enabled locally, document and verify via migration inspection + query plan instead.
- **Flaky concurrency tests.** Fix 2 / Fix 7 involve `Task.async_stream`; tests may be timing-sensitive. Mitigation: rely on existing convention (no `Process.sleep`, `start_supervised!`); if flake is observed, document rather than mask.
- **Scope creep temptation.** "Verification" can drift into refactoring. Mitigation: hard rule — edits only for a confirmed defect or a confirmed missing test; everything else stays untouched.
- **Stale plan file vs. spec.** The on-disk plan file is the older "Implementation Plan" form, while the ticket carries the newer "Spec" form. Mitigation: closeout edits the on-disk file's frontmatter and annotations; if fuller content reconciliation is wanted, flag it as a follow-up rather than rewriting silently.