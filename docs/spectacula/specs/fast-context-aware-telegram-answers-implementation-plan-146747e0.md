---
created_at: 2026-05-10T00:45:05Z
created_by: cybrus
cybrus_task_id: 146747E0-52BF-47CD-AE6D-2D6C47F98620
project: Maraithon App
status: ready
---
# Fast & Context-Aware Telegram Answers — Implementation Plan

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 146747E0-52BF-47CD-AE6D-2D6C47F98620
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

## Objective

Reduce Telegram-perceived latency and improve answer quality on the Maraithon assistant hot path by shipping eight surgical fixes: Anthropic prompt caching, parallel tool execution, a fast routing model (Haiku), a today-digest ETS cache, streaming progress via `editMessageText`, fuzzy person resolution via `pg_trgm`, parallel context prefetch, and rolling conversation summarization. No new subsystems beyond a small ETS context cache and a trigram index — the rest is targeted edits inside the existing assistant pipeline.

Success means: the assistant responds noticeably faster (perceived <2s to first token-equivalent via placeholder edit), accepts fuzzy names without confidently picking the wrong person, and survives long conversations without unbounded prompt growth — all while existing tests stay green.

---

## Assumptions and Decisions

- **Anthropic SDK shape:** the provider already POSTs a JSON body to `/v1/messages`. We restructure the `system` field into a list of content blocks with `cache_control: %{type: "ephemeral"}` rather than introducing a new SDK abstraction. Cache scope is the largest stable block (system prompt + policy/voice block).
- **Parallel tool concurrency cap:** `max_concurrency: 3`. Higher concurrency risks rate-limit pressure on Gmail/Calendar APIs and complicates the repeat-guard. `ordered: true` preserves the existing tool-history ordering contract.
- **Routing model defaults:** Anthropic → `claude-haiku-4-5-20251001`; OpenAI → `gpt-4o-mini`. Both are env-overridable via `ANTHROPIC_ROUTING_MODEL` / `OPENAI_ROUTING_MODEL`. If unset, callers transparently fall back to `LLM.complete/1` so behavior is unchanged in environments that haven't been configured.
- **Context cache TTL:** 30 minutes for the today-digest. This is short enough that stale data isn't dangerous and long enough to absorb most "what should I do?" follow-ups in a session. Cache is per-user, in-memory only — it's a hot-path optimization, not a system of record. Cold start = miss = compute as today.
- **Streaming flag default:** `telegram_assistant.streaming_enabled?` defaults to `false` in `:test` and `true` in `:dev`/`:prod`. This lets us land Fix 5 without rewriting every existing assertion that counts `send_turn` calls.
- **pg_trgm threshold:** `similarity > 0.3`, ordered by similarity desc, take first. Below 0.3 we treat as no-match and fall through to "create new person" path. Standard Postgres extension — already supported on Fly's managed Postgres.
- **Rolling summarization trigger:** > 24 turns. Summary lives on `conversations.summary` (text column, additive migration). Failure is non-blocking — if the summarization call fails, the conversation simply keeps the longer raw history for that turn.
- **Test conventions:** ExUnit with `start_supervised!`, no `Process.sleep`, use `Maraithon.LLM.MockProvider` for any LLM call paths. New ETS GenServers are started via `start_supervised!` in tests so they're cleaned up between cases.
- **Order of work:** ship fixes in the listed order so each can be merged independently behind narrow tests. Fix 5 (streaming) depends on Fix 2 (parallel tools) for the per-tool progress edits; everything else is independent.
- **Out of scope:** multi-LLM abstraction changes, new visual UI, agent runtime changes, anything touching Phoenix LiveView outside of what these fixes require.

---

## Implementation Plan

### Fix 1 — Anthropic prompt caching

- In `Maraithon.LLM.AnthropicProvider`, extract a private `build_body/1` that constructs the request payload.
- When the incoming messages list contains a leading `%{role: "system", content: text}`, pull it out and emit a top-level `system: [%{type: "text", text: text, cache_control: %{type: "ephemeral"}}]`.
- Leave the rest of the message list untouched (user/assistant/tool turns flow through as today).
- Verify via unit test that the body shape matches Anthropic's documented caching contract.

### Fix 2 — Parallel tool execution

