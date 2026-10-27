# Agent Manifest and Markdown Skill Harness Specification

Status: Implemented v1
Purpose: Define the target Maraithon agent architecture where agents are database-driven marketplace packages composed from a system prompt, model intelligence, goals, and Markdown skills, while the Elixir application acts as the connector, MCP, tool, state, and safety harness.

Implementation note: Phases 0-6 are implemented in the database-backed marketplace tables, manifest/Markdown skill loader, generic manifest harness, connector/tool catalog, package install lifecycle, run observability, and Markdown-backed Chief of Staff/PM/Coding skill packs. Runtime bootstrap now syncs built-in packages, installs the default Chief of Staff package for the primary operator, and resumes it as a manifest-backed agent so the existing briefing cron can deliver value through Telegram. Manifest-backed package versions must include at least one loadable Markdown skill. Legacy behavior modules remain only as compatibility shims where source behavior shims are still needed for existing acquisition and delivery loops.

Depends on:
- [AI Chief of Staff Skill-Orchestrated Agent Architecture](/Users/kent/bliss/maraithon/docs/spectacula/specs/ai-chief-of-staff-skill-orchestration.md)
- [Chief of Staff Shared Acquisition and Attention Arbitration](/Users/kent/bliss/maraithon/docs/spectacula/specs/chief-of-staff-shared-acquisition-and-attention-arbitration.md)
- [Source-Backed Morning Briefing](/Users/kent/bliss/maraithon/docs/spectacula/specs/source-backed-morning-briefing.md)

## 1. Problem Statement

Maraithon is currently halfway between two architectures:

- behavior modules and Elixir skill adapters encode too much product intelligence
- individual skills still contain prompt policy, model settings, connector assumptions, and fallback behavior
- the runtime has useful primitives for effects, tools, connectors, PubSub, source bundles, and Telegram delivery, but those primitives are not yet exposed as a clean generic harness
- agent identity is spread across behavior modules, builder templates, skill configs, and ad hoc prompt strings
- adding or removing an agent for a user currently means creating or mutating a runtime record, not installing a reusable productized agent package

The desired system is:

> An agent is a database-backed marketplace package made from a system prompt, model/intelligence settings, goals, and Markdown skill files. A user can install, configure, disable, or remove that package. The app is the harness that safely exposes connected accounts, MCP servers, tools, budgets, memory, state, retries, and delivery until the loop finishes.

This moves product intelligence into model-readable artifacts while keeping execution, permissions, and persistence in deterministic code.

## 2. Goals and Non-Goals

### 2.1 Goals

- Make agent configuration explicit and inspectable: system prompt, model, intelligence, goals, skills, connectors, budgets, and delivery policy.
- Move skill instructions into Markdown files that explain when and how to use connector-backed tools.
- Keep Elixir responsible for execution safety: auth, connected account availability, MCP/tool invocation, budget enforcement, idempotency, persistence, retries, and observability.
- Replace one-off behavior-specific LLM calls with a generic agent loop that can reason, call tools, inspect results, and continue until done.
- Preserve high-quality specialized behavior by letting skills carry domain instructions, schemas, examples, and completion criteria.
- Support dynamic skill addition without requiring the main runtime to hardcode labels, prompts, model settings, or connector handling.
- Support an agent marketplace where agents are database records that can be added to or removed from a user's workspace without deploys.
- Separate reusable agent package definitions from per-user installed agent instances.
- Let installed agents carry user-level configuration, connector grants, schedules, and enabled/disabled state without mutating the marketplace package.
- Make semantic failure explicit and visible rather than silently degrading to low-intelligence heuristics.
- Ban semantic keyword heuristics from agent work. If model synthesis or model classification is unavailable, the run must fail visibly instead of fabricating a lower-quality answer.

### 2.2 Non-Goals

- Do not remove deterministic connectors, OAuth, MCP integration, or safety checks.
- Do not let Markdown skills directly execute network calls or bypass authorization.
- Do not require all existing Elixir behavior modules to disappear in one migration.
- Do not build payment, ratings, external publishing, or third-party submission workflows in this slice.
- Do not store secrets, tokens, or user-private source data inside skill Markdown.

## 3. Target Architecture

### 3.1 Marketplace Package and Installed Agent

The architecture separates two concepts that are currently conflated:

| Concept | Scope | Owned by | Purpose |
|---|---|---|---|
| Agent package | Global marketplace/catalog | Maraithon or approved publisher | Reusable definition: prompt, model policy, goals, skills, connector needs, default schedules, tool policy, version metadata. |
| Installed agent | Per user/workspace | User | Runtime instance: enabled state, user-specific config, granted connectors, schedules, budgets, memory scope, delivery targets, project binding. |

The marketplace package is immutable once published. Any material change creates a new package version. An installed agent references a package version and stores only user-specific overrides.

User-facing lifecycle:

1. Browse available agents in the marketplace/catalog.
2. Open an agent detail page showing purpose, required connectors, skills, model/intelligence, expected outputs, and permissions.
3. Click `Add` to install the agent for the user/workspace.
4. Grant required connectors and set optional configuration such as schedule, project scope, or delivery channel.
5. Enable, pause, or remove the installed agent at any time.
6. When a package has an update, review the changelog and upgrade the installed agent to a newer package version.

Removal semantics:

- `disable` pauses future runs and keeps configuration/history.
- `remove` uninstalls the user agent and stops schedules/subscriptions, but preserves prior artifacts/runs for audit unless the user explicitly deletes data.
- package removal from the catalog must not delete installed history.

### 3.2 Agent Definition

An agent is defined by an `AgentManifest`.

| Field | Purpose |
|---|---|
| `id` | Stable package identifier. |
| `version` | Immutable package version identifier. |
| `publisher` | Owner/source of the package. |
| `visibility` | `system`, `private`, `workspace`, or later `public`. |
| `name` | Operator-facing name. |
| `summary` | Marketplace row description. |
| `category` | Marketplace grouping, for example `chief_of_staff`, `sales`, `engineering`, `personal_ops`. |
| `system_prompt` | Base identity, operating rules, voice, and safety posture. |
| `model` | Provider/model selection, for example `gpt-5.4`. |
| `intelligence` | Reasoning effort or equivalent, for example `high` or `xhigh`. |
| `goals` | Ordered durable objectives the agent should optimize for. |
| `skills` | Ordered Markdown skill references. |
| `connectors` | Required and optional connected apps the harness may expose. |
| `tools` | Tool/MCP capability allowlist derived from skills and connectors. |
| `budgets` | Per-run LLM turns, tool calls, token, time, and cost limits. |
| `memory_policy` | What durable memory to fetch and update. |
| `delivery_policy` | Where and when outputs can be sent. |
| `install_policy` | Required setup steps, connector grants, and default enabled state. |

### 3.3 Markdown Skill Pack

A skill is a Markdown capability file plus optional static metadata.

Recommended file shape:

```md
---
id: morning_briefing
label: Morning briefing
description: Build a concise Chief of Staff morning brief.
connectors:
  required: [telegram]
  optional: [gmail, calendar, slack, news]
tools:
  allow:
    - gmail.search
    - calendar.list_events
    - slack.search
    - telegram.send_message
model:
  default_intelligence: high
  default_max_output_tokens: 3200
---

# Skill: Morning Briefing

## Goal
Generate a highly condensed Chief of Staff brief that flags only what changes today's actions.

## When To Use
Use on scheduled morning wakeups or explicit operator requests for a brief.

## Inputs
Describe useful connector data, expected freshness, and minimum viable context.

## Procedure
Step-by-step model-readable operating instructions.

## Output Contract
JSON schema or markdown shape the agent must produce.

## Completion Criteria
The loop is done when the brief is persisted and delivered, or when the operator-visible failure is recorded.

## Failure Handling
What to do when sources, model output, or delivery fails.
```

The Markdown file tells the model how to reason. The harness decides what tools actually exist, whether the account is connected, and whether a call is permitted.

### 3.4 Harness Responsibilities

The Elixir runtime becomes the generic agent harness.

| Harness responsibility | Description |
|---|---|
| Manifest loading | Resolve package version, installed agent overrides, skill Markdown, defaults, and runtime policy. |
| Context assembly | Fetch relevant memory, goals, current event, source health, and available capabilities. |
| Tool exposure | Convert connected apps and MCP servers into a bounded model-facing tool catalog. |
| Execution loop | Run model turns, validate tool calls, execute tools, append results, and continue. |
| Budget enforcement | Stop on LLM/tool/time/token/cost limits with explicit status. |
| Persistence | Record runs, steps, tool calls, artifacts, briefs, insights, todos, and errors. |
| Delivery | Send Telegram or other output only through approved transport code. |
| Observability | Emit run status, model used, intelligence, tool steps, finish reason, failures, and generation mode. |

