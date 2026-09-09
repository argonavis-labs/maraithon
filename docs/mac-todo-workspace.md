# Mac todo workspace

Opening a todo title (or pressing Return on the selected row) opens a workspace.
The todo and completion controls stay above suggested next actions. Conversation
history sits below, with a resizable People sidebar on the right. The sidebar can
switch to source details. Each todo retains its conversation, unsent composer
text, and edited drafts while navigating between todos in the same Todos view.

People and suggestions are authored by the existing durable todo brief job
(version 8). The brief reads the original source and candidate CRM profiles;
first-name matches retrieve candidates, while the model must identify actual
participants from evidence. Suggestions describe specific supporting work and
are not hardcoded to any person or source. Opening a todo enqueues missing/stale
brief work; the workspace refreshes until that brief arrives.

## Actions and conversation

Runner's action-card system is the interaction reference:
`docs/architecture/action-card-system.md`, `ActionCardChrome.tsx`, and its
Email, Messaging, and Google Calendar body views in `~/bliss/runner`.
Maraithon uses native SwiftUI views and its existing prepared-action lifecycle.
It does not import Runner's Electron runtime or introduce a second coordinator.

- Gmail and Slack expose recipient/account context and editable message content.
- Calendar exposes the proposed title, start, end, and time zone for review.
  Current calendar tools create a time block on the connected primary Google
  Calendar; they do not add guests or send invitations.
- Messages drafts require an actual user-scoped People contact or source-message
  handle. An editable draft opens the native Messages composer through
  `NSSharingService.composeMessage`; this is not recorded as delivery.
- Suggested browser work uses the paired Mac’s persistent background Chrome through `todo_browser`. See `docs/todo-browser-workspace.md`.
- Conversational supporting actions keep the parent todo open. Completion stays
  a distinct user control or existing evidence-backed completion process.

The existing `AssistantChat` thread worker, durable runs, and recovery mechanisms
own model work. The Mac observes the same thread used by mobile. A dropped read
backs off; retrying an unconfirmed message reuses its original client message ID.
Action timeouts reconcile the same prepared action instead of assuming failure.
No provider action executes merely because a card appears.

The linked-todo tool catalog includes source reads and draft/calendar preparation.
Person context includes direct Gmail and Slack reads. A rejected unknown-tool
batch gets one model correction against the same catalog and wall-clock deadline;
no rejected tool is executed and the retry cannot expand permissions. Todo chat
allows up to 8 model turns and 12 tool steps within 120 seconds for source lookup,
recipient resolution, and preparation.

The native list treats view cancellation as cancellation, so auth/navigation
recreation during launch does not strand it on a false network error.

Authenticated app preparation is independent of the Telegram/provider feature
default. Explicit disable settings still apply. Failed preparation is reconciled
against tool outcomes before a response can claim that an action is ready.

Google action cards identify the account and expose an incremental consent link
when write access is missing. Gmail requests readonly plus compose (drafts and
sending); calendar uses the existing event-write grant. Previously granted
scopes are retained. Draft text remains editable in Maraithon when saving to
Gmail fails. A saved-draft send proposal must first verify the draft in Gmail.
Consent does not send a message or book an event; those remain separate reviews.
Draft diagnostics use JSON strings so the bounded tool-result guard retains the
draft instead of discarding it because of atom or tuple status values.

## Manual checks

The signed Mac app was exercised against production with the Michael/Christina
todo: source-backed relationship answers, an editable verified-recipient
Messages draft, native Messages review (cancelled without sending), persistent
chat history after app restart, and a calendar preview with exact time and zone.
The todo remained open throughout. An email preview exposed a false saved-draft
claim; direct Gmail inspection found no saved draft, motivating the provider
verification and local-draft recovery above. No email or calendar write was
executed during verification.

The final live check retained the editable Michael email after Gmail rejected
the save, showed the correct account and consent link, and disabled preparation
until permission is granted. Edited text and an unsent composer survived Back
and reopen. Expanding a review now allocates space explicitly; the previous
geometry preference left cards clipped in a short shelf. Both the original
checkout's Phoenix and Swift builds passed after merging the conversation work.

Google consent reaches an unverified-app warning requiring the user's review.
The account remains read-only; actual Gmail sending and calendar booking await
that consent. Calendar proposals expire normally and can be prepared again.

## Paired-device API

The companion bearer routes reuse the mobile controllers and authenticated user:

- `POST /api/v1/companion/todos/:id/chat`
- `GET /api/v1/companion/chat/threads/:id`
- `POST /api/v1/companion/chat/threads/:thread_id/messages`
- `GET /api/v1/companion/chat/runs/:id`
- `POST /api/v1/companion/chat/prepared-actions/:id/decision`

Existing todo details expose `brief.people` and `brief.suggested_actions` as
optional fields. Old clients remain compatible. Server deployment precedes the
signed companion installation.
