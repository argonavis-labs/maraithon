---
created_at: 2026-05-30T22:39:54Z
created_by: cybrus
cybrus_task_id: 30CC0092-3355-469F-9FF6-E8B011A59B4C
project: Maraithon App
status: ready
---
# Spec: Self-serve install flow for Chief of Staff agent

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 30CC0092-3355-469F-9FF6-E8B011A59B4C
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

The plan file write needs permission I don't have here, but the deliverable is the plan itself. Here it is.

---

> **⚠️ Status correction (read first).** A codebase audit at `/Users/kent/bliss/maraithon` found this ticket is **substantially already implemented and tested**. The spec's "What's missing" list and its critical Open Question 1 (Telegram self-serve linking) are resolved in code. This is therefore a **verify-and-reconcile plan**, not a greenfield build. The coding agent must first *confirm* the existing implementation — not rebuild the install handler, dashboard section, or smoke test.

## Objective

Confirm that a fresh (non-Kent) user can sign in → connect Telegram + Google → create a project → install Chief of Staff from the project dashboard → and be scheduled for a first morning brief within 24h, with installs gated on connector readiness and no Kent/org-specific copy baked into code. Reconcile the spec's acceptance criteria with what was actually built, run the existing test and `mix precommit` as proof, and close only the genuine residual gaps.

---

## Assumptions and Decisions