## 4. Core Domain Model

### 4.1 Marketplace Tables

The database should become the source of truth for available agents and per-user installs.

#### `agent_packages`

| Field | Type | Notes |
|---|---|---|
| `id` | binary_id | Stable package id. |
| `slug` | string | Unique package key, for example `chief_of_staff`. |
| `name` | string | Marketplace display name. |
| `summary` | string | Short row-level description. |
| `description` | text/string | Detail-page description. |
| `publisher` | string | `maraithon`, workspace id, or future external publisher. |
| `category` | string | Marketplace grouping. |
| `visibility` | string | `system`, `private`, `workspace`, future `public`. |
| `status` | string | `draft`, `published`, `deprecated`, `archived`. |
| `latest_version_id` | binary_id | Points to current published version. |
| `metadata` | map | Icons, docs links, screenshots, examples, flags. |

#### `agent_package_versions`

| Field | Type | Notes |
|---|---|---|
| `id` | binary_id | Immutable version id. |
| `agent_package_id` | binary_id | Parent package. |
| `version` | string | Semver or monotonic release id. |
| `manifest` | map | Full AgentManifest snapshot. |
| `skill_refs` | array/map | Markdown skill references and version pins. |
| `connector_requirements` | map | Required/optional connectors and scopes. |
| `tool_policy` | map | Allowlist, approval policy, side-effect policy. |
| `default_config` | map | Default schedules, budgets, delivery settings. |
| `changelog` | string | Human-readable release notes. |
| `status` | string | `draft`, `published`, `deprecated`, `archived`. |
| `published_at` | utc_datetime | Null until published. |

#### `user_agent_installations`

This may initially be represented by the existing `agents` table plus new fields. The target normalized model is:

| Field | Type | Notes |
|---|---|---|
| `id` | binary_id | Installed agent id. |
| `user_id` | string | Owning user/workspace. |
| `agent_package_id` | binary_id | Installed package. |
| `agent_package_version_id` | binary_id | Installed package version. |
| `status` | string | `enabled`, `paused`, `setup_required`, `error`, `removed`. |
| `config` | map | User overrides only. |
| `connector_grants` | map | Which connected accounts this install can use. |
| `schedule_policy` | map | Per-user schedule overrides. |
| `delivery_policy` | map | Per-user delivery targets and approvals. |
| `memory_scope` | map | User/project/workspace memory boundaries. |
| `installed_at` | utc_datetime | Install timestamp. |
| `removed_at` | utc_datetime | Soft-remove timestamp. |

The existing `agents` row can serve as the installed-agent runtime record during migration, but it should stop being the package definition. Its `behavior` should eventually become a generic harness behavior, and package identity should come from package/version references.

### 4.2 Agent Manifest

Persisted in `agent_package_versions.manifest` as an immutable package version. During migration it may also be embedded in `agents.config`.

```json
{
  "package_id": "chief_of_staff",
  "package_version": "1.0.0",
  "agent_version": 2,
  "system_prompt": "You are Kent's Chief of Staff...",
  "model": {
    "provider": "openai",
    "name": "gpt-5.4",
    "intelligence": "high",
    "max_output_tokens": 3200
  },
  "goals": [
    "Surface the highest-leverage action Kent should take next.",
    "Prefer concise action briefs over source inventories."
  ],
  "skills": [
    {"id": "morning_briefing", "source": "priv/skills/morning_briefing.md"},
    {"id": "followthrough", "source": "priv/skills/followthrough.md"}
  ],
  "connectors": {
    "required": ["telegram"],
    "optional": ["gmail", "calendar", "slack", "notaui"]
  },
  "budgets": {
    "llm_turns": 8,
    "tool_calls": 20,
    "timeout_ms": 120000
  },
  "install_policy": {
    "default_status": "setup_required",
    "required_connectors": ["telegram"],
    "optional_connectors": ["gmail", "calendar", "slack"],
    "setup_steps": ["connect_telegram", "grant_google_read", "grant_slack_read"]
  }
}
```