- In `Maraithon.TelegramAssistant.Runner.execute_tool_calls/5`, replace the `Enum.reduce_while/3` accumulator with `Task.async_stream/3` over the tool calls (`ordered: true`, `timeout: :infinity`, `max_concurrency: 3`).
- The per-task closure performs: DB step record → Toolbox execution → step completion. The closure must capture only the data it needs (no shared mutable state).
- After the stream completes, fold each `{:ok, result}` back into state in original order, preserving `sequence`, `tool_steps`, and `tool_history`.
- Run the repeat-guard once on the merged history at the end of the batch (was previously checked inside the reduce — close enough semantically because we still detect repeats across batches).

### Fix 3 — Fast routing model (Haiku)

- `config/runtime.exs`: read `ANTHROPIC_ROUTING_MODEL` and `OPENAI_ROUTING_MODEL` env vars and stash them under `:maraithon, :llm, routing_models: %{anthropic: ..., openai: ...}`.
- `Maraithon.LLM`: add `routing_model/0` returning `{provider, model_id}` or `nil`, plus `complete_routing/1` which merges `model:` into params and delegates to `complete/1`. If `routing_model/0` is `nil`, `complete_routing/1` falls back to `complete/1` unchanged.
- `Maraithon.TelegramInterpreter`: replace its `LLM.complete/1` call with `LLM.complete_routing/1`.
- Document the env vars in `config/runtime.exs` comments.

### Fix 4 — Today digest ETS cache

- New module `Maraithon.ContextCache` (GenServer + named ETS table `:maraithon_context_cache`, `:set`, `read_concurrency: true`).
- Public API: `put_digest(user_id, digest, ttl_ms \\ 30 * 60 * 1000)`, `get_digest(user_id)` (returns `{:ok, digest}` or `:miss`, transparently expiring stale entries).
- Wire into supervision tree in `Maraithon.Application`.
- After a successful Chief of Staff briefing run (`morning_briefing.ex` or `attention_arbiter.ex`, whichever is the actual writer), call `ContextCache.put_digest/2` with `%{generated_at, top_todos, open_loops_summary, waiting_on, last_24h_changes}`.
- In `Maraithon.TelegramAssistant.Context.build/1`, read from cache and include a `today_digest:` block in the snapshot when present.

### Fix 5 — Streaming progress via editMessageText

- In `Runner`, at the start of a run, send a placeholder turn ("Working on it…") via the existing `TelegramAssistant.send_turn`/equivalent and capture the returned message_id.
- After each tool completes (inside the parallel stream from Fix 2), call a new `TelegramAssistant.update_progress_turn(message_id, text)` that wraps `editMessageText` with the running tool list ("Working on it… (checking gmail, calendar)").
- The final answer goes through the existing `send_turn` path with `send_mode: :edit, message_id: <placeholder_id>` so the same message becomes the answer.
- Gate everything behind `Application.get_env(:maraithon, :telegram_assistant)[:streaming_enabled?]` (default `false` in `:test`, `true` in `:dev`/`:prod`).

### Fix 6 — Fuzzy person resolve (pg_trgm)

- Migration: `CREATE EXTENSION IF NOT EXISTS pg_trgm;` plus a GIN trigram index on `crm_persons.display_name` (and a generated index on `first_name || ' ' || last_name` if needed).
- `Maraithon.Crm.find_existing_person/2`: when the exact-match path returns `nil` and the input has a `display_name`, run a fallback query: `WHERE similarity(display_name, ?) > 0.3 ORDER BY similarity(display_name, ?) DESC LIMIT 1`.
- `Maraithon.Crm.list_people/2`: when `query` opt is given, augment the existing ILIKE branch with a similarity ordering tiebreak.

### Fix 7 — Parallel context prefetch

- In `Maraithon.TelegramAssistant.Context.build/1`, group calls into two passes:
  - **Pass 1 (linked items):** delivery, todo, project, travel — run via `Task.async_stream`.
  - **Pass 2 (everything else):** preference, operator memory, user memory, open loops, relationships, todos, connected accounts, projects, agents, briefing schedule, tool defaults — all independent of pass 1's output, run via `Task.async_stream`.
- Output shape unchanged. Add a `Logger.debug` of pass timings to make the win measurable.

### Fix 8 — Rolling conversation summarization

