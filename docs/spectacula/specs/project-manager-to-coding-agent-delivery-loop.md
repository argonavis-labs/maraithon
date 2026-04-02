# Project Manager To Coding Agent Delivery Loop

Status: Implemented v1
Purpose: Define how project recommendations turn into accepted plans, explicit repo-access grants, coding-agent runs, branches, pull requests, and user-visible status updates inside Maraithon.
Depends on:
- [Project-Oriented Conversational Operator](/Users/kent/bliss/maraithon/docs/spectacula/specs/project-oriented-conversational-operator.md)
- [Unified Telegram Operator Chat](/Users/kent/bliss/maraithon/docs/spectacula/specs/unified-telegram-operator-chat.md)

## 1. Overview and Goals

### 1.1 Problem Statement

Maraithon already has the right raw ingredients:

- project-owned recommendation retrieval through the `github_product_planner`
- project records and project-local memory
- natural-language assistant flows and prepared actions
- OTP-backed agent runtime

What is still missing is the actual product loop from:

`recommendation -> user says yes -> repo access granted -> coding run starts -> branch/PR exists -> user sees status`

Without that loop, the Project Manager and Coding Agent remain adjacent capabilities rather than one coherent delivery workflow.

### 1.2 Goals

- Make project recommendations first-class actionable objects.
- Let the user accept, reject, or defer recommendations in natural language or on the dashboard.
- Request repo access explicitly before any implementation run needs it.
- Launch coding runs from accepted plans with durable state and progress updates.
- Persist branch and PR outcomes so the operator can ask for status later.

### 1.3 Design Principles

- Recommendations are not just chat text; they are durable workflow objects.
- Repo access is explicit and user-auditable.
- Coding runs are tracked jobs, not invisible agent side effects.
- PR creation is an approval-bound delivery action unless the repo grant explicitly allows autonomous PR opening.

## 2. Current State and Problem

### 2.1 Existing Surfaces

Relevant modules:

- [github_product_planner.ex](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/github_product_planner.ex)
- [projects.ex](/Users/kent/bliss/maraithon/lib/maraithon/projects.ex)
- [dashboard_live.ex](/Users/kent/bliss/maraithon/lib/maraithon_web/live/dashboard_live.ex)
- [toolbox.ex](/Users/kent/bliss/maraithon/lib/maraithon/telegram_assistant/toolbox.ex)
- [runtime.ex](/Users/kent/bliss/maraithon/lib/maraithon/runtime.ex)

### 2.2 Current Gaps

| Gap | Why it matters |
|---|---|
| Recommendations are still insight-shaped rather than workflow-shaped | the user cannot accept one and reliably continue later |
| No durable repo-access grant model | implementation cannot proceed safely with clear boundaries |
| No implementation-run record | there is no durable object for branch/PR/progress status |
| No acceptance-to-run tool path | the assistant cannot turn `yes, build that` into a structured launch sequence |

## 3. Scope and Non-Goals

### 3.1 In Scope

- recommendation decision objects
- repo-access grant records
- implementation-run records and events
- natural-language acceptance and status flows
- dashboard visibility for recommendations and coding runs
- GitHub branch and PR result persistence

### 3.2 Non-Goals

- autonomous merging to `main`
- generic multi-provider repo access beyond GitHub in the first pass
- replacing the current planner model
- building a public plugin marketplace for coding agents

## 4. Product Workflow

### 4.1 Recommendation Acceptance

The user sees a project recommendation and says things like:

- `Yes, do that for Maraithon Product.`
- `Turn that into a plan first.`
- `Not now.`

The system should:

- resolve the exact recommendation object
- persist an acceptance, rejection, or deferral decision
- create a plan artifact when needed
- ask for repo access if required and not already granted

### 4.2 Repo Access Grant

Repo access should be a durable grant object, not an implicit chat assumption.

Grant dimensions:

- `repo_full_name`
- `provider`
- `scope` such as `read_only`, `branch_write`, or `pr_open`
- `granted_by_user_id`
- `status`

