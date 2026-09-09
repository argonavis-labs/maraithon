# Todo progress stream

Status: implemented September 8, 2026.

A todo workspace observes the existing assistant conversation and run. PostgreSQL remains the source of truth for messages, steps, prepared actions and outcomes. Opening or reconnecting a workspace does not start another agent run.

## Contract

Native endpoints:

- `GET /api/v1/mobile/chat/threads/:id/events`, using the existing mobile session.
- `GET /api/v1/companion/chat/threads/:id/events`, using the existing paired-device credential.

Both return `text/event-stream`. UUIDs are normalized before subscribing. Every snapshot is loaded through the existing user-scoped conversation lookup and `MobileChatJSON` public projection.

```text
id: <opaque cursor>
event: snapshot
data: {"schema_version":1,"cursor":"<opaque cursor>","thread":{...}}

```

A snapshot replaces the server-owned conversation state. Local composer drafts and messages awaiting acknowledgment retain their existing retry IDs. The cursor is a SHA-256 digest of the public projection with ephemeral preview and thinking fields removed. Clients must apply a snapshot successfully before retaining its cursor.

A reconnect sends `Last-Event-ID`. A matching cursor receives a `: resumed` comment. A missing or stale cursor receives the current snapshot. This is snapshot recovery: intermediate tokens and historical progress transitions are not replayed. The existing conversation and action records retain the durable history.

```text
event: preview
data: {"schema_version":1,"thread_id":"...","run_id":"...","reply":"..."}

```

Previews contain the current rolling assistant reply, capped by the existing 600-character preview buffer. They have no cursor, are best effort, and only apply to the currently active matching run. Model reasoning is not included in these stream events. The iPhone keeps previews in view state rather than SwiftData.

## Live updates and recovery

Run, step, prepared-action and conversation mutations publish a lightweight PubSub hint scoped to the user and thread. Publishing a hint must not change whether a database operation succeeded. Subscribers reload the authorized public snapshot rather than trusting event payloads as domain state.

A hint may arrive before an enclosing transaction commits, or be lost during a process restart. Native streams reconcile active conversations every five seconds and idle conversations every thirty seconds. The web workspace uses the same public projection and PubSub hints through LiveView, with the same reconciliation intervals. This supports the existing combined service and tolerates missed cross-node hints.

Native connections send a keepalive every five seconds and end after fifty seconds. Clients reconnect with bounded backoff. The shared `AssistantProgressKit` package owns SSE framing, schema validation, size limits and transport cancellation for both native apps. A frame is bounded before constructing JSON. The server caps its JSON payload at 3.9 MB and the client caps the complete frame at 4 MB.

Leaving a view cancels observation. iPhone observation stops when the scene becomes inactive. A REST mutation or background sync can replace local state after a cursor was applied, so clients invalidate or recheck that cursor before resuming. A terminal snapshot clears stale active-run state on the Mac.

When an observed active run disappears from a snapshot, native clients read its final result through the existing run endpoint. This preserves failure explanations while clearing the activity indicator. A failed result read is retried through reconnection; it does not resubmit the user's message or restart business work.

## Ownership and approvals

The stream is an observation path. It does not acquire run ownership, execute tools, approve prepared actions, resolve todos, or schedule retries of business work. Existing PostgreSQL leases, generation fences, approval records and effect execution remain authoritative. The native read fallback supports a staged server rollout without resubmitting a message or repeating an action.

## Operational limits

Progress is eventually consistent. A lost hint can delay a refresh until reconciliation. Ephemeral text can disappear after a restart. A very large conversation that exceeds the frame limit closes the stream and falls back to the ordinary read endpoint. The server does not maintain a second event journal or a process for every stored todo.

The progress path needs no database migration or hosted service. Deployment also includes a narrowly scoped catalog registration for the earlier People Network cache migration. It uses the existing Phoenix/PubSub and assistant runtime. API authentication is rechecked on each bounded connection; authorization for the thread is rechecked whenever a snapshot is loaded.
