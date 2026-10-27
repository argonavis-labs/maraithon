# Mobile Production Assistant Chat Parity Specification

Status: Ready v2
Purpose: Replace the native iOS chat tab's local canned responder with the production Maraithon assistant runtime so mobile chat behaves like the existing Telegram Chief-of-Staff conversation surface.
Audience: Product, backend engineering, iOS engineering, QA.

## 1. Executive Summary

The current mobile chat pane looks like Telegram, but it is not powered by production assistant chat. The native app sends messages only to a local Swift helper, immediately appends a canned assistant response, and never calls `maraithon.com` for chat.

The production backend does have a real assistant path, but that path is wired around Telegram:

| Surface | Current behavior |
|---|---|
| Native iOS Chat | Uses local SwiftData `ChatThread`/`ChatMessage` and `ChatResponder.response(...)`. No network request, no production LLM, no tools, no connected context. |
| Mobile API | Exposes Magic auth, `me`, todos, and people. No chat/assistant routes exist under `/api/mobile`. |
| Production assistant | `TelegramRouter` starts/continues conversations, persists turns, runs `TelegramAssistant.Runner`, uses tools/context, and delivers replies through `TelegramResponder` to Telegram. |

The fix is not a UI-only change. Mobile needs a production chat API and the backend assistant runtime needs a transport-neutral delivery boundary so the same assistant can deliver to Telegram and to mobile.

### 1.1 Final Product Decision

Mobile Chat is a first-class Maraithon Chief-of-Staff surface, not a local demo bot and not a Telegram client. The user should be able to open the Chat tab, type the same freeform requests they send to the production Telegram assistant, and see production assistant responses, todo writes, CRM writes, memory updates, and confirmation-required actions flow through the same backend policy engine.

For v1, mobile should use a request-and-poll chat API rather than token streaming. Polling is the right default because the existing production runner is bounded around 40 seconds, already persists assistant runs/steps/turns, and the native app can deliver a credible Telegram-like pending state without holding a long HTTP request or adding a realtime channel before the backend transport boundary is stable.

### 1.2 Final Technical Decisions

| Decision | Spec choice | Reason |
|---|---|---|
| Assistant source | Reuse the existing production `TelegramAssistant.Runner` through a neutral `AssistantChat` facade. | It preserves the tested prompt/tool/context/runtime behavior instead of creating a second assistant. |
| Persistence | Reuse existing `telegram_*` tables for v1, adding only small compatibility fields/indexes. | Table renames are high-risk and unnecessary for parity. A facade hides the Telegram naming from new mobile code. |
| Delivery | Add a delivery adapter boundary. Telegram delivery calls `TelegramResponder`; mobile delivery only persists turns and returns JSON. | This is the actual missing seam. The runner currently assumes Telegram send/reply/edit semantics. |
| Run lifecycle | Persist the user turn synchronously, enqueue one assistant run per thread, return `202`, and poll. | This avoids duplicate tool execution, request timeouts, and fragile realtime delivery. |
| Idempotency | Require `client_message_id` and enforce uniqueness per conversation. | Mobile network retries must not create duplicate turns or duplicate todos. |
| Confirmation | Reuse prepared actions and tool policy, but route decisions through a surface-aware path. | Mobile must be able to confirm/cancel safely without Telegram callbacks. |
| Local responder | Keep `ChatResponder` only for previews/offline test fixtures. Never use it as a signed-in production final response. | The screenshot's canned "Captured..." reply is the bug. |

### 1.3 2026 Apple Guidance Applied

Current Apple guidance changes the implementation bar in three concrete ways:

| Area | Source | Requirement for this spec |
|---|---|---|
| iOS 26 design | Apple describes iOS 26 as centered on Liquid Glass and content-first surfaces. SwiftUI standard controls adopt the new material automatically. | Keep Chat built from native `NavigationStack`, `ToolbarItem`, `safeAreaInset`, `TextField`, `Menu`, `Button`, `ScrollView`, and system materials. Use custom glass only for app-owned composer/buttons already covered by the design system. |
| Custom Liquid Glass | Apple's SwiftUI `glassEffect` guidance says custom views can adopt Liquid Glass where they are genuine controls or morphing interface elements. | Do not make the message timeline glassy. Bubbles are content. Glass belongs on chrome: composer, add/send controls, tab bar, and toolbar buttons. |
| App Review readiness | Apple's App Review guidance requires apps to be complete, tested, and backed by live services for account-based features. | Production verification must prove Magic sign-in, mobile chat, todo mutation, and CRM mutation against `maraithon.com`; the app must not ship placeholder chat behavior in production. |
| Privacy | Apple's privacy guidance emphasizes data minimization, clear use, and account deletion/access expectations. | Chat endpoints must derive user identity from session auth, collect only message/action data required for the assistant, and avoid unnecessary Contacts/Microphone/Photos permissions for v1. |

## 2. Root Cause

### 2.1 Mobile Never Calls Production Chat

In `MaraithonMobile/Features/Chat/ChatDetailView.swift`, sending a message does this:

1. Trim the draft.
2. Insert a local user `ChatMessage`.
3. Call `ChatResponder.response(...)`.
4. Insert a local assistant `ChatMessage`.
5. Save SwiftData.

The key line is the local call:

```swift
let response = ChatResponder.response(
    to: body,
    openTodoCount: openTodos.count,
    contactCount: contacts.count
)
```

`MaraithonMobile/Features/Chat/ChatResponder.swift` is a deterministic string matcher. For general text like "Hey", it returns:

```text
Captured. Next best action: convert this into a todo, update a relationship note, or keep exploring the conversation here.
```

That exact canned response appears in the screenshot, which confirms the mobile chat pane is still using the local placeholder.

### 2.2 Mobile API Has No Assistant Routes

`~/bliss/maraithon/lib/maraithon_web/router.ex` exposes mobile auth, todos, and people:

```elixir
scope "/api/mobile", MaraithonWeb do
  pipe_through [:api, :mobile_api_auth]

  get "/me", MobileAuthController, :me
  delete "/session", MobileAuthController, :delete
  get "/todos", MobileTodoController, :index
  post "/todos", MobileTodoController, :create
  ...
  get "/people", MobilePeopleController, :index
  post "/people", MobilePeopleController, :create
  ...
end
```

There is no `/api/mobile/chat`, `/api/mobile/assistant`, `/api/mobile/conversations`, or equivalent endpoint. `MaraithonMobile/Core/API/MobileAPIClient.swift` mirrors this: it has auth, todos, and people methods only.

### 2.3 Production Assistant Is Telegram-Shaped

The real assistant starts in `~/bliss/maraithon/lib/maraithon/telegram_router.ex`:

- Resolves a Telegram `chat_id`.
- Maps that Telegram account to a Maraithon `user_id`.
- Starts or continues a `TelegramConversations.Conversation`.
- Appends a user turn.
- Calls `TelegramAssistant.handle_inbound(...)`.

`TelegramAssistant.handle_inbound(...)` then routes into `TelegramAssistant.Runner.run_inbound(...)`.

The delivery path is also Telegram-shaped:

```elixir
def send_turn(%Conversation{} = conversation, chat_id, text, opts \\ []) do
  ...
  case dispatch_turn(chat_id, text, reply_to_message_id, send_mode, telegram_opts, opts) do
    {:ok, result, telegram_message_id} ->
      TelegramConversations.append_turn(conversation, turn_attrs)
      ...
  end
end

defp dispatch_turn(chat_id, text, _reply_to_message_id, :send, telegram_opts, _opts) do
  TelegramResponder.send(chat_id, text, telegram_opts)
end
```

For mobile, there is no Telegram `chat_id`, no Telegram message id, and no Telegram Bot API delivery. The assistant needs a transport boundary that can persist and return mobile turns without sending to Telegram.

### 2.4 Repository Evidence Summary

