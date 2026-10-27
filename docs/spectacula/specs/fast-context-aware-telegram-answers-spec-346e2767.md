---
created_at: 2026-05-20T13:55:36Z
created_by: cybrus
cybrus_task_id: 346E2767-83CE-414B-B9DE-CDDF29EB374A
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 346E2767-83CE-414B-B9DE-CDDF29EB374A
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

Verification complete. I have what I need: all eight fixes and their tests exist on disk, the `precommit` alias has no credo step (the spec was wrong), and the on-disk plan file is already `status: done` but lacks the per-fix landing annotations. Here is the refined, implementation-ready plan.

---

# Fast & Context-Aware Telegram Answers — Verification & Closeout Plan

## Objective

Cut Telegram-perceived latency and improve answer quality across the eight gaps from the latency audit. **A codebase pass confirms all eight fixes are already implemented and each has test coverage.** This ticket therefore delivers *verification and closeout*, not new construction: prove each fix behaves as intended end-to-end, get `mix precommit` and the targeted module tests green, close the one real test gap (runner has no isolated test), and finish the plan-file paperwork (per-fix landing annotations).

The bar for "done" is: a reviewer can read each landing point, see a passing targeted test, and trust the latency/quality work is live on `main`.

---

## Assumptions and Decisions

- **Decision — this is closeout, confirmed by inspection.** Every fix below was verified present at a specific file/line during planning (markers cited in *Files and Interfaces*). Do not re-implement any of the eight. If verification surfaces a defect, treat it as a *scoped bug fix against the existing module*, never a rebuild.
- **Decision — `mix precommit` ≠ "formatter + credo".** The actual alias (`mix.exs:105`) is `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`. **There is no credo dependency** (`mix.exs` has zero `credo` references). The original spec's "credo" mention is wrong — ignore it. Note `format` *rewrites* files (it is not `format --check`); run it, then confirm `git status` shows no unstaged churn before claiming green.
- **Decision — the plan file is already `status: done`.** `/.claude/plans/2026-05-09-fast-context-aware-answers.md` already carries `status: done` in frontmatter, so the spec's "flip planning → done" step is moot. What is genuinely outstanding is the **per-fix landing annotation** (commit/file refs) — the file currently has no commit hashes or ✅ markers. That annotation is the only plan-file work left.
- **Decision — close the runner test gap only if a fix is uncovered.** There is no `test/maraithon/telegram_assistant/runner_test.exs`; runner behavior is exercised indirectly via `telegram_assistant_test.exs`. The two riskiest runner paths — **parallel tool execution ordering** (Fix 2) and **edit-vs-reply delivery-mode routing** (Fix 5) — warrant a focused, isolated test each. Add `runner_test.exs` with those two cases; do not broadly duplicate existing coverage.
- **Decision — function names from the original draft that don't exist are abandoned.** There is no `find_existing_person/2`; fuzzy resolve lives in `CRM.list_people/search_people` similarity fragments plus `semantic_find_person/3`. Plan against the real surface.
- **Assumption — Postgres is available in the execution environment.** The `test` alias runs `ecto.create --quiet` + `ecto.migrate --quiet` (`--no-start`), so the suite needs a live DB and the pg_trgm migration (`20260510005233`) must apply cleanly (Fix 6). Cybrus runs local Codex CLI with full workspace access, so a local Postgres is assumed reachable; if `ecto.create`/migrate fails, that is a blocker to report, not a test to skip.
- **Assumption — no behavior change is desired.** All edits in this ticket are tests, annotations, and (if a defect is found) a minimal targeted fix. The 16-key shape of `TelegramAssistant.Context.build/1` and the existing public APIs stay stable.

---

## Implementation Plan

Work in three ordered phases. Phase 1 is the bulk of the value (proof); Phases 2–3 are small.

### Phase 1 — Verify each fix end-to-end

For each fix, read the cited landing point and confirm the behavior, then run its targeted test. Record a one-line PASS/FAIL note per fix for the proof-of-work packet.