### 4.3 Coding Run Lifecycle

Once a recommendation is accepted and access is sufficient, Maraithon starts an implementation run.

States:

- `pending_plan`
- `awaiting_repo_access`
- `queued`
- `running`
- `blocked`
- `awaiting_review`
- `completed`
- `failed`

### 4.4 Branch and PR Handling

Each run may produce:

- working branch name
- commit summary
- PR URL
- blocker summary if no PR could be opened

The user should then be able to ask:

- `What happened with that implementation run?`
- `Did the coding agent open a PR?`
- `What is blocked?`

## 5. Data Model

### 5.1 Recommendation Decisions

Add a durable table for user decisions tied back to recommendation sources.

| Field | Meaning |
|---|---|
| `project_id` | owning project |
| `user_id` | owner |
| `source_insight_id` | recommendation source |
| `decision` | `accepted`, `rejected`, `deferred` |
| `decision_note` | optional user rationale |
| `accepted_plan` | normalized implementation plan when created |

### 5.2 Repo Grants

| Field | Meaning |
|---|---|
| `project_id` | owning project |
| `user_id` | owner |
| `provider` | `github` |
| `repo_full_name` | target repo |
| `scope` | `read_only`, `branch_write`, `pr_open` |
| `status` | `active`, `revoked`, `pending` |
| `granted_at` | timestamp |

### 5.3 Implementation Runs

| Field | Meaning |
|---|---|
| `project_id` | owning project |
| `user_id` | owner |
| `agent_id` | coding agent used |
| `recommendation_decision_id` | accepted recommendation |
| `repo_full_name` | target repo |
| `status` | lifecycle status |
| `branch_name` | created branch |
| `pull_request_url` | opened PR when present |
| `result_summary` | operator-facing summary |
| `metadata` | raw run context, model, blockers, commit refs |

## 6. Backend and Assistant Changes

### 6.1 New Assistant Tools

Add tools such as:

- `list_project_recommendations`
- `decide_project_recommendation`
- `grant_project_repo_access`
- `start_implementation_run`
- `list_implementation_runs`

### 6.2 Dashboard Changes

The dashboard should expose:

- project recommendations
- acceptance / defer / reject actions
- repo access status
- implementation run list
- branch / PR links

### 6.3 Coding Run Execution

The first pass should launch the coding run through an existing or dedicated coding-agent behavior with:

- project context
- accepted plan
- repo grant scope
- user memory and project memory

## 7. Safety and Approval Boundaries

| Action | Policy |
|---|---|
| recommendation acceptance | conversational or dashboard confirmation is enough |
| repo access grant | explicit user approval required |
| branch creation | allowed only with active `branch_write` grant |
| PR opening | allowed only with active `pr_open` grant or explicit one-off confirmation |
| merge | always out of scope for this slice |

## 8. Test Plan and Validation Matrix

### 8.1 Backend Tests

- recommendation decision persistence
- repo grant lookup and revocation behavior
- implementation run lifecycle transitions
- PR result persistence

### 8.2 Conversational Tests

- `yes, build that` resolves the right recommendation
- missing repo access triggers a grant request instead of silent failure
- completed runs can be queried naturally later

### 8.3 Verification Gates

- `mix test`
- `mix precommit`
- targeted end-to-end acceptance for `recommendation -> accept -> grant -> run -> PR status`

## 9. Definition of Done

- project recommendations can be accepted, rejected, or deferred as durable workflow objects
- repo access is explicitly granted and auditable
- accepted work can launch a tracked coding run
- coding runs surface progress, blockers, and final results
- branch and PR outcomes are persisted and visible in chat and on the dashboard
- the implementation passes `mix precommit`

## 10. Assumptions

- GitHub is the first repo provider for this workflow.
- The user would prefer explicit repo grants over hidden ambient permissions.
- One accepted recommendation should map to one primary implementation run, with later retries recorded as run events rather than separate unrelated jobs.
