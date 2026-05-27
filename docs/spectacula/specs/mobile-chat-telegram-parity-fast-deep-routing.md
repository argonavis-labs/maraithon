# Mobile Chat Telegram-Parity Fast/Deep Routing Specification

Status: Done v1
Purpose: Make native in-app chat feel as fast as Telegram for ordinary conversation while preserving high-reasoning assistant behavior for todos, contacts, and connected-context work.
Audience: Engineering and product review.

## 1. Problem Statement

The mobile in-app chat currently routes nearly every non-direct command through the full assistant runner. In the observed screenshot evidence (`IMG_8935.jpg`), a simple "Hey" message leaves the app showing a long "Maraithon is thinking" pending state. That is the wrong interaction model for chat: short greetings, acknowledgements, and simple conversational turns should come back quickly and should not appear to need deep planning.

The app must still switch into the Telegram-grade assistant path when the user asks about todos, contacts, people, relationship context, open loops, or work that requires tool calls. The todos screenshot (`IMG_8934.jpg`) shows the product value lives in source-backed follow-up and stale-contact reasoning; those prompts must use the high-thinking path rather than a canned fast reply.

## 2. Goals and Non-Goals

### 2.1 Goals

- Reply immediately for low-risk, ordinary chat openers such as "Hey", "Hi", "Thanks", and "OK".
- Keep explicit direct commands, such as deterministic todo creation, on the existing instant command path.
- Route todo, contact, people, CRM, waiting-on, calendar/prep, and open-loop questions through the existing assistant runner with reasoning-tier model routing.
- Preserve the mobile REST contract: message send returns a thread plus optional run, and pending runs remain pollable.
- Add production verification that proves the behavior against real production data: a fast "Hey" path and a deep todo/contact path.
- Keep this change scoped; no new assistant runtime, no Telegram rewrite, no broad mobile redesign.

### 2.2 Non-Goals

- Replace Telegram assistant behavior.
- Add concurrent assistant runs within a single mobile thread.
- Add true token streaming to mobile chat in this pass.
- Redesign the chat UI beyond minimal pending-state behavior needed by the routing contract.
- Fake production verification with local fixtures or test doubles.

## 3. Current System Overview

- `MaraithonWeb.MobileChatController.create_message/2` calls `Maraithon.AssistantChat.send_message/3`.
- `AssistantChat.send_message/3` appends a user turn, starts a mobile `Run`, and calls `dispatch_user_message/4`.
- `AssistantChat.DirectIntent` only handles explicit todo creation. Everything else enqueues `AssistantChat.ThreadWorker`.
- `ThreadWorker` runs `TelegramAssistant.Runner.run_inbound/1`, which already chooses chat vs reasoning tiers through `TelegramAssistant.ModelRouting`.
- `ModelRouting` already sends planning, todo, waiting-on, connector, and person-context prompts to the reasoning model.
- The iOS `ChatSyncService` posts a message, merges the returned thread, and polls pending runs. `ChatDetailView` disables the composer and shows a generic thinking row while `pendingRunID` exists.

## 4. Core Requirements

| ID | Requirement |
|---|---|
| FR-1 | Simple chat openers and acknowledgements complete synchronously with an assistant turn and no queued/running pending run. |
| FR-2 | Fast replies must be clearly marked in run/message structured data as `message_class=assistant_reply` and `direct_intent=fast_chat_reply`. |
| FR-3 | Explicit todo creation continues to create the todo synchronously and return an action-result assistant turn. |
| FR-4 | Todo/contact/open-loop/person-context prompts must not be captured by the fast reply path. They must continue into the runner and use `ModelRouting` reasoning tiers where applicable. |
| FR-5 | The mobile client must continue to merge synchronous responses without polling when no pending run remains. |
| FR-6 | The production verification loop must create a real production session, send a fast chat prompt, assert no pending run and a non-empty assistant reply, then send a real todo/contact reasoning prompt and assert it completes through a run against production data. |
| FR-7 | Local tests must cover fast chat, direct todo creation, dedupe, and model routing for todo/contact prompts. |

## 5. Proposed Design

### 5.1 Backend Routing

Extend `AssistantChat.DirectIntent` with a narrow `:fast_chat_reply` intent. The classifier should only match very short, low-risk conversational inputs:

- greetings: `hey`, `hi`, `hello`, `yo`, `gm`, `good morning`, `good afternoon`, `good evening`
- acknowledgements: `ok`, `okay`, `thanks`, `thank you`, `sounds good`, `got it`

The classifier must explicitly reject text that contains work/context keywords such as `todo`, `task`, `contact`, `person`, `people`, `crm`, `follow up`, `waiting`, `owe`, `calendar`, `meeting`, `open loop`, `connected`, or `source`.

