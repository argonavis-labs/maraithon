---
created_at: 2026-05-30T01:39:08Z
created_by: cybrus
cybrus_task_id: D68F5B51-B04C-4F4D-9F0A-CD0B700F5812
project: Maraithon App
status: ready
---
# Spec: Self-serve install flow for Chief of Staff agent

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: D68F5B51-B04C-4F4D-9F0A-CD0B700F5812
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

The file-write and git commands need approval, but the required deliverable is the plan returned as Markdown — so here it is. It's grounded in a live audit of the repo, which **corrected several stale claims in the original spec** (noted in Decision D5).

---

# Plan: Self-serve install flow for Chief of Staff agent

**Ticket:** B637351D — Build self-serve install flow for Chief of Staff agent
**Repo:** `/Users/kent/bliss/maraithon` (Phoenix 1.8 + LiveView, Fly.io)

---

## Objective

A brand-new (non-Kent) user can complete, with **no code changes, seeds, or admin API calls**:

1. Land on `maraithon.com` → sign in via magic link.
2. Connect the required connectors — **Telegram** (delivery) and **Google / Gmail + Calendar** (content) — entirely in-app.
3. Create a project.
4. Click **Install Chief of Staff** on the project dashboard.
5. Receive their first morning brief in Telegram within 24 h (by 08:00 local the next day).

The install must be connector-aware: it must **never** start a "running" agent that can't deliver a brief because Telegram isn't linked. The first brief must contain no Kent- or Runner-specific copy.

---

## Assumptions and Decisions

These resolve the spec's four open questions as decisions to implement.

### D1 — Telegram self-serve via bot deep-link + `/start` token (the blocker)
There is **no** Telegram OAuth route today; Telegram accounts are created only by the webhook (`POST /webhooks/telegram/:secret_path` → `WebhookController.telegram`), `ConnectedAccounts.upsert_manual/3`, or the Companion app's `/companion/auth` device pairing. A web-only user has no path.

**Decision:** add a **bot deep-link connect flow** reusing the existing webhook ingress:
- Mint a short-lived signed token bound to the user (`Phoenix.Token.sign/4`, ~15-min TTL, payload `%{user_id: …}`) — no new table.
- Render `https://t.me/<bot_username>?start=<token>` (button + copyable raw link) on `/connectors` and the dashboard install row.
- User taps it → Telegram sends `/start <token>` to the existing webhook. Add handling: verify token → `ConnectedAccounts.upsert_manual(user_id, "telegram", %{"chat_id" => …, "telegram_user_id" => …})` → reply "✅ Connected to Maraithon."
- Bot username from existing Telegram config (not hardcoded). Companion pairing remains a documented fallback.

Smallest correct solution: no new OAuth provider, no new persistence; reuses `upsert_manual` and `telegram_destination/1`, which `BriefingCron` already checks.

### D2 — Install allowed as `setup_required`, with a resume path (not blocked)
When required connectors are missing, install still creates the `Agent` row but with `install_status: "setup_required"` and `status: "stopped"`. `install_status` is a real enum: `["enabled","paused","setup_required","error","removed"]` (`lib/maraithon/agents/agent.ex:65`). `list_due_morning_agents/1` draws from `Agents.list_resumable_agents()` + `telegram_deliverable?/1`, so a `setup_required` / Telegram-less agent is **automatically skipped** — no silent brief-less "running" agent. The dashboard offers **Finish setup** to flip it to `enabled` + start it once connectors are present.

### D3 — Self-serve is independent of the primary-admin auto-install; no new guard, add a regression test
`AgentMarketplace.ensure_default_installations` → `default_install_allowed?` (`agent_marketplace.ex:178`) is **already gated** to the primary admin (`:explicit` → `primary_admin_user?`; `:primary_admin` → requires `telegram_destination != nil`). The org-specific config (`@primary_admin_chief_of_staff_config`, `agent_marketplace.ex:13-51`: `runner-general`, `Cogniate`, `Glossier`, `runner.now`) is applied **only** on that admin path. Self-serve goes through a different entry point (dashboard event → `Runtime.install_chief_of_staff/2`) and must **not** route through `ensure_default_installations`. **Decision:** no new guard; add a regression test asserting a non-admin self-serve install gets **empty** org-specific config.

