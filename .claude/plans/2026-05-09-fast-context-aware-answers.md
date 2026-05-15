---
status: planning
---
# Fast & Context-Aware Telegram Answers — Implementation Plan

**Goal:** Cut Telegram-perceived latency and improve answer quality across the eight gaps identified in the audit.

**Architecture:** Surgical edits to the existing assistant hot path — no new subsystems beyond a small ETS context cache and a pg_trgm-backed fuzzy-resolve fallback. Tests use the existing `Maraithon.LLM.MockProvider` and ExUnit conventions in the repo (no Process.sleep, use start_supervised!).

**Tech Stack:** Elixir, Phoenix 1.8, Ecto, Postgres (pg_trgm), Anthropic Claude API, OpenAI Responses API, OTP supervision, Telegram Bot API.

---

## Fix 1 — Anthropic prompt caching

**Files**
- Modify: `lib/maraithon/llm/anthropic_provider.ex`
- Test: `test/maraithon/llm/anthropic_provider_test.exs` (create or extend)

**Plan**
- The system prompt and the long policy/voice block in `AssistantHarness.system_prompt/0` + `build_prompt/1` are stable across turns. Anthropic's `messages` API accepts `cache_control: %{type: "ephemeral"}` on `system` blocks and message content blocks — turn the system message into a list of content blocks where the largest stable block is cached.
- Implementation: when an Anthropic request comes in with a `"system"` role message, lift it out into a top-level `system: [%{type: "text", text: ..., cache_control: %{type: "ephemeral"}}]` field. That's the structure Anthropic supports.
- Add a small helper `Maraithon.LLM.AnthropicProvider.build_body/1` and unit-test that the request body shape includes the cache_control block.

## Fix 2 — Parallel tool execution

**Files**
- Modify: `lib/maraithon/telegram_assistant/runner.ex` — `execute_tool_calls/5`
- Test: extend `test/maraithon/telegram_assistant_test.exs` or `test/maraithon/telegram_assistant/runner_test.exs` (add if missing)

**Plan**
- Replace `Enum.reduce_while/3` with `Task.async_stream(tool_calls, fn call -> execute_one(...) end, ordered: true, timeout: :infinity, max_concurrency: 3)`.
- Each task does the per-call DB step record, Toolbox execution, and step completion.
- After the stream finishes, fold results back into state (sequence, tool_steps, tool_history) preserving original order via `ordered: true`.
- Repeat-guard runs once on the merged history at the end (not after each tool — close to original semantics).

## Fix 3 — Fast routing model (Haiku)

**Files**
- Modify: `config/runtime.exs` — accept `ANTHROPIC_ROUTING_MODEL` / `OPENAI_ROUTING_MODEL` env vars
- Modify: `lib/maraithon/llm.ex` — add `routing_model/0`, `complete_routing/1` that swaps the `model` param
- Modify: `lib/maraithon/telegram_interpreter.ex` — call `LLM.complete_routing/1` (with fallback to `LLM.complete/1` if no routing_model configured)
- Test: extend `test/maraithon/llm_test.exs` and `test/maraithon/telegram_interpreter_test.exs` (or whatever exists)

