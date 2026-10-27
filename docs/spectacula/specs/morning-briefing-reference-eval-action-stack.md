# Morning Briefing Reference Eval and Action Stack

Status: In Progress
Purpose: Make Maraithon's morning briefing match the dense operational reference brief, including action-card stack triage, conflict surfacing, and durable todo capture.

## 1. Problem Statement

The source-backed morning briefing already gathers the right raw inputs, but the generated brief still behaves too much like a concise digest. It can hide the exact things Kent needs in the morning: which conflicts require a decision, which queued drafts/action cards are ready to fire, which tasks are dashboard or judgment work rather than reply work, and how old commitment backlog should be attacked.

The reference briefing Kent provided is the target quality bar. It is not merely longer; it is operationally denser:

- It opens with a day-level read and the highest-leverage move.
- `Needs Your Attention` ranks the few items that change the morning.
- `Today's Schedule` includes every material meeting, calls out real conflicts, and recommends what to move, leave, or choose.
- `Inbox` and `Slack` are scoped triage sections with counts and only decision-changing threads.
- `Open Commitments` shows active counts, overdue work, due-today work, coming-up work, action-card/draft IDs, and non-draft jobs.
- `Look Ahead` names tomorrow/week risks and closes with a directive.

The current prompt and verifier do not enforce that shape. The app skill even tells the model not to include Inbox or Slack sections, which conflicts with the reference when those sections are useful as triage rather than inventory.

## 2. Goals and Non-Goals

### 2.1 Goals

- Update the Morning Briefing prompt and skill instructions so the model targets the reference briefing shape.
- Treat the reference as an eval contract, not a style suggestion.
- Preserve the existing source-backed input pipeline: Calendar, Gmail, Slack, commitments, open work, CRM, local sources, and source health.
- Make the quality verifier detect and patch missing operational sections when the source input clearly requires them:
  - schedule conflicts
  - open commitment buckets
  - action-card/draft stack
  - non-draft dashboard/judgment jobs
  - durable todo cards with person/company/why-now context
- Improve todo capture/finding by requiring durable todos to include source IDs, dedupe keys, person/company context, evidence, next action, and whether the item is draftable or non-draft work.
- Keep output scannable. Dense is correct; noisy inventory is not.

### 2.2 Non-Goals

- Do not build new connectors in this slice.
- Do not send drafts, Slack replies, or emails from the briefing itself.
- Do not replace OmniFocus, action cards, or the todo system. The briefing should surface and cross-reference them.
- Do not require the model to invent names for phone numbers or infer facts absent from sources.
- Do not force every morning to be long. Quiet days can remain short.

## 3. Current System

### 3.1 Runtime Path

`Maraithon.ChiefOfStaff.Skills.MorningBriefing` builds `brief_input`, compacts source sections, loads `priv/agents/skills/chief_of_staff/morning_briefing.md`, and calls the LLM. Model output is JSON:

```json
{
  "title": "...",
  "summary": "...",
  "body": "...",
  "todos": []
}
```

The runtime persists model todos through `OpenLoops.ingest_todos/3` and falls back to direct todo upserts if ingestion fails.

### 3.2 Current Gaps

| Gap | Impact |
|---|---|
| Prompt discourages Inbox/Slack sections | The model may omit useful account/channel triage from the reference brief |
| Quality verifier only checks personal/weekend/person-todo gaps | A brief can score 10/10 while missing conflicts, commitments, action cards, or non-draft jobs |
| Response budget is generic | The model may compress a packed day below useful density |
| Todo metadata is recommended but not specific enough for action-card finding | Follow-up cards can be hard to dedupe, group, or explain later |
| External Runner skill and in-app skill can drift | Kent may improve the standalone prompt while the app keeps old behavior |

## 4. Reference Briefing Acceptance Contract

The briefing should pass this contract whenever the source data contains the relevant signals.

| Area | Acceptance rule |
|---|---|
| Title | Specific day headline: weekday/date plus the actual day theme and primary move |
| Needs attention | Top 4-6 ranked items, each with why it matters and the next move |
| Schedule | Every required/material event with time, owner/domain, context, and prep/decision |
| Conflicts | Overlapping events called out explicitly with a recommendation |
| Inbox | Account-level counts and only the important threads; no raw newsletter inventory |
| Slack | Channel/mention counts and only blocked/decision-changing threads |
| Commitments | Active count plus overdue, due today, and coming-up buckets when present |
| Action cards | Draft/action-card IDs shown beside related work when source data has them |
| Non-draft jobs | Dashboard, payment, review, or judgment work separated from reply/draft work |
| Todos | Durable todos emitted as separate cards only when worth a Done/Dismiss decision |
| Look ahead | Tomorrow/week risks and a final directive for the first focused block |

## 5. Proposed Design

### 5.1 Prompt and Skill Instruction Changes

Update both prompt surfaces:

- `priv/agents/skills/chief_of_staff/morning_briefing.md`
- `/Users/kent/.runner/workspaces/my-workspace-68/skills/morning-briefing/SKILL.md`

