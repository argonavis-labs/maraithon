# Project-Oriented Conversational Operator

Status: Implemented foundation v1
Purpose: Define and record the shipped foundation for Maraithon as a project-oriented conversational operator: connected accounts, project-scoped state, operator events, subscriptions, durable todos, user memory, natural-language assistant flows, and a user-facing dashboard that exposes the resulting state cleanly.
Depends on:
- [AI Chief of Staff Skill-Orchestrated Agent Architecture](/Users/kent/bliss/maraithon/docs/spectacula/specs/ai-chief-of-staff-skill-orchestration.md)
- [Unified Telegram Operator Chat](/Users/kent/bliss/maraithon/docs/spectacula/specs/unified-telegram-operator-chat.md)

## 1. Overview and Product Direction

### 1.0 Implementation Note

This broad v2 draft has now been split into a completed foundation spec plus explicit follow-on specs.

Delivered here:

- user-owned projects and project items
- optional `project_id` association on agents
- operator events and agent subscriptions
- durable todos as the assistant's work object layer
- user memory and operator memory surfaced into runtime and chat
- dashboard surfaces for projects, todos, memories, connected accounts, and agent logs
- natural-language assistant flows for todo creation, resolution, and itemized Telegram delivery
- project recommendation retrieval from the existing `github_product_planner`

Deferred into the next explicit spec:

- recommendation acceptance and plan approval as a first-class workflow
- repo-access requests and grants
- coding-agent execution records, branch management, and PR creation

### 1.1 Problem Statement

Maraithon already has the right substrate:

- connected accounts for Gmail, Calendar, Slack, GitHub, Linear, Telegram, and other systems
- OTP agents and scheduling primitives
- a conversation runtime with tool use and durable audit history
- durable project and todo foundations

What it does not yet fully express is the right product model.

The intended product is not "a Telegram bot" and not "a set of tools with commands." It is:

- one operator intelligence harness
- connected to the user's systems
- continuously receiving updates from those systems
- deciding what matters with model-backed reasoning
- keeping durable state across global and project scopes
- speaking with the user like a super ChatGPT for the user's actual working context

The system should feel like:

1. connect accounts once
2. enable specialist agents
3. create projects
4. talk naturally
5. receive proactive briefings and alerts when the model judges that attention is warranted
6. give natural-language feedback so the system becomes better at understanding what matters

### 1.2 Product Thesis

Maraithon should be an event-driven LLM operating layer over the user's connected accounts.

That means:

- new Gmail messages, Slack replies, calendar changes, GitHub commits, issue updates, and user replies become normalized internal events
- installed agents subscribe to the events and wake on relevant triggers
- the assistant answers both general questions and highly specific connected-account questions from current durable state plus live retrieval when needed
- durable state is updated continuously, not rebuilt from scratch on every chat turn
- the assistant can proactively interrupt when the model-backed attention score is high enough
- importance and interruption policy improve over time from user feedback expressed in natural language

### 1.3 Goals

- Make Maraithon an event-driven pub/sub system for connected work, not only a request/response chat loop.
- Keep the user experience natural-language first across proactive pushes and reactive conversation.
- Ensure prioritization and importance judgments are model-mediated rather than hand-authored business heuristics.
- Learn user preferences from natural-language feedback and explicit approvals/rejections.
- Support both global operator state and project-scoped state.
- Allow specialist agents to subscribe to different trigger types and wake windows.
- Turn chief-of-staff, project-manager, and coding-agent workflows into first-class product capabilities.
- Let accepted recommendations flow into implementation and PR creation through higher-power coding agents with explicit repo-access gating.

### 1.4 Non-Goals

- Requiring slash commands or explicit tool invocation for normal operation.
- Building a deterministic natural-language router for product semantics.
- Replacing OTP supervision with a purely prompt-driven runtime.
- Multi-user collaboration and shared project ownership in v1 of this operator model.
- Autonomous write actions with no approval boundary for risky or externally visible changes.

### 1.5 Design Principles

- Conversation first: the user should just talk.
- Event first: connected-account changes should enter the system as durable events.
- AI-mediated prioritization: importance, interrupt-worthiness, and follow-up relevance should be model-scored, not rule-guessed.
- Deterministic plumbing only: use deterministic code for auth state, dedupe, permissions, id lookup, storage, retries, and transport; use the LLM for interpretation and judgment.
- Memory improves operation: user feedback should shape later prioritization and briefing quality.
- Projects are first-class: some work is global, some belongs to a project, and the system must understand both.
- OTP owns reliability: subscriptions, projectors, schedulers, and action waiters must survive crashes and restarts cleanly.