**Plan**
- `routing_model/0` returns `{provider_name, model_id}` — defaults to nil. If nil, callers fall back to main model.
- `complete_routing/1` puts the routing model name into params and calls `LLM.complete/1`.
- Default routing model: `claude-haiku-4-5-20251001` for Anthropic, `gpt-4o-mini` (or what's configured) for OpenAI.

## Fix 4 — Today digest ETS cache

**Files**
- Create: `lib/maraithon/context_cache.ex` — GenServer + ETS table
- Modify: `lib/maraithon/application.ex` — start the cache in the supervision tree
- Modify: `lib/maraithon/chief_of_staff/skills/morning_briefing.ex` (or `attention_arbiter.ex`) — write the digest to the cache after each run
- Modify: `lib/maraithon/telegram_assistant/context.ex` — read `today_digest` from cache and include in the snapshot
- Test: `test/maraithon/context_cache_test.exs`

**Plan**
- ETS table `:maraithon_context_cache`, GenServer owner.
- Public API: `put_digest(user_id, digest, ttl_ms \\ 30 * 60 * 1000)`, `get_digest(user_id)`.
- Digest shape: `%{generated_at, top_todos: [...], open_loops_summary: "...", waiting_on: [...], last_24h_changes: [...]}`.
- Chief of Staff skill writes after a successful run; Context.build reads it; LLM gets a `today_digest:` block in context, which it can use for fast "what should I do?" answers without re-running tools.

## Fix 5 — Streaming progress via editMessageText

**Files**
- Modify: `lib/maraithon/telegram_assistant/runner.ex` — send a placeholder turn at start; edit with progress; final answer replaces it
- Modify: `lib/maraithon/telegram_assistant.ex` — likely already has `send_turn`/edit semantics; add a thin `send_progress_turn` and `update_progress_turn` if needed
- Test: extend runner test

**Plan**
- At run start, send "Working on it…" (configurable text) as a normal turn; capture its message_id.
- After each tool completes (in the parallel branch from Fix 2), edit that message to "Working on it… (checking gmail, calendar)".
- Final answer goes via the existing `send_turn` with `send_mode: :edit, message_id: <placeholder_id>`.
- Behind a config flag `telegram_assistant.streaming_enabled?` (default false in tests, true in dev/prod) so existing tests don't have to change.

## Fix 6 — Fuzzy person resolve (pg_trgm)

**Files**
- Create: `priv/repo/migrations/<timestamp>_enable_pg_trgm_for_crm_persons.exs`
- Modify: `lib/maraithon/crm.ex` — `find_existing_person/2`, `list_people/2` query branch
- Test: extend `test/maraithon/crm_test.exs`

**Plan**
- Migration: `CREATE EXTENSION IF NOT EXISTS pg_trgm;` and add a GIN trigram index on `crm_persons.display_name` (and `first_name || ' ' || last_name`).
- In `find_existing_person`, if exact contact match misses and `display_name` query is provided, fall back to a `similarity(display_name, ?) > 0.3` query ordered by similarity desc, take first.
- `list_people` query path already uses ILIKE — augment with similarity ordering when a `query` opt is given.
- Test inserts persons "Charlie Smith", "Daniel Bourke", "Charles Williams"; asserts that `Crm.find_existing_person(user, %{display_name: "Charlie"})` returns Charlie Smith rather than Charles Williams (or returns whichever is highest similarity).

## Fix 7 — Parallel context prefetch

**Files**
- Modify: `lib/maraithon/telegram_assistant/context.ex` — `build/1`
- Test: existing `test/maraithon/telegram_assistant_test.exs` should keep passing

**Plan**
- Group the 14+ DB-bound calls in `build/1` into independent groups and run with `Task.async_stream`.
- Two passes: first pass resolves linked items (delivery, todo, project, travel) in parallel; second pass resolves preference/operator/user memory + open loops + relationships + todos + connected accounts + projects + agents + briefing schedule + tool defaults in parallel.
- Output shape stays identical.

## Fix 8 — Rolling conversation summarization

**Files**
- Modify: `lib/maraithon/telegram_conversations.ex` — `recent_turns/2` plus a new `compact_old_turns/1`
- Modify: `lib/maraithon/telegram_assistant/runner.ex` — call `compact_old_turns` after a successful delivery
- Test: extend `test/maraithon/telegram_conversations_test.exs`

**Plan**
- When a conversation has > 24 turns, fold turns 25+ from the oldest into a `conversation.summary` field by appending a short LLM-generated summary (uses the routing model from Fix 3).
- `recent_turns/2` continues to return last N raw turns.
- Initial summarization is best-effort; failure is silent and non-blocking.

## Final verification

- Run `mix precommit` (formatter + credo + tests).
- Run targeted tests for changed modules.
- Fix any failures.