### D4 — Capture timezone at install (lightweight), editable later
Default offset is `-5` EST (`briefing_schedules.ex:13`). A non-EST user's first brief would mistime. **Decision:** add a simple timezone/offset select to the install row (default `America/Toronto` / `-5`), persisted into the agent's schedule/config at install, editable post-install via the existing `update_morning_brief_time` event. Not a full IANA picker.

### D5 — Most "de-Kent" work in spec §4 is **already done** (scope reduction)
Live verification contradicts the spec:
- `priv/agents/skills/chief_of_staff/morning_briefing.md` already says **"You are the operator's Chief of Staff"** — no "Kent" copy.
- `assistant_harness.ex` has **no** "write them for Kent" instruction (already "the operator"/"you"). The spec's `:291` ref is **stale**.
- `admin_navigation.ex` `support_email/0` already reads app config (default `support@maraithon.app`) — **not** `kent.fenwick@gmail.com`.
- `acquisition.ex` skill defaults are already empty (`@default_commercial_gmail_queries []`, `@default_slack_key_channels []`).
- `action_cards.ex`, `todos/user_facing_copy.ex`, `telegram_assistant/todo_actions.ex` already normalize "Kent needs…" → "you need…" for any owner.

**Decision:** §4 collapses to a **verify-and-confirm** step plus optionally threading the operator's `Accounts` name into the brief greeting. Do **not** migrate constants that are already isolated.

### D6 — Other decisions
- **Single agent only** — Chief of Staff; no marketplace grid.
- **No `runtime_status` field exists** — the Agent schema uses `status` (running/stopped/…) + `install_status`. Code/spec mentions of `runtime_status` map to `status`.
- **Reuse the install plumbing** — `Agents.installation_attrs/4` (`agents.ex:677`) already reads `project_id`, `delivery_policy`, `connector_grants`, `schedule_policy`, `memory_scope` from opts. The work is to **thread opts** from the LiveView through `Runtime.install_chief_of_staff/2` (the actual path the install event uses — `agents_live.ex:1832-1838`), not to change persistence.

---

## Implementation Plan

### Phase 1 — Telegram self-serve connect (D1; do first, it's the blocker)
1. **Token + helper** (`lib/maraithon/telegram/connect.ex` or in `connected_accounts.ex`): `mint_link(user_id)` → `{deep_link, token}` via `Phoenix.Token.sign` (salt `"telegram-connect"`, 15-min max age); `verify_token/1` → `{:ok, user_id} | {:error, _}`; `bot_username/0` from config.
2. **Webhook handling** in `WebhookController.telegram` (router `post "/webhooks/telegram/:secret_path"`) / its message router: detect `/start <token>` → verify → `ConnectedAccounts.upsert_manual(user_id, "telegram", %{"chat_id" => …, "telegram_user_id" => …})` → confirmation reply. Bad/expired token → friendly "link expired" message, no account.
3. **Connect UI** on `/connectors` (reused by dashboard row): **Connect Telegram** button (Catalyst) rendering the deep link + copyable URL.
4. **Test:** `/start <valid-token>` creates a `"telegram"` `ConnectedAccount` with `chat_id`; expired token does not.

### Phase 2 — Thread install opts to the Chief of Staff install
1. Extend `Runtime.install_chief_of_staff/1` → `/2` accepting `opts` (`project_id`, `delivery_policy`, `install_status`, `status`, schedule/tz) → forward to `Agents.install_agent_package/3` → `installation_attrs/4` (already opt-aware). Keep `/1` as a default wrapper.
2. Confirm `installation_attrs/4` writes `project_id` + `delivery_policy` (it does, `agents.ex:677-702`) — no schema change.
3. Confirm `maybe_start_installed_agent` (`runtime.ex:86-107`) only starts when `install_status == "enabled"`; `setup_required` stays stopped (`start_existing_agent` already rejects `setup_required`).