| Finding | Evidence | Why it matters |
|---|---|---|
| Native Chat is local-only | `MaraithonMobile/Features/Chat/ChatDetailView.swift` inserts both user and assistant `ChatMessage` locally and calls `ChatResponder.response(...)`. | This is why the screen can look like Telegram while never reaching production. |
| Mobile API surface is missing chat | `~/bliss/maraithon/lib/maraithon_web/router.ex` exposes `/api/mobile/auth`, `/me`, `/session`, `/todos`, and `/people`, but no chat routes. | iOS has no production endpoint to call. |
| iOS API client mirrors missing backend routes | `MaraithonMobile/Core/API/MobileAPIClient.swift` has auth/todos/people DTOs and methods only. | The mobile layer cannot sync chat without new DTOs and methods. |
| Existing mobile auth is production-ready | `ProductionMagicAuthProvider` stores a Bearer session token and `RequireMobileSession` validates it server-side. | Chat can reuse the same auth pipeline and must not introduce a separate credential path. |
| Existing verification loop is reusable | `scripts/verify-production-simulator.sh` already mints a fresh production magic token, signs into Simulator, writes a todo, writes a person, and verifies via live API. | Chat verification should extend this loop instead of creating a second production test harness. |
| Assistant runner persists runs and steps | `TelegramAssistant.Runner.start_run/3`, `create_step/1`, and `complete_run/2` already record run status, model, prompt snapshot, tool steps, errors, and result summaries. | Mobile does not need a new run table for v1. It needs surface-aware metadata and JSON serialization. |
| Runner delivery is the coupling point | `Runner.deliver_standard_response/9`, `send_todo_messages/4`, and `handle_run_failure/4` call `TelegramAssistant.send_turn(...)`; `send_turn(...)` calls `TelegramResponder`. | These are the exact seams to refactor behind a delivery adapter. |
| Prepared actions are Telegram-biased | `TelegramAssistant.respond_to_prepared_action/6` sends action results through `send_turn(...)`; `Runner.execute_tool_action/3` hardcodes `surface: "telegram"`. | Mobile confirmation cannot be safe until prepared-action execution is surface-aware. |
| Todo digest delivery is Telegram-specific | `Runner.send_todo_messages/4` uses `TodoActions.telegram_payload(...)`, `parse_mode: "HTML"`, and Telegram reply markup. | Mobile needs structured todo message data and native buttons instead of Telegram HTML/buttons. |
| Liveness is Telegram-specific | `LivenessSession` sends Telegram chat actions/progress messages through `TelegramResponder`. | Mobile v1 should expose pending/run status through polling, not reuse Telegram typing/progress transport. |

## 3. Product Goal

The Chat tab should behave like the user's Telegram assistant:

- A user can type any natural-language message.
- Maraithon uses the production assistant runtime, connected context, todo tools, CRM tools, memory, and confirmation policies.
- The app shows the user's message immediately.
- The app shows a pending/typing state while the assistant works.
- The assistant's final response appears in the same thread.
- Write actions that require confirmation show explicit Confirm/Cancel controls in the mobile UI.
- Created todos, updated people, learned relationship context, and other side effects go through the same production policies as Telegram.

## 4. Non-Goals

- Do not build a second assistant in Swift.
- Do not call OpenAI directly from the iOS app.
- Do not expose raw Telegram Bot API concepts to the mobile client.
- Do not require the user to have Telegram connected to use mobile chat.
- Do not send mobile chat replies to Telegram.
- Do not rename all existing `telegram_*` database tables in the first implementation pass.
- Do not implement the fix as part of this spec-writing task.

## 5. Design Principles

| Principle | Requirement |
|---|---|
| One brain, multiple surfaces | Telegram and mobile must use the same production assistant runner, tools, policies, and context loading. |
| Transport-neutral delivery | Assistant output must be delivered through a surface adapter: Telegram sends to Bot API; mobile persists and returns JSON. |
| Fast mobile UX | The mobile app must not block indefinitely on a long-running LLM/tool loop. It should show pending state and poll or stream status. |
| Idempotent sends | Retried mobile requests must not duplicate user turns or execute write tools twice. |
| Policy parity | Confirmation-required tools must remain confirmation-required on mobile. |
| No fake answers | In signed-in production mode, mobile must not use canned local assistant responses as final replies. |

## 6. Recommended Architecture

### 6.1 Target Component Map

| Layer | New/changed module | Responsibility |
|---|---|---|
| HTTP | `MaraithonWeb.MobileChatController` | Authenticated mobile thread/message/run/action endpoints. |
| HTTP JSON | `MaraithonWeb.MobileChatJSON` | Stable snake_case JSON for threads, turns, runs, pending actions, linked todos, and errors. |
| Backend facade | `Maraithon.AssistantChat` | Surface-neutral orchestration for mobile and future non-Telegram chat surfaces. |
| Delivery behavior | `Maraithon.AssistantChat.Delivery` | Behaviour contract for turning assistant output into surface-specific persistence/delivery. |
| Mobile delivery | `Maraithon.AssistantChat.MobileDelivery` | Persist assistant turns without Telegram API calls; return turn/action metadata for mobile polling. |
| Telegram delivery | `Maraithon.AssistantChat.TelegramDelivery` | Preserve existing Telegram `send`, `reply`, `edit`, HTML, and inline keyboard behavior. |
| Runner | `Maraithon.TelegramAssistant.Runner` | Keep reasoning/tool loop; accept surface/delivery context and stop hardcoding Telegram in delivery and action execution paths. |
| iOS API | `MobileAPIClient+Chat` or chat section in `MobileAPIClient` | Encode/decode chat endpoints using existing Bearer session and app configuration. |
| iOS sync | `ChatSyncService` | Optimistic send, polling, SwiftData merge, retry, and prepared-action decisions. |

The module names can still reference `TelegramAssistant.Runner` internally in v1. The important architectural boundary is that new mobile code talks to `AssistantChat`, not directly to Telegram modules.

### 6.2 Backend Facade Contract

Add `Maraithon.AssistantChat` as the only new backend context used by `MobileChatController`.

Required public functions:

```elixir
def list_threads(user_id, opts \\ [])
def create_thread(user_id, attrs \\ %{})
def get_thread(user_id, thread_id)
def send_message(user_id, thread_id, attrs)
def get_run(user_id, run_id)
def decide_prepared_action(user_id, prepared_action_id, decision, attrs \\ %{})
```

Required invariants:

| Invariant | Enforcement |
|---|---|
| User id is never supplied by the client. | Read `conn.assigns.current_user.id`; pass it to `AssistantChat`; scope every query by this user id. |
| Mobile never chooses `chat_id`. | Generate server-owned synthetic chat ids for mobile threads. |
| One active run per mobile thread. | Detect a running/degraded-not-finished run before enqueuing a new one. |
| Retried sends are safe. | Deduplicate by `(conversation_id, client_message_id)` before creating a turn or run. |
| Prepared-action decisions are owner-scoped. | Query prepared actions by `id` and `user_id`; reject cross-user ids with `404`. |

### 6.3 Delivery Behaviour

Introduce a behaviour with one general turn callback and one optional liveness callback set:

```elixir
@callback deliver_turn(Conversation.t(), String.t(), keyword()) ::
            {:ok, Conversation.t(), Turn.t(), map()} | {:error, term()}

@callback prepare_final_delivery(Run.t(), map()) ::
            {:ok, %{mode: atom(), message_id: String.t() | nil, summary: map()}}

@callback liveness_enabled?(map()) :: boolean()
```

Recommended modules:

| Module | `deliver_turn/3` behavior |
|---|---|
| `AssistantChat.TelegramDelivery` | Delegate to the current `TelegramAssistant.send_turn/4`, preserving Telegram `send_mode`, `reply_to_message_id`, `telegram_opts`, and message id capture. |
| `AssistantChat.MobileDelivery` | Call `TelegramConversations.append_turn/2` directly with role/kind/origin/structured data, set delivery metadata, and return `%{surface: "mobile", delivered: true}`. It must never call `TelegramResponder`. |