1. **Prompt caching (Fix 1)** — Confirm `build_system_blocks/1` attaches `cache_control: %{type: "ephemeral"}` only to system text past the size threshold, and that response parsing reads `cache_read_input_tokens` / `cache_creation_input_tokens` into the usage map. Run `anthropic_provider_test.exs`.
2. **Parallel tool execution (Fix 2)** — Confirm `run_tool_calls_in_parallel/5` uses `Task.async_stream` with `max_concurrency` ≥ tool-call count, results are reassembled in original order, and `guard_tool_history/2` blocks repeat/loop calls. This is a runner-test target (Phase 2).
3. **Fast routing model (Fix 3)** — Confirm `LLM.routing_model/0` resolves the configured Haiku model, `complete_routing/1` falls back to the main model when unset, and `TelegramInterpreter.default_llm_complete/1` routes through `complete_routing/1`. Run `llm_test.exs`.
4. **Today digest ETS cache (Fix 4)** — Confirm `ContextCache` is supervised, `Context.build/1` reads the digest non-blocking and kicks `maybe_refresh_async/1`, and `today_digest` is populated in the output. Run `context_cache_test.exs`.
5. **Streaming/edit-in-place (Fix 5)** — Confirm the Liveness path: `prepare_final_delivery/1` yields a delivery with `mode`, runner's `apply_delivery_mode/2` + `send_mode_for_delivery/1` select `:edit`, and `dispatch_turn/.../:edit` calls `TelegramResponder.edit/4` with a fallback to `:reply` on edit failure. This is a runner-test target (Phase 2); also sanity-check `liveness_session_streaming_test.exs`.
6. **Fuzzy person resolve (Fix 6)** — Confirm migration `20260510005233` enables `pg_trgm` and creates GIN trigram indexes, and that `list_people`/`search_people` use `similarity(...) > 0.3` with similarity-ordered results plus ILIKE and `semantic_find_person/3` fallback. Run `crm_test.exs` and the `crm/` suite.
7. **Parallel context prefetch (Fix 7)** — Confirm `parallel_fetch/2` fans the independent fetchers through `Task.async_stream` and the merged output keeps its 16-key shape. Covered by `context_cache_test.exs` + assistant tests.
8. **Rolling summarization (Fix 8)** — Confirm `compact_old_turns/2` folds older turns into `metadata["historical_summary"]` at the documented thresholds while `recent_turns/2` still returns raw recent turns, and that summarization uses `complete_routing/1`. Run `telegram_conversations_test.exs`.

### Phase 2 — Close the runner test gap

- Create `test/maraithon/telegram_assistant/runner_test.exs` using `Maraithon.LLM.MockProvider` and existing ExUnit conventions (no `Process.sleep`; `start_supervised!` for any process deps).
  - **Test A — parallel ordering + loop guard:** drive `execute_tool_calls` with ≥2 mock tool calls; assert results return in request order and a duplicated call is short-circuited by `guard_tool_history/2`.
  - **Test B — delivery-mode routing:** with a liveness placeholder present, assert the final turn routes via `send_mode: :edit`; without one, assert `:reply`; and assert an edit failure falls back to `:reply`.
- If Phase 1 finds a fix that is *incomplete or incorrect*, fix the underlying module minimally and add a regression test rather than weakening an assertion.

### Phase 3 — Run gate + finish plan paperwork

- Run `mix precommit`; resolve any compile warnings, format churn, unused deps, or test failures.
- Run the targeted module tests as a focused pass (faster signal than the full suite during iteration).
- Annotate `/.claude/plans/2026-05-09-fast-context-aware-answers.md`: under each of the eight fixes, add its landing file/line (and commit ref where known: `ed86f0a` for Fix 1, `1a43a67` for Fix 2). Leave `status: done` as-is.

---

## Files and Interfaces

**Verify (read-only confirmation, no edits expected):**

| Fix | File | Markers confirmed during planning |
|----|------|-----------------------------------|
| 1 | `lib/maraithon/llm/anthropic_provider.ex` | `split_system_messages/1` (:34,:168), `build_system_blocks/1` + `cache_control: %{type: "ephemeral"}` (:221–235), cache-token parsing (:121–135) |
| 2 | `lib/maraithon/telegram_assistant/runner.ex` | `run_tool_calls_in_parallel/5` + `Task.async_stream` (:236–274), `guard_tool_history` (:274), `apply_delivery_mode/2` + `send_mode_for_delivery/1` (:540–550, :733) |
| 3 | `config/runtime.exs` (:71,:77,:157,:165,:198–199), `lib/maraithon/llm.ex` (`routing_model/0` :42, `complete_routing/1` :129, `chat_model/0` :54, `complete_chat/1` :147), `lib/maraithon/telegram_interpreter.ex` (`default_llm_complete/1` → `LLM.complete_routing/1` :149,:157) |
| 4 | `lib/maraithon/context_cache.ex`, `lib/maraithon/application.ex` (:26 child), `lib/maraithon/telegram_assistant/context.ex` (`get_digest` :39, `maybe_refresh_async` :40, `today_digest` :72) |
| 5 | `lib/maraithon/telegram_assistant.ex` (`LivenessSupervisor` child :13, `start_session` :363, `prepare_final_delivery/1` :389, `dispatch_turn .../:edit` + `TelegramResponder.edit` + reply fallback :653–672), `runner.ex` (:435 `send_mode`) |
| 6 | `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`, `lib/maraithon/crm.ex` (`similarity(...) > 0.3` :844,:855,:987,:1014; `semantic_find_person/3` :104–119; ILIKE :804,:1038,:1053) |
| 7 | `lib/maraithon/telegram_assistant/context.ex` (`parallel_fetch/2` :43,:76; 16-key output) |
| 8 | `lib/maraithon/telegram_conversations.ex` (`compact_old_turns/2` :244–302, `historical_summary` :301–302, `recent_turns/2` :224, `default_summary_llm` → `complete_routing` :362) |

