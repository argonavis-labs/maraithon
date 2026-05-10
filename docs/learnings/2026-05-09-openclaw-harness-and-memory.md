# Openclaw harness & memory architecture — learnings for Maraithon

**Date:** 2026-05-09
**Source:** `/Users/kent/bliss/aitools/openclaw` deep-dive (~20 read passes)
**Goal:** identify reusable harness + memory patterns to port into Maraithon.

## TL;DR

Maraithon's runtime (OTP + Phoenix + Postgres) is more cohesive than
openclaw's. Where openclaw is ahead is in **harness modularity**, **tool-loop
classification**, **proactive conversation compaction**, and **prompt-cache
stability ordering**. Memory-wise, openclaw uses a single pluggable hybrid
(vector + BM25 + temporal decay) layer rather than Maraithon's tiered
PreferenceMemory / OperatorMemory / UserMemory / Memory split.

## Top 5 ports (ranked by impact-vs-effort)

### 1. Tool-loop detection with classification — small effort, high impact

**Openclaw:** `src/agents/tool-loop-detection.ts` distinguishes
`generic_repeat`, `unknown_tool_repeat`, `known_poll_no_progress`,
`ping_pong`. Levels: warning at 10x, critical at 20x, breaker at 30x.

**Maraithon today:** `AssistantHarness.guard_tool_history/2` just trips on
3+ repeats of the same `(tool, args, outcome)` triplet — no classification.

**Port plan:** keep the 3-window guard but classify the loop type and
emit telemetry per class. Helps debug stuck assistants faster.

### 2. Proactive conversation compaction — medium effort, high impact

**Openclaw:** `src/agents/pi-embedded-runner/compact.ts` (~56KB) monitors
prompt token count between turns, summarizes old turns, falls back to
truncating tool results, and has `post-compaction-loop-guard.ts` to avoid
infinite retry. Explicit error codes: `isLikelyContextOverflowError`,
`isCompactionFailureError`.

**Maraithon today:** `TelegramConversations.compact_old_turns/2` runs
async after every reply once total turns > threshold. Doesn't measure
tokens; just turn count.

**Port plan:** add token-aware compaction trigger (use the recorded
`tokens_in` from previous turns to estimate). Keep async pattern.

### 3. Prompt-cache boundary marking + deterministic ordering — small effort, medium impact

**Openclaw:** `src/agents/system-prompt-cache-boundary.ts` +
`src/agents/prompt-cache-stability.ts` enforce deterministic ordering on
maps, lists, plugin metadata before serializing. LRU prefix-hash cache
(64 entries) reuses across sessions.

**Maraithon today:** Anthropic cache_control is in place on the system
block, but the context payload contains maps/lists whose iteration order
isn't guaranteed (could miss cache hits between turns).

**Port plan:** add a `PromptStability` module that sorts map keys + list
elements deterministically before encoding. Run it on `Context.build`'s
output before injection into the prompt.

### 4. Auth-profile rotation framework — medium effort, low immediate impact

**Openclaw:** `resolveAuthProfileOrder()` cycles through OAuth profiles
on auth failures (rotating GitHub/Google/Anthropic/etc). Adaptive
backoff with cooldown-expiring profiles.

**Maraithon today:** single-provider (OpenAI). No rotation needed yet.

**Port plan:** defer until multi-provider lands. Just note the shape
when designing it.

### 5. Context engine behaviour — medium effort, medium impact

**Openclaw:** `src/context-engine/` is a pluggable subsystem that owns
system-prompt construction + memory recall + tool-catalog assembly +
context-limit enforcement. Multiple engines can be registered.

**Maraithon today:** `TelegramAssistant.Context.build/1` is monolithic.

**Port plan:** extract a `ContextEngine` behaviour with `build/1`,
`tool_catalog/1`, `inject_memory/2`. Lets future agents (Slack bot,
chief of staff) reuse the context rules.

## Things openclaw has that we should NOT port

- Multi-runtime harness registry (`pi` vs `codex`): only useful if you
  have multiple LLM frameworks per provider. We don't.
- Multi-channel session resolution: future work, not blocking now.
- Replayable agent event log: Maraithon already has richer event-sourced
  state (operator_events, memory feedback, open loops).

## Things Maraithon has that openclaw lacks

- OTP supervision tree for crash recovery without state loss.
- Per-person embeddings + fuzzy lookup (pgvector + pg_trgm) — openclaw
  has memory-level embeddings but not relationship-graph embeddings.
- Unified operator event bus.
- Live progress note edits during tool runs (openclaw uses status
  reactions; we use editMessageText).
- Telegram-native interrupt budget + proactive check-in cadence
  (openclaw treats every channel as equal).