The runner should receive a delivery module and surface in `runtime_context`:

```elixir
%{
  surface: "mobile",
  delivery_module: Maraithon.AssistantChat.MobileDelivery,
  delivery: %{mode: :persist, message_id: nil}
}
```

Then replace direct calls:

| Current runner call | Target call |
|---|---|
| `TelegramAssistant.send_turn(...)` in `deliver_standard_response/9` | `deliver_turn(runtime_context, conversation, text, opts)` |
| `TelegramAssistant.send_turn(...)` in `send_todo_messages/4` | `deliver_todo_item(runtime_context, conversation, todo, opts)` |
| `TelegramAssistant.send_turn(...)` in `handle_run_failure/4` | `deliver_failure(runtime_context, conversation, reason, opts)` |
| `TelegramAssistant.prepare_final_delivery(run.id)` | `delivery_module.prepare_final_delivery(run, runtime_context)` |

### 6.4 Persistence Strategy

Reuse the existing conversation/run/prepared-action tables in v1, with minimal additive schema work.

Add a migration:

| Table | Field/index | Purpose |
|---|---|---|
| `telegram_conversations` | `surface :string, null: false, default: "telegram"` | Query/scoping without JSON fragments and a clear future migration path. |
| `telegram_conversations` | index `[:user_id, :surface, :last_turn_at]` | Fast mobile thread list. |
| `telegram_conversation_turns` | `client_message_id :string` | Stable idempotency key from iOS. |
| `telegram_conversation_turns` | `delivery_state :string, default: "delivered"` | Mobile send/poll status and failure rendering. |
| `telegram_conversation_turns` | unique index `[:conversation_id, :client_message_id] where client_message_id IS NOT NULL` | DB-level duplicate protection. |
| `telegram_assistant_runs` | `surface :string, null: false, default: "telegram"` | Filter mobile runs and log surface-specific behavior. |
| `telegram_assistant_runs` | allow status `queued` in schema validation | Let mobile API return before the worker starts the runner. Transition to `running` when execution begins. |
| `telegram_prepared_actions` | `surface :string, null: false, default: "telegram"` | Execute confirmation decisions with the correct policy surface. |

Backfill existing rows with `surface = "telegram"` and leave existing Telegram unique indexes intact. Do not rename tables or columns in this pass. Add schema fields to `Conversation`, `Turn`, `Run`, and `PreparedAction` changesets, plus validation for `surface in ["telegram", "mobile"]` and `delivery_state in ["sending", "sent", "delivered", "failed"]`.

### 6.5 Represent Mobile Threads

Use existing conversation ids as mobile thread ids. For a new mobile thread:

1. Insert a `telegram_conversations` row with `surface: "mobile"`.
2. Generate `chat_id = "mobile:" <> user_id <> ":" <> conversation_id` after id allocation.
3. Store mobile-specific metadata:

```json
{
  "mobile_thread": true,
  "client_thread_id": "optional-ios-uuid",
  "title": "New conversation",
  "last_mobile_run_id": null
}
```

The backend should derive the visible title from:

1. `metadata["title"]`, when user-renamed;
2. first user turn text, truncated with `ChatThreadNaming`-compatible behavior;
3. `"New conversation"`.

### 6.6 Async Run Model

Mobile uses a request/poll model:

1. iOS app sends a user message with `client_message_id`.
2. Backend validates the thread belongs to the current user and `surface == "mobile"`.
3. Backend checks idempotency. If duplicate, return the existing user turn and active/latest run.
4. Backend inserts the user turn synchronously.
5. Backend enqueues one assistant run for the thread.
6. API returns `202 Accepted`, the thread snapshot, and run id/status.
7. iOS shows an assistant pending row and polls `GET /api/mobile/chat/runs/:id` and/or `GET /api/mobile/chat/threads/:id`.
8. The worker runs the existing assistant loop with `surface: "mobile"` and `MobileDelivery`.
9. iOS merges assistant turns and removes pending UI when the run reaches a terminal state.

Use an OTP worker pattern rather than a bare `Task.start` from the controller. Preferred v1 implementation:

| Module | Responsibility |
|---|---|
| `Maraithon.AssistantChat.ThreadSupervisor` | Dynamic supervisor for mobile thread workers. |
| `Maraithon.AssistantChat.ThreadRegistry` | Registry keyed by `{user_id, conversation_id}`. |
| `Maraithon.AssistantChat.ThreadWorker` | Serializes sends/runs for one mobile thread and invokes the runner. |

This mirrors the production need for per-chat serialization and prevents two HTTP requests from running write tools concurrently for the same mobile thread.

### 6.7 Liveness And Progress

Do not reuse Telegram liveness transport for mobile v1. Telegram liveness sends chat actions/progress messages through `TelegramResponder`, which is exactly what mobile must avoid.

Mobile v1 progress contract:

| Run state | Mobile presentation |
|---|---|
| `queued` | User bubble acknowledged; pending assistant row appears. |
| `running` | Assistant row shows a native typing/thinking affordance. |
| `running` with latest tool step | Optional status text from `telegram_assistant_steps.step_type/tool`, never raw arguments. |
| `waiting_confirmation` | Assistant prompt has Confirm/Cancel actions. |
| `completed` | Pending row is replaced by assistant turn(s). |
| `degraded` or `failed` | Pending row becomes retryable assistant/system failure. |

Streaming and incremental token display are future work after the transport-neutral path is stable.

## 7. Backend API Contract

All routes live under `/api/mobile` and use the existing `mobile_api_auth` pipeline. The backend must infer `user_id` from `conn.assigns.current_user`; clients must never send or choose `user_id`.

### 7.0 API Conventions

| Convention | Requirement |
|---|---|
| Format | JSON request/response, snake_case keys, `Accept: application/json`. |
| Auth | `Authorization: Bearer <session_token>` using the existing mobile session token. |
| User scope | Every thread, run, turn, and prepared action query must be scoped to `conn.assigns.current_user.id`. |
| Body size | Reject message bodies over 16 KB with `422 message_too_long`; trim leading/trailing whitespace. |
| Idempotency | `client_message_id` is required for send and action-decision requests; valid UUID string preferred, opaque string accepted up to 128 chars if the app ever changes generators. |
| Dates | ISO 8601 UTC strings, matching existing mobile JSON conventions. |
| Errors | Stable `%{error: "code", message?: "human safe detail", run?: ..., thread?: ...}`. Do not return stack traces or raw LLM/provider errors. |
| Versioning | Keep this under `/api/mobile/chat/...` for v1. Add fields compatibly; do not remove or rename keys without an app version gate. |

Canonical message object:

```json
{
  "id": "turn-uuid",
  "client_message_id": "ios-message-uuid",
  "role": "assistant",
  "body": "I found three open items.",
  "turn_kind": "assistant_reply",
  "message_class": "assistant_reply",
  "sent_at": "2026-05-26T09:45:03Z",
  "delivery_state": "delivered",
  "run_id": "run-uuid",
  "actions": [],
  "linked_todo": null,
  "structured_data": {}
}
```

For approval prompts, `actions` must be native-action metadata rather than Telegram callback markup:

```json
{
  "turn_kind": "approval_prompt",
  "message_class": "approval_prompt",
  "actions": [
    {
      "id": "prepared-action-uuid",
      "kind": "prepared_action_decision",
      "label": "Confirm",
      "decision": "confirm",
      "style": "primary"
    },
    {
      "id": "prepared-action-uuid",
      "kind": "prepared_action_decision",
      "label": "Cancel",
      "decision": "reject",
      "style": "destructive"
    }
  ]
}
```

### 7.1 List Threads

