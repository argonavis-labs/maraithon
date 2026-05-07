# Maraithon — Goals

## What it is

Maraithon is an Erlang/OTP-based agent platform. Same job as Runner (`~/bliss/runner`) — be the chief-of-staff that lives alongside your work — but built **agentic-first**, with always-on, long-lived agents instead of request-response sessions.

The bet: OTP's long-lived, supervised, fault-tolerant processes are a near-perfect substrate for agents that need to stay alive for days/weeks, react to events instantly, and recover cleanly from crashes without losing context.

## Primitives

Three building blocks the whole product composes from:

1. **Connectors** — event streams and tool surfaces into the outside world.
2. **Projects** — scoped contexts you create and feed: files, documents, links, briefs.
3. **Agents** — installable, opinionated workers that combine prompt + state + connectors + tools.

## Current state (May 2026)

**Live in production at `maraithon.fly.dev`** — Phoenix 1.8 + LiveView, deployed to Fly (Toronto region), Postgres-backed, encrypted at rest with Cloak. Magic-link sign-in works. The product is real.

**Connectors shipped (9):**
- GitHub, Gmail, Google Calendar, Google Contacts, Slack, Notaui MCP, WhatsApp, Linear, Telegram (Notion is OAuth-ready, not wired up).

**Agents shipped:**
- **Chief of Staff agent** — operational, delivers day briefs and check-ins as actionable todo cards via Telegram, has trigger-aware behaviors, runs holiday planning radar, surfaces follow-throughs.
- **Generic PromptAgent** behavior — anyone can spin up a custom agent on the runtime by writing prompts + subscriptions.

**Platform:**
- Project dashboard exists with agent attachment flows.
- Cross-agent durable user memory persists between sessions.
- Operator events / event bus / effect logs / spend tracking all instrumented.
- LiveView operator workspace ships briefings, todos, inbox refresh in real-time.
- Onboarding proof and self-serve sign-up via magic link.
- Service disconnect notifications.

**Activity:**
- 83 commits in last 90 days; **0 commits in last 30 days** — the project has gone cold mid-flight.
- Last commit: 2026-04-02. The April push delivered the chief-of-staff todo-card flow and project persistence, then went silent.

## The real question (May 2026)

The next 6 months for Maraithon are **not** about building the runtime — that's done. They're about answering one question that's been hanging:

**Is this still the bet, or has Runner (and the broader market) moved past it?**

Three honest possibilities:

1. **Yes, double down.** Maraithon's OTP architecture is a structural advantage for the always-on agent thesis, and the next move is finding 5–10 users who can't live without it. The dormancy is a focus problem, not a product problem.
2. **No, fold the wins back into Runner.** The runtime experiments validated the architecture; the lessons (durable memory, projects-as-context, todo-cards-as-output) get ported into Runner where the GTM is real. Maraithon goes to maintenance mode.
3. **Pause and reassess in 90 days.** Don't kill it, don't push on it, don't pretend it's active. Set a calendar checkpoint to revisit with fresh eyes.

**The next session should pick one of these three. Without a decision, every PM run on Maraithon will keep generating ideas for a project that may not need them.**

## If the answer is "double down" — definition of done in 6 months

**Users:**
- 5 external users running at least one agent against their own accounts (alpha cohort, free).
- 2 weekly-active external users (i.e., the agent is *actually* useful, not just installed).
- One real testimonial worth quoting on a homepage.

**Agents (installable, dogfooded):**
- Chief of Staff agent stable enough to run on Kent's accounts 24/7 without intervention for 30 straight days.
- **Product Manager agent shipped** — the workflow you're reading right now, ported to Maraithon's runtime, replacing the Claude skill.
- A third agent of opportunistic choice. Top candidates:
  - **Inbox triage agent** — drafts replies on priority threads, flags VIPs.
  - **Customer-voice agent** — watches a Slack channel + support inbox, summarizes themes weekly.

**Distribution:**
- A landing page (not just a magic-link sign-in) explaining what Maraithon is, who it's for, and which 1–2 agent types you can install.
- Self-serve install of at least one agent type without any code edits — pick a connector + project, click "install Chief of Staff," done.

**Runtime hardening:**
- Crash recovery proven in production: auto-restart, state intact, in-flight work resumes. Live demo-able.
- Per-agent observability dashboard (event log, effect log, spend) accessible to the user, not just to Kent.

## Non-goals (next 6 months)

- Web UI parity with Runner — start CLI / minimal-LiveView, the runtime is the product.
- Visual agent builder. Agents ship as Elixir code for now.
- Marketplace / multi-tenant SaaS. Single-tenant deploys (Fly.io) only.
- Multi-LLM abstraction layer. Pick one provider and don't fight that war yet.
- Pricing / paid tier. Until weekly-active users exist, charging is theater.

## Big open questions to resolve first

1. **Why did April's momentum stop?** Was it priority, was it blocker, was it boredom? The answer determines whether re-starting is realistic.
2. **Does Maraithon actually have a user other than Kent?** If yes — who, what's their workflow, what do they need next? If no — that's the goal for 6 months.
3. **What's the relationship to Runner getting clearer or muddier?** When Runner ships its next major release, does Maraithon become more or less relevant?

## Relationship to Runner

Runner is the chief-of-staff product Kent is shipping commercially. Maraithon was an explicit experiment in whether OTP gives a structural advantage for the same job. The runtime, primitives, and chief-of-staff agent all *work* — the bet is partly validated. **The remaining question is distribution and dogfood, not architecture.**

If the answer is "fold back into Runner," that's a successful experiment, not a failure.