### 4.3 Skill Registry

Replace the current module-only registry with a registry that can resolve:

- Markdown skills
- legacy Elixir adapter skills
- hybrid skills that use Markdown instructions plus Elixir validators

The registry must expose:

| Function | Output |
|---|---|
| `list/0` | All known skill descriptors. |
| `get!/1` | Descriptor by id. |
| `load_instructions/1` | Markdown body and frontmatter. |
| `requirements/1` | Connector and tool requirements. |
| `default_model_policy/1` | Optional skill-level model preferences. |

### 4.4 Tool Catalog

Tools should be described generically, not by behavior-specific code.

Each tool descriptor includes:

| Field | Meaning |
|---|---|
| `name` | Model-facing tool name, for example `gmail.search`. |
| `connector` | Owning connector or MCP server. |
| `description` | Concise model-facing usage note. |
| `input_schema` | JSON schema for arguments. |
| `output_schema` | Result shape or summary contract. |
| `auth_scope` | Required connected account state. |
| `side_effect` | `read`, `write`, or `deliver`. |
| `approval_policy` | Whether the harness can execute automatically. |

## 5. Execution Loop

### 5.1 Run Lifecycle

1. Receive trigger: scheduled wakeup, Telegram message, PubSub connector event, or admin/manual run.
2. Load installed agent.
3. Resolve package version and manifest.
4. Merge package defaults with user installation config.
5. Resolve active skills based on trigger and goals.
6. Build context:
   - system prompt
   - goals
   - relevant skill Markdown
   - connector health
   - available tools
   - memory
   - recent run state
7. Call the configured model with the configured intelligence.
8. If the model requests tools, validate and execute them through the harness.
9. Feed tool results back to the model.
10. Repeat until:
   - model returns a final answer/artifact
   - completion criteria are met
   - budget expires
   - unrecoverable safety or connector failure occurs
11. Persist outputs and delivery status against the installed agent and package version.

### 5.2 Reference Pseudocode

```elixir
installation = AgentInstallations.get_enabled!(trigger.agent_id)
package_version = AgentPackages.version!(installation.agent_package_version_id)
manifest = AgentManifests.materialize!(package_version, installation.config)
run = Runs.start(installation, package_version, trigger)
skills = SkillRegistry.resolve(manifest.skills, trigger)
catalog = ToolCatalog.for(installation.user_id, skills, manifest.connectors, installation.connector_grants)
context = ContextBuilder.build(manifest, skills, catalog, trigger, run)

loop(context, run, budgets) do
  model_result = LLM.complete(context.messages, manifest.model)

  case parse_step(model_result) do
    {:tool_calls, calls} ->
      results = HarnessTools.execute_allowed(calls, catalog, run)
      loop(ContextBuilder.append_tool_results(context, results), run, budgets)

    {:final, artifact} ->
      Artifacts.persist(run, artifact)
      Delivery.dispatch_if_allowed(run, artifact, manifest.delivery_policy)
      Runs.complete(run)

    {:invalid, reason} ->
      Runs.fail(run, reason)
  end
end
```

## 6. Configuration Precedence

Model and intelligence settings must resolve in this order:

1. explicit run override
2. user installation override if allowed by package policy
3. package version manifest model policy
4. active skill model policy if the run is single-skill
5. application default

Rules:

- the resolved model and intelligence must be recorded on every run
- the package id/version and installed agent id must be recorded on every run
- a skill may request higher intelligence, but the harness applies budgets and global policy
- semantic failure must be recorded as `generation_mode: "error"` or equivalent, never silent

## 7. Model-Only Semantic Policy

Deterministic code is allowed to do mechanical work:

- authenticate and select connected accounts
- fetch source records
- bound source windows by time, count, and permissions
- validate schemas
- enforce budgets
- execute approved tools
- persist outputs
- retry failed infrastructure calls

Deterministic code is not allowed to decide semantic relevance or produce user-facing synthesis for an agent.

Forbidden examples:

- keyword filtering promotional email before the model sees it
- classifying email as `review`, `security`, or `billing` via `String.contains?`
- generating a "good enough" morning brief from counts and source rows when the model fails
- summarizing Slack/news/inbox content through templates that look like an AI brief
- silently switching from high-intelligence model synthesis to deterministic fallback text