**Create:**
- `test/maraithon/telegram_assistant/runner_test.exs` — Tests A and B above (only new file expected).

**Edit:**
- `/.claude/plans/2026-05-09-fast-context-aware-answers.md` — append per-fix landing/commit annotations.
- *(Conditional)* any single fix module + its test, only if Phase 1 finds a real defect.

**Existing tests to run:** `anthropic_provider_test.exs`, `llm_test.exs`, `context_cache_test.exs`, `crm_test.exs` (+ `crm/`), `telegram_conversations_test.exs`, `telegram_assistant_test.exs`, `liveness_session_streaming_test.exs`.

**Gate:** `mix precommit` = `compile --warnings-as-errors` → `deps.unlock --unused` → `format` → `test` (the `test` alias runs `ecto.create`/`ecto.migrate --quiet --no-start`). No credo.

---

## Acceptance Checks

- [ ] All eight fixes verified end-to-end with a recorded PASS note each (Phase 1).
- [ ] `test/maraithon/telegram_assistant/runner_test.exs` exists and passes — parallel ordering + loop guard, and edit/reply/fallback delivery routing.
- [ ] `mix precommit` passes with zero compile warnings, no `format` churn (`git status` clean after format), and no unused-dep warnings.
- [ ] Targeted module tests all pass individually.
- [ ] pg_trgm migration applies cleanly against a fresh test DB (no migration error during `mix test` setup).
- [ ] `TelegramAssistant.Context.build/1` still returns its 16-key shape (no regression from verification).
- [ ] Plan file annotated with per-fix landing points; `status: done` retained.
- [ ] No new subsystems introduced; no production behavior changed except a minimal fix if a defect was found (with regression test).

---

## Proof of Work Expectations

Cybrus writes a local review packet. Include:

1. **Per-fix verification table** — the eight fixes with PASS/FAIL and the exact `file:line` confirming each behavior.
2. **Test output** — full `mix precommit` console output showing the suite green, plus the focused `mix test <file>` runs for the seven existing modules and the new `runner_test.exs`. Paste real output; if anything failed and was fixed, show before/after.
3. **`git status` / `git diff --stat`** — proving the only changes are the new runner test, the plan-file annotations, and (if applicable) one minimal fix + its regression test. A large diff is a red flag that something was rebuilt rather than verified.
4. **Migration evidence** — log line or test-setup output showing `20260510005233` ran without error.
5. **Honest gaps** — if Postgres was unavailable, or any fix could only be partially verified, state it plainly rather than asserting green.

---

## Risks

- **Stale spec assumptions.** The closeout spec being refined claimed `status: planning` and a "credo" gate; both are wrong (file is already `done`; no credo dep). Risk: an executor follows the spec verbatim and either reverts the status or chases a nonexistent credo step. *Mitigation:* this plan corrects both explicitly in Assumptions.
- **DB dependency.** `mix precommit` cannot pass without a reachable Postgres and a clean pg_trgm migration. *Mitigation:* treat a DB/migration failure as a reported blocker, not a skipped test (per `CLAUDE.md`: tests must not be gamed green).
- **Over-building the test gap.** Temptation to write a sprawling `runner_test.exs` duplicating `telegram_assistant_test.exs`. *Mitigation:* scope to exactly Tests A and B (the two uncovered runner-specific paths).
- **`format` rewriting unrelated files.** `mix format` (not `--check`) may touch files beyond this ticket. *Mitigation:* inspect `git status` after formatting; if unrelated files churn, note it and keep the diff scoped.
- **Hidden defect masquerading as closeout.** Verification might reveal a fix that compiles and has a passing test but misbehaves at runtime (e.g., cache_control on the wrong block, parallel results mis-ordered). *Mitigation:* Phase 1 reads behavior, not just presence; a found defect becomes a minimal scoped fix + regression test, explicitly allowed by Out-of-Scope's exception.
- **Low residual value.** Because the work is already shipped, the deliverable is confidence, not features. *Mitigation:* the proof packet is the product here — weight effort toward credible verification evidence over code volume.