# Source-Backed Morning Briefing

Status: Done
Purpose: Replace the current insight-only Chief of Staff morning brief with a Runner-quality, source-backed morning briefing skill that gathers Calendar, Gmail, Slack, commitments, and open work, then synthesizes an opinionated executive brief.
Depends on:
- [AI Chief of Staff Skill-Orchestrated Agent Architecture](/Users/kent/bliss/maraithon/docs/spectacula/specs/ai-chief-of-staff-skill-orchestration.md)
- [Chief of Staff Shared Acquisition and Attention Arbitration](/Users/kent/bliss/maraithon/docs/spectacula/specs/chief-of-staff-shared-acquisition-and-attention-arbitration.md)

## 1. Problem

Runner's Morning Briefing works because it is source-first: it checks Calendar, Gmail, Slack, Linear, Notion, and the commitment source of truth, then connects the dots. Maraithon's current briefing path is downstream of `Insights` and `Todos`; it can say "nothing urgent" while raw source data still contains security alerts, billing changes, schedule prep, or low-level commitments the insight stream did not classify.

The Chief of Staff should therefore treat scheduled morning briefing as a first-class workflow skill, not as a prompt over existing insight summaries.

## 2. Goals

- Produce a 400-700 word morning brief with Runner's structure and tone.
- Gather raw source snapshots before synthesis:
  - today's Calendar events plus tomorrow's first event
  - recent unread Gmail, with VIP/security/billing/reply-debt cues
  - Slack key-channel and mention/thread signals
  - open commitments as the source of truth for what Kent owes
  - open insights and todos as already-derived operational state
- Add Slack to the shared Chief of Staff source bundle.
- Add durable `commitments` storage so Maraithon can own "what Kent owes" instead of repeatedly inferring it from messages.
- Keep the Chief of Staff root as the harness and the morning briefing as a skill.
- Preserve Telegram brief delivery through the existing `Briefs` pipeline.

## 3. Non-Goals

- Full Linear issue listing and Notion document search in the first production slice. The briefing input contract should reserve fields for them, but implementation can mark them unavailable until list/read adapters exist.
- A visual editor for brief sections or prompts.
- Replacing follow-through insights. The morning brief consumes insights but does not make them the only source of truth.
- Sending emails or Slack replies from the briefing itself.

## 4. Architecture

### 4.1 Components

| Component | Responsibility |
|---|---|
| `AIChiefOfStaff` | Harness: selects skills, builds source bundle, routes effects, arbitrates emits |
| `MorningBriefing` skill | Scheduled workflow: builds a briefing input, requests LLM synthesis, records a brief |
| `Acquisition` | Shared raw-source fetches for Gmail, Calendar, Slack |
| `SourceBundle` | Normalized same-cycle source snapshot |
| `Commitments` context | Durable source of truth for open obligations |
| `Briefs` | Persistence and Telegram delivery |

### 4.2 Source Bundle Additions

`SourceBundle` must support:

```elixir
"slack" => %{
  "workspaces" => [
    %{
      "team_id" => "...",
      "team_name" => "...",
      "key_channels" => [%{"id" => "...", "name" => "...", "messages" => [...]}],
      "mentions" => [...],
      "metadata" => %{}
    }
  ]
}
```

Slack acquisition should prefer user tokens for search/mentions and fall back to bot tokens for channel history where available. Key channels are configurable but default to Runner and Agora channels:

- `runner-general`, `runner-leads`, `runner-gtm`, `runner-user-feedback`
- `gtm-leads`, `general`, `eng-general`, `exec-agora-gov-mgmt-w-dash`, `jeff`, `charlie`, `yitong`
- any channel whose normalized name starts with `exec-` or `founders-`

### 4.3 Commitment Contract

`commitments` is user-scoped durable state.

