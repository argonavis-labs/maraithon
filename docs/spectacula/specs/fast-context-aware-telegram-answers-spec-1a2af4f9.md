---
created_at: 2026-05-14T18:35:48Z
created_by: cybrus
cybrus_task_id: 1A2AF4F9-E618-4797-B97A-D1E1C3FECAC4
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 1A2AF4F9-E618-4797-B97A-D1E1C3FECAC4
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

All eight fixes verified against the live codebase. Two corrections to the prior spec surfaced: `find_existing_person/2` **does** exist (crm.ex:598 — the old note was wrong), and `mix precommit` is `["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]` — **no credo**, and `format` rewrites files rather than checking. Refined plan below.

---

# Fast & Context-Aware Telegram Answers — Implementation Plan

## Objective

Close out the "Fast & Context-Aware Telegram Answers" initiative. A full codebase pass confirms **all eight latency/quality fixes from the original audit are already implemented and landed on `main`** (two via explicit commits `ed86f0a` and `1a43a67`, the rest present). The remaining work is **verification and closeout**, not construction: confirm each fix behaves as intended end-to-end, run the test suite, fill any test gaps verification exposes, and flip the tracking plan file from `status: planning` to `status: done` with landing-point annotations.

This is a scoped closeout. No new subsystems. If verification reveals a fix is incomplete or incorrect, treat it as a targeted bug fix against the existing module — not a rebuild.

---

## Assumptions and Decisions

- **All eight fixes are live.** Verified file paths, functions, and line numbers below. The job is to *prove* they work, not re-derive them.
- **`mix precommit` is the gate**, defined in `mix.exs:97` as `["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]`. Decision: run `mix precommit` as the authoritative check. Note it runs `format` (which **rewrites** files) — run `mix format --check-formatted` *first* as a read-only check so any reformatting shows up as a reviewable diff rather than a silent mutation. **Credo is not part of precommit**; the original spec's mention of credo is dropped — do not add a credo run unless the repo adds it.
- **`compile --warnings-as-errors` is in scope.** Any warning is a hard failure and must be fixed as part of closeout.
- **Correction to prior spec:** `find_existing_person/2` **does exist** (`lib/maraithon/crm.ex:598`). The original spec's note that it doesn't exist was wrong and is removed. Fix 6's fuzzy stack is: `find_existing_person/2`, `fuzzy_find_person/2` (`similarity(...) > 0.3`, crm.ex:641–669), `semantic_find_person/3` embedding fallback (crm.ex:102–115), plus ILIKE paths.
- **Fix 6 is "PARTIAL" only in integration breadth**, not correctness — migration and core functions are present. Decision: verify the trigram indexes are actually created (migration applied) and that `list_people/2` / `search_people/3` call paths reach the similarity fragments. If a call path still uses plain ILIKE where fuzzy was intended, that is the one candidate scoped bug fix; otherwise mark verified.
- **Test gaps:** there is no dedicated `test/maraithon/telegram_assistant/runner_test.exs`; runner coverage lives in `telegram_assistant_test.exs`. Decision: only add focused tests where verification finds an *uncovered* fix behavior — do not build out a full runner test file speculatively.
- **No DB/prod changes.** Migration `20260510005233` already exists; closeout only confirms it's applied in the dev/test DB, it does not author new migrations.

---

## Implementation Plan

### Step 1 — Environment baseline
- `git log --oneline` to confirm `ed86f0a` (caching) and `1a43a67` (parallel tools) are present.
- `mix deps.get`, ensure the dev/test DB is migrated: `mix ecto.migrate` — confirm `20260510005233_enable_pg_trgm_for_crm_persons` is applied (check `schema_migrations`).
- `mix format --check-formatted` — record whether the tree is already clean.

### Step 2 — Verify each fix against its landing point
For each, read the cited code and confirm the behavior, then run the targeted test:

