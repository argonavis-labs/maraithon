# Chief of Staff Shared Acquisition and Attention Arbitration

Status: Draft v1
Purpose: Define the next `AI Chief of Staff` slice: one assistant-owned source acquisition layer and one assistant-level attention arbiter that deduplicates provider work, builds bounded source bundles, and merges skill outputs before delivery.
Depends on:
- [AI Chief of Staff Skill-Orchestrated Agent Architecture](/Users/kent/bliss/maraithon/docs/spectacula/specs/ai-chief-of-staff-skill-orchestration.md)

## 1. Overview and Goals

### 1.1 Problem Statement

The shipped `AI Chief of Staff` root already gives Maraithon the right top-level product boundary:

- one assistant-facing behavior
- one internal skill contract
- one builder entry
- one trigger-aware orchestration loop

What it does not yet provide is one acquisition boundary or one assistant-level attention boundary.

Today:

- skills can still rely on their own underlying fetch paths
- adjacent skills can inspect overlapping provider state independently
- same-cycle skill outputs are not yet ranked and capped through one assistant-owned arbiter before downstream staging

That leaves two important gaps:

- duplicate provider work can still happen across Gmail, Calendar, Slack, and news retrieval
- the assistant cannot yet make one clean "what actually deserves interruption right now?" decision before persistence and delivery

### 1.2 Goals

- Acquire overlapping provider inputs once per assistant cycle where practical.
- Build a normalized, bounded `source_bundle` that multiple skills can consume in the same cycle.
- Introduce an assistant-level attention arbiter that ranks and caps same-cycle outputs before they stage delivery.
- Preserve deterministic storage, retries, safety checks, and transport boundaries.
- Keep the current skill model intact rather than replacing it.

### 1.3 Design Principles

- Acquire once, reason many times.
- Trigger scope should shrink the bundle rather than force a full-system refresh.
- Arbitration belongs to the assistant root, not to individual skills.
- Gmail and Calendar sharing matters first; Slack and web/news follow once the common path exists.

## 2. Current State and Problem

### 2.1 Shipped Foundation

Relevant modules:

- [ai_chief_of_staff.ex](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/ai_chief_of_staff.ex)
- [skills.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills.ex)
- [skill.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skill.ex)
- [followthrough.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills/followthrough.ex)
- [travel_logistics.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills/travel_logistics.ex)
- [briefing.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/skills/briefing.ex)
- [source_scope.ex](/Users/kent/bliss/maraithon/lib/maraithon/chief_of_staff/source_scope.ex)

The current system already has:

- internal skill ids and requirements
- shared assistant-owned state
- trigger-aware routing for scheduled, message, and PubSub wakeups
- runtime cleanup of transient trigger context

### 2.2 Remaining Gaps

| Gap | Why it matters |
|---|---|
| No assistant-owned acquisition coordinator | Skills can still depend on separate provider fetch paths |
| No normalized `source_bundle` contract | Adjacent skills cannot reliably share one bounded snapshot |
| No same-cycle attention arbiter | Delivery policy is still partly delegated to downstream insight/brief staging |
| No explicit fetch telemetry by assistant cycle | Duplicate provider work is hard to measure and reduce |

## 3. Scope and Non-Goals

### 3.1 In Scope

- Shared `source_bundle` contract
- Assistant-owned acquisition coordinator
- Trigger-scoped fetch planning
- Assistant-level attention candidate and arbitration contract
- Additive metadata for assistant-origin ranking decisions
- Verification for duplicate-fetch reduction and arbitration behavior

### 3.2 Non-Goals

- Rewriting underlying Gmail, Calendar, Slack, or travel extraction systems
- Replacing insights and briefs as the persistence layer
- Adding end-user skill toggles
- Full interruption-class product policy beyond the minimal arbiter contract

## 4. Proposed Design

### 4.1 Source Bundle Contract

Introduce an assistant-local `source_bundle` map passed to interested skills in a cycle.

| Field | Meaning |
|---|---|
| `trigger` | normalized trigger context for the cycle |
| `fetched_at` | UTC timestamp for the bundle |
| `freshness` | per-source freshness metadata and watermarks |
| `gmail` | account-grouped Gmail snapshot or delta |
| `calendar` | calendar snapshot or delta |
| `slack` | Slack snapshot or delta |
| `web_context` | bounded news/web retrieval for morning brief windows only |
| `source_scope` | assistant-level source policy and allowed provider set |

Rules:

- omit unavailable sources rather than fabricate partial structures
- include connection-health and access-health state beside fetched data
- prefer deltas for reactive cycles and fuller bundles for scheduled briefs