| Field | Meaning |
|---|---|
| `user_id` | owner |
| `source` | `maraithon`, `omnifocus`, `gmail`, `slack`, etc. |
| `source_id` | external id or deterministic generated id |
| `title` | what Kent owes |
| `owed_to` | person, group, or organization |
| `project` | context bucket, e.g. Runner, Agora, Personal |
| `due_at` | optional deadline |
| `status` | `open`, `done`, `dismissed`, `snoozed` |
| `priority` | 0-100 |
| `evidence` | list of source evidence strings |
| `metadata` | provider details, thread ids, import ids |

The first implementation should support direct upsert/list/close APIs and derive open commitments from existing todos/insights when durable rows are not yet populated.

### 4.4 Morning Brief Input

The skill constructs a compact JSON payload:

```json
{
  "date": "2026-05-07",
  "timezone_offset_hours": -4,
  "calendar": {"today_events": [], "tomorrow_first_event": null},
  "gmail": {"recent_unread": [], "counts": {}},
  "slack": {"key_threads": [], "mentions": [], "counts": {}},
  "commitments": {"overdue": [], "due_today": [], "coming_up": [], "no_deadline": []},
  "open_work": {"insights": [], "todos": []},
  "source_health": {}
}
```

The LLM receives this payload and returns JSON:

```json
{
  "title": "Thursday, May 7 — Light day, but check account security",
  "summary": "One security alert stands out; otherwise the inbox is mostly noise.",
  "body": "markdown/telegram-safe brief body"
}
```

If the LLM fails, the skill must emit a deterministic fallback brief from the same input.

## 5. Behavior

### 5.1 Schedule

Morning briefing runs at `morning_brief_hour_local`. It must not duplicate an already-recorded morning brief for the same local day.

### 5.2 Synthesis Rules

- Open with a temperature read, not a generic greeting.
- Put only the 1-3 most important items in `Needs Your Attention`.
- Always include Calendar if connected.
- Show Gmail counts and the top 5-7 important messages, not all noise.
- Include Slack only when available; explicitly report if Slack is connected but acquisition failed.
- Include commitments if any open obligations exist.
- Cross-reference commitments with calendar attendees and email/slack people where possible.
- Do not claim a source was checked if its freshness status is unavailable or error.

### 5.3 Failure Handling

| Failure | Behavior |
|---|---|
| Gmail unavailable | Brief says Gmail was unavailable and continues with other sources |
| Slack search unavailable | Include channel-history signals if available; otherwise mark Slack unavailable |
| LLM fails | Deterministic fallback brief |
| Commitments table empty | Derive temporary commitment-like rows from open todos/insights |
| Telegram unavailable | Brief remains `pending`/`failed` through existing `Briefs` delivery path |

## 6. Implementation Plan

1. Add `Maraithon.Commitments.Commitment` schema and `Maraithon.Commitments` context.
2. Add migration for `commitments`.
3. Extend `SourceBundle` with `put_slack/2`, `slack_workspaces/1`, and freshness counts.
4. Extend `Acquisition` to fetch Slack key channels and recent mention/search results.
5. Add `Maraithon.ChiefOfStaff.Skills.MorningBriefing`.
6. Register the new skill and retire the old `briefing` default path or keep it disabled by default.
7. Add focused tests:
   - commitment upsert/list buckets
   - source bundle Slack normalization
   - morning brief LLM prompt/input shape
   - deterministic fallback brief
8. Verify with `mix format`, focused tests, and `mix compile`.

## 7. Definition of Done

- `ai_chief_of_staff` can run a morning cycle that records one source-backed morning brief per local day.
- The brief input includes Calendar, Gmail, Slack, commitments, open insights, open todos, and source health.
- Slack is included in the shared acquisition bundle.
- Durable commitments can be stored, listed, bucketed, and closed.
- The skill has an LLM synthesis path and a deterministic fallback path.
- The old insight-only morning brief no longer masks raw source state for morning briefing.
- Production deploy succeeds and Kent receives a Telegram confirmation.