## 2. Current State and Gaps

### 2.1 Relevant Existing Surfaces

Relevant modules and artifacts:

- [`lib/maraithon/connected_accounts.ex`](/Users/kent/bliss/maraithon/lib/maraithon/connected_accounts.ex)
- [`lib/maraithon/agents.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agents.ex)
- [`lib/maraithon/agents/agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/agents/agent.ex)
- [`lib/maraithon/runtime.ex`](/Users/kent/bliss/maraithon/lib/maraithon/runtime.ex)
- [`lib/maraithon/behaviors/inbox_calendar_advisor.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/inbox_calendar_advisor.ex)
- [`lib/maraithon/behaviors/chief_of_staff_brief_agent.ex`](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/chief_of_staff_brief_agent.ex)
- [`lib/maraithon/projects.ex`](/Users/kent/bliss/maraithon/lib/maraithon/projects.ex)
- [`lib/maraithon/todos.ex`](/Users/kent/bliss/maraithon/lib/maraithon/todos.ex)
- [`lib/maraithon/telegram_assistant/context.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/context.ex)
- [`lib/maraithon/telegram_assistant/toolbox.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/toolbox.ex)
- [`lib/maraithon/telegram_assistant/runner.ex`](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/runner.ex)

### 2.2 What Already Exists

| Capability | Current state |
|---|---|
| Connected account model | Implemented and production-shaped |
| Specialist agents | Implemented as behavior-backed OTP agents |
| Project records | Implemented |
| Durable todos | Implemented |
| Conversational assistant | Implemented with tool loop and prepared actions |
| Proactive push channel | Implemented on Telegram |
| Memory surfaces | Implemented via preference memory, operator memory, insights, and conversation state |

### 2.3 Gaps Against the Target Model

| Gap | Why it blocks the target product |
|---|---|
| No first-class internal event model | Connected systems are not yet normalized into one operator event stream |
| No explicit pub/sub contract for installed agents | Agents cannot cleanly declare "wake me for Gmail reply-needed events" or "run me on morning brief window" |
| Importance is still partly surface-specific | The product does not yet consistently route attention through one AI-backed scoring path |
| Feedback learning is not a closed loop | The user can react conversationally, but that feedback is not yet systematically folded into prioritization policy |
| Chief of Staff is not yet a continuous per-message reviewer across sources | The desired "read every email and decide if action is needed" contract is not yet first-class |
| Morning and end-of-day briefing are not yet unified operator products | They exist in pieces, but not as one model-owned operator loop across Slack, Gmail, Calendar, and web context |
| Project Manager to Coding Agent handoff is not yet a product workflow | Recommendations, acceptance, repo access, implementation, and PR creation need a unified path |

## 3. Product Model

### 3.1 Product Vocabulary

| Primitive | Meaning |
|---|---|
| `connected account` | External system the user authorizes Maraithon to inspect or act through |
| `operator event` | Normalized internal representation of a message, state change, timer firing, or user reply |
| `subscription` | Declarative contract saying which events or schedules wake an agent or projector |
| `project` | Durable scoped container for work, memory, recommendations, repos, and attached agents |
| `global state` | Operator-wide memory, attention policy, connected-account state, and cross-project work |
| `project state` | Project-local goals, memory, opportunities, todos, and attached resources |
| `todo` | Durable object representing work the user or system believes still needs attention |
| `attention candidate` | An event or state change that may warrant user interruption if the model scores it highly |
| `briefing` | Scheduled or triggered summary delivered proactively by the system |
| `prepared action` | Durable approval-bound write or operational action |

### 3.2 User Experience Contract

The user should be able to ask broad or specific questions naturally:

- `What matters today?`
- `Anything urgent in my inbox?`
- `What does Slack need from me this morning?`
- `What feature should I work on next for Maraithon Product?`
- `Handled the billing, what else?`
- `Do I have anything risky on my calendar today?`
- `What changed in GitHub since yesterday?`

The assistant should also proactively say things like:

- `Good morning. You have two inbox items that need action, one calendar commitment at risk, and one project recommendation worth reviewing.`
- `You said billing matters less unless it blocks production. I downgraded this one.`
- `The project manager thinks the top feature for Maraithon Product is operator event subscriptions. Want me to have the coding agent draft an implementation plan?`

### 3.3 Specialist Agent Catalog

The initial productized specialist agents should be:

| Template ID | User-facing name | Main inputs | Main outputs |
|---|---|---|---|
| `ai_chief_of_staff` | `Chief of Staff` | Gmail, Calendar, Slack, user memory, web/news context | open loops, morning brief, end-of-day summary, proactive attention candidates |
| `github_product_planner` | `Project Manager` | GitHub repos, issue/project state, project memory | feature recommendations, improvement plans, project opportunities |
| `coding_agent` | `Coding Agent` | accepted plans, repo access, project context | implementation branches, PRs, delivery updates, blockers |

Rules:

- templates remain behavior-backed
- installed agents declare subscriptions and schedules
- the user should not need to know behavior ids or manual trigger names
- the operator assistant may ask for missing access before activating higher-power workflows

### 3.4 State Scopes

| Scope | Examples |
|---|---|
| Global operator state | connected-account health, interruption preferences, global todos, cross-project memory, preferred importance patterns |
| Project state | repos, accepted plans, project-local todos, recommendation backlog, latest delivery summary |
| Ephemeral conversation state | recent turns, pending approvals, referenced objects in the current dialogue |

Rules:

- global state informs all projects
- project state must not silently overwrite global user preferences
- the assistant should infer project scope when safe and ask only when ambiguity materially changes action
- specialist agents may publish to global state, project state, or both depending on their contract

## 4. Attention, Feedback, and Briefing Contract

### 4.1 AI-Backed Importance Only

Product requirement:

- do not use hand-authored business heuristics as the main importance engine
- do not use phrase-matching routers for concepts like "important", "urgent", "needs action", or "should interrupt"
- use model-backed classification and scoring over normalized events plus durable context

Deterministic logic is still valid for:

- auth and connection health
- object lookup and dedupe
- time windows and schedule dispatch
- permission and approval boundaries
- transport retries and error handling

### 4.2 User Feedback Learning

The system must learn what matters from natural-language feedback such as:

- `That was useful.`
- `Don't interrupt me for this kind of thing.`
- `Only flag billing if it blocks production.`
- `Calendar commitments are usually more important than Slack chatter.`
- `This kind of repo cleanup is lower priority unless we are already in that project.`

That feedback should update durable preference state and later affect:

- attention scoring
- push rate
- morning briefing ranking
- inbox triage ranking
- project recommendation ranking

### 4.3 Proactive Push Policy

Pushes should happen only when:

- the model-backed attention score crosses a configured threshold
- the user asked for a follow-up and the trigger condition is met
- a scheduled briefing is due
- a long-running requested job completes

Pushes must include:

- why this surfaced now
- what action is likely needed
- enough context for the user to decide quickly
- approval or follow-up options when appropriate

### 4.4 Chief of Staff Briefing Contract

The Chief of Staff should:

- review incoming Gmail messages and decide whether user action is needed
- continuously watch Slack, Calendar, and inbox state through subscribed events and scheduled refreshes
- produce a morning briefing combining:
  - inbox triage
  - Slack action items
  - today's calendar risks and commitments
  - relevant web/news context
- produce an end-of-day summary covering:
  - what changed
  - what remains open
  - what got done
  - what should roll into tomorrow

## 5. Proposed Architecture

### 5.1 Core Runtime Roles

Introduce the following runtime roles:

| Role | Responsibility |
|---|---|
| `event ingestors` | Turn connected-account changes and user turns into normalized operator events |
| `event bus` | Deliver events to interested projectors, agents, and conversation sessions |
| `state projectors` | Convert events into durable todos, open loops, summaries, and attention candidates |
| `operator assistant` | Conversation-facing LLM harness for question answering, action brokering, and delegation |
| `specialist agents` | Chief of Staff, Project Manager, Coding Agent, and future templates |
| `briefing scheduler` | Fire morning, end-of-day, and periodic review triggers |
| `action broker` | Hold approvals, repo-access requests, and high-risk write boundaries |

### 5.2 Event Bus

Every inbound change should become an `operator_event`.

Canonical event classes:

| Event class | Examples |
|---|---|
| `external_message` | Gmail message, Slack thread reply, GitHub notification |
| `external_state_change` | Calendar event moved, Linear issue changed state, GitHub commit landed |
| `scheduled_trigger` | morning briefing window, end-of-day summary window, periodic repo review |
| `conversation_turn` | user message, user approval, user rejection, natural-language feedback |
| `action_result` | email draft created, PR opened, deploy finished, repo access denied |

Event topics should support routing by:

- `user_id`
- `project_id` when available
- `source`
- `event_class`
- `agent_template`

### 5.3 State Projectors

Projectors subscribe to events and maintain durable queryable state.

Initial projector outputs:

- `todos`
- `open loops`
- `waiting_on`
- `attention candidates`
- `briefing snapshots`
- `project recommendation backlog`

Rules:

- projectors are deterministic in storage and lifecycle
- projector interpretation can call into the LLM harness
- projector outputs must keep provenance back to source events and source objects

### 5.4 LLM Harness Contract

The LLM harness is the decision layer over events and state.

Responsibilities:

- classify whether a new event matters
- score importance and interrupt-worthiness
- synthesize compact summaries
- interpret natural-language feedback
- answer user questions from current global and project state
- decide which specialist to consult
- decide which durable objects to create, update, or close
- prepare write actions and approvals

Constraints:

- no product-semantic phrase routers as the primary behavior engine
- all model decisions must write enough structured output to be auditable
- deterministic fallbacks may handle connection errors, missing access, or object lookup failures

### 5.5 Conversation Runtime

For each user message, the assistant should:

1. load recent conversation context
2. load relevant global state
3. load relevant project state if any
4. include connected-account health and freshness
5. answer from existing state when possible
6. retrieve live context when the question is freshness-sensitive
7. update durable state when the conversation changes operator understanding

The assistant must support both:

- general questions about the user's life/work state
- specific questions about connected-account state

### 5.6 Specialist Agent Subscription Model

Each installed agent should declare:

| Field | Meaning |
|---|---|
| `subscription_topics` | event topics it listens to |
| `trigger_policy` | immediate, batched, scheduled, or manual |
| `wake_window` | optional time-of-day or cadence constraints |
| `scope` | global, one project, or future multi-project |
| `output_contract` | what durable objects it may emit |
| `approval_requirements` | which actions require explicit user confirmation |

This is the pub/sub-style contract that differentiates agents.

Examples:

- `Chief of Staff`: subscribes to Gmail, Slack, Calendar, morning trigger, end-of-day trigger
- `Project Manager`: subscribes to GitHub repo activity, periodic review triggers, accepted feedback on recommendations
- `Coding Agent`: subscribes to accepted plans, approved repo access, code review feedback, blocked-run retries

### 5.7 Chief of Staff Workflow

The Chief of Staff should operate in two loops:

1. Continuous review loop
   - inspect new Gmail, Slack, and calendar events
   - decide whether they create or update user work
   - publish todos, open loops, or attention candidates

2. Scheduled briefing loop
   - morning: summarize inbox triage, Slack, Calendar, and relevant web/news
   - end-of-day: summarize progress, unresolved work, and tomorrow setup

Key requirement:

- email review should be message-aware and user-aware, not thread-title heuristic driven
- decisions should consider user memory, past feedback, project context, and durable preferences

### 5.8 Project Manager Workflow

The Project Manager should:

- periodically inspect new code, repository activity, issues, and project state
- suggest improvements or next features
- persist those as project recommendations
- explain why each recommendation matters now

When the user says yes:

- convert the recommendation into an accepted plan or approved work item
- request missing repo access if needed
- hand off to the Coding Agent

### 5.9 Coding Agent Workflow

The Coding Agent should:

- receive accepted plans plus project context
- request repo access when absent
- use higher-power coding models for implementation runs
- create branches, commits, and PRs when allowed
- report progress and blockers back through the operator assistant

This workflow must remain approval-aware:

- repo access requests are explicit
- PR creation is explicit or policy-bound
- risky deploys or destructive operations require clear confirmation

## 6. Data Model

### 6.1 Existing Durable Entities

These remain part of the model:

| Entity | Role |
|---|---|
| `projects` | project scope container |
| `agents` | installed specialist instances |
| `todos` | durable work objects |
| `prepared_actions` | approval-bound writes |
| `telegram_assistant_runs` and steps | conversation audit |
| memory tables | user preference and operator memory |

### 6.2 New `operator_events`

Add a durable `operator_events` table.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key |
| `user_id` | string | owner |
| `project_id` | UUID nullable | when event resolves to a project |
| `event_class` | string | normalized event type |
| `source` | string | gmail, slack, github, calendar, user, system |
| `source_item_id` | string nullable | provider object id |
| `dedupe_key` | string | per-user unique event key |
| `occurred_at` | utc datetime usec | source event time |
| `payload` | map | normalized source payload |
| `metadata` | map | ingestion and trace metadata |
| timestamps | utc datetime usec | standard |

### 6.3 New `agent_subscriptions`

Add a durable subscription contract for installed agents.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key |
| `agent_id` | UUID | installed agent |
| `user_id` | string | owner |
| `project_id` | UUID nullable | optional project scope |
| `topic` | string | logical pub/sub topic |
| `trigger_policy` | string | immediate, batched, scheduled, manual |
| `wake_window` | map | optional timing constraints |
| `filters` | map | source- or project-specific restrictions |
| `status` | string | active, paused |
| timestamps | utc datetime usec | standard |

### 6.4 New `attention_candidates`

Add a durable attention queue driven by model output.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key |
| `user_id` | string | owner |
| `project_id` | UUID nullable | optional project scope |
| `source_event_id` | UUID | originating event |
| `origin_type` | string | chief_of_staff, project_manager, system |
| `status` | string | pending, surfaced, dismissed, accepted |
| `attention_score` | float | model-scored importance |
| `interrupt_score` | float | model-scored push-worthiness |
| `summary` | string | concise user-facing reason |
| `recommended_action` | string | likely next step |
| `rationale` | map | structured explanation for audit |
| `feedback_state` | map | later user response and learning linkage |
| timestamps | utc datetime usec | standard |

### 6.5 New `feedback_events`

Add a durable record of user feedback that can influence later attention policy.

| Field | Type | Notes |
|---|---|---|
| `id` | UUID | primary key |
| `user_id` | string | owner |
| `project_id` | UUID nullable | optional scope |
| `conversation_turn_id` | UUID nullable | source turn |
| `feedback_type` | string | useful, not_useful, priority_hint, interruption_hint, preference_update |
| `target_type` | string nullable | todo, attention_candidate, project_recommendation |
| `target_id` | string nullable | referenced object |
| `content` | string | natural-language feedback |
| `parsed_policy` | map | model-extracted preference update |
| timestamps | utc datetime usec | standard |

### 6.6 Briefing Artifacts

Morning and end-of-day briefings should be durable objects rather than only sent messages.

They may extend the existing briefs layer or introduce a dedicated `briefing_runs` table, but they must capture:

- source window
- included objects
- model rationale
- delivery outcome
- user feedback

## 7. Backend Changes By Area

### 7.1 Event Ingestion and Normalization

Add new modules for:

- `Maraithon.OperatorEvents`
- source-specific normalizers
- event dedupe and persistence
- topic derivation for subscriptions

Responsibilities:

- normalize provider payloads
- persist canonical events
- publish events into in-app pub/sub
- preserve source provenance

### 7.2 Subscription Registry

Add:

- `Maraithon.AgentSubscriptions`
- schema plus context methods for install/update/pause
- runtime helpers for matching events to subscriptions

### 7.3 State Projection Layer

Extend the current todo and insight model into a projector-oriented layer.

Add or evolve:

- todo projector
- attention candidate projector
- briefing snapshot builder
- project recommendation projector

### 7.4 Assistant Context Assembly

Update assistant context assembly to include:

- relevant events
- open todos
- attention candidates
- connected-account freshness and access state
- installed agent subscriptions
- project recommendation backlog
- durable feedback summaries

### 7.5 Chief of Staff Evolution

Evolve Chief of Staff from periodic summary behavior into:

- per-event review behavior
- scheduled morning briefing behavior
- scheduled end-of-day summary behavior
- user-feedback-aware ranking behavior

### 7.6 Project Manager and Coding Handoff

Add:

- accepted recommendation state
- plan approval flow
- repo-access request flow
- coding-run lifecycle tracking
- PR submission result tracking

## 8. OTP Runtime Implications

### 8.1 Supervisors and Long-Lived Processes

Introduce or reserve:

- `OperatorEventSupervisor`
- `SubscriptionSupervisor`
- `ProjectorSupervisor`
- `BriefingSupervisor`
- `ConversationSessionSupervisor`

Each process type should be narrow and restartable.

### 8.2 Process Responsibilities

| Process | Responsibility |
|---|---|
| `EventDispatcher` | fan out persisted events to interested subscribers |
| `ProjectorWorker` | project one event into durable state |
| `AgentTriggerWorker` | wake a specialist when an event or schedule matches |
| `BriefingWorker` | build and deliver morning or end-of-day brief |
| `ActionWaiter` | wait for approval, repo access, or user reply |

### 8.3 Runtime Rules

- events are persisted before fan-out
- fan-out can be retried without duplicating semantic state
- LLM calls should be wrapped in bounded OTP workers with durable audit rows
- long-running specialist jobs should surface status back to the operator assistant
- failed projectors or brief builders should not block unrelated subscriptions

## 9. Rollout Plan

### 9.1 Phase 1: Foundation

Deliver:

- projects
- durable todos
- project-aware conversational assistant

Status:

- substantially implemented

### 9.2 Phase 2: Event and Subscription Core

Deliver:

- `operator_events`
- `agent_subscriptions`
- in-app pub/sub fan-out
- initial event projectors
- assistant context fed from projected state

### 9.3 Phase 3: Chief of Staff Operator Loop

Deliver:

- per-message chief-of-staff review
- AI-backed attention candidates
- morning briefing across Gmail, Slack, Calendar, and web/news
- end-of-day summary
- learned importance from user feedback

### 9.4 Follow-On: Recommendation To Delivery Loop

The original Phase 4 and Phase 5 scope proved to be a separate product slice rather than unfinished residue inside this foundation spec.

That work is now carried by:

- [Project Manager To Coding Agent Delivery Loop](/Users/kent/bliss/maraithon/docs/spectacula/specs/project-manager-to-coding-agent-delivery-loop.md)

It covers:

- recommendation acceptance
- repo-access requests
- coding-agent execution
- branch and PR lifecycle
- progress reporting and blocker surfacing

## 10. Risks and Failure Handling

| Risk | Mitigation |
|---|---|
| Over-notification | use model-scored interrupt thresholds plus learned user feedback |
| Inconsistent model output | require structured LLM outputs and durable audit traces |
| Stale connected-account understanding | include freshness and connection-health state in every relevant decision |
| Feedback misinterpretation | keep parsed feedback and raw feedback side by side for review and correction |
| Agent thrash from noisy subscriptions | support batched and scheduled trigger policies, not only immediate wakeups |
| Unsafe repo actions | explicit repo-access gating and approval-bound action broker |
| Prompt bloat | fetch detailed state on demand and keep default context compact |

## 11. Test Plan and Validation Matrix

### 11.1 Backend Tests

- operator event normalization and dedupe
- subscription matching and fan-out
- projector idempotency
- attention candidate persistence
- feedback event persistence and preference updates
- morning and end-of-day briefing assembly

### 11.2 Conversational Tests

- general questions answered from global state
- specific connected-account questions answered from relevant projected or live state
- natural-language feedback updates later ranking behavior
- `Handled the billing, what else?` style flows resolve durable todos through the LLM/tool contract
- accepted project recommendations hand off into implementation flows

### 11.3 Runtime and Failure Tests

- projector crash recovery
- duplicate event replay safety
- missed-schedule recovery for briefings
- repo-access denied flow
- failed coding run surfaces a useful blocker update

### 11.4 Verification Gates

- `mix test`
- `mix precommit`
- production smoke check after deploy
- targeted operator acceptance checks for morning brief, end-of-day summary, and recommendation-to-PR loop

## 12. Assumptions

- Telegram remains the first proactive delivery surface, but the core operator model is channel-agnostic.
- LLM judgment is the primary product-semantic engine; deterministic code remains for storage, safety, lookup, and lifecycle.
- The user may have multiple Google accounts connected, and the system should reason across them.
- Project Manager and Coding Agent remain behavior-backed specialist agents rather than a separate plugin platform in v1.
- Web/news context for morning briefings can be pulled through a dedicated retrieval surface rather than embedded hardcoded feeds.

## 13. Definition of Done For This Foundation Slice

This foundation slice is considered achieved when:

- connected systems and conversation turns publish normalized operator events into Maraithon
- installed agents subscribe to event and schedule triggers through a first-class contract
- the assistant answers both general and specific connected-account questions from durable operator state plus live retrieval when needed
- user natural-language feedback updates durable memory and later assistant behavior
- projects are stored per user, support attached agents, and expose project-local items and recommendation retrieval
- durable todos act as the assistant's persistent work layer across dashboard and Telegram surfaces
- Telegram can render actionable work as one message per todo item so the user can resolve or react item-by-item
- the dashboard gives the user direct visibility into projects, todos, memories, connected accounts, and agent activity
- the implementation is covered by tests and passes `mix precommit`
