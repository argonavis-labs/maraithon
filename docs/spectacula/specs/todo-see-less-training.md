# Todo See Less Training Specification

Status: Done
Purpose: Define a model-backed feedback loop that lets the operator say "see less like this" on a todo and have future todo surfacing adapt without brittle text heuristics.

## 1. Overview and Goals

Maraithon already persists todos, renders them on `/todos`, delivers Telegram todo cards, and stores durable user memory. The missing loop is negative relevance training at the point of review: when a todo is low-value, noisy, or too routine, the operator should be able to mark it as something the system should show less often.

The v1 feature adds a clear "See less" action on todo surfaces. That action should:

- remove the current todo from the active queue immediately;
- ask the model to infer the durable pattern behind the feedback from the todo's source, title, summary, next action, metadata, and attention profile;
- write that pattern as negative todo-relevance memory;
- include those memories in future todo-intelligence prompts so the model can skip, demote, or monitor similar candidates;
- avoid exact keyword, sender, title, or source-only heuristics as the basis for suppression.

## 2. Current State and Problem

Current code:

| Area | Current behavior |
|---|---|
| Todo context | `Maraithon.Todos` owns todo CRUD, status changes, feedback, prompt serialization, and ingestion delegation. |
| Todo schema | `Maraithon.Todos.Todo` stores source fields, user-facing copy, priority, attention mode, status, and `metadata`. |
| Todo UI | `MaraithonWeb.TodosLive` renders a searchable table with Done and Dismiss actions plus a detail panel. |
| Telegram UI | `Maraithon.TelegramAssistant.TodoActions` renders todo cards with Done, Dismiss, Important, and Not Important callbacks. |
| Todo intelligence | `Maraithon.Todos.Intelligence` builds an LLM prompt from candidates, recent todos, CRM summaries, and `Memory.prompt_context/2`. |
| Durable memory | `Maraithon.Memory` stores `relevance_feedback` and other memories; `Memory.Intelligence` model-selects relevant memories after local candidate recall. |

Problem: "Dismiss" and "Not Important" affect the current todo, but they do not create a durable, semantically generalized preference that steers future todo creation. If the same kind of noisy work arrives through a different title, thread, sender, or account, the system can repeat the same mistake.

## 3. Scope and Non-Goals

In scope:

- Add a public `Todos.see_less_like/3` context API.
- Add a model-backed todo feedback trainer that converts a selected todo into durable negative memory.
- Add "See less" actions to `/todos` row actions, todo detail, and Telegram todo cards.
- Dismiss the current todo after a successful training write.
- Include todo relevance memories explicitly in todo-intelligence prompts.
- Update prompt rules so the model decides whether future candidates should be skipped, demoted to `monitor`, or created with lower priority.
- Add tests for the context API, memory contents, UI action, Telegram callback, and prompt contract.

Out of scope:

- Global account blocking or sender blocking.
- A separate preference-management UI.
- Bulk "see less" in v1.
- Embedding migrations for todos or memory.
- Rewriting the deterministic `AttentionRanker` as an LLM ranker.
- Deleting already-created similar todos other than the one the user clicked.

## 4. UX / Interaction Model

### 4.1 `/todos`

Add a quiet "See less" action beside existing Done and Dismiss actions. It must be visually secondary and row-oriented, consistent with `DESIGN.md`.

Behavior:

- Clicking "See less" stops row-click propagation.
- The LiveView calls `Todos.see_less_like(current_user_id, todo_id, source: "todos_page")`.
- On success, the todo disappears from the active list because it is dismissed.
- The flash says "Maraithon will show fewer todos like that."
- On failure, the flash reports that the preference could not be saved.

The detail panel should also expose "See less" near Done and Dismiss because the operator often decides after reading detail.

### 4.2 Telegram

Telegram todo cards should include a callback action named "See Less" in the same feedback row as Important and Not Important. Callback data uses the existing `tgtodo:<uuid>:<action>` shape.

Behavior:

- `see_less` calls `Todos.see_less_like(user_id, todo_id, source: "telegram")`.
- The edited message shows the dismissed state and a concise feedback acknowledgement.
- The callback notice says "I'll show fewer todos like this."

### 4.3 Current Item Semantics

The action combines two operations:

1. Create durable feedback memory.
2. Dismiss the clicked todo with a resolution note.

If memory writing succeeds but dismissing fails, the user should still be told the preference was saved but the todo could not be dismissed. If memory writing fails, the todo should not be dismissed because the action would silently lose the training signal.

## 5. Functional Requirements

