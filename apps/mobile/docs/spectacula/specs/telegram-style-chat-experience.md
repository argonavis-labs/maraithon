# Telegram-Style Chat Experience Specification

Status: Complete v1
Purpose: Make the SwiftUI Chat tab feel like a real mobile messenger, using Telegram as the interaction benchmark while preserving Maraithon's local assistant behavior.
Audience: Engineering and product review.

## 1. Overview and Goals

The current Chat tab has persistent threads, message bubbles, a composer, and deterministic assistant responses. It does not yet feel like a primary messaging surface because new chats do not open immediately, thread rows are sparse, quick prompts occupy composer space, and message bubbles do not group or carry timestamp context like a modern messenger.

This upgrade makes the Chat tab conversation-first and thumb-friendly without adding backend chat, push messaging, accounts beyond the existing signed-in session, or a third-party UI framework.

### 1.1 Goals

| Goal | Requirement |
|---|---|
| Telegram-like flow | Creating a new chat immediately navigates into the conversation and focuses the message field. |
| Conversation density | Thread rows show an avatar, title, latest message preview, and relative timestamp. |
| Messenger bubble behavior | Messages align by sender, visually group adjacent messages, show day separators, and expose timestamps without role labels taking vertical space. |
| Ergonomic composer | Composer is pinned in the bottom safe area, supports multi-line text, send button state, prompt menu, and keyboard-safe scrolling. |
| Native behavior | Use SwiftUI, SwiftData, SF Symbols, context menus, safe area insets, and system materials. |
| Testability | Keep timeline grouping rules in a pure helper covered by unit tests. |

## 2. Current-State Context

Current files:

| File | Current behavior |
|---|---|
| `ChatThreadsView` | Lists threads, can create a thread, but creation does not navigate into the new chat. |
| `ChatThreadRow` | Shows title, relative updated date, and latest message preview. |
| `ChatDetailView` | Shows all messages in a scroll view, quick prompt chips above the composer, and sends deterministic assistant replies. |
| `MessageBubble` | Aligns user messages right and assistant messages left, but shows role labels on every message and does not group bubbles. |
| `ChatThreadNaming` | Generates a title from the first user message. |
| `ChatResponder` | Produces a deterministic assistant response from local todo/person counts. |

## 3. UX Contract

### 3.1 Thread List

- The Chat tab remains a top-level tab.
- Rows must resemble a messaging inbox:
  - circular avatar with initials or symbol;
  - title on the first line;
  - latest message preview on the second line;
  - relative timestamp trailing on the first line;
  - no marketing copy or explanatory UI when threads exist.
- Tapping a row opens the thread.
- Tapping the compose button creates a new empty thread, saves it, navigates into it, and focuses the composer.
- Deleting a thread from the list remains supported.

### 3.2 Conversation Detail

- The conversation occupies the full screen above a bottom composer.
- The scroll view starts at the bottom on appear and after send.
- Pulling/scrolling dismisses the keyboard interactively.
- Messages render in chronological order.
- Day separators appear before the first message of each calendar day.
- Adjacent messages from the same role on the same day are grouped:
  - first/last group state controls bubble corner radii and vertical spacing;
  - repeated role labels are not shown.
- User messages align trailing with accent-colored bubbles.
- Assistant messages align leading with neutral system bubbles and a compact assistant avatar on the last bubble in a group.
- Message context menu supports Copy and Delete.

### 3.3 Composer

- The composer is pinned with `.safeAreaInset(edge: .bottom)` and uses `.bar` material.
- The text input is a rounded, multi-line field with placeholder "Message".
- The send button is icon-only, disabled when trimmed text is empty, and uses an accessibility label.
- Quick prompts move into a compact menu so the composer does not feel like a form.
- Sending a user message:
  - trims whitespace;
  - clears the draft;
  - appends user and assistant messages;
  - updates `thread.updatedAt`;
  - renames a new conversation from the first user message;
  - scrolls to the bottom.

## 4. Technical Design

### 4.1 Components

| Component | Change |
|---|---|
| `ChatThreadsView` | Switch to value-based navigation using thread IDs so created threads can be opened immediately. |
| `ChatThreadRow` | Add avatar and inbox-style layout. |
| `ChatDetailView` | Move composer to bottom safe area, add focus handling, prompt menu, copy/delete context actions, and timeline rendering. |
| `MessageBubble` | Accept grouping state and render Telegram-like bubbles. |
| `ChatMessageTimeline` | New pure helper that computes day headers and first/last group flags. |
| `AppFormatters` | Add time-only and chat-day formatting helpers. |

### 4.2 Data Model

No schema change is required. Existing `ChatThread` and `ChatMessage` fields are sufficient:

| Model | Used fields |
|---|---|
| `ChatThread` | `id`, `title`, `createdAt`, `updatedAt`, `messages` |
| `ChatMessage` | `id`, `body`, `sentAt`, `role`, `thread` |

## 5. Failure Handling

- If a newly created thread cannot be saved, keep it inserted locally for the current context and avoid crashing.
- If a navigation destination cannot resolve a deleted thread ID, show a native unavailable state.
- Empty drafts do not create messages.
- Copy action writes only the selected message body to the pasteboard.

## 6. Validation Matrix

| Area | Validation |
|---|---|
| Project generation | `xcodegen generate` succeeds after adding source files. |
| Build | App target builds on the configured iOS simulator. |
| Unit tests | Existing tests plus new timeline grouping tests pass. |
| Thread creation | New chat button creates and navigates into a new conversation. |
| Composer | Empty send is disabled; non-empty send appends user and assistant messages. |
| Timeline | Day headers and same-role grouping are deterministic. |
| Simulator | App launches so the Chat tab can be reviewed interactively. |

## 7. Definition of Done

- Spec and manifest are tracked under `docs/spectacula`.
- Chat tab supports immediate new-thread navigation.
- Conversation detail uses grouped bubbles, day separators, context menus, and a bottom safe-area composer.
- Quick prompts are available without taking over the composer.
- Timeline grouping has unit test coverage.
- `xcodegen generate`, build, and relevant tests pass.
- Final review confirms the implementation matches this spec.

## 8. Assumptions

| Assumption | Impact |
|---|---|
| Telegram is the interaction benchmark, not a visual clone. | Use native iOS materials, SF Symbols, and SwiftUI while matching messenger ergonomics. |
| Chat remains local/deterministic for now. | No backend realtime, delivery ticks, media upload, or push notification work in this scope. |
| Existing assistant response behavior remains useful. | Keep `ChatResponder` and improve the chat shell around it. |