- Add `summary :text` column to `conversations` (additive migration, nullable).
- `Maraithon.TelegramConversations.recent_turns/2` keeps current behavior (last N raw turns).
- New `compact_old_turns/1`: when conversation has > 24 turns, summarize turns 25+ from the oldest using the routing model (Fix 3) and append (or replace) `conversation.summary`. Old turns themselves are not deleted — only excluded from the prompt window in favor of the summary.
- `Runner` calls `compact_old_turns/1` in a `Task.start` (fire-and-forget) after a successful delivery so it never blocks the user-facing reply.

### Final verification

- Run `mix precommit` (formatter + credo + tests).
- Run targeted suites: `mix test test/maraithon/llm/`, `mix test test/maraithon/telegram_assistant/`, `mix test test/maraithon/crm_test.exs`, `mix test test/maraithon/context_cache_test.exs`.
- Capture before/after timings for a representative Telegram turn (one tool call, one DB-heavy context build) in `Logger.debug` output to validate the parallel-prefetch and parallel-tool wins.

---

## Files and Interfaces

**Modified**

- `lib/maraithon/llm/anthropic_provider.ex` — `build_body/1` (new private), restructures `system` block with `cache_control`.
- `lib/maraithon/llm.ex` — `routing_model/0` (new public), `complete_routing/1` (new public).
- `config/runtime.exs` — read `ANTHROPIC_ROUTING_MODEL`, `OPENAI_ROUTING_MODEL`; populate `:maraithon, :llm, routing_models`.
- `lib/maraithon/telegram_interpreter.ex` — swap `LLM.complete/1` → `LLM.complete_routing/1`.
- `lib/maraithon/telegram_assistant/runner.ex` — `execute_tool_calls/5` rewritten for `Task.async_stream`; placeholder turn + progress edits; `compact_old_turns` post-delivery.
- `lib/maraithon/telegram_assistant/context.ex` — `build/1` two-pass parallel prefetch; reads `today_digest` from `ContextCache`.
- `lib/maraithon/telegram_assistant.ex` — new thin `update_progress_turn(message_id, text)` wrapping `editMessageText`.
- `lib/maraithon/chief_of_staff/skills/morning_briefing.ex` (or `attention_arbiter.ex` — whichever owns the digest) — write to `ContextCache.put_digest/2` after run.
- `lib/maraithon/crm.ex` — `find_existing_person/2` similarity fallback; `list_people/2` similarity tiebreak.
- `lib/maraithon/telegram_conversations.ex` — `compact_old_turns/1` (new public), schema change for `summary`.
- `lib/maraithon/application.ex` — supervise `Maraithon.ContextCache`.

**Created**

- `lib/maraithon/context_cache.ex` — GenServer + ETS owner; API: `put_digest/3`, `get_digest/1`.
- `priv/repo/migrations/<ts>_enable_pg_trgm_for_crm_persons.exs` — extension + GIN trigram index.
- `priv/repo/migrations/<ts>_add_summary_to_conversations.exs` — `add :summary, :text`.

**Tests (created or extended)**

- `test/maraithon/llm/anthropic_provider_test.exs` — body shape includes `cache_control` block.
- `test/maraithon/llm_test.exs` — `routing_model/0` resolution; `complete_routing/1` fallback.
- `test/maraithon/telegram_assistant/runner_test.exs` — parallel tool execution preserves order; placeholder turn lifecycle; streaming flag respected.
- `test/maraithon/telegram_assistant_test.exs` — context build still produces identical snapshot shape.
- `test/maraithon/context_cache_test.exs` — put/get/expire semantics; concurrent reads.
- `test/maraithon/crm_test.exs` — fuzzy resolve picks highest-similarity match (Charlie vs Charles example).
- `test/maraithon/telegram_conversations_test.exs` — `compact_old_turns/1` fires past threshold; failure is non-blocking.

**Configuration keys**

- `:maraithon, :llm, routing_models: %{anthropic: model_id, openai: model_id}`
- `:maraithon, :telegram_assistant, streaming_enabled?: bool`
- `:maraithon, :context_cache, default_ttl_ms: int` (optional override hook)

---

## Acceptance Checks