- **The implementation already exists.** Verified present and wired:
  - `Agents.install_chief_of_staff/2` + `Runtime.install_chief_of_staff/2` perform connector-readiness gating, set `install_status` `"enabled"` vs `"setup_required"` (runtime `"running"` vs `"stopped"`), pass `project_id`, default `delivery_policy: %{"telegram" => "enabled"}`, validate project ownership, and update-in-place on re-install (`agents.ex:495-556`, `runtime.ex:109-117`).
  - The **project dashboard** (`dashboard_live.ex`) already renders the full install section: readiness chips, missing-connector connect links, project selector, brief-hour + timezone selects, and an `install_chief_of_staff` submit handler (`:356`, render `~1041-1146`, `refresh_chief_of_staff_install/1` `~2578`).
  - **Connector readiness** is computed by `Connections.connector_readiness/3` against `AgentMarketplace.required_connectors_for("ai_chief_of_staff")`.
  - **Telegram self-serve linking (the spec's blocker) is solved**: the connect URL is a signed bot deep-link `TelegramLink.deep_link/1` → `https://t.me/<bot>?start=<signed_token>` (`connections.ex:639`, `telegram_link.ex`), and inbound `/start <token>` / `/link <token>` is verified and the chat linked in `insight_notifications.ex:89,457-470`.
  - The **end-to-end smoke test already exists**: `test/maraithon_web/self_serve_install_smoke_test.exs` — 4 tests (enabled install, setup_required install, finish-setup, `ensure_default_installations` non-admin guard).
  - The **install doc already exists**: `docs/install-chief-of-staff.md`.
  - **Org constants are neutralized**: `@default_slack_key_channels []` (`acquisition.ex:24`); the smoke test asserts `glossier` is absent from a fresh tenant's `commercial_thread_terms`. Kent-name leakage is defended by string-replacers in `action_cards.ex` and `todos/user_facing_copy.ex`.
  - The persisted **behavior is `"manifest_agent"`** with `config["source_behavior"] == "ai_chief_of_staff"` — **not** `behavior: "ai_chief_of_staff"` as the original spec assumed. This plan adopts reality.
- **Decision:** Do not refactor/duplicate `install_chief_of_staff`. The generic `install_agent_package/3` (hard-defaults `enabled/running`) is the intentional *non-gated* path and must not be used for self-serve.
- **Decision:** Treat the existing smoke test as the executable acceptance oracle; extend it rather than writing a new one if a gap appears.
- **Working-tree caveat:** `git status` shows uncommitted edits to `dashboard_live.ex` (plus unrelated files). The install section may be mid-edit — baseline against the working tree, and any drift between the rendered section and the smoke test's selectors (`#chief-of-staff-install`, `#chief-of-staff-install-form`) is an in-scope fix.

---

## Implementation Plan

### Step 0 — Establish baseline (before any code change)
1. From `/Users/kent/bliss/maraithon`: `mix compile --warnings-as-errors`, then `mix test test/maraithon_web/self_serve_install_smoke_test.exs`.
2. Record pass/fail per test. **Branch:**
   - **All green →** ticket is functionally complete; skip to Steps 4–5 and the proof packet.
   - **Any red →** proceed scoped to exactly the failing assertion. Per `CLAUDE.md`, fix the underlying code or intentionally retire obsolete coverage — never game it green.

### Step 1 — Reconcile acceptance criteria with reality
- Correct the criterion from `behavior: "ai_chief_of_staff"` to: `behavior == "manifest_agent"` **and** `config["source_behavior"] == "ai_chief_of_staff"`. Doc-truth fix; verify the test already encodes it (`self_serve_install_smoke_test.exs:85,90`).

### Step 2 — Audit dashboard section against test selectors
- Confirm the working-tree `dashboard_live.ex` still renders the asserted elements/states: `#chief-of-staff-install` ("Ready to install" / "Setup required" / "Ready to enable"), `#chief-of-staff-install-form`, "Connect Telegram"/"Connect Gmail" links, and button labels ("Install Chief of Staff" / "Install for later" / "Finish setup").
- If uncommitted edits broke a selector/label, restore alignment (prefer fixing the view to match the tested contract). Keep Catalyst/row-oriented styling per `DESIGN.md` — no one-off UI.

### Step 3 — Verify the Telegram deep-link fallback
- `TelegramLink.deep_link/1` requires `:telegram, :bot_username`; when set it returns the `t.me` deep-link. Confirm prod/staging config sets `bot_username`.
- The fallback `auth_url("/connectors/telegram", …)` (`connections.ex:639`) has **no matching route** (router only defines `get "/connectors"`, `router.ex:86`), so it can 404 when `bot_username` is unset. Harden it (point fallback at `/connectors`, or add the route). If `bot_username` is configured in prod, downgrade to a documented note.

### Step 4 — Confirm org-constant neutralization for a fresh tenant
- Re-run the `glossier`-absent assertion. Spot-check `acquisition.ex` and `chief_of_staff/skills/morning_briefing.ex` read Slack channels / commercial terms / team domain from per-agent `config` with neutral defaults; ensure no `runner.now` / `runner-general` / commercial keywords remain as code-level defaults.

### Step 5 — Validate the install doc
- Read `docs/install-chief-of-staff.md`; confirm it describes the actual flow: sign in → connect Telegram via the bot deep-link (tap → `/start`) → connect Google → create project → Install → first brief next day at chosen local hour → where to change brief time (`update_morning_brief_time` / dashboard schedule selects). Fix drift, especially any Companion-app-only Telegram framing.

### Step 6 — Full verification
- Run `mix precommit` (`compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`, `maraithon.assistant.eval --fail-on-issues`).

---

## Files and Interfaces

**Read / verify (already implemented — do not rebuild):**
- `lib/maraithon/agents.ex` — `install_chief_of_staff/2` (`:495-556`), `installation_attrs/4` (`:677-703`), `install_agent_package/3` (non-gated).
- `lib/maraithon/runtime.ex` — `install_chief_of_staff/2` (`:112`), `start_existing_agent/1` `setup_required` handling (`:136`).
- `lib/maraithon_web/live/dashboard_live.ex` — install render (`~1041-1146`), `handle_event("install_chief_of_staff", …)` (`:356`), `refresh_chief_of_staff_install/1` (`~2578`), state/label helpers (`~2993-3014`).
- `lib/maraithon/connections.ex` — `connector_readiness/3` (`:181`), `telegram_card/4` (`:617`), connect-URL (`:639`).
- `lib/maraithon_web/telegram_link.ex` — `deep_link/1`, `sign_token/1`, `verify_token/2`, `bot_username/0`.
- `lib/maraithon/insight_notifications.ex` — `/start` & `/link` verification + chat linking (`:89`, `:457-470`).
- `lib/maraithon/connected_accounts.ex` — `upsert_manual/3` (`:97`), `telegram_destination/1`, `get/2`.
- `lib/maraithon/agent_marketplace.ex` — `required_connectors_for/1`, `default_install_allowed?/2`, `ensure_default_installations/0`.
- `lib/maraithon/briefing_schedules.ex` — `list_due_morning_agents/1`, `update_schedule/2`, `summarize_for_prompt/1`.
- `lib/maraithon/runtime/briefing_cron.ex` — `telegram_deliverable?/1`.

**Touch only if a gap is confirmed:** `dashboard_live.ex` (selector realignment, Step 2); `router.ex` / `connections.ex:639` (fallback hardening, Step 3); `chief_of_staff/acquisition.ex`, `chief_of_staff/skills/morning_briefing.ex` (residual org default, Step 4); `docs/install-chief-of-staff.md` (Step 5).

**Test (exists — extend, don't replace):** `test/maraithon_web/self_serve_install_smoke_test.exs`.

---

## Acceptance Checks

- `mix test test/maraithon_web/self_serve_install_smoke_test.exs` — all 4 pass: (a) connected fresh user → `enabled`/`running`, correct `project_id`, `delivery_policy: %{"telegram" => "enabled"}`, picked up by `list_due_morning_agents/1`; (b) unconnected → `setup_required`/`stopped`, **no** due brief; (c) finish-setup → transitions to enabled/running and becomes due; (d) `ensure_default_installations` does not auto-install for a connected non-admin.
- Persisted agent has `behavior == "manifest_agent"` and `config["source_behavior"] == "ai_chief_of_staff"` (corrected criterion).
- Fresh tenant's `commercial_thread_terms` has no Kent/org constants (e.g. `glossier`); no `runner.now` / `runner-general` code defaults remain.
- Telegram linking works without the Companion app: connect action is the signed `t.me/<bot>?start=<token>` deep-link; `/start`/`/link` links the chat (exercisable on staging).
- `docs/install-chief-of-staff.md` matches the shipped flow.
- `mix precommit` is clean.

---

## Proof of Work Expectations

- Terminal output of `mix test …/self_serve_install_smoke_test.exs` showing 4 passing tests (Step 0 baseline, re-run after any fix).
- Terminal output of a clean `mix precommit`.
- A **reconciliation note**: which spec items were found already-implemented (with `file:line` evidence), the `behavior` criterion correction, and the Telegram-blocker resolution mechanism.
- A diff for any residual-gap fix (Steps 2–5). If no code change was needed, state that explicitly with the doc/route verification notes.
- Confirmation of the `bot_username` configuration source backing the deep-link path (Step 3).

---

## Risks

- **Re-building already-shipped code** — the dominant risk if the agent takes the stale spec literally. Mitigated by the Step 0 baseline gate.
- **Uncommitted working-tree edits** to `dashboard_live.ex` may be out of sync with the test's DOM selectors. Mitigated by running the test against the working tree first.
- **Telegram fallback 404** (`/connectors/telegram` has no route) — only bites if `bot_username` is unset. Mitigated by config check + fallback hardening.
- **`maraithon.assistant.eval` flakiness** in `precommit` can fail on unrelated drift — distinguish eval failures from install-flow regressions in the packet.
- **Criterion mismatch confusion** — reviewers expecting `behavior: "ai_chief_of_staff"` may flag a false regression; the reconciliation note documents the `manifest_agent` + `source_behavior` design.
- **Schedule timezone edge cases** (offset vs named tz, DST) are asserted in the test; schedule-select changes must keep those assertions valid.

---

**One note for the human approver:** the original spec is materially out of date — the audit shows the feature, the Telegram blocker, the smoke test, and the doc all already exist in the working tree. I'd recommend approving this as a **verification/reconciliation** task rather than a build. If you instead expect net-new implementation, that suggests the working tree contains someone else's in-flight work that should be reviewed before this task runs. Want me to run the baseline test suite now to confirm green before handoff? (The plan file write was blocked by a permission prompt on `.claude/plans/` — say the word and I'll save it once that's allowed.)