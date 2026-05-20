---
created_at: 2026-05-14T18:38:42Z
created_by: cybrus
cybrus_task_id: 7E902F13-AAEA-4A8E-A430-8F3E013C4D1D
project: Maraithon App
status: ready
---
# Spec: Self-serve install flow for Chief of Staff agent

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 7E902F13-AAEA-4A8E-A430-8F3E013C4D1D
- Workflow: WORKFLOW.md

## Dependencies

- None

## Notes

No additional notes were attached to this task.

## Workflow Context

Deterministic Cybrus configuration:
- Execution mode: local Codex CLI with full local workspace access.
- Task source: Orchestrator/Cybrus task queue.
- Workflow file: WORKFLOW.md
- Workflow file found: no
- Human handoff: produce proof of work, then Cybrus writes a local review packet.

Repository workflow instructions:
No repository workflow instructions were found. Use the existing codebase conventions.

## Objective

Ship a self-serve install flow so any non-Kent user can land on `maraithon.fly.dev`, sign in via magic link, connect the required connectors (Telegram + Google), create a project, click **Install Chief of Staff** on the project dashboard, and receive their first day-brief within 24 hours — with no code changes, seeds, or admin calls. Install must gate on connector readiness (never produce a silently brief-less "running" agent), attach the agent to the user's project, and the first brief must contain no Kent- or Runner-specific copy baked into code.

---

## Assumptions and Decisions