Execution persists a short assistant turn through `MobileDelivery.deliver_turn/4`, then completes the existing run with `tool_steps: 0` and `llm_turns: 0`. This avoids the queue and lets the current mobile client return without polling.

### 5.2 Deep Thinking Path

Leave the existing `ThreadWorker` plus `TelegramAssistant.Runner` path in place. Strengthen `ModelRouting` tests and, if needed, patterns so these prompt shapes use the reasoning tier:

- "What todos need my attention?"
- "Which contacts are stale?"
- "Who should I follow up with?"
- "What open loops are waiting on me?"

This keeps mobile and Telegram using the same assistant harness, context engine, toolbox, and escalation logic.

### 5.3 Mobile Client Behavior

The existing mobile merge behavior is acceptable when the backend returns no pending run. No app contract change is required for the fast path.

If app code changes are required during implementation, keep them minimal:

- Do not poll when `send` returns no pending run.
- Keep pending composer disabling for deep runs until the backend supports concurrent runs.
- Prefer more specific pending text only if run metadata is already available without expanding the API.

## 6. Failure Modes and Safeguards

| Failure Mode | Safeguard |
|---|---|
| Fast classifier captures a prompt that needs context. | Keep patterns short and denylist source-backed work keywords. Add tests for todo/contact prompts. |
| Fast reply becomes a stale canned assistant for real work. | Only use fast path for social openers and acknowledgements. Everything else falls through to runner. |
| Production runner is slow for deep prompt. | Verification polls the real run and fails if it does not finish in the configured window. |
| Mobile client keeps polling a completed fast run. | Backend returns no queued/running run, refreshed threads have no active `pending_run`, and the current client clears `pendingRunID`. |
| Existing direct todo behavior regresses. | Preserve current direct-intent path and controller test. |

## 7. Test and Validation Plan

- Backend focused tests:
  - Mobile chat "Hey" returns HTTP 200 with a user turn and assistant reply, completed run, no Telegram delivery, and no queued worker.
  - Mobile direct todo creation still creates a todo immediately.
  - Todo/contact prompts are not classified as fast replies.
  - `ModelRouting` maps todo/contact/stale-follow-up prompts to reasoning or focused context.
- Production verification script:
  - Authenticate to production with generated mobile email code.
  - Create a production mobile thread and send `Hey`.
  - Assert the send response has no queued/running run status, the refreshed thread has no pending run, a non-empty assistant response, and elapsed request time below a small threshold.
  - Create a second production thread and send a todo/contact prompt against the real account.
  - Poll the real production run until terminal and assert it is not failed and the final thread has a source-backed assistant response.
- Full verification:
  - `mix test` for focused backend files.
  - `mix precommit`.
  - `make verify-production-mobile` after deployment.

## 8. Implementation Checklist

- [x] Inspect current mobile chat, direct intent, runner, and iOS polling behavior.
- [x] Save Spectacula spec and active manifest.
- [x] Add narrow fast-chat direct intent and tests.
- [x] Strengthen reasoning routing patterns/tests for todo/contact prompts.
- [x] Update production mobile verification to assert fast and deep chat behavior.
- [x] Run focused tests and `mix precommit`.
- [x] Deploy backend if production behavior changed.
- [x] Run production verification with real production data.
- [x] Move manifest to `done` only after production verification passes.

## 10. Completion Evidence

- Local focused tests passed for mobile chat direct intent, mobile chat controller, and model routing.
- `mix precommit` passed before deployment.
- Production deploy completed on Fly release `v540`, image `maraithon:deployment-01KSMV6XZBB14HGJFGHAF4RY1G`.
- `https://maraithon.com/health/` returned HTTP 200 after deployment.
- `make verify-production-mobile` passed against production data for run `20260527141302`.
- Production simulator created and completed todo `iOS prod todo 20260527141302`.
- Production simulator created and updated contact `iOS Prod Person 20260527141302` with notes containing `Updated from simulator 20260527141302`.
- Fast chat sent `Hey` and replied in 1s with `Hey - I'm here.`, direct intent `fast_chat_reply`, run `f00919b1-9c57-4da6-bda3-8d48cc4430b6`.
- Deep chat recovered the exact production contact notes through assistant run `d132d8c8-4fee-42f7-9061-5c24e5372f48`.
- Direct mobile assistant todo creation created `iOS chat assistant todo 20260527141302`, run `b903d819-9d78-4910-93e4-f25a231b52a0`.

## 9. Open Questions / Assumptions

- Assumption: It is acceptable for fast chat replies to be deterministic for this pass. This minimizes latency and avoids unnecessary model calls for greetings.
- Assumption: Todo/contact prompts should use the existing Telegram assistant runner rather than a separate mobile-only assistant.
- Assumption: Production verification may create harmless verification threads and todos in the configured production account.
