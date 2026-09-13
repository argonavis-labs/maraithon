# Todo workspace: one next action, one conversation

Date: 2026-09-13
Surface: macOS companion (`apps/companion`), the pushed `TodoWorkspaceView`.
Server: unchanged. The durable `AssistantChat` thread, runs, prepared actions,
and the SSE progress stream already provide everything the client needs.

## Problem

Opening a todo shows a scrolling shelf of everything at once: a generic
"Prepare this for me" button, every suggested action, every draft the assistant
ever produced (the newest expanded with a full editor), then the chat, then a
People sidebar that is usually still loading. The user cannot tell what to do
next, and the chat is squeezed under the shelf.

## Goal

The workspace moves the user to complete the todo. It shows at most two action
cards, one of them open, and a chat pane that feels like a fast session with
Maraithon. Everything else is reachable but quiet.

## Layout

Two columns when the content area is at least 900pt wide, stacked below that.

```
┌ Title                                          [Details] [Done] ┐
│ Messages · Your move · Due Fri                                   │
├──────────────────────────────┬───────────────────────────────────┤
│ Maraithon's read             │ CHAT                              │
│ summary (≤ 68ch)             │                                   │
│ Done when: …                 │        ┌───────────────────────┐  │
│ Your decision: …             │        │ user turn (bubble)    │  │
│                              │        └───────────────────────┘  │
│ NEXT ACTION                  │ Maraithon reply, chromeless prose │
│ ┌──────────────────────────┐ │ ▸ Reviewed calendar, prepared…    │
│ │ [msg] Message Christina  │ │ ● Working… 12s                    │
│ │ To Christina · +1416…    │ │                                   │
│ │ ┌──────────────────────┐ │ │                                   │
│ │ │ editable body        │ │ │                                   │
│ │ └──────────────────────┘ │ │ ┌───────────────────────────────┐ │
│ │ Copy · Open in Messages  │ │ │ Talk to this todo…            │ │
│ │           Cancel  [Send] │ │ │ Return to send        [Send]  │ │
│ └──────────────────────────┘ │ └───────────────────────────────┘ │
│ [gmail] Reply to Michael … ↗ │                                   │
│ PEOPLE  Christina · Michael  │                                   │
└──────────────────────────────┴───────────────────────────────────┘
```

- Work column: flexible width, minimum 420pt. Chat column: 38% of the content
  width clamped to 380–520pt. The chat column is full height with the composer
  pinned at the bottom.
- Stacked mode: the work column scrolls inside the top 45% of the height; the
  chat takes the rest.
- The People sidebar is removed. People become a compact chip row under the
  next action; clicking a chip asks Maraithon about that person in the chat.
- Details (status, priority, due, notes, source context, dismiss, reopen) move
  into a sheet opened from the header. The workflow owner line stays in the
  header with its editor.

## Action plan (client logic, `TodoActionPlan`)

Inputs: the todo (status, `brief.suggested_actions`, `brief.recommendation`)
and the thread messages.

1. **Live reviews**: assistant messages with a `draft_card` whose status is not
   terminal (`Completed, Running, Saving, Could not complete, Sent, Saved to
   calendar, Cancelled, Expired, Sending, Could not send, Check before
   retrying`), newest first. A review the user chose to focus moves to the front.
2. **Suggestions**: `suggested_actions` in server order, minus any suggestion a
   live review already covers (same provider and the person's name appears in
   the card's recipient, recipient name, title, or subject).
3. **Primary slot**: the first live review, open. Otherwise the first
   suggestion as an open card with a Prepare button. Otherwise, for an open
   todo, a Prepare card that sends the generic preparation prompt and shows
   `brief.recommendation` or the recommended move as its subtitle.
4. **Secondary slot**: the next live review as a compact row (title, status,
   Review), otherwise the next suggestion as a compact row. Never shown when
   the primary slot is the generic Prepare card.
5. Closed todos show no cards. The read shows the resolution note instead.

Finished reviews are not cards. They appear only as a muted reference line
under the assistant turn that produced them.

## Chat pane

Ported from the runner-next session transcript, rendered natively:

- **Asymmetric turns.** User turns are a quiet bubble (5% ink fill, 12pt
  radius, right-aligned, at most 80% wide). Assistant turns are chromeless
  prose at full width. No avatars, no dividers. Extra space before a user turn
  (32pt), tight before a reply (10pt).
- **Activity group.** Tool calls on an assistant turn fold into one collapsed
  disclosure: chevron, the server headline (or "Supporting work"), a count
  chip. Expanded rows show status glyph, label, summary, detail.
- **Live run.** One assistant turn at the bottom shows the streamed preview
  text as it arrives, and a working indicator (pulsing dot, "Working… 12s")
  driven by run status and `started_at`, so it cannot flicker when content
  folds away.
- **Card references.** An assistant turn that produced a draft shows a single
  plain-button line: "Review Messages draft" for a live card (focuses it in the
  work column), or "Message to Christina · Sent" muted for a finished one. The
  draft body never renders in the chat.
- **Hidden turns.** The `todo_chat_primer` turn is hidden unless it carries a
  draft card; its summary already leads the work column. Turns with no body,
  no tool calls, and no card are hidden.
- **Timestamps** appear on hover in the turn footer as a caption.
- **Composer.** Hairline card that takes the accent border on focus. Return
  sends, Shift-Return inserts a newline, Command-Return also sends. The text
  stays editable while a run is active. A send during a run is queued locally
  and dispatched when the run finishes; the queued message shows as a shelf
  above the composer with Remove. A failed send keeps the message as a pending
  user turn with Retry.
- The composer takes focus when the workspace opens.

## Header

Title (page title scale), meta line (provider mark and label · workflow or
status · due), owner line with the workflow editor button when a workflow
exists. Right side: Details (secondary) and Done or Reopen (primary). Under the
read, a plain "Open original" link when the source has a destination.

## Data changes (client only)

- `CompanionConversation.Message.sentAt` and `Run.startedAt` decode the fields
  the server already sends.
- `TodoConversationStore` gains `queuedMessage`, `preferredReviewID`, and
  `visibleMessages`. Queue flushing happens where a run transitions from
  active to settled.

## Tokens and components

- New `Tokens.TodoLayout` (in `Tokens+Todo.swift`) holds every numeric value
  for this surface. The obsolete action-shelf tokens leave `Tokens.swift`.
- New shared primitives: `RunnerActivityGroup` (collapsed step list) and
  `RunnerWorkingIndicator` (pulsing dot with elapsed time). Cards use
  `RunnerCard`, `RunnerBadge`, `RunnerButtonStyle`, `SectionHeader`.

## Files

Replace: `TodoWorkspaceView`, `TodoConversationTimeline`.
Add: `TodoWorkspaceHeader`, `TodoWorkColumn`, `TodoActionPlan`,
`TodoReviewCard`, `TodoReviewFields`, `TodoSuggestionCard`, `TodoChatPane`,
`TodoConversationTurnView`, `TodoConversationComposer`, `TodoActionCopy`,
`RunnerActivityGroup`, `RunnerWorkingIndicator`, `Tokens+Todo`.
Remove: `TodoNextActionsView`, `TodoPeopleSidebar`,
`TodoConversationMessageView`, `TodoConversationDraftView`.

## Verification

`make build-companion` (compile) and a DEBUG self-snapshot of the workspace
against production with `MARAITHON_SNAPSHOT_PATH`. No tests are run under the
current development mode.

## Out of scope

Server ranking of suggested actions, the calendar block endpoint the web uses,
restyling the stock Details form, and multi-session threads per todo.
