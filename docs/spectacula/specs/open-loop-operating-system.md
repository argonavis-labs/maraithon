# Open Loop Operating System

Status: Done v1
Purpose: Define the product and technical shape for Maraithon's durable open-loop layer across todos, CRM people, and deep memory.

## 1. Problem Statement

Maraithon now has persistent todos, CRM people, and deep memory, but agents need one coherent operating layer for tracking work the user must not miss. Morning Briefing, Telegram, Gmail, Slack, Calendar, and Chief of Staff skills should all create or refresh durable open loops through model-level intelligence, attach relevant people, and store durable memories when the model provides structured relationship or preference evidence.

## 2. Goals and Non-Goals

### 2.1 Goals

- Keep all actionable user work in a per-user durable todo list with model-mediated dedupe.
- Make relationships first-class by linking todos and other resources to CRM people only from explicit structured model/tool output.
- Make deep memory available before agent reasoning and writable by tools when relevance, preferences, or durable facts are learned.
- Provide a single open-loop snapshot for Telegram, runtime agents, and MCP clients.
- Preserve source evidence from Slack, Gmail, Calendar, Telegram, and Chief of Staff activities.

### 2.2 Non-Goals

- Do not infer people from names with local heuristics.
- Do not replace the existing Todo, CRM, or Memory schemas.
- Do not create a separate task engine outside the built-in Maraithon tools/MCP surface.

## 3. System Overview

The open-loop layer sits above `Maraithon.Todos`, `Maraithon.Crm`, and `Maraithon.Memory`.

- `OpenLoops.ingest_todos/3` remains model-backed by delegating dedupe to `Todos.ingest_many/3`.
- Persisted todos can be enriched from explicit `person`, `people`, `memory`, or `memories` payloads in the model candidate.
- `OpenLoops.snapshot/2` returns a compact state of overdue, today, upcoming, unscheduled, monitored todos, relationship contexts, and relevant memories.
- Runtime agents and Telegram include this snapshot in prompt context.
- MCP and Telegram expose `get_open_loops` for direct recall.

## 4. Core Requirements

- Every durable write remains scoped by `user_id`.
- Todo dedupe must remain model-level, not exact-string or source-id heuristics.
- Person linking must use explicit IDs or structured person attributes supplied by the model/tool caller.
- Memory writes must be explicit structured memory objects supplied by the model/tool caller.
- Tool callers must be able to ask "what am I missing?", "what do I owe this person?", and "what open loops need attention?" through a single tool.

## 5. Proposed Design

Add `Maraithon.OpenLoops` as the domain service for:

- `snapshot(user_id, opts)`: query open/snoozed todos, bucket them by urgency, include people with linked open todos, and include relevant deep memories.
- `ingest_todos(user_id, candidates, opts)`: call `Todos.ingest_many/3`, then enrich persisted decisions from explicit structured people and memories in the original candidates.
- `render_prompt_section(user_id, opts)`: provide a compact prompt section for generic prompt agents.

Add `get_open_loops` to:

- `Maraithon.Tools` for MCP/runtime tool use.
- `TelegramAssistant.Toolbox` for Telegram-safe use.
- `AgentHarness.ToolCatalog` and runner guidance.

Update existing todo write paths in Chief of Staff and Telegram to use `OpenLoops.ingest_todos/3`.

## 6. Failure Modes and Safeguards

- If enrichment fails, return enrichment errors without rolling back the todo write.
- If memory recall fails, return the open-loop snapshot with an empty memory section.
- If no user is present, leave context unchanged.
- If structured person or memory payloads are absent, do not infer them locally.

## 7. Test and Validation Plan

- Unit test open-loop ingestion with explicit person and memory enrichment.
- Unit test open-loop snapshot bucketing and relationship context.
- Tool tests for `get_open_loops` and MCP discovery/call.
- Telegram toolbox test for the Telegram-safe `get_open_loops` tool.
- Run `mix precommit`.

## 8. Implementation Checklist

- [x] Define open-loop architecture and checklist.
- [x] Add `Maraithon.OpenLoops`.
- [x] Replace direct model-todo ingestion call sites with open-loop ingestion.
- [x] Add MCP/runtime `get_open_loops` tool.
- [x] Add Telegram `get_open_loops` tool and prompt guidance.
- [x] Inject open-loop context into runtime and harness prompts.
- [x] Add focused tests.
- [x] Run verification gates.

## 9. Open Questions / Assumptions

- Assumption: explicit structured model fields are the contract for CRM and memory enrichment.
- Assumption: first-pass snapshots can be compact and query-driven; deeper proactive background review can be layered later.
