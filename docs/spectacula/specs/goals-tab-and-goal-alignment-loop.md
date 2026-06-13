# Goals Tab and Goal Alignment Loop

Status: Draft v1
Purpose: Define Maraithon's first-class Goals tab and the agent architecture that lets the Chief of Staff routinely align connected work, people, health, and life context against the user's stated goals.
Audience: Product, engineering, and operator review.

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon already has the main pieces of a personal operating layer:

- connected accounts and local companion sources
- durable open work in `Todos`
- People and relationship context in `Crm`
- memory and preference state
- scheduled tasks, briefings, and Chief of Staff skills
- proactive Telegram and mobile/web assistant surfaces

What it does not yet have is an explicit source of truth for what the user is trying to become, achieve, maintain, or repair. Without that layer, the Chief of Staff can triage messages and surface work, but it cannot consistently answer the product question: "Is what is happening in the user's life moving them toward their goals?"

The Goals tab should make goals first-class. The agent loop should then use those goals as durable operating context for prioritization, open-work creation, briefings, and routine review across connected systems.

### 1.2 Product Thesis

A useful Chief of Staff should not only react to urgent work. It should know the user's stated goals and repeatedly check whether the user's current actions, commitments, relationships, schedule, and open loops are aligned with those goals.

Goals are not just another todo list. Goals are durable intent and outcome state. Todos are concrete next moves. People, calendar, messages, notes, reminders, and memory provide evidence. The agent loop should connect those layers.

### 1.3 Goals

- Add a top-level Goals tab for managing active goals.
- Support four v1 goal categories:
  - `work`
  - `person`
  - `health_fitness`
  - `life`
- Persist goals as durable, user-scoped domain objects with status, cadence, sensitivity, and target metadata.
- Let goals link to concrete work items, people, source observations, and progress updates.
- Add a routine goal-alignment loop to the Chief of Staff agent.
- Inject active goals into assistant context so reactive chat, Telegram, morning briefings, and prioritization can use them.
- Convert goal-alignment findings into concrete next moves only when the system has enough evidence to justify action.
- Preserve privacy and approval boundaries, especially for health, fitness, life, and relationship goals.
- Keep the UI operational, compact, and Catalyst-aligned.

### 1.4 Non-Goals

- Do not build the implementation as part of this spec.
- Do not create a full OKR, habit tracker, or quantified-self product in v1.
- Do not ingest Apple Health, Google Fit, wearable, medical, or biometric data in v1.
- Do not let agents autonomously send external messages, schedule personal commitments, or modify third-party systems solely because a goal exists.
- Do not replace `Todos`; goals should feed and contextualize durable work items.
- Do not require every goal to have a numeric metric. Qualitative goals are valid.
- Do not expose private health/life goal details in broad surfaces unless the user has opted into that visibility.

## 2. Current State and Affected Systems

### 2.1 Existing Product Surfaces

Relevant web surfaces:

| Surface | File | Current role |
|---|---|---|
| Authenticated LiveView routes | [`lib/maraithon_web/router.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/router.ex) | Owns `/briefing`, `/todos`, `/stream`, `/operator/people`, `/chat`, `/agents`, `/insights` |
| Primary navigation | [`lib/maraithon_web/components/admin_navigation.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/components/admin_navigation.ex) | Defines primary web and mobile-web nav |
| Work tab | [`lib/maraithon_web/live/todos_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/todos_live.ex) | Durable open work list, filters, manual creation, actions |
| People tab | [`lib/maraithon_web/live/people_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/people_live.ex) | CRM people and relationship state |
| Agents tab | [`lib/maraithon_web/live/agents_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/agents_live.ex) | Agent registry, lifecycle, inspection |
| Today tab | [`lib/maraithon_web/live/briefing_live.ex`](/Users/kent/bliss/maraithon/lib/maraithon_web/live/briefing_live.ex) | Briefing-oriented daily surface |

Relevant native mobile surfaces:

| Surface | File | Current role |
|---|---|---|
| App tabs | [`apps/mobile/MaraithonMobile/Features/AppShell/AppShellView.swift`](/Users/kent/bliss/maraithon/apps/mobile/MaraithonMobile/Features/AppShell/AppShellView.swift) | Native tabs: Today, Work, Stream, People, Chat |
| Navigation coordinator | [`apps/mobile/MaraithonMobile/Features/AppShell/AppNavigation.swift`](/Users/kent/bliss/maraithon/apps/mobile/MaraithonMobile/Features/AppShell/AppNavigation.swift) | Cross-tab routing for work, people, chat |
| Mobile API client | [`apps/mobile/MaraithonMobile/Core/API/MobileAPIClient.swift`](/Users/kent/bliss/maraithon/apps/mobile/MaraithonMobile/Core/API/MobileAPIClient.swift) | REST client models for mobile data |
| Production sync | [`apps/mobile/MaraithonMobile/Core/Sync/ProductionDataSync.swift`](/Users/kent/bliss/maraithon/apps/mobile/MaraithonMobile/Core/Sync/ProductionDataSync.swift) | Pulls remote todos and people into SwiftData |

### 2.2 Existing Domain Primitives

| Primitive | Existing module | Role for Goals |
|---|---|---|
| Open work | [`Maraithon.Todos`](/Users/kent/bliss/maraithon/lib/maraithon/todos.ex) | Goal-alignment output should create or update concrete work items here |
| Todo schema | [`Maraithon.Todos.Todo`](/Users/kent/bliss/maraithon/lib/maraithon/todos/todo.ex) | Can carry goal linkage in metadata for v1, but should get explicit goal linkage through `goal_links` |
| Commitments | [`Maraithon.Commitments.Commitment`](/Users/kent/bliss/maraithon/lib/maraithon/commitments/commitment.ex) | Existing obligation source for goal review |
| Insights | [`Maraithon.Insights.Insight`](/Users/kent/bliss/maraithon/lib/maraithon/insights/insight.ex) | Optional attention artifact for goal drift or goal opportunity |
| Open loops | [`Maraithon.OpenLoops`](/Users/kent/bliss/maraithon/lib/maraithon/open_loops.ex) | Goals should become another input to the open-loop snapshot |
| Scheduled tasks | [`Maraithon.ScheduledTasks`](/Users/kent/bliss/maraithon/lib/maraithon/scheduled_tasks.ex) | User-created routines can request goal review jobs |
| Context engine | [`Maraithon.ContextEngine`](/Users/kent/bliss/maraithon/lib/maraithon/context_engine.ex) | Active goals should be included in bounded assistant context |
| Source scope | [`Maraithon.ChiefOfStaff.SourceScope`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/source_scope.ex) | Goal review uses the same source availability and account scoping |
| Chief of Staff skills | [`lib/maraithon/chief_of_staff/skills`](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills) | Add a `goal_alignment` skill rather than a separate agent |

### 2.3 Existing Architectural Direction

This spec builds on these completed or draft Spectacula contracts:

- [`Open Loop Operating System`](/Users/kent/bliss/maraithon/docs/spectacula/specs/open-loop-operating-system.md)
- [`Source-Backed Morning Briefing`](/Users/kent/bliss/maraithon/docs/spectacula/specs/source-backed-morning-briefing.md)
- [`Chief of Staff Shared Acquisition and Attention Arbitration`](/Users/kent/bliss/maraithon/docs/spectacula/specs/chief-of-staff-shared-acquisition-and-attention-arbitration.md)
- [`Dedicated Agents Tab`](/Users/kent/bliss/maraithon/docs/spectacula/specs/dedicated-agents-tab.md)
- [`Project-Oriented Conversational Operator`](/Users/kent/bliss/maraithon/docs/spectacula/specs/project-oriented-conversational-operator.md)

The important direction is stable: durable state first, source-backed review, bounded context, model judgment for interpretation, deterministic code for auth, storage, dedupe, transport, and approvals.

## 3. Product Model

### 3.1 Core Vocabulary

| Term | Meaning |
|---|---|
| Goal | Durable user-stated outcome, direction, or standard the user wants Maraithon to consider over time |
| Goal category | Broad bucket for goal handling: work, person, health/fitness, life |
| Goal alignment | The agent's judgment about whether current context supports, blocks, or ignores an active goal |
| Progress update | Manual or agent-authored record of what changed for a goal |
| Goal link | Typed association between a goal and a todo, person, source observation, chat thread, brief, or other resource |
| Review cadence | How often Maraithon should proactively reassess a goal |
| Goal evidence | Source-backed fact or excerpt used to justify an alignment finding |
| Goal next move | Concrete work item generated from a goal review |

### 3.2 Goal Categories

| Category | Examples | Primary sources | Default sensitivity |
|---|---|---|---|
| `work` | Ship Maraithon Goals, hire a designer, raise a round, grow Runner pipeline | todos, projects, Gmail, Slack, Linear, GitHub, calendar, notes | standard |
| `person` | Rebuild relationship with X, be more present with family, stay close to key customers | People, contacts, calendar, messages, Gmail, Slack, notes, reminders | sensitive |
| `health_fitness` | Train for a race, lift 3x/week, sleep earlier, reduce drinking | manual input, calendar, reminders, local notes, future health integrations | sensitive |
| `life` | Move cities, plan a trip, write weekly, build a stronger community | calendar, reminders, notes, files, browser history, people, todos | sensitive |

Rules:

- Category controls defaults, copy, review prompts, and source weighting.
- Category must not be used as an authorization boundary by itself. Authorization comes from user ownership, source scopes, and explicit sensitivity settings.
- `health_fitness` remains manual and local-context-only in v1. No wearable or medical-source ingestion belongs in this slice.

### 3.3 Goal States

| Status | Meaning | Agent behavior |
|---|---|---|
| `active` | Goal is currently relevant and should influence prioritization | Include in assistant context and routine reviews |
| `paused` | Goal remains saved but should not proactively drive suggestions | Exclude from routine reviews unless directly referenced |
| `achieved` | Goal is completed | Exclude from routine reviews; available in history |
| `archived` | Goal is no longer relevant | Exclude from context by default |

### 3.4 Goal Sensitivity

| Sensitivity | Meaning | Default surfaces |
|---|---|---|
| `standard` | Safe to summarize in normal authenticated product surfaces | Goals tab, Today, Work, Chat, Telegram when relevant |
| `sensitive` | Personal or potentially private content | Goals tab and direct user-requested chat; brief summaries only when opted in |
| `private` | Hidden from proactive delivery and broad context | Goals tab only unless the user explicitly asks about that goal |

Rules:

- `person`, `health_fitness`, and `life` goals default to `sensitive`.
- A user may downgrade or upgrade sensitivity per goal.
- Sensitive goals may still influence ranking, but proactive copy must avoid exposing private details unless the goal's `proactive_visibility` permits it.
- Private goals must not be included in Telegram proactive pushes or morning brief text.

## 4. Scope and Product Decisions

### 4.1 In Scope For V1

- Web Goals tab at `/goals`.
- Durable goal CRUD.
- Goal detail view with progress, linked work, linked people, and review settings.
- A goal-aware assistant context snapshot.
- Goal management tools for Telegram/chat/MCP where appropriate.
- Chief of Staff `goal_alignment` skill.
- Goal review output that can:
  - record progress updates
  - link existing todos or people
  - create goal-linked todos
  - surface a brief alignment note when evidence is strong
- Mobile API contracts for listing and editing goals.
- Native mobile model/client groundwork and a Goals tab if the mobile nav decision is approved.

### 4.2 Out Of Scope For V1

- Full OKR hierarchy, team goals, or shared goals.
- Habit streak analytics.
- HealthKit, Apple Fitness, Garmin, Oura, Whoop, Strava, or other health data ingestion.
- Cross-user collaboration or family accounts.
- Autonomous external actions caused only by a goal.
- LLM-only stored truth. User-authored fields and deterministic persistence remain the source of truth.
- Automatic deletion of goals based on inferred inactivity.

### 4.3 Product Decisions In This Spec

| Decision | Choice |
|---|---|
| Goals are first-class durable state | Yes, not only memory entries or todos |
| Goals tab placement | Primary product navigation, recommended between Today and Work |
| Concrete action output | Use `Todos` for goal next moves |
| Agent ownership | Add a Chief of Staff skill, not a separate default agent |
| Routine review cadence | Daily lightweight scan plus per-goal cadence for deeper review |
| Sensitive categories | Person, health/fitness, and life default to sensitive |
| Health integrations | Deferred |
| Mobile | API and model included; visible tab placement remains an explicit open question |

## 5. UX / Interaction Model

### 5.1 Navigation

Recommended web primary navigation:

1. Today
2. Goals
3. Work
4. Stream
5. People
6. Chat

Goals should be before Work because goals answer "why and what direction" while Work answers "what now".

Implementation notes for later:

- Add `/goals` to `MaraithonWeb.Router` inside the existing authenticated LiveView `live_session`.
- Add `GoalsLive` to `MaraithonWeb.AdminNavigation.@primary_nav`.
- `active?/2` must treat `/goals` and any future `/goals/:id` route as the Goals section.
- Follow Phoenix v1.8 layout rules: LiveView templates begin with `<Layouts.app flash={@flash} ...>`.

### 5.2 Goals Index

The Goals tab should be an operational list, not a decorative dashboard.

Primary layout:

- compact page heading: `Goals`
- primary action: `New goal`
- filters:
  - status
  - category
  - sensitivity
  - review state
  - search
- category-grouped or single table/list rows
- selected goal detail panel or route-backed detail state

Goal row fields:

| Field | Required | Notes |
|---|---|---|
| Title | Yes | User-authored, direct |
| Category | Yes | Badge or compact label |
| Status | Yes | active, paused, achieved, archived |
| Priority | Yes | 0-100 or low/normal/high mapping |
| Target | Optional | Target date or horizon |
| Next review | Yes for active goals | Show overdue review state quietly |
| Linked work count | Yes | Count active goal-linked todos |
| Last progress | Optional | Short timestamp and one-line summary |

### 5.3 Goal Detail

Goal detail should contain:

- editable title, category, desired outcome, why, target date, success metric
- status and priority controls
- sensitivity and proactive visibility controls
- review cadence controls
- linked work rows
- linked people rows for person/work/life goals
- progress timeline
- source-backed alignment findings
- agent review history

The detail view should make the next concrete move visible near the top:

| State | Detail behavior |
|---|---|
| Active with open linked work | Show the highest-priority linked work row and action |
| Active with no concrete next move | Show "No next move saved" and offer `Add next move` |
| Review overdue | Show subtle review-due state and `Review now` |
| Paused/achieved/archived | Suppress proactive controls and show restore/reactivate action |

### 5.4 Goal Creation

Fields:

| Field | Required | Behavior |
|---|---|---|
| `title` | Yes | 4-240 chars |
| `category` | Yes | work, person, health_fitness, life |
| `desired_outcome` | Yes | What success should look like |
| `why` | Optional | Motivation or standard |
| `success_metric` | Optional | Numeric or qualitative |
| `target_at` | Optional | Goal horizon |
| `review_cadence` | Yes | default by category |
| `priority` | Yes | default 50 |
| `sensitivity` | Yes | default from category |
| `proactive_visibility` | Yes | default from sensitivity |

Default review cadence:

| Category | Default cadence |
|---|---|
| `work` | weekly |
| `person` | weekly |
| `health_fitness` | weekly |
| `life` | monthly |

### 5.5 Chat And Natural-Language Capture

The user should be able to say:

- `Add a goal to get my running back to 3 times a week.`
- `Make rebuilding my relationship with Charlie a goal.`
- `My top work goal this month is shipping the Goals tab.`
- `Pause the marathon training goal until July.`
- `What am I doing that conflicts with my health goals?`
- `What should I do today to make progress on my life goals?`

The assistant should use tools rather than hidden prompt memory for durable mutations.

Minimum assistant tools:

| Tool | Purpose |
|---|---|
| `list_goals` | Read active/saved goals with filters |
| `create_goal` | Create a user-scoped goal |
| `update_goal` | Edit status, copy, cadence, priority, or sensitivity |
| `record_goal_progress` | Add manual or agent-authored progress update |
| `link_goal_resource` | Link a goal to a todo, person, brief, chat thread, or source observation |
| `review_goal_alignment` | Run an on-demand goal alignment pass for one goal or all active goals |

Tool responses should be compact and user-facing. They must not expose raw prompt internals, hidden scores, or sensitive source excerpts unless requested on an authenticated surface.

## 6. Data and Domain Model

### 6.1 `goals`

New table: `goals`.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | binary_id | Yes | Primary key |
| `user_id` | string | Yes | Owner, same user id pattern as `todos` |
| `category` | string | Yes | `work`, `person`, `health_fitness`, `life` |
| `status` | string | Yes | `active`, `paused`, `achieved`, `archived` |
| `title` | string | Yes | 4-240 chars |
| `desired_outcome` | string | Yes | 8-2000 chars |
| `why` | string | No | 0-2000 chars |
| `success_metric` | string | No | Qualitative or quantitative target |
| `priority` | integer | Yes | 0-100, default 50 |
| `sensitivity` | string | Yes | `standard`, `sensitive`, `private` |
| `proactive_visibility` | string | Yes | `full`, `summary`, `none` |
| `review_cadence` | string | Yes | `daily`, `weekly`, `monthly`, `manual` |
| `starts_on` | date | No | Defaults to current user-local date |
| `target_at` | utc_datetime_usec | No | Optional target |
| `last_reviewed_at` | utc_datetime_usec | No | Last completed goal alignment review |
| `next_review_at` | utc_datetime_usec | No | Deterministic next review time |
| `metadata` | map | Yes | Default `%{}` |
| `inserted_at` | utc_datetime_usec | Yes | Standard timestamps |
| `updated_at` | utc_datetime_usec | Yes | Standard timestamps |

Indexes:

- `(user_id, status, next_review_at)`
- `(user_id, category, status)`
- `(user_id, updated_at)`

Validation:

- `category` in `~w(work person health_fitness life)`
- `status` in `~w(active paused achieved archived)`
- `sensitivity` in `~w(standard sensitive private)`
- `proactive_visibility` in `~w(full summary none)`
- `review_cadence` in `~w(daily weekly monthly manual)`
- title and desired outcome are required
- `user_id` is never accepted from public params when a controller or LiveView already has the current user; set it programmatically

### 6.2 `goal_progress_updates`

New table: `goal_progress_updates`.

Purpose: append-only timeline for manual updates, agent review summaries, and state changes.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | binary_id | Yes | Primary key |
| `goal_id` | binary_id | Yes | FK to `goals` |
| `user_id` | string | Yes | Denormalized for scoping |
| `source` | string | Yes | `manual`, `agent`, `briefing`, `chat`, `system` |
| `summary` | string | Yes | 4-2000 chars |
| `progress_state` | string | Yes | `on_track`, `at_risk`, `blocked`, `stale`, `achieved`, `unknown` |
| `confidence` | float | No | 0.0-1.0 for agent-authored updates |
| `evidence` | map | Yes | Redacted source pointers and excerpts |
| `metadata` | map | Yes | Default `%{}` |
| `occurred_at` | utc_datetime_usec | Yes | User/event time |
| `inserted_at` | utc_datetime_usec | Yes | Standard timestamps |
| `updated_at` | utc_datetime_usec | Yes | Standard timestamps |

Indexes:

- `(user_id, goal_id, occurred_at)`
- `(user_id, progress_state, occurred_at)`

Rules:

- Agent-authored updates must include evidence pointers when claiming source-backed progress or risk.
- Evidence must be redacted and bounded. Do not store full email bodies, long messages, or full note contents here.
- Manual updates can omit evidence.

### 6.3 `goal_links`

New table: `goal_links`.

Purpose: typed links between goals and existing Maraithon objects without adding goal-specific foreign keys to every table.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | binary_id | Yes | Primary key |
| `goal_id` | binary_id | Yes | FK to `goals` |
| `user_id` | string | Yes | Denormalized for scoping |
| `resource_type` | string | Yes | `todo`, `person`, `insight`, `brief`, `chat_thread`, `memory`, `source_observation`, `scheduled_task` |
| `resource_id` | string | Yes | UUID or stable source key |
| `relationship` | string | Yes | `supports`, `blocks`, `evidence`, `next_move`, `progress`, `context` |
| `source` | string | Yes | `manual`, `agent`, `chat`, `system` |
| `confidence` | float | No | 0.0-1.0 for agent links |
| `metadata` | map | Yes | Default `%{}` |
| `inserted_at` | utc_datetime_usec | Yes | Standard timestamps |
| `updated_at` | utc_datetime_usec | Yes | Standard timestamps |

Indexes:

- unique `(user_id, goal_id, resource_type, resource_id, relationship)`
- `(user_id, resource_type, resource_id)`
- `(user_id, goal_id, relationship)`

Rules:

- Link validation must confirm the linked resource belongs to the same `user_id` when the resource is a Maraithon-owned table.
- Source observations may use stable synthetic ids when the source item is not stored as a local object.
- Links are additive. Removing a link must not delete the target resource.

### 6.4 `goal_review_runs`

New table: `goal_review_runs`.

Purpose: durable audit trail for scheduled and on-demand goal-alignment runs.

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | binary_id | Yes | Primary key |
| `user_id` | string | Yes | Owner |
| `goal_id` | binary_id | No | Null means all active goals |
| `trigger` | string | Yes | `scheduled`, `manual`, `chat`, `briefing`, `system` |
| `status` | string | Yes | `running`, `completed`, `failed`, `partial` |
| `started_at` | utc_datetime_usec | Yes | Start time |
| `finished_at` | utc_datetime_usec | No | End time |
| `source_summary` | map | Yes | Sources attempted, skipped, stale, failed |
| `result` | map | Yes | Counts and bounded finding summaries |
| `error` | map | Yes | Bounded failure details |
| `metadata` | map | Yes | Default `%{}` |
| `inserted_at` | utc_datetime_usec | Yes | Standard timestamps |
| `updated_at` | utc_datetime_usec | Yes | Standard timestamps |

Indexes:

- `(user_id, started_at)`
- `(user_id, goal_id, started_at)`
- `(user_id, status, started_at)`

## 7. Backend and Service Design

### 7.1 New Context

Add `Maraithon.Goals`.

Responsibilities:

- CRUD for goals.
- List active goals for context and UI.
- Compute `next_review_at`.
- Record progress updates.
- Manage goal links.
- Record and serialize review runs.
- Provide bounded prompt snapshots.
- Enforce user scoping.

Representative API:

```elixir
Goals.list_goals(user_id, opts \\ [])
Goals.get_goal(user_id, goal_id)
Goals.create_goal(user_id, attrs, opts \\ [])
Goals.update_goal(user_id, goal_id, attrs, opts \\ [])
Goals.delete_goal(user_id, goal_id, opts \\ [])
Goals.record_progress(user_id, goal_id, attrs, opts \\ [])
Goals.link_resource(user_id, goal_id, attrs, opts \\ [])
Goals.unlink_resource(user_id, goal_id, link_id, opts \\ [])
Goals.context_snapshot(user_id, opts \\ [])
Goals.due_for_review(now \\ DateTime.utc_now(), opts \\ [])
Goals.record_review_run(user_id, attrs, opts \\ [])
```

### 7.2 Context Snapshot Contract

`Goals.context_snapshot/2` returns a bounded map for assistant context.

```elixir
%{
  "active_goals" => [
    %{
      "id" => "...",
      "category" => "work",
      "title" => "Ship Maraithon Goals",
      "desired_outcome" => "A goal-aware Chief of Staff that drives next moves.",
      "priority" => 90,
      "sensitivity" => "standard",
      "proactive_visibility" => "summary",
      "target_at" => "2026-07-01T00:00:00Z",
      "review_cadence" => "weekly",
      "next_review_at" => "2026-06-20T13:00:00Z",
      "latest_progress" => %{
        "progress_state" => "on_track",
        "summary" => "Spec drafted; implementation not started.",
        "occurred_at" => "2026-06-13T00:00:00Z"
      },
      "linked_work_count" => 2,
      "linked_people_count" => 0
    }
  ],
  "counts" => %{
    "active" => 6,
    "review_due" => 2,
    "at_risk" => 1
  }
}
```

Budget rules:

- Default max active goals in prompt context: 12.
- Default max progress update per goal: 1.
- Private goals are excluded unless the request directly references goals or the caller opts into private context for an authenticated direct chat.
- Sensitive goals are summarized by title and intent, not raw evidence.

### 7.3 Goal-Aware Open Loops

Update `Maraithon.OpenLoops.snapshot/2` to include a compact goal section:

- active goals due for review
- goal-linked open todos
- at-risk goals from latest progress update
- stale goals with no progress update beyond cadence

Open-loop output must keep goals separate from todos. A goal is not open work by itself. A goal can cause open work to be created when a review identifies a concrete next action.

### 7.4 Assistant Tools

Add goal tools to the Telegram assistant toolbox, MCP surface, and any shared tool catalog used by chat.

Read tools:

- `list_goals`
- `get_goal`
- `goal_context`

Write tools:

- `create_goal`
- `update_goal`
- `record_goal_progress`
- `link_goal_resource`
- `review_goal_alignment`

Tool safety:

- All tools require `runtime_context.user_id`.
- Write tools validate current-user ownership.
- `create_goal` and `update_goal` must set `user_id` from runtime context, not input.
- Tools must return redacted objects that are safe for the current channel.
- Sensitive/private tool results are channel-aware:
  - direct authenticated web/mobile chat can show details
  - Telegram can show sensitive summaries only if `proactive_visibility` permits it
  - proactive pushes never include private goal details

## 8. Goal Alignment Skill

### 8.1 Skill Boundary

Add `Maraithon.ChiefOfStaff.Skills.GoalAlignment`.

This is an internal Chief of Staff skill. It should not be a separate default agent because goal alignment is core to the Chief of Staff's job and should share source acquisition, attention arbitration, and delivery policy.

Skill id: `goal_alignment`.

User-facing label: `Goal alignment`.

Description: `Reviews active goals against connected context and saves concrete next moves when progress, drift, or blockers are detected.`

### 8.2 Requirements

| Requirement | Required? | Notes |
|---|---|---|
| Goals table | Yes | No skill work without active goals |
| Telegram | Optional | For delivery only |
| Gmail | Optional | Work/person/life evidence |
| Google Calendar | Optional | Schedule and commitment evidence |
| Slack | Optional | Work/person evidence |
| Mac companion | Optional | Notes, reminders, messages, local calendar, files, browser history |
| People/CRM | Optional | Person goal context |

The skill must run with partial sources. A missing connector should appear as source health, not as failure.

### 8.3 Trigger Model

| Trigger | Behavior |
|---|---|
| Scheduled daily lightweight scan | Check goals due soon, stale goals, and goal-linked open work |
| Per-goal review cadence | Deeper source-backed review for due active goals |
| Manual `Review now` | Review selected goal immediately |
| Chat `review my goals` | Run on-demand review and respond in chat |
| Morning briefing cycle | Include high-signal goal alignment findings in the brief |

Default schedule:

- Daily lightweight scan after morning source acquisition is available.
- Weekly deeper review for work, person, and health/fitness goals by default.
- Monthly deeper review for life goals by default.

### 8.4 Review Input

The skill builds a bounded input:

```json
{
  "user_id": "operator",
  "reviewed_at": "2026-06-13T09:30:00Z",
  "trigger": {"type": "scheduled", "source": "chief_of_staff"},
  "goals": [],
  "open_work": {"todos": [], "commitments": [], "insights": []},
  "people": {"linked": [], "recent": []},
  "calendar": {"upcoming": [], "recent": []},
  "gmail": {"recent_relevant_threads": []},
  "slack": {"recent_relevant_messages": []},
  "local_context": {
    "reminders": [],
    "notes": [],
    "messages": [],
    "calendar_events": [],
    "browser_history": [],
    "files": []
  },
  "memory": [],
  "source_health": {}
}
```

Input rules:

- Start from active goals due for review.
- Include existing goal-linked todos regardless of source.
- Pull relationship context for person goals and linked people.
- Pull calendar/reminder context for health, life, and work goals.
- Respect source availability from `SourceScope`.
- Respect sensitivity when selecting evidence.
- Keep evidence bounded and summarized.

### 8.5 Review Output

The model or deterministic fallback produces structured candidates:

```json
{
  "progress_updates": [
    {
      "goal_id": "...",
      "progress_state": "at_risk",
      "summary": "Calendar and open work show no protected training time this week.",
      "confidence": 0.74,
      "evidence": {
        "sources": ["calendar", "reminders"],
        "redacted_summary": "No matching workout blocks found this week."
      }
    }
  ],
  "resource_links": [
    {
      "goal_id": "...",
      "resource_type": "todo",
      "resource_id": "...",
      "relationship": "next_move",
      "confidence": 0.82
    }
  ],
  "todo_candidates": [
    {
      "goal_id": "...",
      "title": "Block three training sessions for next week",
      "summary": "Your running goal is at risk because no training blocks are on the calendar.",
      "next_action": "Choose three 45-minute windows and add them to the calendar.",
      "priority": 75,
      "attention_mode": "act_now",
      "due_at": "2026-06-16T13:00:00Z",
      "evidence": {
        "sources": ["calendar"],
        "redacted_summary": "No training events detected in the next seven days."
      }
    }
  ],
  "briefing_notes": [
    {
      "goal_id": "...",
      "mode": "summary",
      "text": "Your training goal needs a calendar block this week."
    }
  ]
}
```

Output rules:

- Create todos only for concrete next moves.
- Do not create vague todos like `Work on life goals`.
- Do not create a todo if an active equivalent goal-linked todo already exists.
- Use `source: "goals"` and metadata with `goal_id`, `goal_category`, and review run id.
- Sensitive/private output must be downgraded or suppressed according to `proactive_visibility`.
- Progress updates can be stored even when no todo is created.

### 8.6 Alignment Classification

| Classification | Meaning | Result |
|---|---|---|
| `on_track` | Evidence shows progress or current work supports the goal | Record progress update, no interruption by default |
| `at_risk` | Current schedule/work/context likely conflicts with goal | Record update; create todo when concrete next move exists |
| `blocked` | External dependency or missing access blocks progress | Record update; create todo or insight if user action is needed |
| `stale` | No meaningful progress or review evidence beyond cadence | Record update; create review/check-in todo if useful |
| `achieved_candidate` | Evidence suggests the goal may be complete | Ask for confirmation, do not auto-mark achieved |
| `unknown` | Insufficient evidence | Record run result, no progress update unless useful |

## 9. API Contracts

### 9.1 Web LiveView

V1 web route:

| Route | LiveView | Meaning |
|---|---|---|
| `/goals` | `MaraithonWeb.GoalsLive` | Goals list and selected detail workspace |

Query params:

| Param | Allowed values | Meaning |
|---|---|---|
| `id` | UUID | selected goal |
| `status` | `active`, `paused`, `achieved`, `archived`, `all` | status filter |
| `category` | `work`, `person`, `health_fitness`, `life`, `all` | category filter |
| `q` | string | search |

Rules:

- Invalid or unauthorized `id` clears selection.
- No `id` shows list-only state.
- Creating a goal patches to `/goals?id=<goal_id>`.

### 9.2 Mobile REST API

Add endpoints under `/api/mobile` with existing mobile session auth:

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/goals` | List goals |
| `POST` | `/goals` | Create goal |
| `GET` | `/goals/:id` | Show goal |
| `PATCH` | `/goals/:id` | Update goal |
| `DELETE` | `/goals/:id` | Archive goal by default |
| `POST` | `/goals/:id/progress` | Record progress update |
| `POST` | `/goals/:id/review` | Queue or run goal review |

List query params:

- `status`
- `category`
- `q`
- `limit`

Example response:

```json
{
  "goals": [
    {
      "id": "uuid",
      "category": "work",
      "status": "active",
      "title": "Ship Maraithon Goals",
      "desired_outcome": "Maraithon knows my goals and turns them into useful next moves.",
      "why": "This is the core Chief of Staff promise.",
      "success_metric": "Goals tab shipped and daily alignment loop running.",
      "priority": 90,
      "sensitivity": "standard",
      "proactive_visibility": "summary",
      "review_cadence": "weekly",
      "target_at": "2026-07-01T00:00:00Z",
      "last_reviewed_at": null,
      "next_review_at": "2026-06-20T13:00:00Z",
      "linked_work_count": 0,
      "linked_people_count": 0,
      "latest_progress": null,
      "inserted_at": "2026-06-13T00:00:00Z",
      "updated_at": "2026-06-13T00:00:00Z"
    }
  ]
}
```

### 9.3 Serialization

Add `MobileJSON.goal/2`, `MobileJSON.goal_progress_update/1`, and related helpers.

Mobile responses must:

- omit raw evidence by default
- include counts and latest progress summaries
- include full progress history only on show/detail endpoints
- preserve snake_case to match existing mobile API style

## 10. Frontend and Mobile Changes

### 10.1 Web UI

Add:

- `lib/maraithon_web/live/goals_live.ex`
- optional reusable row/detail components if the same layout is needed by other surfaces

Use existing primitives first:

- `panel`
- `button`
- `badge`
- `table`
- `field`
- `c_input`
- `c_textarea`
- `c_select`
- `heading`
- `text`

UI constraints:

- no gradient heroes
- no nested cards
- no oversized marketing copy
- rows over decorative cards
- compact table/list and detail workspace
- category and sensitivity as compact badges
- right-aligned secondary actions

### 10.2 Native Mobile

Add mobile models and API methods:

- `Goal`
- `GoalProgressUpdate`
- `MobileAPIClient.RemoteGoal`
- `MobileAPIClient.listGoals`
- `MobileAPIClient.createGoal`
- `MobileAPIClient.updateGoal`
- `MobileAPIClient.recordGoalProgress`

Recommended visible mobile tabs:

1. Today
2. Goals
3. Work
4. People
5. Chat

This moves Stream out of the primary native tab bar. Stream can remain accessible from Today, settings, or a future secondary destination. This is an assumption because the current native tab bar has five visible product tabs, and adding a sixth risks pushing one into a system `More` tab.

## 11. Agent Behavior Contract

### 11.1 Reactive Chat

When the user asks broad prioritization questions, the assistant should include goals:

- `What should I work on today?`
- `What am I missing?`
- `What should I review?`
- `Am I making progress?`
- `What should I say no to?`

Expected behavior:

1. Load open work and active goals.
2. Prefer concrete next moves that advance high-priority active goals.
3. Call out conflicts when current work appears misaligned.
4. Avoid moralizing or generic coaching.
5. Offer or create concrete todos only when the user asks or the tool policy permits.

### 11.2 Proactive Reviews

The routine loop should produce proactive output only when:

- a high-priority goal is at risk and the next move is concrete
- a goal-linked commitment is overdue or blocked
- a person goal has a clear relationship follow-up
- a work goal has a source-backed opportunity or blocker
- the user explicitly requested routine check-ins for that goal

The loop should not proactively output when:

- the finding is vague
- evidence is weak
- the goal is private
- the user has paused the goal
- existing active work already covers the next move

### 11.3 Morning Briefing

Morning briefing should include at most one compact goal-alignment note unless the user opts into a fuller goal review section.

Examples:

- Work standard: `Goal alignment: Shipping Goals is still the highest-leverage Maraithon work. The spec is drafted; next move is implementation planning.`
- Sensitive summary: `One personal goal has no protected time this week. I saved a private next move in Goals.`
- Private: no proactive mention.

### 11.4 Work Item Creation

Goal-created todos must use:

```elixir
%{
  source: "goals",
  kind: "general",
  attention_mode: "act_now",
  title: "...",
  summary: "...",
  next_action: "...",
  priority: 0..100,
  dedupe_key: "goal:#{goal_id}:#{stable_action_key}",
  metadata: %{
    "goal_id" => goal_id,
    "goal_category" => category,
    "goal_review_run_id" => run_id,
    "evidence_summary" => redacted_summary
  }
}
```

After `Todos.upsert_many/3`, also create a `goal_links` row with:

- `resource_type: "todo"`
- `relationship: "next_move"`
- `source: "agent"`

## 12. Failure Modes and Safeguards

| Failure | Expected behavior |
|---|---|
| Goals context unavailable | Assistant continues without goals and records telemetry/error |
| Goal review source unavailable | Run completes partial with source health visible in review run |
| Model output invalid | Store failed/partial run, do not create todos from malformed output |
| Duplicate next move | Link existing todo instead of creating another |
| Sensitive goal in proactive channel | Summarize or suppress based on visibility |
| Private goal in proactive channel | Suppress |
| User pauses goal during review | Finish run without writing new proactive output |
| Linked resource missing | Keep goal link from being created; do not crash the review |
| Connector stale | Mark source stale and avoid pretending it was checked |

Safety requirements:

- No external write actions from goal review without user approval.
- No direct health/fitness recommendations framed as medical advice.
- No shame, scolding, or moralizing copy.
- All goal writes are user-scoped.
- All evidence excerpts are bounded and redacted.
- Agent-authored confidence must not be shown as a precise score in user-facing UI.

## 13. Observability and Instrumentation

Telemetry events:

| Event | Metadata |
|---|---|
| `[:maraithon, :goals, :create]` | user_id hash, category, sensitivity |
| `[:maraithon, :goals, :update]` | status change, category, sensitivity |
| `[:maraithon, :goals, :review, :start]` | trigger, goal_count, source plan |
| `[:maraithon, :goals, :review, :stop]` | status, elapsed_ms, updates_count, todos_count, links_count |
| `[:maraithon, :goals, :review, :error]` | failure class, trigger |
| `[:maraithon, :goals, :context_snapshot]` | active_count, included_count, private_excluded_count |

Operational metrics:

- active goals per user
- review due count
- review success/failure rate
- goal-linked todo creation rate
- duplicate suppression rate
- sensitive/private suppression count
- top source failure classes

Diagnostics export should include:

- goals
- goal progress updates
- goal links
- goal review runs

Sensitive evidence should remain redacted in diagnostics unless diagnostics already have an explicit secure export mode.

## 14. Rollout and Migration Plan

### 14.1 Phase 1: Persistence and Web CRUD

- Generate migrations with `mix ecto.gen.migration`.
- Add `Maraithon.Goals` context and schemas.
- Add web `/goals` LiveView.
- Add nav entry.
- Add goal CRUD and progress timeline.
- Add compile/build sanity check only unless Kent asks for broader tests.

### 14.2 Phase 2: Assistant Tools and Context

- Add goal tool contracts.
- Add goals to context snapshots.
- Add prompt guidance for goal-aware prioritization.
- Add tool verification fixtures.

### 14.3 Phase 3: Goal Alignment Skill

- Add `GoalAlignment` Chief of Staff skill.
- Use shared source acquisition where available.
- Record review runs.
- Create progress updates, links, and todos.
- Add action arbitration rules for proactive delivery.

### 14.4 Phase 4: Mobile Parity

- Add mobile REST endpoints.
- Add native models/API methods.
- Add visible Goals tab or approved alternative mobile placement.
- Sync goals and latest progress.

### 14.5 Phase 5: Production Dogfood

- Create several real goals:
  - one work goal
  - one person goal
  - one health/fitness goal
  - one life goal
- Run manual review.
- Confirm the Chief of Staff creates only useful concrete next moves.
- Tune source budgets and copy.

## 15. Test Plan and Validation Matrix

Current repo operating mode prefers compile/build sanity checks over broad test runs unless explicitly requested. When implementation starts, use focused tests where risk justifies them, then `mix compile` or the narrowest relevant build gate.

### 15.1 Backend Tests

| Area | Checks |
|---|---|
| Goal changesets | category/status/sensitivity/cadence validation |
| User scoping | cannot read, update, link, or delete another user's goal |
| Review scheduling | next review computed correctly by cadence and status |
| Progress updates | evidence map validation and append-only behavior |
| Goal links | same-user resource validation and duplicate constraint |
| Context snapshot | private/sensitive filtering and budget limits |
| Todo creation | goal review creates deduped goal-linked todos |

### 15.2 LiveView Tests

| Area | Checks |
|---|---|
| `/goals` route | authenticated only |
| List filters | status/category/search |
| Create/edit | valid and invalid inputs |
| Detail selection | invalid id clears selection |
| Sensitive/private UI | correct badges and proactive visibility controls |

### 15.3 Assistant/Tool Tests

| Area | Checks |
|---|---|
| `list_goals` | returns channel-safe active goals |
| `create_goal` | sets user_id from runtime context |
| `update_goal` | cannot change another user's goal |
| `record_goal_progress` | stores update and returns redacted response |
| `review_goal_alignment` | handles partial sources and invalid model output |
| Prompt guidance | broad prioritization includes goals before generic advice |

### 15.4 Mobile Tests

| Area | Checks |
|---|---|
| API client decoding | goals with optional fields |
| Sync | remote goals update local model |
| Tab navigation | Goals visible if mobile tab decision is accepted |
| Error copy | failed updates use existing mobile error style |

### 15.5 Acceptance Checks

- A user can create work, person, health/fitness, and life goals.
- The Goals tab shows active goals, category, status, next review, linked work count, and last progress.
- A selected goal shows details, progress, linked work, linked people, and review controls.
- Chat can create and update a goal through tools.
- Assistant context includes active goals within budget and excludes private goals from broad proactive surfaces.
- Manual `review now` produces a `goal_review_runs` record.
- Goal review can record a progress update without creating a todo.
- Goal review creates a todo only when it has a concrete next move.
- Goal-linked todos are visible in Work and linked back in Goals.
- Sensitive/private visibility rules are enforced in proactive delivery.
- Missing connectors produce partial review metadata rather than false claims.

## 16. Definition of Done

- `goals`, `goal_progress_updates`, `goal_links`, and `goal_review_runs` are migrated and user-scoped.
- `Maraithon.Goals` owns all goal persistence and context snapshots.
- `/goals` is an authenticated top-level web product surface.
- Goal CRUD works through web UI and mobile API.
- Chat/Telegram tools can list, create, update, and review goals safely.
- Active goals are included in assistant context with sensitivity filtering.
- `GoalAlignment` runs as a Chief of Staff skill and records review runs.
- Goal review writes progress, links resources, and creates deduped todos when concrete actions exist.
- Morning briefing and reactive prioritization can use goal context.
- Sensitive/private goal safeguards are covered by focused tests.
- Implementation passes the agreed verification gates for the changed slice.

## 17. Open Questions and Assumptions

### 17.1 Open Questions

1. Should native mobile replace Stream with Goals in the primary tab bar, or should Goals wait for a broader mobile navigation redesign?
2. Should `person` goals require explicit linked people, or can they begin as freeform goals and link people later?
3. Should sensitive goals influence priority silently when not shown, or should the assistant only use sensitive goals when it can mention the goal in the response?
4. Should goal review runs be visible in Stream, or only inside each goal detail?
5. Should goal progress state be user-editable, or only derived from progress updates and review results?

### 17.2 Assumptions

- Kent wants an implementation-ready architecture spec, not code in this turn.
- Web Goals is the first canonical surface.
- Goals should be part of primary navigation because they are central to the Chief of Staff product promise.
- Goals feed `Todos`; they do not replace `Todos`.
- The first production slice should avoid health data integrations and rely on manual/local context for health and fitness goals.
- The Chief of Staff should own goal alignment through a skill rather than requiring users to install a separate goal-specific agent.
- Production-first verification mode remains active until Kent says otherwise.