Required behavior when a model is unavailable or invalid:

1. stop the semantic step
2. persist a run/brief/artifact error with the model, intelligence, finish reason, and failure reason
3. notify the operator when the workflow normally produces an operator-visible artifact
4. do not mark the semantic task as successfully completed
5. do not claim sources were synthesized or understood

The only acceptable non-model output in this path is an explicit error notice, for example:

> Morning briefing generation failed because the configured model did not return a valid synthesized brief. No heuristic or keyword-based fallback was used.

## 8. Connector and MCP Harness

### 8.1 Connector Boundary

Connectors own:

- OAuth and token refresh
- account selection
- raw API calls
- pagination and rate-limit handling
- source health
- normalization into bounded result structs

Skills do not know secrets or call connector modules directly.

### 8.2 MCP Boundary

MCP servers are tool providers in the same catalog.

The harness must:

- discover enabled MCP servers
- list tools/resources
- map MCP tool schemas into model-facing descriptors
- enforce user/account/project permissions
- record tool input/output summaries
- cap large outputs before feeding them back to the model

### 8.3 Side-Effect Policy

| Tool type | Default execution |
|---|---|
| Read-only source inspection | Automatic within budget. |
| Draft creation | Automatic if persisted as draft. |
| External write/send/delete | Requires explicit policy or operator approval. |
| Telegram delivery of scheduled brief | Automatic only when delivery policy allows it. |

## 9. Marketplace and Install UX

### 9.1 Marketplace Index

The marketplace index should be row-oriented and operational, not marketing-heavy. Each row should show:

- agent name
- summary
- category
- required connectors
- installed state for the current user: `not_installed`, `setup_required`, `enabled`, `paused`, `update_available`
- compact actions: `Add`, `Configure`, `Pause`, `Remove`, `Upgrade`

### 9.2 Agent Detail

The detail page should show:

- what the agent does
- model and intelligence default
- goals
- skills included
- connector requirements and scopes
- tool side effects
- default schedule/delivery behavior
- examples of outputs
- version/changelog
- install/configure/remove controls

### 9.3 Add/Remove Flow

`Add` must:

1. create a user installation referencing the selected package version
2. copy package defaults into user config only where overrides are expected
3. validate required connector availability
4. create required schedules/subscriptions only after setup is complete
5. set status to `enabled` or `setup_required`

`Remove` must:

1. pause/disable schedules and subscriptions
2. mark the installation `removed`
3. keep historical runs/artifacts/briefs linked to the old installation and package version
4. prevent new triggers from selecting the removed installation

## 10. Migration Plan

### Phase 0: Package/Install Split

- Add package/version/install concepts while preserving current `agents` behavior.
- Seed current built-in agents as `agent_packages` and `agent_package_versions`.
- Treat existing `agents` rows as installed agents and backfill package references where possible.
- Add marketplace read APIs/UI that list packages and user install status.

### Phase 1: Manifest Envelope

- Add `agent_version: 2` support while preserving current behavior IDs.
- Store system prompt, model policy, goals, skill IDs, and budgets in agent config.
- Update architecture inspection UI/API to show these fields.

### Phase 2: Markdown Skill Loader

- Add `priv/skills/*.md` or `docs/skills/*.md` as the canonical skill source.
- Parse frontmatter and Markdown body.
- Add a skill registry path for Markdown skills.
- Keep existing Elixir skills as legacy adapters.

### Phase 3: Generic Agent Loop

- Introduce `Maraithon.AgentHarness` or equivalent.
- Route model/tool/effect loops through the generic harness.
- Persist run steps and resolved model policy.
- Refactor morning briefing to be a Markdown skill using existing brief persistence and Telegram delivery tools.

### Phase 4: Tool and MCP Catalog

- Normalize existing `Maraithon.Tools` and hosted MCP tools into one catalog.
- Add connector-aware tool availability and side-effect policy.
- Make skill Markdown reference tool names rather than Elixir modules.

### Phase 5: Database-Driven Marketplace Operations

- Add install, pause, remove, and upgrade commands backed by database state.
- Ensure schedules, subscriptions, and triggers select installed agents instead of built-in behavior templates.
- Add package version changelog and upgrade review.
- Add admin controls for publishing/deprecating packages.