The revised instructions should:

- Allow `Inbox` and `Slack` as triage sections when they carry counts, blocked people, or decisions.
- Require `Open Commitments` buckets when commitment data is present.
- Require schedule conflict detection and an explicit recommendation.
- Require action-card/draft IDs to stay attached to the item they unblock.
- Require a `Not a draft job` grouping for work that needs a dashboard, payment, decision, or review.
- Keep the JSON-only contract and existing todo schema.
- Raise the practical length ceiling for packed days while preserving concise quiet days.

### 5.2 Runtime Prompt Changes

Update `morning_prompt/1` so the in-code guardrails match the markdown skill:

- Keep required meeting and commercial-thread coverage.
- Add a “Reference briefing eval” block with the acceptance contract from section 4.
- Replace the old “at most 8 body sections and 12 todos” phrasing with a packed-day budget: normally under 2,200 words, but complete coverage beats artificial brevity.
- Tell the model to run a private final review against the reference contract.

### 5.3 Verifier Changes

Extend `verify_quality/3` with new findings:

| Finding | Trigger |
|---|---|
| `:missing_needs_attention` | LLM brief body lacks `Needs Your Attention` |
| `:missing_schedule_conflicts` | input has overlapping events but body lacks conflict/overlap language |
| `:missing_open_commitments` | commitment buckets have active items but body lacks commitment/overdue/due-today coverage |
| `:missing_action_stack` | todos/open work/source metadata shows draft/action-card work but body lacks card/draft/action-stack coverage |
| `:missing_non_draft_jobs` | input contains payment/dashboard/review/judgment tasks but body does not separate non-draft work |

When a finding is deterministic, the verifier should append a compact corrective section rather than failing silently. These appended sections are safety rails for delivery; the prompt should still aim to avoid needing them.

### 5.4 Todo Capture and Finding Rules

Model-emitted todos should keep the existing schema but use metadata consistently:

| Metadata key | Meaning |
|---|---|
| `source_item_id` | Gmail message/thread ID, Slack channel/ts, OmniFocus ID, action-card ID, or local source ID |
| `dedupe_key` | Stable key for the underlying obligation |
| `person` | Human waiting or affected, when known |
| `company` / `organization` | Business context |
| `why_it_matters` | Short operational reason |
| `evidence` | Source-backed one-line evidence |
| `draft_id` / `action_card_id` | Pending draft/card reference when available |
| `work_type` | `draftable`, `dashboard`, `payment`, `review`, `decision`, `prep`, or `personal_logistic` |

User-facing todo titles must explain the person or company context. Raw phone numbers alone are not acceptable titles when source context exists.

## 6. Failure Modes and Safeguards

| Failure mode | Safeguard |
|---|---|
| Model collapses a packed day into a short digest | Prompt reference contract plus verifier findings append missing sections |
| Model includes Inbox/Slack noise | Instructions define those sections as triage only; newsletters and FYI chatter remain excluded |
| Model misses calendar overlaps | Deterministic overlap detection adds `Schedule Conflicts` |
| Model loses action-card IDs | Prompt requires IDs to stay attached; verifier checks for card/draft language when inputs contain IDs |
| Non-draft jobs get mixed with reply drafts | Prompt and verifier require a separate non-draft grouping |
| Todo cards become vague | Tests assert person/company/why-now context in model todo metadata and user-facing text |

## 7. Test and Validation Plan

- Add prompt tests that assert the new reference contract is present.
- Add verifier tests using a source fixture shaped like the May 27 reference brief:
  - overlapping 11:00/11:30/11:45 and 14:45/15:00 meetings
  - active commitments with overdue, due today, and coming-up buckets
  - Slack and inbox counts
  - pending draft/action-card IDs
  - non-draft dashboard/payment/review jobs
- Run focused tests:
  - `mix test test/maraithon/chief_of_staff/skills/morning_briefing_test.exs`
- Run project completion gate:
  - `mix precommit`
- Spectacula lifecycle validation is attempted, but existing unrelated manifests currently contain legacy status values that make global validation fail. Do not edit unrelated manifests for this slice.

## 8. Implementation Checklist

- [ ] Update in-app Morning Briefing skill markdown.
- [ ] Update external Runner morning-briefing skill markdown supplied by Kent.
- [ ] Update `morning_prompt/1` with the reference eval contract.
- [ ] Extend `verify_quality/3` findings and deterministic appenders.
- [ ] Add focused prompt/verifier tests.
- [ ] Run formatter and focused tests.
- [ ] Run `mix precommit`.
- [ ] Record verification results in this manifest and move to `done`.

## 9. Assumptions

- Plain `$spectacula` was requested, so final strict vetting is off.
- The sample briefing is the eval target for shape and operational density, not a literal template that must always emit every section.
- Action-card IDs may appear as `actc_...`, draft IDs, OmniFocus IDs, or source metadata; the verifier should detect common forms without inventing missing IDs.
- Existing source acquisition already provides enough data for this improvement.