| ID | Requirement |
|---|---|
| FR-1 | A user can invoke "See less" on a visible todo from `/todos`. |
| FR-2 | A user can invoke "See Less" from a Telegram todo card. |
| FR-3 | The current todo is dismissed only after a durable feedback memory is written. |
| FR-4 | The feedback memory is user-scoped and source-linked to the todo id. |
| FR-5 | The trainer uses an LLM prompt to infer a generalized suppression pattern; it must not rely on exact string matching, fixed source filters, or sender-only rules. |
| FR-6 | The trainer response is normalized into a `Memory.Item` with `kind: "relevance_feedback"`, `polarity: "negative"`, tags including `todo_relevance` and `see_less`, and metadata containing the model rationale. |
| FR-7 | Todo intelligence receives recent active negative todo-relevance memories independently from the candidate text query. |
| FR-8 | Todo intelligence prompt rules require the model to skip or demote candidates that match negative todo-relevance memories unless stronger fresh evidence justifies surfacing them. |
| FR-9 | Prompt output preserves explicit decisions: every candidate still returns `create`, `update`, or `skip`. |
| FR-10 | Tests can inject an `llm_complete` function so the trainer is deterministic in test runs. |

## 6. Data and Domain Model

No schema migration is required for v1.

### 6.1 Memory Shape

The trainer writes through `Maraithon.Memory.write/3`:

| Field | Value |
|---|---|
| `kind` | `relevance_feedback` |
| `scope` | `user` |
| `title` | Short model-generated title such as `See less: routine vendor newsletters` |
| `content` | Durable instruction written as a generalized preference |
| `summary` | One-sentence summary for prompt rendering |
| `source` | `todo_see_less` |
| `source_ref_type` | `todo` |
| `source_ref_id` | clicked todo id |
| `author_type` | `user` |
| `tags` | `["todo_relevance", "see_less", "negative_feedback"]` plus model categories |
| `importance` | default `85` |
| `confidence` | model confidence, clamped `0.0..1.0`, default `0.85` |
| `polarity` | `negative` |
| `dedupe_key` | stable per user/todo pattern key produced from the normalized trainer output |
| `metadata` | model rationale, pattern attributes, original todo snapshot, feedback source, and trainer sentinel |

### 6.2 Trainer Output Contract

The model returns JSON:

```json
{
  "title": "See less: routine FYI newsletters",
  "summary": "Routine FYI newsletters without a direct ask should not become action todos.",
  "content": "When an incoming item is only a broad FYI/newsletter and does not ask Kent for a decision, reply, approval, or personal action, skip it instead of creating an action todo.",
  "pattern_key": "routine_fyi_newsletters_without_direct_ask",
  "categories": ["newsletter", "fyi", "no_direct_ask"],
  "negative_signals": ["broadcast update", "no explicit ask", "no owner waiting"],
  "exceptions": ["personal/family impact", "customer waiting", "explicit deadline"],
  "confidence": 0.86,
  "reasoning": "The selected todo is low-value because it is informational rather than actionable."
}
```

Invalid or partial model output should fall back to a conservative memory that records the exact feedback without pretending to infer a broad rule.

## 7. Backend / Service Changes

### 7.1 New Trainer Module

Create `Maraithon.Todos.FeedbackTrainer`.

Public API:

```elixir
train_see_less(user_id, %Todo{} = todo, opts \\ [])
```

Responsibilities:

- serialize the clicked todo with `Todos.serialize_for_prompt/1`;
- include the todo's `AttentionRanker.profile/1`;
- build a trainer prompt with explicit instructions against exact-match and sender-only rules;
- call `llm_complete` from opts, app config, or the default LLM provider;
- decode and normalize JSON;
- write a durable memory through `Memory.write/3`;
- return `{:ok, %{memory: item, training: normalized}}` or `{:error, reason}`.

### 7.2 Todos Context API

Add:

```elixir
Todos.see_less_like(user_id, todo_id, opts \\ [])
```

Behavior:

1. Fetch todo by `user_id` and `todo_id`.
2. Run `FeedbackTrainer.train_see_less/3`.
3. Dismiss the todo with note `"See less feedback recorded from <source>."`.
4. Return `{:ok, %{todo: dismissed_todo, memory: memory, training: training}}`.

### 7.3 Todo Intelligence Prompt

`Maraithon.Todos.Intelligence.build_prompt/4` should add:

- `"todo_relevance_memories"`: active negative `Memory.Item`s tagged `todo_relevance`, serialized for prompt use.
- Prompt rules that say these memories are durable steering context and the model should decide semantically whether a candidate matches them.

