---
status: ready
ticket: DC9BFBFF
title: Fast & Context-Aware Telegram Answers
---
# Fast & Context-Aware Telegram Answers — Spec

**Goal:** Cut Telegram-perceived latency and improve answer quality across the
eight gaps from the latency audit.

## Key finding

A codebase pass shows **all eight fixes from the draft plan are already
implemented**. Two are committed explicitly (`ed86f0a`, `1a43a67`); the rest are
present on `main`. This spec therefore scopes **verification and closeout**, not
new construction. Each fix below maps to its landing point so a reviewer can
confirm behavior and a closeout commit can flip the plan file to `done`.

## Status by fix

### Fix 1 — Anthropic prompt caching ✅
- `lib/maraithon/llm/anthropic_provider.ex`: `build_body/1`,
  `split_system_messages/1`, `build_system_blocks/1`. System text ≥ ~1024 chars
  gets `cache_control: %{type: "ephemeral"}`; response parsing reads
  `cache_read_input_tokens` / `cache_creation_input_tokens`.
- Test: `test/maraithon/llm/anthropic_provider_test.exs` exists.
- Committed: `ed86f0a`.

### Fix 2 — Parallel tool execution ✅
- `lib/maraithon/telegram_assistant/runner.ex`: `execute_tool_calls/5` →
  `run_tool_calls_in_parallel/5` uses `Task.async_stream` with
  `max_concurrency: max(length(tool_calls), 1)`. Repeat/loop guard via
  `guard_tool_history/2` (`AssistantHarness`). State threads `sequence`,
  `tool_steps`, `tool_history`, `iteration`, `llm_turns`.
- Committed: `1a43a67`.

### Fix 3 — Fast routing model (Haiku) ✅
- `config/runtime.exs`: `ANTHROPIC_ROUTING_MODEL` (default
  `claude-haiku-4-5-20251001`), `OPENAI_ROUTING_MODEL` (default `gpt-4o-mini`).
- `lib/maraithon/llm.ex`: `routing_model/0`, `complete_routing/1` (falls back to
  main model); also `chat_model/0` / `complete_chat/1`.
- `lib/maraithon/telegram_interpreter.ex`: `default_llm_complete/1` calls
  `LLM.complete_routing/1`.

### Fix 4 — Today digest ETS cache ✅
- `lib/maraithon/context_cache.ex` exists; `Maraithon.ContextCache` is in the
  `application.ex` supervision tree.
- `lib/maraithon/telegram_assistant/context.ex`: `build/1` calls
  `ContextCache.get_digest/1` (non-blocking) and
  `ContextCache.Builder.maybe_refresh_async/1`; `today_digest` is one of the 16
  output keys.
- Test: `test/maraithon/context_cache_test.exs` exists.

### Fix 5 — Streaming progress / edit-in-place ✅
- Implemented via the **Liveness** subsystem rather than an ad-hoc placeholder
  turn. `Maraithon.TelegramAssistant.LivenessSupervisor` is in the supervision
  tree; `TelegramAssistant.prepare_final_delivery/1` returns a `delivery` with a
  `mode` (`:edit` | `:reply`/`:send`) and `message_id`.
- `runner.ex`: `apply_delivery_mode/2` and `send_mode_for_delivery/1` route the
  final turn through `send_mode: :edit` when liveness produced a placeholder.
- `telegram_assistant.ex`: `dispatch_turn/6` handles `:edit` via
  `TelegramResponder.edit/4` and falls back to `:reply` on edit failure.

### Fix 6 — Fuzzy person resolve (pg_trgm) ✅
- Migration `priv/repo/migrations/20260510005233_enable_pg_trgm_for_crm_persons.exs`:
  enables `pg_trgm`, GIN trigram indexes on `crm_people.display_name` and the
  computed full-name expression.
- `lib/maraithon/crm.ex`: `list_people/2` / `search_people/3` use
  `similarity(... , ?) > 0.3` fragments with similarity-ordered results
  (lines ~647, ~658, ~786, ~813), alongside ILIKE. Embedding fallback via
  `semantic_find_person/3`. (Note: there is no `find_existing_person/2` — the
  draft plan named a function that does not exist.)

### Fix 7 — Parallel context prefetch ✅
- `lib/maraithon/telegram_assistant/context.ex`: `build/1` runs ~15 independent
  fetchers through `parallel_fetch/2` (`Task.async_stream`). Output shape
  unchanged (16 keys).

### Fix 8 — Rolling conversation summarization ✅
- `lib/maraithon/telegram_conversations.ex`: `Conversation` schema has a
  `summary` field; `compact_old_turns/2` folds old turns into
  `metadata["historical_summary"]` (keeps 12 recent; triggers at >24 turns or
  ~30k tokens). `recent_turns/2` still returns last N raw turns.
- Test: `test/maraithon/telegram_conversations_test.exs` exists.

## Closeout work (the actual remaining scope)

1. **Confirm each fix end-to-end** — read the landing points above and verify
   behavior matches intent (cache_control emitted, parallel streams ordered
   correctly, routing model actually swapped, digest read path populated, edit
   delivery path exercised, trigram queries return expected ranking, context
   shape stable, compaction triggers).
2. **Run `mix precommit`** (formatter + credo + full test suite) plus targeted
   tests for the modules above: `anthropic_provider_test`, `llm_test`,
   `telegram_assistant_test`, `context_cache_test`, `crm_test`,
   `telegram_conversations_test`. Fix any failures.
3. **Fill test gaps** if verification finds them — notably there is no dedicated
   `telegram_assistant/runner_test.exs`; runner coverage lives in
   `telegram_assistant_test.exs`. Add focused cases only where a fix is
   uncovered.
4. **Update the tracking plan file** `.claude/plans/2026-05-09-fast-context-aware-answers.md`
   — flip `status: planning` → `status: done` and annotate each fix with its
   commit / landing point.

## Out of scope

No new subsystems. Do not re-implement any of the eight fixes; if verification
shows a fix is incomplete or incorrect, treat that as a scoped bug fix against
the existing module, not a rebuild.

## Verification

- `mix precommit` passes.
- Targeted module tests pass.
- Plan file status updated; spec reviewed.