```http
GET /api/mobile/chat/threads?limit=50&cursor=<opaque>
Authorization: Bearer <session_token>
```

Response:

```json
{
  "threads": [
    {
      "id": "conversation-uuid",
      "title": "Prep me for Matthew",
      "status": "open",
      "last_turn_at": "2026-05-26T09:45:00Z",
      "updated_at": "2026-05-26T09:45:00Z",
      "message_count": 6,
      "latest_message": {
        "id": "turn-uuid",
        "role": "assistant",
        "body": "Matthew is waiting on setup path, pricing owner, and ETA.",
        "sent_at": "2026-05-26T09:45:00Z"
      }
    }
  ],
  "next_cursor": null
}
```

### 7.2 Create Thread

```http
POST /api/mobile/chat/threads
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "thread": {
    "client_thread_id": "ios-generated-uuid",
    "title": "New conversation"
  }
}
```

Response: `201 Created`

```json
{
  "thread": {
    "id": "conversation-uuid",
    "title": "New conversation",
    "status": "open",
    "messages": []
  }
}
```

### 7.3 Get Thread

```http
GET /api/mobile/chat/threads/:id
Authorization: Bearer <session_token>
```

Response:

```json
{
  "thread": {
    "id": "conversation-uuid",
    "title": "Hey",
    "status": "open",
    "pending_run": {
      "id": "run-uuid",
      "status": "running",
      "started_at": "2026-05-26T09:45:00Z"
    },
    "messages": [
      {
        "id": "turn-uuid",
        "client_message_id": "ios-message-uuid",
        "role": "user",
        "body": "Hey",
        "turn_kind": "user_message",
        "message_class": null,
        "sent_at": "2026-05-26T09:45:00Z",
        "delivery_state": "sent",
        "structured_data": {}
      },
      {
        "id": "turn-uuid",
        "role": "assistant",
        "body": "What would you like to work through?",
        "turn_kind": "assistant_reply",
        "message_class": "assistant_reply",
        "sent_at": "2026-05-26T09:45:03Z",
        "delivery_state": "delivered",
        "structured_data": {
          "run_id": "run-uuid"
        }
      }
    ]
  }
}
```

### 7.4 Send Message

```http
POST /api/mobile/chat/threads/:id/messages
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "message": {
    "client_message_id": "ios-message-uuid",
    "body": "What todos are open?",
    "reply_to_message_id": null
  }
}
```

Response: `202 Accepted`

```json
{
  "thread": {
    "id": "conversation-uuid",
    "title": "What todos are open?",
    "status": "open",
    "messages": [
      {
        "id": "turn-uuid",
        "client_message_id": "ios-message-uuid",
        "role": "user",
        "body": "What todos are open?",
        "delivery_state": "sent",
        "sent_at": "2026-05-26T09:45:00Z"
      }
    ]
  },
  "run": {
    "id": "run-uuid",
    "status": "queued"
  }
}
```

If the assistant completes before the HTTP response deadline, the endpoint may return `200 OK` with the assistant turn included. The client must support both `200` and `202`.

### 7.5 Get Run

```http
GET /api/mobile/chat/runs/:id
Authorization: Bearer <session_token>
```

Response:

```json
{
  "run": {
    "id": "run-uuid",
    "thread_id": "conversation-uuid",
    "status": "completed",
    "started_at": "2026-05-26T09:45:00Z",
    "finished_at": "2026-05-26T09:45:05Z",
    "error": null
  }
}
```

### 7.6 Confirm Or Reject Prepared Action

```http
POST /api/mobile/chat/prepared-actions/:id/decision
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "decision": "confirm",
  "client_message_id": "ios-decision-message-uuid"
}
```

Allowed `decision` values:

| Value | Meaning |
|---|---|
| `confirm` | Execute the prepared action. |
| `reject` | Cancel the prepared action. |

Response:

```json
{
  "prepared_action": {
    "id": "prepared-action-uuid",
    "status": "executed"
  },
  "thread": {
    "id": "conversation-uuid",
    "messages": [
      {
        "role": "assistant",
        "turn_kind": "action_result",
        "body": "Created the todo."
      }
    ]
  }
}
```

### 7.7 Error And Status Codes

| Status | Error code | Trigger |
|---|---|---|
| `200 OK` | none | Thread/run/action request completed synchronously or poll returned current state. |
| `201 Created` | none | Thread created. |
| `202 Accepted` | none | Message accepted and assistant run queued/running. |
| `400 Bad Request` | `invalid_request` | Malformed JSON or unsupported decision value. |
| `401 Unauthorized` | `unauthorized` | Missing/expired mobile session. |
| `404 Not Found` | `not_found` | Thread/run/prepared action absent or belongs to another user. |
| `409 Conflict` | `assistant_run_in_progress` | New message attempts to start while the thread already has a non-terminal run. |
| `410 Gone` | `prepared_action_expired` | User tries to confirm/reject an expired action. |
| `422 Unprocessable Entity` | `message_too_long`, `missing_client_message_id`, `empty_message` | Validation failures. |
| `429 Too Many Requests` | `rate_limited` | Per-user burst or abuse protection. |
| `503 Service Unavailable` | `assistant_unavailable` | Assistant disabled or provider unavailable before a run can be queued. |

`409 assistant_run_in_progress` should include the active run and current thread snapshot so iOS can keep polling instead of losing user context.

## 8. Backend Implementation Plan

### 8.1 Add Mobile Chat Controller

New modules:

| Module | Responsibility |
|---|---|
| `MaraithonWeb.MobileChatController` | HTTP endpoints for threads, messages, runs, and prepared-action decisions. |
| `MaraithonWeb.MobileChatJSON` | JSON serialization for threads, turns, runs, prepared actions, and errors. |
| `Maraithon.AssistantChat` | Surface-neutral orchestration boundary. |
| `Maraithon.AssistantChat.MobileDelivery` | Persist/return mobile assistant turns without Telegram Bot API calls. |
| `Maraithon.AssistantChat.TelegramDelivery` | Thin wrapper around the current Telegram delivery behavior. |

### 8.2 Add Routes

In `MaraithonWeb.Router`:

```elixir
scope "/api/mobile", MaraithonWeb do
  pipe_through [:api, :mobile_api_auth]

  get "/chat/threads", MobileChatController, :index
  post "/chat/threads", MobileChatController, :create
  get "/chat/threads/:id", MobileChatController, :show
  post "/chat/threads/:id/messages", MobileChatController, :create_message
  get "/chat/runs/:id", MobileChatController, :show_run
  post "/chat/prepared-actions/:id/decision", MobileChatController, :decide_prepared_action
end
```

### 8.3 Refactor Assistant Delivery

Current hard coupling:

```text
Runner -> TelegramAssistant.send_turn -> TelegramResponder -> Telegram API
```

Target:

```text
Runner -> AssistantChat.deliver_turn(surface_adapter, conversation, text, opts)
```

For Telegram, behavior remains the same. For mobile, delivery appends the turn and returns it for JSON/polling.

Implementation detail:

1. Add `surface` and `delivery_module` to the runner attrs/context.
2. Keep `TelegramAssistant.handle_inbound/1` for Telegram, but add `AssistantChat.run_inbound/1` for mobile that calls the same runner with `surface: "mobile"`.
3. Extract runner delivery helpers:

```elixir
defp deliver_turn(runtime_context, conversation, text, opts) do
  runtime_context.delivery_module.deliver_turn(conversation, text, opts)
end
```

4. Replace every final-response `TelegramAssistant.send_turn(...)` call in the runner with `deliver_turn(...)`.
5. Preserve `TelegramAssistant.send_turn/4` as a Telegram-specific implementation used by `TelegramDelivery`.
6. For mobile todo digests, do not call `TodoActions.telegram_payload/1`; serialize todo data into `structured_data["linked_todo"]` and an `actions` array that iOS can render with native controls.