1. `mix precommit` passes locally.
2. Anthropic request body, when a system message is present, contains a top-level `system` array with at least one entry carrying `cache_control: %{type: "ephemeral"}`. Verified by unit test.
3. With three tool calls in a single turn, the runner executes them concurrently (verified via timing assertion or instrumented mock that records overlap), and the resulting `tool_history` is in original order.
4. With `ANTHROPIC_ROUTING_MODEL=claude-haiku-4-5-20251001` set, `Maraithon.TelegramInterpreter` issues an LLM request whose `model` param is the Haiku id. With it unset, behavior is identical to before this change.
5. After a Chief of Staff briefing run, `ContextCache.get_digest(user_id)` returns the digest. `Context.build/1` includes a `today_digest:` block in its output for that user. Cache entries past their TTL return `:miss`.
6. With streaming enabled, a turn with two tool calls produces: (a) an initial "Working on it…" send, (b) at least one `editMessageText` mid-run, (c) a final edit replacing it with the answer — message_id stable across all three. With streaming disabled (test env), no placeholder is sent.
7. `Crm.find_existing_person(user, %{display_name: "Charlie"})` returns "Charlie Smith" rather than "Charles Williams" given those two records exist. Below-threshold matches return `nil` (not a wrong person).
8. `Context.build/1` emits a debug log line showing both passes ran in parallel (count of tasks), and the snapshot shape matches the pre-change snapshot for the same fixture.
9. After a 25th turn lands in a conversation, `conversations.summary` becomes non-null. `recent_turns/2` still returns the last N raw turns. A simulated summarizer failure does not block the user reply.
10. pg_trgm extension and GIN index present after migration; rollback is clean.

---

## Proof of Work Expectations

- **Diff:** All listed files modified/created; no unrelated changes.
- **Test output:** Full `mix precommit` output captured, plus targeted suite runs for each module touched. Each new test must show as run+passed.
- **Migration evidence:** `mix ecto.migrate` and `mix ecto.rollback` both run cleanly against a dev DB; pg_trgm extension is present after up-migration.
- **Latency snapshot:** Logger.debug output (or a small benchmark script committed under `bench/` if useful) showing parallel-prefetch wall-clock vs sequential baseline on a representative fixture. Order-of-magnitude is enough — we need evidence the parallelism is real, not a marketing number.
- **Streaming evidence:** A short transcript (or test assertion log) showing the placeholder → progress-edit → final-answer lifecycle on a turn with multiple tool calls.
- **Fuzzy-resolve evidence:** Test output for the Charlie/Charles fixture passing.
- **Caching evidence:** Anthropic provider unit test passing showing the `cache_control` block; if accessible, an Anthropic API response showing `cache_creation_input_tokens` / `cache_read_input_tokens` on a real call (nice-to-have, not required for sign-off).
- **Review packet:** Cybrus writes the local review packet after Codex CLI completes; human picks it up from there.

---

## Risks

- **Anthropic API contract drift.** If the `cache_control` block format changes between SDK/API versions, requests could 400. Mitigation: contract test on the request body shape; fail loudly in dev.
- **Parallel tool side-effects.** Some tools may have implicit ordering assumptions (e.g., one tool reads state another tool writes in the same turn). Mitigation: cap concurrency at 3; preserve `ordered: true` for history; if any tool flags itself as serial-only in the future, add an opt-out.
- **Rate limits under parallelism.** Gmail/Calendar APIs have per-user QPS limits. Three-way parallelism is conservative but a hot user could still hit ceilings. Mitigation: surface rate-limit errors in tool steps; don't retry implicitly inside the stream.
- **Routing-model quality regressions.** Haiku may misroute edge-case intents that Sonnet handled. Mitigation: env-var gated, easy to disable per-environment; no behavioral fallback inside the interpreter (keep it simple — if Haiku misroutes, we adjust the prompt or fall back via env).
- **Cache staleness.** A 30-minute digest could mislead the user when something just changed. Mitigation: explicit `generated_at` timestamp in the digest block so the LLM can disclose freshness; cache is invalidated on the next briefing run.
- **Streaming flag in tests.** Existing tests count `send_turn` calls; if any environment overrides the default, they'll see extra calls. Mitigation: default `false` in `:test`; document the override in the config comments.
- **pg_trgm threshold tuning.** 0.3 may be too loose or too tight depending on real names in the data. Mitigation: keep the threshold configurable via app env so we can tune without a redeploy.
- **Summarization quality.** A poor summary can degrade long-conversation answers more than truncation would. Mitigation: keep raw turns in DB (only excluded from prompt); easy to revert by emptying `summary` and shipping a summarizer prompt fix.
- **Scope creep.** Eight fixes is a lot for one ticket. Mitigation: each fix is independently mergeable behind its own tests; if any one stalls, the rest can ship.