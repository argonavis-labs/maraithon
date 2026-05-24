---
created_at: 2026-05-24T00:02:05Z
created_by: cybrus
cybrus_task_id: FB16E55C-BBD9-4ECB-9894-FB810C273FF7
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Spec

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: FB16E55C-BBD9-4ECB-9894-FB810C273FF7
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

I now have full ground truth. Every one of the eight fixes, all six named test files, the pg_trgm migration, and the `summary` schema field are present on disk — and the tracking plan file already carries `status: done`. The only inaccuracies in the current spec are (1) `mix precommit` does **not** run credo, and (2) the "flip status to done" step is already complete. Here is the refined, implementation-ready plan.

---

```markdown
---
status: planning
ticket: Fast & Context-Aware Telegram Answers — Spec
type: verification-and-closeout
tracking_plan: .claude/plans/2026-05-09-fast-context-aware-answers.md
---

# Fast & Context-Aware Telegram Answers — Verification & Closeout Plan

## Objective

Cut Telegram-perceived latency and improve answer quality across the eight gaps
from the latency audit. A direct read of the codebase on disk confirms **all
eight fixes are already implemented and each has a backing test file**. This
ticket therefore delivers **verification and closeout**, not new construction:

1. Prove each fix behaves as intended end-to-end (static landing-point review +
   targeted tests + full `mix precommit`).
2. Fix — as scoped bugs against the existing module — anything verification shows
   to be incomplete or incorrect. Do **not** rebuild or re-architect any fix.
3. Finish the bookkeeping on the tracking plan file so the audit trail is
   self-consistent.

The bar for "done" is a green `mix precommit`, green targeted module tests, and a
consistent tracking plan file — backed by captured proof-of-work artifacts.

---

## Assumptions and Decisions

These were decided without follow-up; each is recorded so a reviewer can
challenge it.

- **All eight fixes are landed (verified against the working tree, not assumed).**
  Confirmed by reading the cited files:
  - Fix 1 caching — `anthropic_provider.ex` (`split_system_messages/1`,
    `build_system_blocks/1`, `cache_control: %{type: "ephemeral"}`,
    `cache_read_input_tokens`).
  - Fix 2 parallel tools — `runner.ex` (`run_tool_calls_in_parallel/5`,
    `Task.async_stream`, `AssistantHarness.guard_tool_history/2`).
  - Fix 3 routing model — `runtime.exs` (`ANTHROPIC_ROUTING_MODEL` default
    `claude-haiku-4-5-20251001`, `OPENAI_ROUTING_MODEL`), `llm.ex`
    (`routing_model/0`, `complete_routing/1`), `telegram_interpreter.ex`
    (`default_llm_complete/1` → `LLM.complete_routing/1` at line ~157).
  - Fix 4 digest cache — `context_cache.ex` present and supervised in
    `application.ex`; `context.ex` `build/1` calls `ContextCache.get_digest/1`
    + `ContextCache.Builder.maybe_refresh_async/1`; `today_digest` key emitted.
  - Fix 5 edit-in-place — `runner.ex` (`apply_delivery_mode/2`,
    `send_mode_for_delivery/1`, `:edit` mode);
    `TelegramAssistant.LivenessSupervisor` supervised in `application.ex`.
  - Fix 6 fuzzy person — migration
    `20260510005233_enable_pg_trgm_for_crm_persons.exs` present; `crm.ex` uses
    `similarity(...) > 0.3` fragments + `ILIKE` + `semantic_find_person/3`.
  - Fix 7 parallel prefetch — `context.ex` `parallel_fetch/2` via
    `Task.async_stream`; output shape unchanged.
  - Fix 8 rolling summarization — `telegram_conversations/conversation.ex` has
    `field :summary, :string` and `field :metadata, :map`;
    `telegram_conversations.ex` has `compact_old_turns/2` →
    `metadata["historical_summary"]` and `recent_turns/2`.
- **Correction to the prior spec: `mix precommit` does not run credo.** The
  actual alias (`mix.exs:105`) is
  `["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]`.
  Acceptance is keyed to that real definition. Any reference to "credo" in the
  prior spec is dropped.
- **Correction to the prior spec: the tracking plan file is already
  `status: done`.** `.claude/plans/2026-05-09-fast-context-aware-answers.md`
  exists and its frontmatter already reads `status: done`. The "flip planning →
  done" step is a no-op; the remaining bookkeeping is to add the per-fix
  landing-point / commit annotations that file currently lacks.
- **Naming notes carried forward (both correct):** there is no
  `find_existing_person/2` (the original draft named a non-existent function; the
  real surface is `list_people/2`, `search_people/3`, `semantic_find_person/3`),
  and there is no dedicated `telegram_assistant/runner_test.exs` (runner
  behavior is covered by `telegram_assistant_test.exs`; the only `runner_test.exs`
  is `agent_harness/runner_test.exs`).
- **Test execution requires Postgres with `pg_trgm`.** `mix test` runs
  `ecto.create --quiet` + `ecto.migrate --quiet` first; the Fix 6 CRM tests
  depend on the `pg_trgm` extension that migration `20260510005233` enables. The
  executing environment must have a reachable Postgres. If unavailable, that is a
  blocker to surface, not a reason to skip tests.
- **No new subsystems.** If a fix is found broken, the response is a scoped patch
  to the existing module plus a regression test — never a re-implementation.
- **No production deploy is part of this ticket.** Closeout ends at green
  verification + consistent plan file. Deploy follows the normal `main` → Fly
  GitHub Actions path and is out of scope here.

---

## Implementation Plan

Execute in order. Steps 1–2 are read-only verification; step 3 is conditional;
step 4 is bookkeeping.

### Step 1 — Static landing-point review (read-only)

For each of the eight fixes, open the cited file/lines and confirm the behavior
matches intent. Concretely confirm:

- **Fix 1:** `build_body/1` attaches `cache_control: %{type: "ephemeral"}` only
  to system blocks at/above the size threshold; response parsing reads
  `cache_read_input_tokens` and `cache_creation_input_tokens` into usage.
- **Fix 2:** `Task.async_stream` preserves result order back into `tool_steps`;
  `max_concurrency` is `max(length(tool_calls), 1)`; the loop/repeat guard
  (`guard_tool_history/2`) prevents infinite tool loops.
- **Fix 3:** `complete_routing/1` actually targets the Haiku routing model and
  falls back to the main model when unset; `telegram_interpreter` routes through
  it.
- **Fix 4:** `context.ex` reads the digest non-blocking (cache miss returns
  fast, refresh is async) and `today_digest` is one of the output keys; cache is
  supervised.
- **Fix 5:** when liveness produced a placeholder, the final turn uses
  `send_mode: :edit` and `dispatch_turn` edits in place, falling back to
  `:reply`/`:send` on edit failure.
- **Fix 6:** `list_people/2` and `search_people/3` combine `ILIKE` and
  `similarity(...) > 0.3` with similarity-ordered results; `semantic_find_person/3`
  is the embedding fallback.
- **Fix 7:** ~15 independent fetchers run through `parallel_fetch/2`; the output
  map shape (16 keys) is unchanged vs. the serial version.
- **Fix 8:** compaction triggers on the documented thresholds (>24 turns or
  ~30k tokens), folds old turns into `metadata["historical_summary"]`, keeps the
  recent N, and `recent_turns/2` still returns raw recent turns.

Record any divergence as a defect candidate for Step 3.

### Step 2 — Run the test suite

- Run targeted module tests first (fast feedback):
  ```
  mix test \
    test/maraithon/llm/anthropic_provider_test.exs \
    test/maraithon/llm_test.exs \
    test/maraithon/telegram_assistant_test.exs \
    test/maraithon/context_cache_test.exs \
    test/maraithon/crm_test.exs \
    test/maraithon/telegram_conversations_test.exs
  ```
- Then run the full gate:
  ```
  mix precommit
  ```
  (= `compile --warnings-as-errors` → `deps.unlock --unused` → `format` →
  `test`). Treat `--warnings-as-errors` failures and `deps.unlock --unused`
  changes as real failures to resolve, not noise.

### Step 3 — Fix defects only if verification finds them (conditional)

- For any failing test or behavioral divergence, apply the **Testing Principle**
  from `CLAUDE.md`: decide whether production code has a real bug or the test no
  longer represents valid behavior, then fix the code or intentionally rewrite
  the test with rationale. Do not delete/skip tests to go green.
- Keep patches scoped to the owning module of the affected fix.
- **Targeted test-gap fill (optional, only where a fix is uncovered):** runner
  behavior is exercised via `telegram_assistant_test.exs`; add a focused case
  there (or a new `test/maraithon/telegram_assistant/runner_test.exs`) **only if**
  Step 1/2 shows an uncovered branch in `run_tool_calls_in_parallel/5`,
  `apply_delivery_mode/2`, or `send_mode_for_delivery/1`. Do not add speculative
  tests for already-covered paths.

### Step 4 — Reconcile the tracking plan file (bookkeeping)

- File: `.claude/plans/2026-05-09-fast-context-aware-answers.md`.
- Frontmatter is already `status: done` — leave it (do not regress it).
- Add per-fix landing-point / commit annotations the file currently lacks: under
  each "Fix N" heading note the file(s)/function(s) that landed it and the commit
  where known (Fix 1 → `ed86f0a`; Fix 2 → `1a43a67`; remaining fixes → "present
  on `main`"). This makes the file a self-contained audit trail.
- Flip this verification plan's own frontmatter `status: planning` → `done` once
  Steps 1–3 pass.

---

## Files and Interfaces

**Reviewed / verified (no edits expected unless a defect is found):**

- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1`,
  `split_system_messages/1`, `build_system_blocks/1`, usage parsing.
- `lib/maraithon/llm.ex` — `routing_model/0`, `complete_routing/1`,
  `chat_model/0`, `complete_chat/1`.
- `config/runtime.exs` — `ANTHROPIC_ROUTING_MODEL`, `OPENAI_ROUTING_MODEL`.
- `lib/maraithon/telegram_interpreter.ex` — `default_llm_complete/1`
  (routes to `complete_routing/1`).
- `lib/maraithon/telegram_assistant/runner.ex` — `run_tool_calls_in_parallel/5`,
  `apply_delivery_mode/2`, `send_mode_for_delivery/1`.
- `lib/maraithon/telegram_assistant/context.ex` — `build/1`, `parallel_fetch/2`,
  `today_digest` output key.
- `lib/maraithon/context_cache.ex` (+ `ContextCache.Builder`) and
  `lib/maraithon/application.ex` (supervision of `ContextCache` and
  `TelegramAssistant.LivenessSupervisor`).
- `lib/maraithon/crm.ex` — `list_people/2`, `search_people/3`,
  `semantic_find_person/3` (similarity + ILIKE + embedding).
- `lib/maraithon/telegram_conversations.ex` — `compact_old_turns/2`,
  `recent_turns/2`.
- `lib/maraithon/telegram_conversations/conversation.ex` — `:summary`,
  `:metadata` fields.
- `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`.

**Tests (exist; run, extend only on a found gap):**

- `test/maraithon/llm/anthropic_provider_test.exs`
- `test/maraithon/llm_test.exs`
- `test/maraithon/telegram_assistant_test.exs` (covers runner)
- `test/maraithon/context_cache_test.exs`
- `test/maraithon/crm_test.exs`
- `test/maraithon/telegram_conversations_test.exs`

**Bookkeeping file (edit):**

- `.claude/plans/2026-05-09-fast-context-aware-answers.md` (add per-fix
  annotations; keep `status: done`).
- This plan file (flip `status` to `done` at the end).

---

## Acceptance Checks

- [ ] Static landing-point review (Step 1) completed for all eight fixes; any
      divergence recorded.
- [ ] Targeted module tests pass:
      `mix test test/maraithon/llm/anthropic_provider_test.exs test/maraithon/llm_test.exs test/maraithon/telegram_assistant_test.exs test/maraithon/context_cache_test.exs test/maraithon/crm_test.exs test/maraithon/telegram_conversations_test.exs`.
- [ ] `mix precommit` passes green (compile with `--warnings-as-errors` clean,
      `deps.unlock --unused` produces no changes, `format` clean, full `test`
      green).
- [ ] No fix was re-implemented; any code change is a scoped patch to an existing
      module with a clear rationale (and a regression test if it fixed a bug).
- [ ] `.claude/plans/2026-05-09-fast-context-aware-answers.md` carries per-fix
      landing/commit annotations and remains `status: done`.
- [ ] This verification plan's frontmatter is `status: done`.

---

## Proof of Work Expectations

Cybrus review packet should include:

- **Verification matrix** — the eight fixes × {file:line cited, static review
  result, covering test, pass/fail}. Pre-filled ground truth from this plan's
  Assumptions can seed it; the executing agent confirms each row.
- **Test output** — full console output of the targeted `mix test` run and of
  `mix precommit`, showing the final `N tests, 0 failures` summary lines (and
  the compile/format/deps.unlock steps for precommit). Paste real output, not a
  summary.
- **Diff** — `git diff` for any code change made under Step 3 (expected: none, or
  small scoped patches), plus the plan-file edits from Step 4.
- **Environment note** — Postgres availability and that `pg_trgm` migration
  applied cleanly (relevant to Fix 6 tests).
- **Closeout note** — one line per fix confirming behavior, and an explicit
  statement of anything found broken and how it was scoped-fixed (or "no defects
  found").
- If any check could not run (e.g., no database), state it plainly with the
  blocking error rather than marking it passed.

---

## Risks

- **Stale-spec risk (already partially realized):** the prior spec misstated
  `mix precommit` (claimed credo) and assumed the plan file still needed flipping
  to done. Both are corrected here; watch for other small drift between the prior
  spec's prose and the actual tree, and trust the tree.
- **Database dependency:** `mix test` requires a reachable Postgres with
  `pg_trgm`; absent that, Fix 6 (and the broader suite) cannot be verified. This
  is a hard blocker, not a skip.
- **`--warnings-as-errors` brittleness:** unrelated compiler warnings elsewhere
  in the tree can fail `mix precommit` even though the eight fixes are sound.
  Decide per warning whether it is in-scope to fix or should be flagged to the
  human, rather than silencing globally.
- **`deps.unlock --unused` churn:** if `mix.lock` carries unused deps, precommit
  will modify the lock file; confirm whether that change is expected before
  committing it.
- **Order-sensitivity in parallel paths (Fix 2 / Fix 7):** the highest-value
  manual check is that `Task.async_stream` results are reassembled in the
  original order and the context map shape is unchanged — a regression here is
  silent (no crash, wrong answer). Prioritize this in Step 1 even though tests
  pass.
- **Over-reach:** the temptation under a "verification" ticket is to "improve"
  working code. Out of scope — only defects found by Steps 1–2 justify edits.
```

**Summary of what changed from the prior spec, after verifying against the working tree:**

- Confirmed all eight fixes, all six named test files, the pg_trgm migration, and the `summary`/`metadata` schema fields actually exist on disk — the plan now rests on verified ground, not assertion.
- **Corrected `mix precommit`**: it runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test` — **not** credo.
- **Corrected the closeout premise**: the tracking plan file already has `status: done`, so that step becomes "add the missing per-fix landing/commit annotations and keep status done," not "flip planning → done."
- Added concrete commands, a Postgres/`pg_trgm` execution prerequisite, and a `--warnings-as-errors` / `deps.unlock` risk that the prior spec omitted.

One thing I did **not** do: run `mix precommit` myself, since this is the planning phase (execution happens after the human moves the task Planned → Approved). The plan instructs the executing agent to capture that output as proof of work.