### 4.2 Acquisition Coordinator

Add assistant-owned modules:

- `Maraithon.ChiefOfStaff.SourceBundle`
- `Maraithon.ChiefOfStaff.Acquisition`

Responsibilities:

- inspect enabled skills and current trigger
- compute the minimum provider set needed for this cycle
- fetch Gmail and Calendar first through one shared path
- fetch Slack only when an interested skill or trigger requires it
- fetch web/news only for morning-brief-oriented cycles
- return bounded bundle plus fetch telemetry

### 4.3 Skill Consumption Model

The skill contract stays stable, but the `context` passed into skills gains:

- `source_bundle`
- `assistant_cycle_id`
- `assistant_fetch_telemetry`

Rules:

- skills consume bundle data first
- direct provider fetches are still allowed only as an exception path and should emit telemetry
- exception fetches should be phased out as the bundle surface matures

### 4.4 Attention Candidate Contract

Each skill may emit `attention_candidate` records before persistence.

| Field | Meaning |
|---|---|
| `skill_id` | emitting skill |
| `kind` | `insight`, `brief`, `notice`, or `digest_only` |
| `priority_hint` | skill-local numeric hint |
| `confidence` | model or deterministic confidence |
| `delivery_urgency` | `act_now`, `same_day`, `digest`, or `silent` |
| `payload` | structured candidate payload |
| `explanation` | why this surfaced now |

### 4.5 Attention Arbiter

Add `Maraithon.ChiefOfStaff.AttentionArbiter`.

Responsibilities:

- merge same-cycle candidates from all skills
- rank them at the assistant layer
- cap same-cycle interrupting outputs
- downgrade lower-value items to digest-only when stronger items exist
- annotate persisted artifacts with assistant-origin arbitration metadata

The arbiter should decide things like:

- travel prep due this afternoon beats a routine follow-through digest
- morning brief content should merge rather than send multiple parallel assistant voices
- multiple low-signal items should roll into digest instead of separate pushes

## 5. Backend Changes

### 5.1 New Modules

- `lib/maraithon/chief_of_staff/source_bundle.ex`
- `lib/maraithon/chief_of_staff/acquisition.ex`
- `lib/maraithon/chief_of_staff/attention_arbiter.ex`

### 5.2 Runtime Changes

Update [ai_chief_of_staff.ex](/Users/kent/bliss/maraithon/lib/maraithon/behaviors/ai_chief_of_staff.ex) to:

- build one bundle per cycle
- pass that bundle to interested skills
- collect candidates and route them through the arbiter
- emit telemetry for fetch count, fetch latency, and arbitration decisions

### 5.3 Persistence Changes

No new core persistence tables are required for the first pass.

Add additive metadata to insights and briefs:

- `assistant_behavior`
- `assistant_cycle_id`
- `origin_skill_id`
- `arbitration_rank`
- `arbitration_reason`

## 6. Failure Modes and Safeguards

| Failure | Safeguard |
|---|---|
| shared acquisition fails for one provider | return partial bundle with explicit health metadata; let unaffected skills continue |
| one skill still performs its own fetch | emit telemetry and keep the cycle running |
| arbiter drops too much context | keep demoted items persisted as digest-capable artifacts rather than losing them |
| morning brief bundle becomes too heavy | keep bundle field budgets and fetch only source classes required by the trigger |

## 7. Test Plan and Validation Matrix

### 7.1 Unit Tests

- acquisition planner picks Gmail/Calendar before Slack when only follow-through is active
- morning brief trigger adds web/news acquisition
- arbiter ranks and caps same-cycle candidates deterministically

### 7.2 Integration Tests

- `AI Chief of Staff` cycle fetches Gmail once for overlapping skills
- partial bundle failure does not crash unrelated skills
- same-cycle outputs merge into one assistant-facing delivery plan

### 7.3 Verification Gates

- `mix test`
- `mix precommit`
- targeted fetch-count telemetry assertions for the shared-acquisition path

## 8. Definition of Done

- assistant cycles build one normalized `source_bundle`
- overlapping Gmail/Calendar work no longer causes duplicate fetches inside the same cycle
- skills consume the shared bundle by default
- same-cycle skill outputs flow through one assistant-level arbiter before staging
- persisted artifacts carry additive assistant-origin arbitration metadata
- the implementation passes `mix precommit`

## 9. Assumptions

- Gmail and Calendar sharing is the first optimization target; Slack comes after the common path exists.
- Existing insight and brief storage remains the persistence substrate for this slice.
- The user would prefer less duplicate work and cleaner interruption decisions over a bigger first-pass feature surface.
