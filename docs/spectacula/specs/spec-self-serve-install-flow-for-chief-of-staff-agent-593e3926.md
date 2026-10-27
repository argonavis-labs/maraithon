---
created_at: 2026-05-20T13:53:08Z
created_by: cybrus
cybrus_task_id: 593E3926-9CFF-47A0-AEA5-B9A78595A51A
project: Maraithon App
status: ready
---
# Spec: Self-serve install flow for Chief of Staff agent

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 593E3926-9CFF-47A0-AEA5-B9A78595A51A
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

The write to disk was declined — that's fine, the deliverable is the plan itself. Here is the complete refined plan.

> [!IMPORTANT]
> **Critical finding from the codebase audit:** the spec is **stale**. Nearly everything it frames as "missing" — including its self-described "critical blocker" (self-serve Telegram connect) — is already implemented and even covered by an existing three-branch smoke test, and the install doc already exists. I verified this by reading the actual code (`Runtime.install_chief_of_staff/2`, the dashboard install section, `TelegramLink.deep_link/1`, `connector_readiness/3`, the smoke test, and the doc). The plan below re-scopes the work to **verify + one cleanup + sign-off** so a coding agent doesn't rebuild — and regress — working, tested code.

---

# Plan: Self-serve install flow for Chief of Staff agent

**Ticket:** B637351D — Build self-serve install flow for Chief of Staff agent
**Spec:** `.claude/plans/B637351D-D25D-4607-B791-CC1D69592342-spec.md`
**Planning date:** 2026-05-20

---

## Objective

Deliver a verified, fresh-tenant-safe self-serve install path for the Chief of Staff agent: a non-Kent user signs in via magic link → connects Telegram + Google (Gmail/Calendar) → creates a project → clicks **Install Chief of Staff** on the dashboard → and is scheduled for a morning brief within 24h, with install blocked into `setup_required` (never a silently brief-less "running" agent) when required connectors are missing, and with no Kent/org-specific constants baked into the code path that produces the first brief.

**Critical context — read before doing anything.** A current-state audit against `/Users/kent/bliss/maraithon` shows the spec is **substantially already implemented**. The work below is therefore primarily *verification, one targeted cleanup, and sign-off* — **not** a greenfield build. A coding agent that re-implements the install flow, dashboard section, Telegram connect, or smoke test from scratch will duplicate or regress working, tested code. The explicit first step is to confirm the existing implementation, then close only the genuine residual gap.

What already exists and is wired (verified by reading the code):

| Spec item | Status | Evidence |
| --- | --- | --- |
| Install pipeline w/ connector gating | **Done** | `Agents.install_chief_of_staff/2` (`lib/maraithon/agents.ex:502-556`) computes `install_status` `enabled` vs `setup_required` from `Connections.connector_readiness/2`, sets `runtime_status`, defaults `delivery_policy: %{"telegram" => "enabled"}`, passes `project_id`. `Runtime.install_chief_of_staff/2` delegates + starts only when `enabled`+`running` (`runtime.ex` `maybe_start_installed_agent/1`). |
| `setup_required` honored by runtime | **Done** | `Runtime.start_existing_agent/1` returns `:agent_setup_required` and does not start the process (`runtime.ex:122-157`). |
| Dashboard install section | **Done** | `#chief-of-staff-install` section (`dashboard_live.ex:~892-976`), `handle_event("install_chief_of_staff", …)` (`~325-366`), populated by `refresh_chief_of_staff_install/1` (`~2404-2419`) on the 5s refresh. Not behind a flag. |
| Telegram self-serve connect ("the blocker") | **Done** | `TelegramLink.deep_link(user_id)` → `https://t.me/<bot>?start=<signed 15-min token>`; `/start <token>` webhook handler creates the `telegram` `ConnectedAccount` (`insight_notifications.ex:392-479`). Surfaced on `/connectors` telegram card AND the dashboard missing-readiness "Connect Telegram" link (both via `connect_path`). |
| `project_id` attached on install | **Done** | Dashboard handler passes `project_id`; smoke test asserts `agent.project_id == project.id`. |
| Read-only "what this agent does" | **Done** | Agents inspect/apps/skills panels (`agents_live.ex:~909-1082`); dashboard links to `…&panel=inspect`. |
| Post-install brief-time / timezone editing | **Done** | `update_morning_brief_time` (`agents_live.ex:375-407`) → `BriefingSchedules.update_schedule/2` updates `morning_brief_hour_local` / `timezone_offset_hours`. |
| Brief scheduling pickup | **Done** | `BriefingSchedules.list_due_morning_agents/1` (default 08:00, -5h offset) + `telegram_deliverable?/1`; `BriefingCron` polls 60s. |
| `ensure_default_installations` guard vs self-serve | **Done** | `default_install_allowed?/2` requires primary admin; self-serve uses the separate `install_chief_of_staff` path. Covered by smoke test #3. |
| Kent/org de-hardcoding (prompts, support email, acquisition) | **Done** | `morning_briefing.md` uses "you"/"the signed-in user"; `assistant_harness.ex` voice contract is generic; `acquisition.ex` defaults empty + config-driven; support email is config (`support@maraithon.app`). |
| End-to-end smoke test | **Done** | `test/maraithon_web/self_serve_install_smoke_test.exs` — 3 tests: enabled install, `setup_required`, bootstrap-guard for connected non-admin. |
| Install doc | **Done** | `docs/install-chief-of-staff.md` — non-Kent, covers connect → install → setup_required → first brief. |

