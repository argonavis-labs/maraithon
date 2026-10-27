# Skill state payload diet

Status: proposed · Owner: runtime · Follows: 2026-08-28 runtime recovery (commits `f70ace30`…`9654e47a`)

## Goal

Chief of Staff checkpoints must stay small and lossless. A checkpoint is the
Agent's only durable memory across crashes and deploys; it is capped at 1 MiB
total and 64 KiB per string by `SnapshotFormat`, and it is written after every
effect and every 10-minute checkpoint. Today the skills keep raw provider
payloads (email bodies, HTML, prompt inputs built from hundreds of messages,
tool output) in their state for the duration of a cycle, so a checkpoint
taken mid-cycle serialises megabytes. `SnapshotTrim` now nulls the source
bundle and truncates any string above 16 KiB so the Agent survives, and logs
`snapshot_scalar_truncated`. That is a safety net, not a design: a restored
state can hold a truncated prompt input or tool result and behave differently
from the live state.

After this work: no skill or wrapper state holds raw source content. State
holds identifiers, compact projections, and decisions; raw content is read
from the cycle's source bundle (or refetched by id) at the moment it is used.
`SnapshotTrim` never truncates in normal operation, and if it does, the event
is a bug with a key path attached.

## Non-goals

- Changing what the skills send to the model. Prompt content limits
  (`@llm_candidate_body_excerpt_chars`, `email_scan_limit`, …) stay as they
  are; this spec is about what survives in *state* between effects.
- Changing the snapshot format, its caps, or the trigger authority model.
- Persisting source bundles server-side as a cache. The bundle is fetched per
  cycle by design.

## Current behaviour (measured 2026-08-28)

- `AIChiefOfStaff` keeps `source_bundle` and `assistant_fetch_telemetry` in
  state for the whole cycle (`lib/maraithon/behaviors/ai_chief_of_staff.ex:710`);
  `InboxCalendarAdvisor` keeps its own copy (`:278`). The bundle is the full
  Gmail/Calendar/Slack fetch. First checkpoint failure: `snapshot_too_large`.
- `CommitmentTracker.pending_tracker_input` embeds up to `email_scan_limit`
  (200) inbox and 200 sent messages rendered by `gmail_message_for_prompt/1`,
  plus calendar events, until the LLM result returns.
- `CalendarCheckIn.pending_check_in_input`, `HolidayRadar.pending_holidays`,
  and `InboxCalendarAdvisor.pending_candidates` carry per-cycle prompt inputs
  in the same way. Candidates already cap `body_excerpt` at 1,500 chars, but
  other keys copy whole message fields.
- `ManifestAgent.tool_results` keeps the last 10 raw tool outputs.
- Any single string above 64 KiB (an HTML email body, a large tool output)
  failed the checkpoint outright: `snapshot_scalar_too_large`, seen once per
  effect on `00076`–`00079`, exiting the Agent with
  `directive_settlement_incomplete` until the restart guard tripped.
- `SnapshotTrim` (`lib/maraithon/behaviors/snapshot_trim.ex`) now nulls the
  transient keys and truncates strings above 16 KiB inside maps, lists,
  tuples, and non-calendar structs, logging `snapshot_scalar_truncated` with
  the key paths. Cloud Logging drops list-valued metadata, so the paths do not
  currently appear in the log line (task 0 below).

## Design

### 1. State holds references and projections, never content

Introduce one rule, enforced by a test: a skill state (and the wrapper state
around it) may contain

- identifiers: `message_id`, `thread_id`, `event_id`, `source_item_id`,
  `dedupe_key`, account/provider keys;
- compact projections needed to interpret the model's answer:
  `subject`, `from`, `to`, `occurred_at`, `body_excerpt` (≤ 1,500 chars),
  `window_key`, review keys;
- decisions and memory the skill owns: ledgers, watermarks, cycle memos,
  suppression sets.

It may not contain: full message bodies (`body`, `html_body`, `text_body`,
`content`), rendered prompt inputs, raw provider records, or tool output.

### 2. Pending effect context moves out of state

Every skill that issues an LLM effect today stores its prompt input in state
(`pending_tracker_input`, `pending_check_in_input`, `pending_candidates`,
`pending_holidays`) so it can interpret the reply. Replace each with a
`pending_effect` map that holds only what interpretation needs:

```elixir
%{
  effect_kind: :commitment_review,
  cycle_id: cycle_id,
  candidate_refs: [%{message_id: ..., thread_id: ..., subject: ..., occurred_at: ...}],
  dedupe_key: "...",
  issued_at: DateTime.t()
}
```

The full prompt input is built, handed to the effect, and dropped. When the
result arrives, the skill interprets it against `candidate_refs` (ids and
subjects are enough to attach todos, insights, and resolutions). If a skill
genuinely needs message text after the reply (none does today; the inbox
advisor reads `response.content` only), it reads it from the current cycle's
source bundle by id via `SourceBundle`, or refetches by id through the
connector.