### Phase 6: Retire Behavior-Specific Intelligence

- Remove prompt-heavy logic from behavior modules.
- Keep behavior modules only as compatibility shims or launch presets.
- Move domain instructions into Markdown skill files.

## 11. Failure Modes and Safeguards

| Failure | Required behavior |
|---|---|
| Package version missing | Mark installation invalid; do not fall back to a behavior module with similar name. |
| Package deprecated | Existing installs may continue if allowed; new installs blocked. |
| Removed installation receives trigger | Drop trigger and record ignored trigger; do not run. |
| Skill Markdown missing | Mark agent invalid; do not run silently without the skill. |
| Connector unavailable | Tell model source health is unavailable; do not fabricate checked sources. |
| Model incomplete | Treat as failed/incomplete, retry if policy allows, or surface an explicit generation error. |
| Tool output too large | Summarize or page; never dump raw unbounded source rows. |
| Budget exhausted | Persist partial run with `budget_exhausted` status and operator-safe summary. |
| Tool call not allowed | Return structured tool error to model and continue if possible. |
| Delivery fails | Persist artifact and delivery failure separately so retry is possible. |

## 12. Observability

Every run must record:

- run id and manifest version
- installed agent id
- package id and package version id
- active skills
- resolved model and intelligence
- LLM turns
- tool calls
- connector health
- budget usage
- completion status
- generation mode
- delivery status

The morning briefing incident should become diagnosable from one run record: the system should show that `gpt-5.4 high` was requested, whether the model returned incomplete, whether an explicit generation error was surfaced, and which sources were available.

## 13. Test Plan

| Test | Expected result |
|---|---|
| User adds marketplace agent | Installation row is created from package version and moves to `enabled` or `setup_required`. |
| User removes marketplace agent | Installation is soft-removed, schedules/subscriptions stop, prior run history remains readable. |
| Package version updated | Existing install keeps old version until explicit upgrade. |
| Removed installation receives trigger | Harness does not run the agent. |
| Agent manifest with `gpt-5.4 high` | LLM call receives resolved model/intelligence. |
| Markdown skill with Gmail/Slack tools | Tool catalog exposes only connected and allowed tools. |
| Missing Telegram connector for delivery skill | Run stops or produces deliverable failure without claiming sent. |
| Model requests forbidden write tool | Harness rejects call and records policy violation. |
| Morning briefing skill runs | Output is model-synthesized, not raw source inventory. |
| Model returns incomplete JSON | Provider returns incomplete error before any semantic artifact is produced. |
| Model returns invalid semantic output | Operator receives explicit generation error; no heuristic brief is produced. |
| Promotional email appears in source rows | Model receives bounded source data and decides relevance; no keyword pre-filter is applied. |
| MCP tool output is large | Harness truncates/summarizes before next model turn. |
| Skill added by Markdown only | Agent inspection and runtime can discover it without UI hardcoding. |

## 14. Definition of Done

- Agents are available as database-backed package/version records.
- Users can add, configure, pause, remove, and upgrade installed agents without deploys.
- Installed agents reference immutable package versions and store only user-level overrides.
- Agents have explicit persisted system prompt, model/intelligence, goals, skills, connector requirements, and budgets.
- At least one production skill, preferably `morning_briefing`, runs from Markdown instructions.
- The generic harness can execute a model/tool loop against connector-backed tools.
- Skill UI/inspection reads registry metadata, not hardcoded skill IDs.
- Every LLM run records resolved model, intelligence, finish reason, and generation mode.
- Semantic failures produce explicit errors; no agent-facing workflow silently falls back to keyword or template heuristics.
- `mix precommit` either passes or failures are isolated to known unrelated tests with a tracking issue/spec.

## 15. Assumptions

- Marketplace packages are first-party/admin-published in v1; third-party publishing, billing, reviews, and external submission are later.
- Markdown skill files are repository-owned or admin-authored in v1, not arbitrary untrusted user uploads.
- Dynamic skills mean dynamically configured and discovered compiled/Markdown capabilities, not untrusted runtime code execution.
- `agents` can remain the installed-agent runtime table during migration, but package definitions must move out of user mutable config.
- MCP integration remains behind the same auth and policy boundary as native connector tools.
- Existing Elixir skills can remain during migration, but new product intelligence should move into Markdown skill packs.