The **only genuine residual code gap** against the acceptance criteria is one org-specific constant in a default keyword list — `"glossier"` in `@commercial_thread_terms` (`lib/maraithon/chief_of_staff/skills/morning_briefing.ex:69`). Because that list merges as `defaults ++ configured`, a fresh tenant inherits `"glossier"`, violating the criterion *"no org-specific constants baked into code."* Everything else is verification and proof of work.

---

## Assumptions and Decisions

Decided without follow-up per the planning brief; these resolve the spec's open questions using the now-known state of the code.

- **Do not rebuild working code.** Treat the existing implementation as source of truth. Only fill the residual gap and prove the path. Any change to install/dashboard/Telegram/runtime code must be justified by a failing test or a concrete acceptance-criterion miss, not by the spec's (stale) "what's missing" list.
- **Open Q1 (Telegram self-serve) → resolved: bot deep-link.** Already implemented via `TelegramLink.deep_link/1` + the `/start` webhook. No new connect flow needed. The `/start your@email.com` fallback also exists.
- **Open Q2 (block vs `setup_required`) → resolved: `setup_required`.** Install is allowed and recorded `setup_required` + `stopped` when connectors are missing; never starts a brief-less running agent. Already implemented + tested.
- **Open Q3 (`ensure_default_installations` guard) → resolved: guard exists.** `default_install_allowed?/2` is keyed to the primary admin; self-serve cannot collide. No change. Regression-covered by smoke test #3.
- **Open Q4 (timezone) → resolved: -5h default + post-install edit.** Acceptable for v1; edit path exists. No up-front timezone prompt in v1.
- **`"glossier"` is the one org constant to move; the rest of the list is generic.** Remove `"glossier"` from the hardcoded default. `"team plan"` / `"ultra plan"` are borderline (possible Runner plan tiers) but plausibly generic SaaS terms; leave them and call them out rather than over-trim.
- **Preserve Kent's tuning when moving `"glossier"`.** Since the merge is `defaults ++ configured`, Kent keeps the term by putting it in his agent's per-agent config rather than the global default. Apply it to the primary admin's installed agent config; do not silently drop Kent's behavior.
- **No suite was executed during planning.** "Done" above means *reading the code*, not *running it*. Completion is therefore gated on actually running `mix precommit` and the smoke test; no success may be claimed without that output.
- **Scope guardrails from the spec hold:** Chief of Staff only (no marketplace UI), no landing page, no visual builder, no deep per-tenant Slack/keyword tuning beyond making the org term configurable.

---

## Implementation Plan

### Step 0 — Branch and baseline (gate)
1. Create a feature branch off the default branch (e.g. `selfserve-cos-verify-cleanup`).
2. Run the existing end-to-end smoke test and capture output: `mix test test/maraithon_web/self_serve_install_smoke_test.exs`.
3. If any of the three tests fail, STOP and treat it as a real regression: use systematic debugging to find whether production code or the test is wrong before changing anything else. Do not proceed on a red baseline.
4. Record the green/red baseline as the first proof-of-work artifact.

### Step 1 — Confirm the end-to-end path matches acceptance criteria
Verify (the smoke test already asserts most of this) that on a fresh tenant:
- Dashboard renders `#chief-of-staff-install` with **Install Chief of Staff** when Telegram + Google are connected and a project exists; install yields `install_status: "enabled"`, `status: "running"`, correct `project_id`, `delivery_policy: %{"telegram" => "enabled"}`, and `BriefingSchedules.list_due_morning_agents/1` picks it up.
- With connectors missing, the section shows **Setup required** + **Connect Telegram** / **Connect Gmail** links, install yields `setup_required` + `stopped`, no brief scheduled.
- The **Connect Telegram** link target is the `t.me` deep-link (not a dead `/connectors` link) for a brand-new user.

No code change expected here; if a gap surfaces, fix narrowly and add/extend a test.

