# Todo detail as a chief-of-staff brief

Date: 2026-08-27

## Goal

The todo detail page (`/todos/:id`) should tell the user why the item matters
and hand them the finished move: a ready-to-send reply when one is warranted,
or the concrete steps when they must act themselves. It should read like a
sharp chief of staff wrote it, not like a field dump.

## Non-goals

- Proactive background generation for every open todo (follow-up).
- Streaming the brief token by token (follow-up if latency is a problem).
- Calendar-aware scheduling replies beyond what the primer already does.

## Page

Order, top to bottom:

1. Header: status/attention/priority badges, title, summary.
2. Brief panel:
   - Why this matters (1-2 sentences).
   - The situation (2-4 sentences grounded in the source thread).
   - Do this: the recommendation, then an ordered list of steps only when the
     user must do something themselves.
   - Open questions (0-2), only when a decision belongs to the user.
   - Footer: generated time, model, Regenerate.
3. Reply panel (only when the brief includes a reply):
   - Gmail: To, Subject, editable body. Actions: Copy, Open in Gmail, Send.
   - Slack: channel/person label, editable body. Actions: Copy, Open in
     Slack, Post to Slack.
   - Other channels: editable body, Copy, Open in <source>.
   - After a successful send: confirmation alert; if the brief marked the
     reply as resolving the todo, the todo is marked done.
4. Sidebar: project select, Mark done, Dismiss / Show less, Ask Maraithon,
   compact facts (source, account, due, updated), collapsed next-action edit.

Loading: a brief panel skeleton with a live progress line ("Reading the Slack
thread", "Drafting the reply").

Removed: "How to solve this" field list, "Supporting details" panel.

## Generation: `Maraithon.Todos.Brief`

`generate_and_store(user_id, todo_id, opts)`:

1. Context (`Maraithon.Todos.Brief.Context`):
   - todo (`Todos.serialize_for_prompt`), action card decision/why-now/next
     best action/context pack, source health note.
   - Source thread: Gmail message body via `gmail_get_message`; Slack thread
     via `slack_get_thread_replies` (or recent channel history when no
     thread_ts); local messages via `Cards.SourceContext` conversation.
   - Linked people via `Crm.people_for_resource` + `relationship_contexts`.
   - `UserIdentity.prompt_block`, `UserVoice.prompt_context` for the channel,
     current time in the user's timezone.
   - Each fetch is bounded (timeout, size) and failures degrade to "not
     available" rather than failing the brief.
2. Prompt: system prompt with the chief-of-staff bar; user prompt with the
   context as labelled sections; strict JSON output:

   ```json
   {
     "why_it_matters": "...",
     "situation": "...",
     "recommendation": "...",
     "steps": ["..."],
     "reply": {"channel": "gmail|slack|imessage|whatsapp", "to": "...",
               "subject": "...", "body": "...", "resolves_todo": true},
     "open_questions": ["..."],
     "effort": "under_2_min|under_15_min|longer"
   }
   ```
   `reply` is null when no message is warranted.
3. Model: `LLM.complete_brief/1` pins `LLM.brief_model()` and
   `LLM.brief_reasoning_effort()` (env `LLM_BRIEF_MODEL` /
   `<PROVIDER>_BRIEF_MODEL`, `LLM_BRIEF_REASONING_EFFORT`, default `xhigh`).
   On provider rejection it retries once on the primary model at `high`.
4. Persist: `metadata["brief"]` = parsed brief + `version`, `generated_at`,
   `model`, `fingerprint` (hash of title/summary/next_action/status/source
   evidence). When `reply` is present, `action_draft` is replaced with a
   `kind: "reply"` draft (`channel`, `subject`, `body`/`text`, `to`,
   `style: "ready_to_send"`, `source: "todo_brief"`).
5. Staleness: `Brief.current/1` returns nil when version or fingerprint
   differ, so the page regenerates after the todo changes.
6. Concurrency: a short lease in `metadata["brief_generation"]` prevents two
   tabs from generating the same brief; the second waits and reloads.

## Sending: `Maraithon.Todos.BriefActions`

- `prepare_reply(user_id, todo)`: `AssistantChat.get_or_create_todo_thread/3`
  with `prepare_timeout_ms: 20_000`, then reads the primer turn's prepared
  action. Returns `{:ok, %{prepared_action, label}}` or
  `{:error, :no_connected_target}` (fallback to Copy / Open in source).
- `send_reply(user_id, todo, prepared_action_id, edits)`:
  `AssistantChat.decide_prepared_action(user_id, id, :confirm, %{"draft_edits"
  => edits})`; on `:prepared_action_expired` it re-prepares once and retries.
  On success, marks the todo done when `brief.reply.resolves_todo` is true.

Primer changes: `ensure/3` accepts `prepare_timeout_ms`; drafts with
`style: "ready_to_send"` are used verbatim (no quote extraction or synthetic
rewrites); new public `prepared_action_for/2`.

## Bug fix

`Todos.ActionDrafts.ensure/2` overwrote a real `action_draft` with a
placeholder on any partial update. It now leaves attrs untouched when the
existing todo already has draft material.

## Testing

- `test/maraithon/todos/brief_test.exs`: context assembly, JSON parsing,
  persistence, fingerprint staleness, action_draft write, mock provider.
- `test/maraithon_web/live/todos_live_test.exs`: detail page renders the
  brief sections and reply panel; obsolete field-list assertions rewritten.
- Mock provider gains a brief sentinel branch.