Important boundary: database recall may narrow candidates for token budget, but creation/suppression decisions stay in the LLM prompt. There should be no Elixir rule that says "if title contains X, skip".

### 7.4 Candidate Decision Guidance

The todo intelligence prompt should state:

- Negative todo memories are not global blocks.
- Similarity is semantic: source evidence, ask/no-ask, owner, relationship, urgency, life domain, and actionability matter more than exact words.
- If a candidate matches negative feedback and has no exception signal, return `skip` with a reason that cites the memory.
- If it partly matches but may be useful later, use `attention_mode: "monitor"` and lower priority.
- If an exception applies, create/update the todo and include reasoning.

## 8. Frontend / UI Changes

Implementation target: `lib/maraithon_web/live/todos_live.ex`.

Required changes:

- Add `handle_event("see_less_todo", %{"id" => todo_id}, socket)`.
- Add a `See less` button to row actions.
- Add a `See less` button to the detail panel; pass any needed event target through assigns.
- Refresh todos after success and clear invalid selection.
- Keep action text compact; do not add explanatory copy blocks.

## 9. Telegram Changes

Implementation target: `lib/maraithon/telegram_assistant/todo_actions.ex`.

Required changes:

- Accept `see_less` in `parse_callback/1`.
- Dispatch `see_less` to `Todos.see_less_like/3`.
- Include `See Less` in the feedback row unless the todo already has see-less feedback recorded.
- Show a callback notice specific to the action.
- Preserve existing Done, Dismiss, Important, and Not Important behavior.

## 10. Observability and Instrumentation

V1 should use existing memory events and todo metadata rather than adding new telemetry.

Required traces in persisted state:

- Memory event from `Memory.write/3`.
- Todo `metadata["feedback"]` or a dedicated `metadata["see_less_feedback"]` entry showing source and memory id.
- Dismissal resolution note.
- Trainer metadata containing sentinel/version and model rationale.

## 11. Failure Modes and Edge Cases

| Case | Expected behavior |
|---|---|
| Todo id is missing or belongs to another user | Return `{:error, :not_found}` and do not write memory. |
| LLM provider is unavailable in test/dev mock mode | Use injected `llm_complete` or existing mock behavior. |
| Trainer returns invalid JSON | Return an error or conservative fallback; do not dismiss unless memory is written. |
| Memory validation fails | Show failure; keep todo active. |
| Todo is already dismissed/done | Still allow training if the user can access it, but do not reopen it. |
| Duplicate pattern | `Memory.write/3` dedupe updates the active memory instead of creating noise. |
| Future candidate resembles feedback but has urgent evidence | Model may create/update and should explain the exception in decision reasoning. |

## 12. Test Plan and Validation Matrix

| Test | Validation |
|---|---|
| `Todos.see_less_like/3` success | Writes negative todo memory, dismisses current todo, records metadata. |
| Trainer normalization | Converts deterministic JSON into a valid `Memory.Item` payload. |
| Trainer invalid todo/user | Returns `:not_found` or validation error without dismissing. |
| Todo intelligence prompt | Includes `todo_relevance_memories` and anti-heuristic instructions. |
| Todo intelligence behavior with injected LLM | A candidate matching a seeded negative memory can be skipped by the model path. |
| `/todos` LiveView action | Clicking See less removes the row and shows success flash. |
| Telegram callback | `tgtodo:<id>:see_less` parses and dispatches. |
| Regression | Existing Done, Dismiss, Important, Not Important tests continue passing. |

Project gate:

- Run `mix precommit` after implementation and fix failures.

## 13. Definition of Done

- A new worktree and branch contain all changes.
- Canonical Spectacula spec and lifecycle manifest are present.
- `/todos` exposes "See less" without violating `DESIGN.md`.
- Telegram todo cards expose "See Less".
- Feedback training writes durable negative todo-relevance memory through the model-backed trainer.
- Todo intelligence receives and honors those memories by prompt contract, not hard-coded text suppression.
- Focused tests pass.
- `mix precommit` passes, or any blocker is recorded explicitly.
- Manifest moves to `done` only after the implementation has been reviewed against this spec.

## 14. Assumptions

- "See less like this" means the current todo should leave the active queue immediately.
- "Using intelligence, not text heuristics" means the durable pattern is model-inferred and future suppression is model-decided. Local database filtering may only gather candidate memories for prompt budget.
- The existing `Memory.Item` schema is sufficient for v1; no migration is needed.
- The first implementation surface is `/todos` plus Telegram cards, not dashboard todo cards.