The runner must keep producing the same `message_class` values (`assistant_reply`, `todo_digest`, `approval_prompt`, `action_result`, `system_notice`) so existing assistant behavior remains comparable across surfaces.

### 8.4 Preserve Existing Telegram Behavior

Telegram behavior must remain unchanged:

- Same webhook path.
- Same per-chat worker serialization.
- Same Telegram message delivery.
- Same confirmation callbacks.
- Same todo review behavior.
- Same verification task behavior.

Implement this by keeping `TelegramRouter.handle_message(...)` as the Telegram ingress, but route final delivery through `TelegramDelivery`.

### 8.5 Prepared Actions And Policy Surface

Prepared actions currently work for Telegram callbacks and text confirmations. Mobile needs the same policy without Telegram callback ids.

Required refactor:

| Current behavior | Required mobile-safe behavior |
|---|---|
| `TelegramAssistant.handle_prepared_action_decision/5` expects Telegram callback/message ids. | Add `AssistantChat.decide_prepared_action/4` that accepts `user_id`, action id, decision, and optional client message id. |
| `TelegramAssistant.respond_to_prepared_action/6` sends result through `send_turn(...)`. | Move shared decision/execution/result-turn logic into a surface-aware helper using the selected delivery module. |
| `Runner.execute_tool_action/3` hardcodes `surface: "telegram"`. | Use `prepared_action.surface || runtime_context.surface || "telegram"` when building `policy_context`. |
| Approval prompts use Telegram inline keyboard markup. | Mobile JSON exposes native action descriptors; Telegram delivery still uses inline keyboard markup. |

Mobile decision flow:

1. Controller validates session and scopes prepared action by `user_id`.
2. If expired, mark expired and return `410 prepared_action_expired` plus thread snapshot.
3. If `reject`, mark rejected, reopen the conversation, and persist a system/action-result turn through `MobileDelivery`.
4. If `confirm`, mark confirmed, execute with `surface: "mobile"` policy context, mark executed/failed, and persist an action-result turn.
5. Return prepared-action status and refreshed thread.

### 8.6 Idempotency

Mobile sends must include `client_message_id`. Backend must store it in `structured_data` on the user turn:

```json
{
  "surface": "mobile",
  "client_message_id": "ios-message-uuid"
}
```

Backend must also store `client_message_id` in the new concrete `telegram_conversation_turns.client_message_id` column. The JSON copy in `structured_data` is useful for old tooling and debug exports, but the column/index is the source of truth.

Before inserting a new user turn, backend must check for an existing turn in the same conversation with the same `client_message_id`, then rely on the DB unique index as the final guard:

```elixir
Repo.transaction(fn ->
  conversation = lock_conversation!(user_id, thread_id)

  case find_turn_by_client_message_id(conversation.id, client_message_id) do
    %Turn{} = existing -> {:duplicate, existing, active_or_latest_run(conversation)}
    nil -> insert_turn_and_enqueue_run(conversation, attrs)
  end
end)
```

If found:

- Return the existing turn.
- Return the current pending/completed run.
- Do not enqueue a second assistant run.
- Do not execute tools again.

### 8.7 Thread Worker And Run Serialization

The controller must not run the LLM loop inline. It should enqueue the work and return quickly.

Recommended worker behavior:

| Step | Behavior |
|---|---|
| Start | `AssistantChat.ThreadWorker.enqueue(user_id, conversation_id, run_request)` starts or locates the worker through Registry. |
| Serialization | Worker processes one message at a time for that conversation. |
| Run creation | Run row is created before returning `202`, with `status: "queued"` or existing runner `running` status. |
| Run execution | Worker calls the existing runner with `%{surface: "mobile", delivery_module: MobileDelivery, conversation: conversation, user_turn: user_turn}`. |
| Completion | Worker updates `telegram_assistant_runs.status`, result summary, and conversation metadata. |
| Failure | Worker persists a visible `system_notice`/failure turn and marks run `degraded` or `failed`. |
| Shutdown | Worker can stop after idle timeout; state is durable in DB. |

If the existing application supervisor already has a dynamic-worker pattern for Telegram chat, mirror it. If not, add only the smallest `DynamicSupervisor` + `Registry` needed for mobile thread serialization.

### 8.8 Rate Limiting

Mirror Telegram's general chat protections for mobile:

| Rule | Requirement |
|---|---|
| Per-user burst | Limit rapid sends to prevent duplicate LLM/tool runs. |
| Per-thread serialization | Only one active assistant run per thread unless explicitly allowed. |
| Duplicate request | Deduplicate by `client_message_id`. |
| Long-running run | Return `409 conflict` or `202 accepted` with existing active run if user sends another message before completion. |

Recommended v1 behavior for an active run:

```json
{
  "error": "assistant_run_in_progress",
  "run": {
    "id": "run-uuid",
    "status": "running"
  }
}
```

### 8.9 Backend File-Level Worklist

| File/module | Change |
|---|---|
| `lib/maraithon_web/router.ex` | Add mobile chat routes under authenticated mobile scope. |
| `lib/maraithon_web/controllers/mobile_chat_controller.ex` | New controller with index/create/show/send/run/action endpoints. |
| `lib/maraithon_web/controllers/mobile_chat_json.ex` | New serializers; keep `MobileJSON` focused on auth/todos/people or delegate shared helpers. |
| `lib/maraithon/assistant_chat.ex` | New facade and orchestration API. |
| `lib/maraithon/assistant_chat/mobile_delivery.ex` | New persist-only delivery adapter. |
| `lib/maraithon/assistant_chat/telegram_delivery.ex` | New wrapper preserving existing Telegram behavior. |
| `lib/maraithon/assistant_chat/thread_worker.ex` | New per-thread worker. |
| `lib/maraithon/telegram_assistant/runner.ex` | Inject surface/delivery context; remove hardcoded Telegram delivery/action policy from shared paths. |
| `lib/maraithon/telegram_assistant.ex` | Keep Telegram-specific send/callback helpers; extract reusable prepared-action decision pieces as needed. |
| `lib/maraithon/telegram_conversations.ex` | Add find/list helpers for mobile threads and client-message id lookup. |
| Ecto schemas/migrations | Add `surface`, `client_message_id`, `delivery_state`, indexes, validations. |

## 9. iOS Implementation Plan

### 9.1 Replace Local Final Responses

`ChatDetailView.send(...)` must stop using `ChatResponder.response(...)` in signed-in production. The local responder can remain only for previews/tests/offline demo mode.

Target flow:

1. User taps send.
2. App creates a local optimistic user message with `deliveryState = sending`.
3. App calls `MobileAPIClient.sendChatMessage(...)`.
4. App marks the user message as `sent`.
5. App stores `pendingRunID`.
6. App shows a typing/pending assistant row.
7. App polls `getChatThread(...)` or `getChatRun(...)`.
8. App merges assistant turns into SwiftData.
9. App removes pending row when run completes/fails.

### 9.2 Add API Methods

In `MobileAPIClient`:

| Method | Endpoint |
|---|---|
| `listChatThreads(sessionToken:)` | `GET /chat/threads` |
| `createChatThread(sessionToken:title:clientThreadID:)` | `POST /chat/threads` |
| `getChatThread(sessionToken:id:)` | `GET /chat/threads/:id` |
| `sendChatMessage(sessionToken:threadID:clientMessageID:body:replyToMessageID:)` | `POST /chat/threads/:id/messages` |
| `getChatRun(sessionToken:id:)` | `GET /chat/runs/:id` |
| `decidePreparedAction(sessionToken:id:decision:clientMessageID:)` | `POST /chat/prepared-actions/:id/decision` |

Add remote DTOs next to the current `RemoteTodo`/`RemotePerson` types or in a focused chat extension file:

```swift
struct RemoteChatThread: Decodable, Equatable, Identifiable { ... }
struct RemoteChatMessage: Decodable, Equatable, Identifiable { ... }
struct RemoteChatRun: Decodable, Equatable, Identifiable { ... }
struct RemoteChatAction: Decodable, Equatable, Identifiable { ... }
```

`MobileAPIClient` is currently `@MainActor` and uses `URLSession.data(for:)`, shared decoder conventions, the configured production base URL, and Bearer auth. Keep those conventions. Do not introduce a third-party networking library for this.

### 9.3 Add Repository Layer

New iOS type:

```swift
@MainActor
struct ChatSyncService
```

Responsibilities:

- Convert remote thread/message DTOs to SwiftData models.
- Own optimistic-send state transitions.
- Own polling loop cancellation.
- Deduplicate remote messages by remote id/client id.
- Hide raw API details from SwiftUI views.

`ChatDetailView` should call `ChatSyncService`, not `MobileAPIClient` directly.

Recommended public API:

```swift
@MainActor
protocol ChatProviding {
    func refreshThreads(modelContext: ModelContext, sessionStore: SessionStore) async throws
    func refreshThread(_ thread: ChatThread, modelContext: ModelContext, sessionStore: SessionStore) async throws
    func send(_ body: String, in thread: ChatThread, modelContext: ModelContext, sessionStore: SessionStore) async throws
    func decidePreparedAction(_ actionID: UUID, decision: ChatActionDecision, in thread: ChatThread, modelContext: ModelContext, sessionStore: SessionStore) async throws
}
```

Implementations:

| Type | Use |
|---|---|
| `ProductionChatProvider` or `ChatSyncService` | Production app runtime; calls `MobileAPIClient`. |
| `LocalChatProvider` | Previews/tests only; can use `ChatResponder` but must not be injected for signed-in production app launch. |

The simplest dependency injection path is to initialize the provider inside Chat views/services from app configuration, matching how `ProductionMagicAuthProvider` owns `MobileAPIClient`. If dependency injection grows, add an environment value later; do not add a broad app-wide service container for this single feature.

### 9.4 Extend SwiftData Models

Add optional remote/sync fields:

`ChatThread`

| Field | Type | Purpose |
|---|---|---|
| `remoteID` | `UUID?` | Production conversation id. |
| `syncStatusRawValue` | `String` | `local`, `syncing`, `synced`, `failed`. |
| `pendingRunID` | `UUID?` | Active assistant run. |
| `lastSyncedAt` | `Date?` | Sync freshness. |

`ChatMessage`

| Field | Type | Purpose |
|---|---|---|
| `remoteID` | `UUID?` | Production turn id. |
| `clientMessageID` | `UUID?` | Idempotency key generated by app. |
| `deliveryStateRawValue` | `String` | `sending`, `sent`, `delivered`, `failed`. |
| `turnKind` | `String?` | `assistant_reply`, `approval_prompt`, `action_result`, etc. |
| `messageClass` | `String?` | Backend assistant message class. |
| `structuredData` | `Data?` | JSON payload for action prompts/cards. |

Keep existing local `id` fields to avoid breaking SwiftData identity. `remoteID` is the production identity.

Schema notes:

| Requirement | Detail |
|---|---|
| Optional fields only | Add nullable/optional model fields so old local demo data can still open. |
| Enum wrappers | Add small `ChatSyncStatus`, `ChatDeliveryState`, and `ChatActionDecision` enums around raw strings. |
| Data encoding | Store `structuredData` as JSON `Data` for flexibility, but expose decoded helpers for `runID`, `linkedTodo`, and `actions`. |
| Migration | Because this app is still early and uses SwiftData without custom migration plans, prefer additive optional fields and test launch against existing simulator data. |
| Local identity | Never replace local `UUID id` with remote ids. Use `remoteID` for merge/dedupe only. |

### 9.5 UI Behavior

| State | UI behavior |
|---|---|
| Sending user message | Show user bubble immediately with subtle pending indicator if network has not acknowledged. |
| Assistant running | Show a left-aligned "thinking" or typing bubble. |
| Assistant completed | Replace pending row with remote assistant message(s). |
| Assistant failed | Show a retryable system/assistant bubble: "I couldn't reach Maraithon. Try again." |
| Confirmation required | Show assistant prompt with Confirm and Cancel buttons. |
| Offline/no session | Disable send or show sign-in/session error; do not produce fake final responses. |

The visual design remains the current Telegram-like chat shell. This spec changes the data source and state handling, not the overall chat layout.

### 9.6 Telegram-Like Native Interaction Details

The chat pane should feel like a modern native messenger while staying Apple-native:

| Interaction | Requirement |
|---|---|
| Send | Return key/send button sends, clears composer immediately, keeps keyboard focus, scrolls to bottom. |
| Optimistic state | User bubble appears immediately. If network fails, bubble remains with retry affordance. |
| Assistant pending | Pending row is visually distinct from a final assistant message and does not fake text content. |
| Actions | Approval prompts show native inline Confirm/Cancel buttons in or directly under the assistant bubble. |
| Todo items | Todo digest turns can render compact linked todo rows/cards, but no card nesting and no Telegram HTML. |
| Offline/session expired | Composer becomes disabled with a concise sign-in/session message. No local fake final answer. |
| Dynamic Type | Bubbles and composer grow naturally; fixed-size controls remain icon-only and accessible. |
| Liquid Glass | Composer chrome and icon controls use the shared design-system glass helpers. The message list remains content-first, legible, and not over-materialized. |

### 9.7 iOS File-Level Worklist

| File/module | Change |
|---|---|
| `MaraithonMobile/Core/API/MobileAPIClient.swift` | Add chat DTOs/methods or split into `MobileAPIClient+Chat.swift` if project organization supports it. |
| `MaraithonMobile/Core/Models/ChatThread.swift` | Add remote/sync fields and enum wrappers. |
| `MaraithonMobile/Core/Models/ChatMessage.swift` | Add remote/client/delivery/kind/class/structured-data fields. |
| `MaraithonMobile/Features/Chat/ChatSyncService.swift` | New sync/orchestration layer. |
| `MaraithonMobile/Features/Chat/ChatThreadsView.swift` | Refresh remote threads on signed-in appear; merge remote state. |
| `MaraithonMobile/Features/Chat/ChatDetailView.swift` | Replace direct `ChatResponder` send path with `ChatSyncService`; manage polling task cancellation. |
| `MaraithonMobile/Features/Chat/MessageBubble.swift` | Render delivery state, pending rows, failure/retry, linked todo/action metadata. |
| `MaraithonMobileUITests/ProductionIntegrationUITests.swift` | Add chat send and chat-driven todo mutation verification. |
| `scripts/verify-production-simulator.sh` | Add live API assertions for mobile chat turns/runs and created todo. |

## 10. Data Mapping

### 10.1 Backend Conversation To Mobile Thread

| Backend | Mobile |
|---|---|
| `Conversation.id` | `ChatThread.remoteID` |
| `Conversation.summary` or first user text | `ChatThread.title` |
| `Conversation.status` | thread status/sync metadata |
| `Conversation.surface` | Must equal `mobile` for mobile-created threads. |
| `Conversation.last_turn_at` | `ChatThread.updatedAt` |
| `Conversation.metadata["last_mobile_run_id"]` | `ChatThread.pendingRunID` |
| `Conversation.metadata["client_thread_id"]` | Local bootstrap mapping before remote id is known. |

### 10.2 Backend Turn To Mobile Message

| Backend | Mobile |
|---|---|
| `Turn.id` | `ChatMessage.remoteID` |
| `Turn.role` | `ChatMessage.role` |
| `Turn.text` | `ChatMessage.body` |
| `Turn.inserted_at` | `ChatMessage.sentAt` |
| `Turn.turn_kind` | `ChatMessage.turnKind` |
| `Turn.origin_type` | `ChatMessage.messageClass` or structured metadata |
| `Turn.client_message_id` | `ChatMessage.clientMessageID` |
| `Turn.delivery_state` | `ChatMessage.deliveryStateRawValue` |
| `Turn.structured_data` | `ChatMessage.structuredData` |

