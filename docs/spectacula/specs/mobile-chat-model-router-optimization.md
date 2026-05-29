# Mobile Chat Model Router Optimization

Status: Implementation Contract
Purpose: Make the mobile chat router faster, cheaper, more reliable, and easier to audit by routing each mobile turn to the least expensive path that can answer well.

## 1. Current State

Mobile chat enters `Maraithon.AssistantChat`, persists a user turn, creates a `telegram_assistant_runs` row, then either:

- handles a deterministic `DirectIntent` such as greeting or todo creation, or
- enqueues `Maraithon.TelegramAssistant.Runner`, which calls `ModelRouting.profile_for/1` and selects the chat or reasoning tier.

Current production configuration on 2026-05-27:

| Setting | Value |
| --- | --- |
| Provider | `openai` |
| Chat model | `gpt-4.1-mini` |
| Reasoning model | `gpt-5.4` |
| Chat reasoning effort | `medium` before this change; implementation default is now `none` |
| Reasoning effort | `high` |

Recent production data showed the useful optimization boundary:

| Path | Runs | Average latency | P50 | P90 |
| --- | ---: | ---: | ---: | ---: |
| deterministic `fast_chat_reply` | 12 | 54ms | 51ms | 72ms |
| deterministic `create_todo` | 8 | 61ms | 59ms | 70ms |
| chat-tier LLM | 13 | 25.9s | 24.4s | 57.1s |
| reasoning-tier LLM | 5 | 48.6s | 17.5s | 131.1s |

The gap is clear: every safe deterministic bypass is worth doing, and every LLM route should carry enough metadata to prove why it used that tier.

## 2. Goals

- Keep mobile chat fast by answering safe, trivial requests without an LLM.
- Preserve quality by routing source-backed, relationship, planning, todo, commitment, meeting-prep, draft, and open-loop requests to the reasoning tier.
- Reduce waste by making chat-tier requests explicit low-complexity work with tight budgets and no unnecessary reasoning effort when configured by default.
- Make routing observable in persisted runs: tier, task class, route reason, model name, reasoning effort, and direct-intent path must be visible.
- Make the router testable as a deterministic contract, with explicit examples for cheap, chat, and reasoning paths.
- Keep production safety: never use deterministic code for ambiguous semantic work, connected-source questions, personal data lookup, or destructive actions.

## 3. Non-Goals

- Do not replace the model-facing assistant contract with a rule engine.
- Do not introduce a learned classifier or additional model call just to choose a model; router overhead should stay near-zero.
- Do not change global provider credentials, default production model environment variables, or App Store/TestFlight behavior in this spec.
- Do not loosen authorization, confirmation, or tool execution policies.

## 4. Routing Contract

### 4.1 Deterministic Path

Use no LLM when the request is fully answerable or executable from the message itself:

| Class | Examples | Output |
| --- | --- | --- |
| `fast_chat_reply` | `Hey`, `thanks`, `sounds good` | fixed natural response |
| `create_todo` | `Create a todo titled ...` | creates todo and confirms |
| `simple_calculation` | `2+2`, `What's 12 * (3 + 4)?` | safe arithmetic answer |

Deterministic handlers must:

- record `llm_turns: 0` and `tool_steps: 0`,
- record `model_tier: deterministic`,
- record `route_reason` and `direct_intent`,
- reject any input that includes semantic context words such as todos, contacts, calendar, people, waiting, sources, projects, or follow-ups.

### 4.2 Chat Tier

Use the chat model for low-risk conversational or single-answer work:

- simple general knowledge that does not require connected sources,
- concise rewrites or wording-only requests,
- connector status requests using narrow context/tool scope,
- source-hinted but bounded identity questions already safe for chat.

Chat-tier profiles should be cheap by default:

- model: `LLM.chat_model()`,
- tier: `chat`,
- task class: one of `simple_answer`, `quick_chat`, `connector_status`, or `general_chat`,
- reasoning effort: default `none`, unless explicitly configured,
- narrow loop budgets for focused work.

### 4.3 Reasoning Tier

Use the reasoning model for work that needs judgment, connected context, prioritization, or higher consequence:

- morning/daily briefings,
- todo/open-loop triage,
- waiting-on/owed-by/commitment analysis,
- contact/CRM review and stale follow-up analysis,
- meeting prep,
- drafts that need relationship/project context,
- background job scheduling,
- broad connected-source search.

Reasoning profiles should use:

- model: `LLM.model()`,
- tier: `reasoning`,
- reasoning effort: `LLM.intelligence()`,
- larger tool and time budgets than chat,
- `request_focus` when the request can narrow context or tool scope.

### 4.4 Escalation

If a chat-tier LLM run fails with timeout, retryable provider errors, invalid JSON, missing content, tool-step limit, or loop-limit errors, retry once with the reasoning profile and record:

- original run id,
- escalated run id,
- escalation reason,
- final tier/model.

## 5. Observability Requirements

Every mobile run should expose routing metadata in `result_summary`:

| Key | Meaning |
| --- | --- |
| `surface` | `mobile` |
| `model_tier` | `deterministic`, `chat`, or `reasoning` |
| `task_class` | stable class such as `simple_calculation`, `waiting_on`, `person_context` |
| `route_reason` | concise decision reason |
| `model_name` | actual LLM model, or `direct_intent` for deterministic |
| `model_reasoning_effort` | actual effort, or `none` for deterministic |
| `llm_turns` | number of LLM turns |
| `tool_steps` | number of tool executions |

This metadata should let an operator answer: "Was this slow because it used reasoning, tools, retry, or model latency?"

## 6. Implementation Plan

1. Extend `DirectIntent` with a safe arithmetic parser and `simple_calculation` handler.
2. Classify direct intent before run creation so deterministic runs persist as `model_provider: deterministic` and `model_name: direct_intent`.
3. Add route metadata helpers so direct and LLM paths use the same summary keys.
4. Extend `ModelRouting.profile_for/1` with `task_class`, `route_reason`, and conservative default chat effort.
5. Update tests for routing tiers, route metadata, direct arithmetic, and context-bearing non-bypass behavior.
6. Run focused tests, assistant eval, and `mix precommit`.
7. Compare the changed behavior against production baseline data.

## 7. Validation Matrix

| Case | Expected path |
| --- | --- |
| `Hey` | deterministic `fast_chat_reply`, no LLM |
| `What's 2+2` | deterministic `simple_calculation`, no LLM |
| `Create a todo titled ...` | deterministic `create_todo`, no LLM |
| `What accounts are connected?` | chat tier, `connector_status` focus |
| `Give me a quick reply saying Tuesday works.` | chat tier, `quick_chat` focus |
| `What do I owe other people right now?` | reasoning tier, `waiting_on` focus |
| `Which contacts are stale?` | reasoning tier, relationship/contact context |
| `What should I know before my meeting?` | reasoning tier, meeting-prep context |
| `Hey, what todos need my attention?` | not deterministic; reasoning tier |

## 8. Definition of Done

- The router has deterministic arithmetic bypass with no unsafe eval.
- Direct-intent runs no longer look like expensive reasoning runs in persisted model fields.
- Routing profiles include task class and route reason.
- Tests prove fast path, chat path, reasoning path, and no-bypass context safeguards.
- Production baseline and verification results are recorded in the manifest.
- `mix precommit` passes before completion.

## 9. Implementation Result

Implemented on 2026-05-27.

Changes shipped in this work:

- Added deterministic `simple_calculation` handling for safe arithmetic, with no `eval` and no LLM turn.
- Moved direct-intent classification before run creation so deterministic mobile runs persist as `model_provider: deterministic` and `model_name: direct_intent`.
- Added route metadata for deterministic, chat, reasoning, and escalation paths.
- Tightened chat-tier default reasoning effort to `none`.
- Added focused profiles for connector status, source-hinted identity, meeting prep, today/todo attention, and waiting-on/open-loop analysis.
- Fixed runner tool-step enforcement so focused route budgets apply before executing an oversized tool batch.
- Exposed route metadata through the mobile chat JSON API.
- Added focused tests for arithmetic bypass, routing metadata, waiting-on classification, meeting-prep budgets, and mobile response serialization.

Verification completed:

| Gate | Result |
| --- | --- |
| Focused router/mobile tests | `44 tests, 0 failures` |
| Broader assistant/Telegram tests | `39 tests, 0 failures` |
| Assistant eval | `60 passed, 0 failed` |
| Full `mix precommit` | `1995 tests, 0 failures`; assistant eval `60/60` |

Verified route matrix using production-like settings:

| Input | Path |
| --- | --- |
| `Hey` | deterministic `fast_chat_reply` |
| `What is 2+2?` | deterministic `simple_calculation` |
| `What accounts are connected?` | chat tier, `gpt-4.1-mini`, `connector_status`, no reasoning |
| `Who is Charlie from Slack?` | chat tier, `gpt-4.1-mini`, `source_hint_identity`, no reasoning |
| `What do I owe other people right now?` | reasoning tier, `gpt-5.4`, `waiting_on`, high reasoning |
| `What should I know before my meeting?` | reasoning tier, `gpt-5.4`, `meeting_prep`, high reasoning |

## 10. Assumptions

- The current production model names are intentional: `gpt-4.1-mini` for chat and `gpt-5.4` for reasoning.
- The app should prefer deterministic zero-model responses only for unambiguous requests.
- Model availability and pricing are environment/configuration concerns; this change improves routing behavior without forcing a provider migration.