Concretely:

- `CommitmentTracker`: `pending_tracker_input` → `pending_effect` with the
  message and event refs it rendered.
- `CalendarCheckIn`: `pending_check_in_input` → `pending_effect` with the
  window key and event ids.
- `HolidayRadar`: `pending_holidays` keeps `%{id => %{name, date, region}}`
  only.
- `InboxCalendarAdvisor`: `pending_candidates` entries are reduced to the
  projection above (drop any key that is not an id, a header field, a
  timestamp, or `body_excerpt`).
- `AIChiefOfStaff`: `source_bundle` and `assistant_fetch_telemetry` become
  cycle-scoped process state, not behavior state. Keep them in the cycle
  context (`context[:source_bundle]` already exists) and thread the context
  through `run_skill_step`; the state keeps `cycle_skill_ids`, `resume_index`,
  and watermarks only.
- `ManifestAgent.tool_results`: keep the last 10 entries but store
  `%{tool, status, summary (≤ 2 KiB), bytes, at}`; the wrapper only ever
  re-renders results into the next prompt, where a 2 KiB summary suffices.

### 3. A size budget the Agent enforces

Add `Maraithon.Behaviors.SnapshotBudget.check(state)` that encodes the
`snapshot_state/1` view with `SnapshotFormat.encode/1` and returns
`{:ok, bytes}` or `{:error, {reason, paths}}`. Use it in two places:

- `Maraithon.Runtime.Agent.persist_exact_snapshot!/1` logs `snapshot_bytes`
  on every checkpoint (metadata key `snapshot_bytes`, integer), so growth is
  visible before it becomes a failure.
- A test helper `assert_snapshot_budget(state, max_bytes)` used by every
  skill's tests with a realistic fixture (20 candidates with 8 KiB bodies,
  200 inbox messages, 80 events). Budget: 128 KiB per skill state, 256 KiB
  for the whole Chief of Staff state.

`SnapshotTrim` stays as the last line of defence. Its truncation log becomes
an error-level signal (`failure_code: "snapshot_scalar_truncated"`) with the
paths joined into one string so Cloud Logging keeps them, and an alert
condition: any occurrence after this work ships is a regression.

### 4. Reading content when it is needed

`SourceBundle` gains id lookups so skills never need to hold content:

```elixir
SourceBundle.gmail_message(bundle, message_id)
SourceBundle.calendar_event(bundle, event_id)
SourceBundle.slack_message(bundle, channel_id, ts)
```

They are O(1) over an index built once per bundle (`SourceBundle.index/1`,
memoised in the cycle context). Skills that today keep a message to render it
later call these with the ids from `pending_effect` instead.

## Migration

- `AIChiefOfStaff.schema_version/0` goes to 2. `migrate_state/3` from 1
  drops `source_bundle`, `assistant_fetch_telemetry`, and every
  `pending_*_input`/`pending_candidates` value (a restored mid-cycle state
  simply restarts the cycle, which is what recovery does today anyway) and
  converts `HolidayRadar.pending_holidays` to the compact form.
- `ManifestAgent` converts existing `tool_results` entries to the summary
  form on restore (`reconcile_restored_state/2`).
- No database migration.

## Testing

- Per-skill: a state built from realistic fixtures round-trips through
  `SnapshotFormat.encode/1` → `decode/1` unchanged and within budget, before
  and after issuing an effect (`pending_effect` populated) and after the
  result.
- Property: for every skill, `snapshot_state/1` is the identity when the
  budget rule holds (no truncation, no nulling needed), asserted by comparing
  with the raw state.
- `SnapshotTrim` keeps its own tests; add one that asserts the joined path
  string in the log metadata.
- `authority_test`/coordination suites are untouched; this is behavior-state
  work only.

## Rollout and metrics

1. Land task 0 (path logging as a string) and the `snapshot_bytes` metric
   first; run one day. Expected: paths name `skill_states.commitment_tracker.pending_tracker_input.gmail.recent_inbox.[].body`-style keys and `manifest.tool_results`.
2. Convert skills one at a time, largest first (commitment tracker, inbox
   advisor, calendar check-in, holiday radar, manifest tool results, then
   the bundle relocation in `AIChiefOfStaff`).
3. Done when, over 24 hours in production: zero `snapshot_scalar_truncated`,
   `snapshot_bytes` p95 under 256 KiB, zero `directive_settlement_incomplete`,
   and the Agent's restart guard never trips outside a deploy.

## Open questions

- Should `body_excerpt` shrink further (1,500 → 800 chars) now that todos
  carry a `source_action` link back to the original message? Decide after the
  first day of `snapshot_bytes` data.
- Do any skills rely on `tool_results` beyond re-rendering into the next
  prompt? Verify in `ManifestAgent.handle_effect_result/3` before replacing
  raw output with summaries.