**Telegram self-serve path (resolves Open Q1 — the stated blocker).** A working linking path already exists: `InsightNotifications.handle_message_event/1` intercepts `/start` and `/link` to the bot and calls `link_telegram_chat/3`, which resolves the argument as an email via `Accounts.normalize_email` and upserts a `"telegram"` `ConnectedAccount`. So no new connector subsystem is needed.
- **Decision:** Add an in-app **Connect Telegram** affordance that produces a `t.me/<bot_username>?start=<token>` deep link. Telegram `start` params only allow `[A-Za-z0-9_-]`, so an email cannot be passed directly. Use a `Phoenix.Token`-signed, short-lived token (encodes `user_id`, ~15 min TTL) — no new schema. Extend `parse_link_user_id/1` + `link_telegram_chat/3` to accept either an email (today's behavior, kept as documented fallback) **or** a signed token. Exposing raw `user_id` in a deep link is rejected for security (anyone with the link could hijack delivery); the signed token is the chosen design.
- Bot username comes from config (`config :maraithon, Maraithon.Connectors.Telegram, bot_username: ...`); add the key if absent and read it for link generation.

**Other open questions:**
- **Q2 — gating:** Allow install when connectors are missing, persisting `install_status: "setup_required"` (already supported by schema + `Runtime.start_existing_agent`). Never start a brief-less `"enabled"`/`"running"` agent. Requirements-met installs go straight to `"enabled"`.
- **Q3 — auto-install collision:** Yes, guard it. `AgentMarketplace.ensure_default_installations` / `default_install_allowed?` stay keyed to `Accounts.primary_admin_email()`; add an explicit early-return for non-admin users and a test asserting a self-serve user is not double-installed.
- **Q4 — timezone:** Ship v1 with the existing -5h default plus post-install editing via `update_morning_brief_time`; do not add a timezone picker to the install UI. Surface the current brief time + an edit control on the dashboard install row so a non-EST user can fix it immediately.

**Product/engineering decisions:**
- Reuse `Runtime.install_agent_package/3` (already takes `opts`); pass `project_id:` and `delivery_policy:` through — no new install pipeline.
- The install UI is a single row-oriented section per `DESIGN.md` (Catalyst look, `core_components.ex` primitives) — not a marketplace grid.
- Org-specific constants (Slack channels, commercial keywords, `runner.now`) move into per-agent `config` with Kent's current values seeded as **his agent's config**, not the global default. A fresh tenant gets an empty-but-functional config.
- Extract the install logic currently inline in `AgentsLive.handle_event("install_library_agent", …)` into a shared context function so both `AgentsLive` and `DashboardLive` call one path.

---

## Implementation Plan

### Phase 1 — Connector readiness as install-time data
1. Add `AgentMarketplace.required_connectors_for(package)` (or reuse existing accessor) returning the package version's `required_connectors`.
2. Add `Connections.connector_readiness(user_id, required_connectors)` → list of `%{provider, label, connected?, connect_path}`. `connect_path` resolves to `/auth/google` for Google and the Telegram deep link (Phase 4) for Telegram.
3. Define the Chief of Staff requirement set: **Telegram** (required — delivery) and **Google/Gmail + Calendar** (required — content). Confirm `builtin_manifest/1` already lists these; if not, add them.

### Phase 2 — Shared install path
4. Extract install handling from `AgentsLive` into `Maraithon.Agents.install_chief_of_staff(user_id, opts)` (or generalize `install_agent_package` opts handling): accepts `project_id` and `delivery_policy`, computes connector readiness, and sets `install_status: "enabled"` when all required connectors are present, `"setup_required"` otherwise.
5. `AgentsLive` install handler now delegates to the shared function (no behavior change there).
6. Ensure `install_agent_package/3` persists `project_id` onto the `Agent` row and `delivery_policy: %{"telegram" => "enabled"}` into config.

### Phase 3 — Dashboard install UI
7. In `DashboardLive.mount/3` + `handle_params`, assign: the Chief of Staff package, connector readiness, and any existing installed CoS agent for the user.
8. Add an **Install agent** section to the dashboard template: one Catalyst-style row showing name, one-line summary, connector requirement chips (connected/missing), and a primary action button. Button states:
   - **Requirements unmet** → "Connect connectors" linking to `/connectors`, `/auth/google`, and the Telegram deep link; install button labeled "Setup required" / disabled.
   - **Requirements met** → "Install Chief of Staff".
   - **Already installed** → status badge (running / setup_required) + link to the agent inspect panel; show current brief time + inline edit.
9. Add `handle_event("install_chief_of_staff", _, socket)` → calls the shared install function with the user's selected/active `project_id`, flashes result, redirects to the agent panel. Require at least one project to exist (the create-project form is already on this LiveView).
10. Add a read-only "what this agent does" view (modal or panel) sourced from the package manifest: system prompt summary, the four bundled skills, required connectors, default 08:00-local schedule. No new copy.
11. Wire `update_morning_brief_time` so it is reachable from the dashboard install row or linked agent panel.

### Phase 4 — Telegram self-serve connect
12. Add `MaraithonWeb.TelegramLink` helper (or function on the Telegram connector): `deep_link(user_id)` → signs a `Phoenix.Token` (`"telegram-link"`, ~900s TTL) and returns `https://t.me/<bot_username>?start=<token>`.
13. Extend `InsightNotifications.parse_link_user_id/1` (or `link_telegram_chat/3`): if the `/start` arg verifies as a valid `"telegram-link"` token, resolve to that `user_id`; else fall back to the existing email path. Invalid/expired token → friendly "link expired, generate a new one" reply.
14. On `/connectors` and the dashboard install row, render the **Connect Telegram** button with the deep link plus a one-line "or message the bot `/start your@email`" fallback.
15. Confirm the webhook route already feeds `/start` messages into `handle_telegram_event` (it does — `WebhookController.telegram` → `InsightNotifications.handle_telegram_event`).

### Phase 5 — De-Kent the first brief
16. Genericize `priv/agents/skills/chief_of_staff/morning_briefing.md` and `assistant_harness.ex:291`: address "the operator" / "you", and substitute the user's name from `Accounts` when available.
17. Move hardcoded Slack channels, commercial keywords, and `runner.now` domain out of code defaults in `chief_of_staff/acquisition.ex` and `chief_of_staff/skills/morning_briefing.ex` into per-agent `config` keys (e.g. `config["org"]["slack_channels"]`, `["keywords"]`, `["team_domains"]`). Code reads config with empty-list defaults.
18. Seed Kent's existing values as **his agent's config** (migration or `ensure_default_installations` setting them only for the primary admin) — not the global manifest default.
19. Repoint / make configurable the support email in `admin_navigation.ex`.

### Phase 6 — Auto-install guard
20. Add an explicit guard in `ensure_default_installations` / `default_install_allowed?`: only the primary admin email gets the free auto-install; everyone else goes through the self-serve dashboard path.

### Phase 7 — Tests + docs
21. New `test/maraithon_web/self_serve_install_smoke_test.exs` (see Acceptance Checks).
22. New `docs/install-chief-of-staff.md` — one page, non-Kent user voice.

---

## Files and Interfaces

**Modify**
- `lib/maraithon_web/live/dashboard_live.ex` — install section assigns, template, `install_chief_of_staff` handler, brief-time edit reachability.
- `lib/maraithon_web/live/agents_live.ex` — delegate `install_library_agent` to the shared install function.
- `lib/maraithon/agents.ex` / `lib/maraithon/runtime.ex` — shared `install_chief_of_staff/2` (or `install_agent_package/3` opts), connector gating → `install_status`, `project_id` + `delivery_policy` pass-through.
- `lib/maraithon/agent_marketplace.ex` — `required_connectors` accessor; `ensure_default_installations` / `default_install_allowed?` non-admin guard; per-admin org config seeding.
- `lib/maraithon/connections.ex` — `connector_readiness/2`.
- `lib/maraithon/insight_notifications.ex` — `parse_link_user_id/1` / `link_telegram_chat/3` accept signed token.
- `lib/maraithon/connectors/telegram.ex` (or new `lib/maraithon_web/telegram_link.ex`) — `deep_link/1`, `bot_username` config read.
- `priv/agents/skills/chief_of_staff/morning_briefing.md`, `lib/maraithon/assistant_harness.ex` — de-Kent prompts.
- `lib/maraithon/chief_of_staff/acquisition.ex`, `lib/maraithon/chief_of_staff/skills/morning_briefing.ex` — org constants → config reads.
- `lib/maraithon_web/components/admin_navigation.ex` — support email.
- `config/config.exs` (+ runtime) — `bot_username` key if missing.

**Create**
- `test/maraithon_web/self_serve_install_smoke_test.exs`
- `docs/install-chief-of-staff.md`
- Possibly `lib/maraithon_web/telegram_link.ex`

**Key interfaces**
- `Agents.install_chief_of_staff(user_id, project_id: id, delivery_policy: %{...})` → `{:ok, %Agent{}} | {:error, term}`; sets `install_status` from readiness.
- `Connections.connector_readiness(user_id, required_connectors)` → `[%{provider, label, connected?, connect_path}]`.
- `TelegramLink.deep_link(user_id)` → `String.t()`.
- Briefing pickup unchanged: `BriefingSchedules.list_due_morning_agents/1` must select the new agent once `install_status: "enabled"` and Telegram is connected.

---

## Acceptance Checks

- **Happy path:** Fresh user → magic link → connect Telegram (deep link) + Google → create project → click **Install Chief of Staff** → `Agent` row exists with `behavior: "ai_chief_of_staff"`, `install_status: "enabled"`, correct `project_id`, `delivery_policy` telegram-enabled; `BriefingSchedules.list_due_morning_agents/1` picks it up at its scheduled local time.
- **Gating:** Installing with a required connector missing yields `install_status: "setup_required"`, `runtime_status` not `"running"`, and no scheduled brief; UI shows a clear resume path.
- **Telegram link:** A `t.me/<bot>?start=<token>` deep link links the chat to the correct user; expired/invalid token gives a friendly retry message; the `/start <email>` fallback still works.
- **De-Kent:** Rendered first brief for a non-Kent user contains no "Kent", `runner.now`, `Cogniate`/`Glossier`, or hardcoded `runner-general` channel; org config is empty and the brief still renders.
- **Auto-install guard:** A non-admin self-serve user is not auto-installed by `ensure_default_installations`; the primary admin still is.
- **Smoke test** (`self_serve_install_smoke_test.exs`): consumes a magic link → stubs Telegram + Google as connected → creates project → fires the dashboard `install_chief_of_staff` event → asserts the enabled-install assertions above; separately asserts the connectors-missing branch yields `setup_required` + no scheduled brief.
- `mix precommit` clean; `docs/install-chief-of-staff.md` exists and is followable by a non-Kent user.

---

## Proof of Work Expectations

- `mix precommit` output (compile, format, credo, full test suite) — clean.
- New smoke test output showing both the enabled and `setup_required` branches passing.
- Screenshots or LiveView render snippets of the dashboard install section in all three button states (unmet / met / installed).
- A demonstration of the Telegram deep link: generated URL + log/test showing a `/start <token>` webhook event creating the `telegram` `ConnectedAccount`.
- Before/after diff of `morning_briefing.md` and a sample rendered brief for a non-Kent user proving no hardcoded constants.
- `docs/install-chief-of-staff.md` rendered.
- Git diff summary scoped to the files listed above.

---

## Risks

- **Telegram token UX:** Deep-link `start` params are length-limited (~64 chars); a default `Phoenix.Token` payload may exceed this. Mitigation: keep the payload minimal (just `user_id`), verify length in a test, fall back to the documented `/start <email>` path if needed.
- **`bot_username` config:** If not currently set anywhere, the deep link can't be built in some environments. Mitigation: add the config key with a clear runtime error/fallback to the email instructions when unset.
- **Org constants more entangled than the audit suggests:** Moving Slack channels/keywords to config may touch acquisition logic deeper than two files. Mitigation: grep for all literal uses first; if scope balloons, ship config-readiness with empty defaults and leave deep tuning as the stated follow-up (non-goal).
- **`ensure_default_installations` timing:** It runs on boot; a self-serve user created between boots is fine, but verify no race where it re-installs on the next deploy. The non-admin guard covers this — assert it in the test.
- **Briefing offset for non-EST users:** First brief may land at an odd local hour until the user edits it. Accepted for v1; the dashboard edit control is the mitigation.
- **Install with zero projects:** Dashboard install handler must handle "no project yet" gracefully (prompt to create one first) rather than installing an unattached agent.