### Phase 3 — Connector readiness check
Add `AgentMarketplace.connector_readiness(user_id, slug)` (or a `DashboardLive` helper): read `required_connectors` off the `ai_chief_of_staff` package version (populated by `builtin_manifest/1`, grouped by provider — `telegram`, `google`/`gmail`, calendar) → compare against `ConnectedAccounts.get/2` + `telegram_destination/1` → return per-connector `%{provider, label, connected?}` and an overall `ready?`.

### Phase 4 — Install UI on the project dashboard (`DashboardLive`)
1. **Install agent** section (row-oriented, Catalyst per `DESIGN.md`; reuse `core_components.ex` / catalyst-ui-kit — no bespoke Tailwind): one Chief-of-Staff row with name, one-line summary, connector chips (Phase 3), tz select (D4), primary button.
2. Button states:
   - **Unmet** → **Connect connectors** (links `/auth/google` + Phase 1 Telegram connect); secondary **Install anyway (finish later)** → `install_status: "setup_required"`.
   - **Ready** → **Install Chief of Staff** → `enabled`, attach `project_id`, `delivery_policy: %{"telegram" => "enabled"}`, chosen tz, start agent.
   - **Installed** → status (running / setup_required) + **Finish setup** for `setup_required` + link to agent inspect panel.
3. Handler `handle_event("install_chief_of_staff", …)` → compute readiness → `Runtime.install_chief_of_staff(user_id, opts)` with correct `install_status`. **Not** via `ensure_default_installations` (D3).
4. **"What this agent does"** read-only view from the package manifest: prompt summary, 4 bundled skills (`morning_briefing`, `commitment_tracker`, `followthrough`, `travel_logistics`), required connectors, default 08:00 schedule. No new copy.
5. Confirm brief time is editable post-install via existing `update_morning_brief_time` (`agents_live.ex:379` → `BriefingSchedules.update_schedule`); link from dashboard/agent panel.

