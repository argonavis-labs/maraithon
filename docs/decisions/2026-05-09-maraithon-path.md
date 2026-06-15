# Maraithon 6-month Path Decision

Decision date: 2026-05-20

## Status

Decided: double down, but only inside a narrow proof window.

Maraithon stays active through the current Chief of Staff dogfood run and a small alpha push. This is not permission to keep broadening the app. It is permission to prove one product loop: Telegram-first Chief of Staff that turns connected context into durable todos, CRM, memory, and useful proactive messages.

## Context

The original 2026-05-09 question was whether Maraithon should double down, fold into Runner, or pause. At that point the risk was real: the repo had a production app, but the project had gone quiet enough that every new backlog item could become speculative.

The repo state on 2026-05-20 is different. Recent work has shipped the self-serve Chief of Staff install flow, proactive delivery planner, memory primitive, CRM merge/source-evidence delta, and crash-recovery dogfood telemetry. That is enough fresh implementation evidence to justify a focused product proof.

Runner is still the commercial center of gravity. It is moving fast on projects, tasks, automations, MCP/OAuth, release infrastructure, and session persistence. Maraithon should not compete with Runner as a broad app. Maraithon earns another cycle only if it proves a product shape Runner has not yet proven: always-on, Telegram-native personal operating state.

## Why April Stopped

April did not stop because the OTP thesis was obviously wrong. The last visible work was still improving the assistant loop, briefing quality, crash behavior, Telegram flow, and runtime resilience. That looks like a working technical direction, not a hard blocker.

The stop looks like a focus and distribution problem. Runner had urgent commercial surface area, Maraithon had no clear external user proof, and the next obvious Maraithon work was expensive product glue rather than one satisfying feature. That makes it easy for a solo developer to drift away even when the architecture is promising.

The honest risk is that Maraithon could become a private engineering playground: lots of runtime depth, not enough proof that anyone besides Kent gets repeated value from Telegram Chief of Staff. The next phase must attack that risk directly.

## Usage Inventory

Production usage was not queried in this local run. I did not have a verified production Postgres session or admin usage export inside the repo context, so this decision treats external usage as unproven rather than inventing numbers.

Known local facts:

- Maraithon is deployed at `maraithon.com`.
- The codebase supports Telegram, Google, Slack, CRM, todos, memory, Chief of Staff skills, and installable agents.
- There is no committed usage report showing external weekly active users.
- The current active dogfood spec requires 30 days of daily digest evidence before it can be marked done.

Decision implication: assume zero proven external retention until measured. The double-down path must produce retention evidence quickly or stop.

## Runner Gap Analysis

Runner has closed some gaps around projects, task ontology, automations, MCP setup, release infrastructure, and session persistence. It is clearly the broader commercial product.

Maraithon's remaining structural advantage is narrower: Phoenix/OTP as an always-on supervised agent runtime, Telegram as the daily operating surface, and first-party durable state for todos, CRM, memory, source links, and proactive delivery. Runner may eventually absorb those ideas, but the fastest way to know which ideas matter is to dogfood them in Maraithon now.

## Options Considered

### A. Double down

Six-month done state: Kent can run a meaningful part of his day from Telegram, at least 5 alpha users have connected Telegram plus one work source, and at least 2 external users are weekly active because Maraithon catches missed commitments or context.

What gets given up: broad feature exploration, marketplace polish, dashboard-first UI, and any connector work that does not improve the Chief of Staff loop.

Biggest risk: building more infrastructure without proving repeated external value.

Execution probability: medium if scoped to dogfood plus alpha; low if treated as a full six-month product roadmap.

### B. Fold into Runner

Six-month done state: Maraithon is frozen, and its best pieces are ported into Runner: durable open loops, CRM/source links, memory steering, proactive Telegram-like check-ins, and model-deduped todo generation.

What gets given up: Maraithon's clean OTP runtime and the ability to dogfood a focused Telegram-first system quickly.

Biggest risk: Runner absorbs the concepts but loses the personal operating-system shape because its surface area is broader.

Execution probability: high for porting individual ideas, medium for preserving the whole product thesis.

### C. Pause and reassess

Six-month done state: no new Maraithon work beyond keeping production safe; revisit with fresher conviction later.

What gets given up: momentum from the newly shipped Chief of Staff primitives and the chance to collect real dogfood telemetry.

Biggest risk: the project quietly dies without producing a clear learning.

Execution probability: high, but it answers little.

## Decision

Choose double down for one narrow proof window.

Maraithon remains active through 2026-06-19 to complete the 30-day Chief of Staff dogfood run, onboard 3 alpha candidates, and prove whether Telegram-first open-loop capture creates repeated value. If that proof does not materialize, the default next decision is fold the useful pieces into Runner, not keep extending Maraithon indefinitely.

## Conditional Plan

### Next 7 days

- 2026-05-21: deploy current `main`, run `mix maraithon.dogfood_baseline`, and confirm the first dogfood digest is delivered to Telegram.
- 2026-05-22: run the Chief of Staff against Kent's real Gmail/calendar/Slack sources and inspect whether todos, CRM links, and memory updates are source-backed.
- 2026-05-25: invite the first 3 alpha candidates:
  - Charlie: teammate/operator who can validate work-source commitments and Slack/Gmail follow-through.
  - Elena: relationship-heavy user who can validate CRM and "what do I owe this person?" behavior.
  - Dan Bourke: external-context user who can validate connected-context review and source-backed answers.
- 2026-05-27: install or attempt to install Chief of Staff for at least one alpha candidate. If setup fails, fix setup friction before adding new features.

### Next 30 days

- Finish the 30-day dogfood spec with daily digest archive, one crash/recover artifact, and `docs/dogfood/2026-chief-of-staff-30-day.md`.
- Use only three product metrics for the proof window:
  - Did Kent leave proactive Telegram enabled?
  - Did Maraithon create or update durable todos/CRM/memory that Kent trusted without rewriting?
  - Did at least one alpha candidate return after first setup because the system caught something useful?
- Cut or defer any work that does not improve one of those metrics.

### Next 90 days

- If the 30-day proof is positive, keep Maraithon active until 2026-08-18 with a target of 5 connected alpha users and 2 weekly active external users.
- If the 30-day proof is weak, freeze new Maraithon feature work and write a fold plan for Runner.
- If the runtime is stable but users do not retain, fold the runtime ideas into Runner and stop treating Maraithon as a separate product.

## Consequences

- The active backlog should prioritize dogfood telemetry, install reliability, Telegram Chief of Staff quality, source-backed todos, CRM, memory, and correction loops.
- `maraithon.com` stays running through at least 2026-06-19.
- `GOALS.md` stays active, but with a status banner that names the proof window.
- Future PM runs should not generate broad product ideas until the dogfood/alpha proof is complete.
- Runner remains the likely home for any Maraithon primitives that prove useful but do not justify a standalone product.

## Non-Goals During The Proof Window

- No marketplace expansion unless it directly improves Chief of Staff installation.
- No large dashboard UI.
- No speculative connector breadth before Gmail/calendar/Slack/Telegram quality is trusted.
- No new agent behavior that does not leave durable todos, CRM links, memory, or auditable source trails.