### 10.3 Backend Run To Mobile Pending State

| Backend | Mobile |
|---|---|
| `Run.id` | `ChatThread.pendingRunID` while non-terminal. |
| `Run.status` | Pending/completed/failed UI state. |
| `Run.result_summary["message_class"]` | Debug metadata and production verification assertion. |
| Latest `Step.step_type/tool` | Optional safe progress text; never expose raw private arguments in UI. |

Terminal statuses for mobile polling are `completed`, `degraded`, `failed`, and `waiting_confirmation`. `waiting_confirmation` can be represented by either a run status or by thread status `awaiting_confirmation` plus an approval prompt turn; the API should normalize it as `run.status = "waiting_confirmation"` for iOS.

## 11. Error Handling

| Case | Backend | iOS |
|---|---|---|
| Invalid/expired session | `401 unauthorized` | Route to sign-in or show session expired. |
| Thread not found | `404 not_found` | Remove local remote mapping or show deleted state. |
| Active run in thread | `409 assistant_run_in_progress` or `202 existing run` | Keep pending state, do not duplicate send. |
| Assistant timeout | Persist failure turn, run status `failed`/`degraded` | Show retryable assistant bubble. |
| Tool requires confirmation | Persist approval prompt and prepared action | Show Confirm/Cancel buttons. |
| Confirm expired action | `410 prepared_action_expired` | Replace buttons with expired state. |
| Network offline | No backend mutation | Keep failed local user bubble with retry. |
| Duplicate send retry | Return existing turn/run | Merge by client id and do not append a second local bubble. |
| App killed while run active | Durable run/turns remain in backend | On next open, refresh thread and resume polling if run is non-terminal. |
| User signs out mid-run | Backend run may continue | Clear local session; do not poll without token; thread returns on next sign-in refresh. |

## 12. Security And Privacy

- Mobile chat endpoints must require mobile session auth.
- Backend must derive user id from authenticated session.
- Thread ids must be scoped to the current user.
- Prepared action ids must be scoped to the current user before execution.
- Do not accept arbitrary `chat_id` from mobile clients.
- Do not expose Telegram message ids unless they already exist as generic remote message ids in structured data.
- Preserve existing write-tool confirmation policy.
- Redact sensitive message text in logs using existing redaction helpers where available.
- Do not request iOS Contacts, Microphone, Photos, Location, or Push permissions for this feature in v1.
- Treat chat transcripts as user content. Avoid analytics payloads containing raw message bodies unless there is an existing explicit diagnostic path with redaction.
- Do not store production session tokens anywhere except the existing authenticated-user persistence path.
- Add App Store review notes/demo credentials only through release process, not source files.

## 13. Observability

Add telemetry/log events:

| Event | Metadata |
|---|---|
| `[:maraithon, :mobile_chat, :message_received]` | user_id, thread_id, client_message_id |
| `[:maraithon, :mobile_chat, :run_started]` | user_id, thread_id, run_id |
| `[:maraithon, :mobile_chat, :run_completed]` | user_id, thread_id, run_id, duration_ms, message_class |
| `[:maraithon, :mobile_chat, :run_failed]` | user_id, thread_id, run_id, reason |
| `[:maraithon, :mobile_chat, :prepared_action_decision]` | user_id, prepared_action_id, decision |

The production verification script should print the run id and final assistant message class so failures are diagnosable.

Operational logs should include ids and statuses but not raw user message bodies by default:

```text
mobile_chat run_completed user_id=<id> thread_id=<uuid> run_id=<uuid> status=completed message_class=todo_digest duration_ms=4312
```

If a model/tool loop is stopped, preserve the existing `ActionLedger` uncertainty recording, but use `surface: "mobile"` for mobile-originated runs.

## 14. Test Strategy

### 14.1 Backend Unit Tests

- `MobileChatControllerTest`
  - requires mobile auth;
  - lists only current user's threads;
  - creates a thread;
  - sends a message;
  - deduplicates repeated `client_message_id`;
  - rejects cross-user thread access;
  - handles active run conflict;
  - confirms/rejects prepared actions.

- `AssistantChatTest`
  - creates mobile conversation metadata correctly;
  - routes mobile messages through the assistant runner;
  - mobile delivery appends turns without Telegram API calls;
  - Telegram delivery behavior remains compatible.
  - prepared-action confirmation executes with `surface: "mobile"`;
  - todo digest delivery serializes linked todo/actions without Telegram HTML.

### 14.2 Backend Integration Tests

- Use `TelegramAssistant.VerificationClient` or a deterministic test client to avoid live LLM calls in CI.
- Assert "What todos are open?" uses assistant/tool path, not local canned text.
- Assert "Add reply to Matthew about pricing by Friday" produces either a created todo or a confirmation-required prepared action depending on policy.
- Assert no `TelegramResponder.send/reply/edit/send_chat_action` calls occur for mobile delivery. In tests, configure the Telegram responder/client module to raise if called from a mobile run.
- Assert duplicate `client_message_id` returns one user turn, one run, and one tool side effect.

Recommended deterministic test client script:

| Prompt contains | Test client response |
|---|---|
| `What todos are open?` | Tool call `list_todos`, then assistant reply with `message_class: "todo_digest"`. |
| `Add a todo to verify mobile assistant chat` | Tool call `upsert_todos`, then assistant reply or approval prompt depending on configured write policy. |
| `Send this email` | Prepared action with `message_class: "approval_prompt"`. |

### 14.3 iOS Unit Tests

- `ChatSyncServiceTests`
  - maps remote DTOs to SwiftData models;
  - deduplicates by remote id and client id;
  - handles optimistic send success;
  - handles send failure;
  - handles pending run completion;
  - renders prepared action state.

- `MobileAPIClientTests`
  - encodes chat payloads correctly;
  - decodes thread/run/action responses;
  - handles `401`, `404`, `409`, and `410`.

### 14.4 iOS UI Tests

- Signed-in chat can send a message and receive a non-canned assistant response.
- Pending assistant state appears while waiting.
- Failed send shows retry.
- Confirmation prompt shows Confirm/Cancel buttons when backend returns prepared action.

### 14.5 Production Verification

Extend `scripts/verify-production-simulator.sh`:

1. Sign in as `kent@runner.now`.
2. Open Chat.
3. Create a new thread.
4. Send `What todos are open?`.
5. Wait for assistant reply.
6. Assert the reply is not the canned local fallback:
   - must not equal `Captured. Next best action...`;
   - must include production assistant metadata or a run id;
   - should mention current production todos or return a valid no-todos response.
7. Send a write-intent prompt such as `Add a todo to verify mobile assistant chat <run_id>`.
8. Confirm action if required.
9. Query production `/api/mobile/todos` to assert the todo exists.

Required script additions:

| Script/file | Assertion |
|---|---|
| `MaraithonMobileUITests/ProductionIntegrationUITests.swift` | UI can open Chat, create/send, wait for non-canned assistant response, and handle pending state. |
| `scripts/verify-production-simulator.sh` | After UI test, use fresh production auth token to query mobile chat API for the thread/run/turns. |
| Live `/api/mobile/chat/threads` | Latest thread contains the sent user turn and assistant turn with `run_id`. |
| Live `/api/mobile/todos` | Chat-created verification todo exists, or an approval prompt was confirmed and then the todo exists. |
| Negative assertion | No assistant body equals or contains the local canned fallback prefix `Captured. Next best action`. |

### 14.6 Verification Commands For The Implementation Pass

Backend:

```sh
cd /Users/kent/bliss/maraithon
mix test test/maraithon_web/controllers/mobile_chat_controller_test.exs
mix test test/maraithon/assistant_chat_test.exs
mix test test/maraithon/telegram_assistant_test.exs
```