1. **Prompt caching** — `anthropic_provider.ex`: confirm `build_system_blocks/1` (l.202–223) attaches `cache_control: %{type: "ephemeral"}` only when system text ≥ ~1024 chars; `parse_response/1` (l.92–129) reads `cache_read_input_tokens` (l.102) / `cache_creation_input_tokens` (l.103). Run `mix test test/maraithon/llm/anthropic_provider_test.exs`.
2. **Parallel tool execution** — `runner.ex`: confirm `run_tool_calls_in_parallel/5` (l.212–256) uses `Task.async_stream` with `max_concurrency`, results re-ordered to call order, and `guard_tool_history/2` (`assistant_harness.ex:160`) blocks loops. Confirm state threads `sequence`/`tool_steps`/`tool_history`/`iteration`/`llm_turns`.
3. **Fast routing model** — `config/runtime.exs` l.68–78: `ANTHROPIC_ROUTING_MODEL` default `claude-haiku-4-5-20251001`, `OPENAI_ROUTING_MODEL` default `gpt-4o-mini`. `llm.ex`: `routing_model/0`, `complete_routing/1` (with fallback to main model). `telegram_interpreter.ex:157`: `default_llm_complete/1` calls `LLM.complete_routing/1`. Run `mix test test/maraithon/llm_test.exs` (and interpreter test if present).
4. **Today digest ETS cache** — `context_cache.ex` (`put_digest/3`, `get_digest/1`); `application.ex:19` has `Maraithon.ContextCache`; `context.ex` `build/1` calls `ContextCache.get_digest/1` (non-blocking) + `ContextCache.Builder.maybe_refresh_async/1`; `today_digest` present in output keys. Run `mix test test/maraithon/context_cache_test.exs`.
5. **Streaming / edit-in-place** — `application.ex:20` has `LivenessSupervisor`; `telegram_assistant.ex` `prepare_final_delivery/1` (l.377–383) returns `delivery` with `mode`; `runner.ex` `apply_delivery_mode/2` (l.494–501) + `send_mode_for_delivery/1` (l.503–504); `dispatch_turn` (l.638–663) routes `:edit` via `TelegramResponder.edit/4` with `:reply` fallback. Verify the edit-failure fallback path is covered.
6. **Fuzzy person resolve** — confirm migration applied; read `crm.ex` `list_people/2` (l.15–36), `search_people/3` (l.46–51), `fuzzy_find_person/2` (l.641–669), `find_existing_person/2` (l.598), `semantic_find_person/3` (l.102–115). Confirm similarity-ordered results. Run `mix test test/maraithon/crm_test.exs`. If a call path that should be fuzzy still uses plain ILIKE only, fix that one path.
7. **Parallel context prefetch** — `context.ex` `build/1` → `parallel_fetch/2` (l.76–110, `Task.async_stream`); confirm the 16-key output shape is unchanged and a failing fetcher degrades gracefully (doesn't crash `build/1`).
8. **Rolling summarization** — `telegram_conversations.ex`: `Conversation` schema `summary` field; `compact_old_turns/2` (l.226–250) keeps 12 recent, triggers at >24 turns or ~30k tokens, folds into `metadata["historical_summary"]` (l.283); `recent_turns/2` returns last N raw. Run `mix test test/maraithon/telegram_conversations_test.exs`.

### Step 3 — Full gate
- Run `mix precommit`. Fix any compile warnings (warnings-as-errors), formatting, unused deps, or test failures. Re-run until green.

### Step 4 — Fill test gaps (only if Step 2 found uncovered behavior)
- Add focused cases to the existing test files (e.g. `telegram_assistant_test.exs` for runner behavior, `crm_test.exs` for fuzzy ranking). Each new test names the fix it covers. Do not create new test files unless a fix has zero existing coverage and can't reasonably live in an existing file.

### Step 5 — Closeout commit
- Update `.claude/plans/2026-05-09-fast-context-aware-answers.md`: frontmatter `status: planning` → `status: done`; annotate each fix with its commit / landing point (file:line).
- Commit on a branch (repo workflow: branch before committing), message summarizing verification outcome and any scoped bug fix made. Include the `Co-Authored-By` trailer.

---

## Files and Interfaces

**Verified — read to confirm, edit only if a scoped bug surfaces:**
- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1`, `split_system_messages/1`, `build_system_blocks/1`, `parse_response/1`
- `lib/maraithon/telegram_assistant/runner.ex` — `execute_tool_calls/5`, `run_tool_calls_in_parallel/5`, `apply_delivery_mode/2`, `send_mode_for_delivery/1`, `dispatch_turn/6`
- `lib/maraithon/assistant_harness.ex` — `guard_tool_history/2`
- `lib/maraithon/llm.ex` — `routing_model/0`, `complete_routing/1`, `chat_model/0`, `complete_chat/1`
- `config/runtime.exs` — `ANTHROPIC_ROUTING_MODEL`, `OPENAI_ROUTING_MODEL` (l.68–78)
- `lib/maraithon/telegram_interpreter.ex` — `default_llm_complete/1`
- `lib/maraithon/context_cache.ex` + `lib/maraithon/context_cache/builder.ex` — `get_digest/1`, `put_digest/3`, `maybe_refresh_async/1`
- `lib/maraithon/application.ex` — supervision tree (`ContextCache` l.19, `LivenessSupervisor` l.20)
- `lib/maraithon/telegram_assistant/context.ex` — `build/1`, `parallel_fetch/2`
- `lib/maraithon/telegram_assistant.ex` — `prepare_final_delivery/1`
- `lib/maraithon/telegram_assistant/liveness_supervisor.ex`
- `lib/maraithon/crm.ex` — `list_people/2`, `search_people/3`, `fuzzy_find_person/2`, `find_existing_person/2`, `semantic_find_person/3`
- `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`
- `lib/maraithon/telegram_conversations.ex` — `Conversation` schema, `compact_old_turns/2`, `recent_turns/2`

**Test files — run; extend only if gaps found:**
- `test/maraithon/llm/anthropic_provider_test.exs`, `test/maraithon/llm_test.exs`
- `test/maraithon/context_cache_test.exs`, `test/maraithon/crm_test.exs`
- `test/maraithon/telegram_conversations_test.exs`, `test/maraithon/telegram_assistant_test.exs`

**Files to edit (closeout):**
- `.claude/plans/2026-05-09-fast-context-aware-answers.md` — frontmatter + per-fix annotations

---

## Acceptance Checks

- `git log` confirms `ed86f0a` and `1a43a67` present; migration `20260510005233` applied in dev/test DB.
- All eight fixes verified end-to-end against their landing points; any deviation either fixed (scoped) or documented.
- `mix format --check-formatted` clean (or reformatting captured as a reviewed diff).
- `mix precommit` passes: compile with `--warnings-as-errors`, no unused deps, formatted, full test suite green.
- Targeted module tests pass: `anthropic_provider_test`, `llm_test`, `context_cache_test`, `crm_test`, `telegram_conversations_test`, `telegram_assistant_test`.
- Any test gap found in Step 2 is filled with a focused, fix-named test; no speculative test files added.
- `.claude/plans/2026-05-09-fast-context-aware-answers.md` is `status: done` with each fix annotated by commit / file:line.

---

## Proof of Work Expectations

For the Cybrus review packet / human handoff, produce:

- **Verification table** — one row per fix: status (Verified / Fixed / Gap-filled), landing point (file:line), the behavior confirmed, and how (test name or manual trace).
- **`mix precommit` output** — full run, pasted, showing green; if it required fixes, before/after.
- **Targeted test output** — the six module test runs, pass counts.
- **Diff summary** — every file changed, with rationale. Expected minimal: the plan file, plus at most one scoped bug fix and any gap-filling tests. A large diff is a red flag and must be justified.
- **Plan file diff** — showing `planning → done` and the annotations.
- **Explicit "no change needed" note** for fixes that verified clean with zero edits.

---

## Risks

- **Verification theater** — the real failure mode is rubber-stamping. Each fix must be confirmed by an executed test or a concrete code trace, not by re-reading the spec. The verification table must cite *how* each was confirmed.
- **`mix format` mutating the tree** — `precommit` runs `format`, which rewrites files. Mitigation: run `--check-formatted` first so any reformatting is a visible, reviewable diff rather than a silent change bundled into the closeout commit.
- **`--warnings-as-errors` surfacing latent warnings** — unrelated compile warnings could block `precommit`. Mitigation: fix warnings as encountered; if a warning is large/unrelated in scope, flag it in proof of work rather than expanding the diff silently.
- **Fix 6 integration gap** — if a person-resolve call path still bypasses the fuzzy/similarity stack, the scoped fix could ripple wider than expected. Mitigation: confine to the single offending call path; if it can't be contained, stop and document rather than rebuild.
- **Test DB missing pg_trgm** — `crm_test.exs` similarity fragments fail if the extension/migration isn't applied in the test DB. Mitigation: confirm `mix ecto.migrate` (test env) in Step 1 before running `crm_test`.
- **Flaky parallel/async tests** — Fixes 2, 4, 7 rely on `Task.async_stream`; ordering or timing assertions may be intermittently flaky. Mitigation: if a failure is timing-related, re-run to confirm flakiness, then fix the test's determinism — do not "fix" the production code to satisfy a flaky test.
- **Scope creep** — the eight fixes are done; the temptation is to "improve" them. Out of scope. Only incomplete/incorrect behavior justifies a code edit, and only a minimal one.