### Step 2 — Remove the org-specific default keyword (the one real gap)
In `lib/maraithon/chief_of_staff/skills/morning_briefing.ex`:
1. Remove `"glossier"` from `@commercial_thread_terms` (~lines 63-76). Keep the generic terms.
2. Leave the existing config-merge intact: `configured_string_list/3` already reads `config["commercial_thread_terms"]` and `config["org"]["commercial_thread_terms"]` and merges `defaults ++ configured`, so org-specific terms now live in config only.

### Step 3 — Preserve Kent's tuning via config (not code)
Restore `"glossier"` for the primary admin's existing agent without re-hardcoding:
1. Identify the primary admin's installed CoS agent (`Agents.get_package_installation(primary_admin_user_id, "ai_chief_of_staff")`).
2. Set its config so the morning_briefing skill receives the org term, e.g. `config["skill_configs"]["morning_briefing"]["commercial_thread_terms"]` includes `"glossier"` (merge, don't clobber). Prefer the lightest idempotent path that fits existing conventions and survives deploys — a small release/seed-style helper keyed to `Accounts.primary_admin_email()`, or the primary-admin `default_config` path if one already exists. Document the chosen mechanism in the PR.
3. Keep it a one-line config write; do not expand into a general org-config UI.

### Step 4 — Tighten test coverage around the residual change
In `test/maraithon_web/self_serve_install_smoke_test.exs` (or a focused unit test next to the skill — match conventions):
1. Assert a fresh tenant's effective commercial-thread terms contain **no** org-specific constant (refute `"glossier"` in the default list / a freshly-built skill state with empty config).
2. Assert supplying `skill_configs.morning_briefing.commercial_thread_terms` (or the `org` key) merges correctly — protects Kent's restoration mechanism and genericization together.
3. *(Optional, if cheap)* A focused `Connections.connector_readiness/2` unit test asserting the telegram item's `connect_path` is a `t.me`/deep-link URL and google's is `/auth/google` — the spec's "critical blocker," currently only covered indirectly. Add only if it doesn't need heavy stubbing beyond the smoke test's existing `:telegram`/`:google` app-env pattern.

### Step 5 — Verify the install doc is accurate post-change
`docs/install-chief-of-staff.md` already exists and is non-Kent. Read it against the actual UI labels: Telegram connect action label, `setup_required` description, brief-time edit location. Make only small corrections if labels drifted; don't rewrite a correct doc.

### Step 6 — Full verification and proof of work
1. `mix precommit` — must be clean (per `AGENTS.md:5`).
2. `mix test test/maraithon_web/self_serve_install_smoke_test.exs` — all green.
3. Capture outputs; assemble the proof-of-work packet (below).
4. Integrate per repo convention (PR). Don't push/PR until precommit + smoke test are green and captured.

---

## Files and Interfaces

**Change (the one real edit):**
- `lib/maraithon/chief_of_staff/skills/morning_briefing.ex` — `@commercial_thread_terms` (~63-76): remove `"glossier"`. Merge mechanism unchanged: `configured_string_list(config, "commercial_thread_terms", @commercial_thread_terms)` (~217); runtime read at ~1745 (`Map.get(state, :commercial_thread_terms, @commercial_thread_terms)`).

**Change (config restoration for primary admin — lightest fitting option):**
- One of: a release/seed helper keyed to `Accounts.primary_admin_email()` (`lib/maraithon/accounts.ex:207`), or the primary-admin `default_config` path in `lib/maraithon/agent_marketplace.ex` (`ensure_default_installations` / `builtin_manifest/1` `default_config_for/1`). Writes `config["skill_configs"]["morning_briefing"]["commercial_thread_terms"]`.

**Tests (extend, do not replace):**
- `test/maraithon_web/self_serve_install_smoke_test.exs` — existing 3 tests (enabled / setup_required / bootstrap-guard); add genericity + config-merge assertions (or place skill-config assertions under `test/maraithon/chief_of_staff/skills/`).
- Conventions to reuse: `MorningBriefing.smoke_test/2`, `ConnectedAccounts.upsert_manual/3`, `OAuth.store_tokens/3`, `Accounts.get_or_create_user_by_email/1`, `Projects.create_project/2`, `log_in_test_user/2`, `live/2` + `render_click/2`.

**Read-only / verify (no change expected):**
- `lib/maraithon/runtime.ex` — `install_chief_of_staff/2`, `start_existing_agent/1`, `maybe_start_installed_agent/1`.
- `lib/maraithon/agents.ex` — `install_chief_of_staff/2` (502-556), `install_agent_package/3`, `installation_attrs/4`, `required_connectors/1`, `get_package_installation/3`.
- `lib/maraithon/agents/agent.ex` — `install_status` enum (`enabled|paused|setup_required|error|removed`), `status` enum.
- `lib/maraithon/connections.ex` — `connector_readiness/3` item shape (`provider, service, label, status, connected?, connect_path, details`); telegram `connect_path` = `TelegramLink.deep_link/1`, google = `/auth/google`.
- `lib/maraithon_web/live/dashboard_live.ex` — `#chief-of-staff-install` render (~892-976), install handler (~325-366), `refresh_chief_of_staff_install/1` (~2404-2419).
- `lib/maraithon_web/live/agents_live.ex` — inspect/apps/skills panels, `update_morning_brief_time` (375-407).
- `lib/maraithon/briefing_schedules.ex` — `list_due_morning_agents/1` (98-105), `telegram_deliverable?/1`, defaults (hour 8 / offset -5).
- `lib/maraithon/agent_marketplace.ex` — `required_connectors_for/1`, `default_install_allowed?/2`, `builtin_manifest/1`.
- `docs/install-chief-of-staff.md` — verify accuracy only.

---

## Acceptance Checks

Each maps to a ticket acceptance criterion; verify with the cited evidence.

1. **Fresh user, no code changes, completes sign-in → connect → create project → install → scheduled within 24h.** Evidence: smoke test #1 green (asserts `project_id`, `enabled`, `running`, telegram delivery, `list_due_morning_agents/1` pickup).
2. **Install blocked/`setup_required` when connectors missing; never a brief-less running agent.** Evidence: smoke test #2 green (`setup_required` + `stopped`, no scheduled brief); runtime refuses to start `setup_required`.
3. **First brief contains no Kent-specific copy or org constants baked into code.** Evidence: `"glossier"` removed from `@commercial_thread_terms`; new assertion that fresh-tenant default terms contain no org constant; prompts already generic.
4. **End-to-end smoke test passes; `mix precommit` clean.** Evidence: captured clean `mix precommit` + green smoke-test run.
5. **`docs/install-chief-of-staff.md` exists and a non-Kent user could follow it.** Evidence: doc present and verified accurate against current UI labels.
6. **No regression to the primary-admin path / default-install guard.** Evidence: smoke test #3 green; Kent's `"glossier"` tuning restored via config (verify the primary-admin agent's effective terms still include it).

---

## Proof of Work Expectations

Cybrus assembles a local review packet from these; produce them explicitly:

- **Baseline run** (Step 0): `mix test test/maraithon_web/self_serve_install_smoke_test.exs` output before changes (expected green; if red, the debugging trail).
- **Diff**: the `morning_briefing.ex` `"glossier"` removal, the primary-admin config-restoration change, and the new/extended test assertions.
- **Final test run**: smoke test all green, with the new genericity/config-merge assertions visible.
- **`mix precommit` output** — clean, full output captured.
- **Acceptance-criteria trace**: a short table mapping each of the 6 checks to its evidence (test name or `file:line`).
- **Doc verification note**: confirmation `docs/install-chief-of-staff.md` matches current UI labels (or the small corrections made).
- **Re-scope note**: an explicit statement (with the audit table) that the bulk of the spec was pre-existing, so reviewers understand why the diff is small relative to the spec's apparent size.

Per `CLAUDE.md`: do not game tests to look green. A red smoke test means real work — fix production or retire/rewrite the test deliberately with rationale.

---

## Risks

- **Re-implementation risk (highest).** The spec reads as greenfield but the code is ~complete. An agent that rebuilds the install flow, dashboard section, Telegram connect, or smoke test will duplicate/regress tested code. Mitigation: Step 0/1 verification gate; the audit table; the explicit "do not rebuild" decision.
- **Dropping Kent's tuning.** Naively deleting `"glossier"` removes it from Kent's live behavior. Mitigation: Step 3 restores via per-agent config; add the config-merge test (Step 4.2).
- **Config-key shape uncertainty.** Exact place to write Kent's restored term (`skill_configs.morning_briefing.*` vs `org.*` vs `default_config`) may need a quick read to standardize. Mitigation: pick the lightest path `configured_string_list/3` already reads; one-line idempotent write; document the choice.
- **Stale-baseline risk.** The "Done" assessment is from reading, not running. If the smoke test is actually red on the current tree, residual scope grows. Mitigation: Step 0 runs it first and branches into debugging before any cleanup.
- **Borderline generic terms.** `"team plan"` / `"ultra plan"` may be Runner-specific. Mitigation: flagged in decisions; left in by default, trivial follow-up to move if the reviewer objects.
- **`mix precommit` surfacing unrelated failures.** The alias may run the full suite; pre-existing unrelated failures could surface. Mitigation: scope the fix to this ticket; report unrelated failures separately.

---

A note on the deliverable: I attempted to save this to `.claude/plans/B637351D-…-plan.md` (per your global instruction to keep plans with the project, using a `-plan.md` name so the original `-spec.md` is untouched), but the write was declined as a sensitive-file edit. The plan above is complete as returned; if you'd like it persisted, re-run with that path approved and I'll write it.