iOS:

```sh
cd /Users/kent/bliss/maraithon-mobile
xcodegen generate
xcodebuild -quiet -project MaraithonMobile.xcodeproj -scheme MaraithonMobile -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.4.1' build
xcodebuild -quiet -project MaraithonMobile.xcodeproj -scheme MaraithonMobile -destination 'platform=iOS Simulator,id=1B948405-BFB9-4A8F-AE50-7D639732BBF5' test
scripts/verify-production-simulator.sh
```

If the named simulator is unavailable, use `xcrun simctl list devices available` and record the replacement destination in the implementation manifest.

## 15. Rollout Plan

| Phase | Scope | Gate |
|---|---|---|
| 0. Schema/facade prep | Add additive DB fields/indexes, `AssistantChat` facade, and delivery behaviour without changing Telegram behavior. | Existing Telegram/backend tests pass. |
| 1. Backend mobile chat | Add mobile chat API, mobile delivery adapter, thread worker, and prepared-action decision path behind config flag. | Backend chat tests pass with deterministic assistant client. |
| 2. iOS integration | Add remote DTOs, model fields, `ChatSyncService`, polling, pending/failure/action UI. | Build/unit/UI tests pass. |
| 3. Production verification | Extend simulator script to verify real assistant chat and todo side effect. | Production verification passes for `kent@runner.now`. |
| 4. Remove fake production path | Ensure signed-in production cannot call local canned final responses. | Static search and UI/prod verification prove no fake final response. |
| 5. Optional streaming | Add SSE/WebSocket if polling feels too slow. | Separate spec after v1 is stable. |

## 16. Risks And Mitigations

| Risk | Mitigation |
|---|---|
| Runner is tightly coupled to Telegram delivery. | Introduce delivery adapter without changing assistant reasoning/tool logic. |
| Long-running assistant calls exceed mobile request lifetime. | Use async run + polling in v1. |
| Duplicate retries create duplicate todos. | Require `client_message_id` and dedupe before starting runs. |
| Existing Telegram behavior regresses. | Keep Telegram ingress intact and add regression tests around `TelegramRouter`/delivery. |
| Mobile chat exposes write tools too broadly. | Reuse existing confirmation and tool policy checks exactly. |
| SwiftData schema changes cause migration issues. | Add optional fields only; retain local ids. |

## 17. Acceptance Criteria

- Mobile chat no longer uses `ChatResponder.response(...)` for signed-in production sends.
- Production exposes authenticated mobile chat endpoints.
- Mobile messages are persisted as production conversation turns.
- Assistant replies come from the production assistant runner.
- Mobile can display pending, completed, failed, and confirmation-required states.
- Telegram chat behavior remains unchanged.
- Production simulator verification proves:
  - sign-in works;
  - chat message reaches production;
  - assistant response is not canned;
  - at least one mobile chat-driven todo mutation works or reaches explicit confirmation flow.
- Static search proves no signed-in production send path calls `ChatResponder.response(...)`.
- Backend test proves mobile delivery does not call `TelegramResponder`.
- Prepared-action confirmation/rejection works from mobile JSON endpoints and is scoped to the authenticated user.
- A duplicate mobile send with the same `client_message_id` creates no duplicate user turn and no duplicate tool side effect.

## 18. Open Decisions

These decisions are resolved for v1. Reopen only if implementation discovers a hard blocker.

| Decision | v1 choice |
|---|---|
| Polling vs streaming for v1 | Polling. Add streaming later if needed. |
| Rename `TelegramConversations` tables now? | No. Add neutral facade now, migrate names in a later low-risk database cleanup. |
| Allow multiple concurrent runs per thread? | No. Serialize per thread for v1. |
| Keep local chat history offline? | Yes, but mark unsynced/failed; never invent final assistant answers in production. |
| Mobile title generation | Backend should return first-message-derived title; iOS can keep local temporary title until sync. |
| Delivery of todo digest | Mobile uses structured linked-todo/action metadata; Telegram keeps HTML/reply markup. |
| Prepared-action policy surface | Use `surface: "mobile"` for mobile-originated confirmations. |

## 18.1 Assumption Ledger

| Assumption | Validation path |
|---|---|
| Existing `telegram_assistant_runs` can safely accept a `surface` field and mobile rows. | Migration/test on local DB; existing Telegram tests remain green. |
| The current assistant client can be made deterministic in backend tests through existing config seams. | `TelegramAssistant.client_module()` already reads config. |
| Production mobile chat can run under the same Fly app and DB as existing mobile todos/people. | Production verification uses `maraithon.com/api/mobile` and existing magic-token helper. |
| Polling is acceptable for v1 user experience. | Simulator verification checks pending state and response completion under production latency. |
| `ChatResponder` remains useful for tests/previews. | Static app runtime wiring must prove it is not used for signed-in production sends. |

## 19. Definition Of Done For Future Implementation

- Spec reviewed and accepted before code changes.
- Backend mobile chat routes implemented and covered by tests.
- Assistant runner supports mobile delivery without Telegram Bot API calls.
- iOS Chat tab sends through production API.
- Local `ChatResponder` is removed from production send path.
- Light/dark visual smoke still passes.
- Full production simulator verification passes against `maraithon.com` for `kent@runner.now`.
- The final implementation manifest is moved to `done` only after production verification.

## 20. Implementation Review Checklist

Before marking the future implementation done, review the code against this checklist:

| Check | Pass condition |
|---|---|
| No fake production replies | `ChatDetailView` or its replacement has no signed-in production path to `ChatResponder.response(...)`. |
| Surface-neutral backend path | `MobileChatController` calls `AssistantChat`, not Telegram router/controller code. |
| Telegram regression guard | Telegram delivery still reaches `TelegramResponder` and existing Telegram tests pass. |
| Mobile delivery guard | Mobile delivery appends turns and returns JSON without Telegram API calls. |
| Idempotency | DB unique index and app client ids prevent duplicate sends/tool writes. |
| Prepared actions | Confirm/reject paths work with mobile buttons and `surface: "mobile"`. |
| App Store readiness | Production backend is live, auth works, and verification loop passes with a real account. |
| DRY/modular iOS | Views render state; `ChatSyncService` owns sync/poll/merge; API client owns HTTP; models own persistence. |
| Native UX | Composer, toolbar, actions, and pending state use SwiftUI/native controls and remain readable under Dynamic Type/dark mode. |
| Documentation | Manifest records implementation files, verification commands, production run id, and any residual risks. |

## 21. References

Local implementation references:

| Area | Path |
|---|---|
| Current mobile chat send path | `MaraithonMobile/Features/Chat/ChatDetailView.swift` |
| Current local responder | `MaraithonMobile/Features/Chat/ChatResponder.swift` |
| Current mobile API client | `MaraithonMobile/Core/API/MobileAPIClient.swift` |
| Current production verification loop | `scripts/verify-production-simulator.sh` |
| Backend mobile routes | `/Users/kent/bliss/maraithon/lib/maraithon_web/router.ex` |
| Backend mobile auth plug | `/Users/kent/bliss/maraithon/lib/maraithon_web/plugs/require_mobile_session.ex` |
| Production assistant runner | `/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/runner.ex` |
| Telegram delivery and prepared actions | `/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant.ex` |
| Conversation persistence | `/Users/kent/bliss/maraithon/lib/maraithon/telegram_conversations.ex` |

External Apple references checked for this v2 upgrade:

| Topic | Reference |
|---|---|
| iOS 26 design/Liquid Glass | https://developer.apple.com/ios/whats-new/ |
| SwiftUI Liquid Glass custom views | https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views |
| Human Interface Guidelines materials | https://developer.apple.com/design/human-interface-guidelines/materials |
| App Review completeness/privacy | https://developer.apple.com/app-store/review/guidelines/ |