### Phase 5 — Verify de-Kenting (D5) + operator name
1. Confirm (don't rewrite) the already-generic prompts/copy in D5.
2. If `Accounts` exposes a name, thread it into the brief greeting via `default_config`; else fall back to "you"/"the operator". No org-constant migration.

### Phase 6 — End-to-end smoke test
New `test/maraithon_web/live/self_serve_install_smoke_test.exs` using `ConnCase.log_in_test_user/2` + direct `Repo.insert!` fixtures (no factory lib exists):
- **Happy path:** non-admin → stub Telegram + Google `ConnectedAccount`s → create project → fire `install_chief_of_staff` → assert `Agent` with `behavior: "ai_chief_of_staff"`, `install_status: "enabled"`, correct `project_id`, `delivery_policy.telegram == "enabled"`, picked up by `list_due_morning_agents/1` at scheduled local time.
- **Unmet branch:** no Telegram → `install_status: "setup_required"`, `status: "stopped"`, **not** returned by `list_due_morning_agents/1`.
- **Regression (D3):** self-serve config contains **no** `runner-general`/`Cogniate`/`Glossier`/`runner.now`.

### Phase 7 — Install doc
`docs/install-chief-of-staff.md`: sign in → connect Telegram (deep-link) → connect Google → create project → Install → first brief by 08:00 local next day → how to change brief time / timezone. For a non-Kent user.

---

## Files and Interfaces

**New**
- `lib/maraithon/telegram/connect.ex` (or helpers in `connected_accounts.ex`) — `mint_link/1`, `verify_token/1`, `bot_username/0`.
- `test/maraithon_web/live/self_serve_install_smoke_test.exs`
- `test/.../webhook_controller_telegram_connect_test.exs`
- `docs/install-chief-of-staff.md`

**Modified**
- `lib/maraithon_web/controllers/webhook_controller.ex` (+ telegram message router) — handle `/start <token>`.
- `/connectors` view (`connectors_live.ex`) — Connect Telegram button.
- `lib/maraithon_web/live/dashboard_live.ex` — install section, readiness chips, tz select, `install_chief_of_staff` + `finish_setup` handlers.
- `lib/maraithon/runtime.ex` — `install_chief_of_staff/1` → `/2`; verify start gating.
- `lib/maraithon/agent_marketplace.ex` — `connector_readiness/2`; confirm self-serve avoids `ensure_default_installations`.
- `lib/maraithon/agents.ex` — confirm `installation_attrs/4` opts (no change expected).
- `lib/maraithon_web/live/agents_live.ex` — extract/reuse install + brief-time handlers if shared.
- (Verify-only) `morning_briefing.md`, `assistant_harness.ex`, `admin_navigation.ex`, `acquisition.ex`.

**Reuse:** `ConnectedAccounts.upsert_manual/3`, `.get/2`, `.telegram_destination/1`; `Agents.install_agent_package/3` → `installation_attrs/4`; `BriefingSchedules.list_due_morning_agents/1`, `.update_schedule/2`; `BriefingCron.telegram_deliverable?/1`; `Projects.create_project/2`; `ConnCase.log_in_test_user/2`, `Accounts.get_or_create_user_by_email/1`.

---

## Acceptance Checks

- Fresh non-admin user, no code/seed changes: sign-in → connect Telegram (deep-link) + Google → create project → **Install** → agent scheduled for a brief within 24 h.
- Missing required connector → `install_status: "setup_required"` + `status: "stopped"`, skipped by `list_due_morning_agents/1`, with a working **Finish setup** that flips to `enabled` + running.
- Self-serve agent config has **no** Runner/Kent org constants; first brief addresses the operator generically (or by `Accounts` name).
- Telegram `/start <token>` connect works end-to-end; expired/invalid tokens create nothing and return a friendly message.
- New smoke test + Telegram-connect test pass.
- `mix precommit` clean — note it runs `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`, **and `maraithon.assistant.eval --fail-on-issues`** (budget time for the eval step).
- `docs/install-chief-of-staff.md` exists and is followable by a non-Kent user.

---

## Proof of Work Expectations

- `mix precommit` output (clean), including the assistant eval step.
- `mix test test/maraithon_web/live/self_serve_install_smoke_test.exs` output showing happy-path, `setup_required`, and org-constant regression assertions passing.
- Telegram-connect controller test output.
- Dashboard install-row evidence (screenshots or LiveView render assertions) in all three states: unmet / ready / installed.
- A short D5 verification note (which de-Kent items were already done, with file:line evidence) so the reviewer sees why §4 shrank.
- The new `docs/install-chief-of-staff.md`.

---

## Risks

- **Telegram deep-link UX (highest).** Depends on the bot receiving `/start <token>` via the existing webhook; per-env differences in webhook secret-path or bot username can break it. Mitigate: read config, add the controller test, document the Companion fallback.
- **Token security.** `Phoenix.Token` with short TTL + dedicated salt; treat as a bearer credential. 15-min expiry + best-effort single-use (skip if a telegram account already exists for the user) limit exposure.
- **Stale spec references.** The spec cites `assistant_harness.ex:291` and a Kent support email that no longer exist — following §4 literally wastes effort. This plan replaces §4 with a verify-only step (D5).
- **`maraithon.assistant.eval` in precommit** may be slow/flaky and gate the build; budget time, re-run if it flags unrelated issues.
- **Offset-based timezone** isn't DST-aware; acceptable for v1 with post-install editing (D4), flagged as a follow-up.
- **Scope creep into marketplace UI** — keep to one Chief-of-Staff row.

---

**Note:** I attempted to save this to `/Users/kent/bliss/maraithon/.claude/plans/B637351D-self-serve-install-chief-of-staff.md` (per your global plan-location instruction) but the write needs approval. Approve it and I'll persist the file; otherwise the plan above is the complete deliverable.