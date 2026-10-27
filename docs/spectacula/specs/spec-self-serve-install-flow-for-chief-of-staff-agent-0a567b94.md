---
created_at: 2026-05-23T23:59:23Z
created_by: cybrus
cybrus_task_id: 0A567B94-80EA-477D-B1AC-4A183A91A32A
project: Maraithon App
status: ready
---
# Spec: Self-serve install flow for Chief of Staff agent

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 0A567B94-80EA-477D-B1AC-4A183A91A32A
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

The plan file write was blocked by the sandbox (the project dir is outside this session's writable root), but the deliverable is the returned plan itself. Here is the complete refined plan.

---

# Self-Serve Install Flow for Chief of Staff — Implementation Plan

**Ticket:** B637351D — Build self-serve install flow for Chief of Staff agent

> Line numbers were accurate against the live repo (`/Users/kent/bliss/maraithon`) at authoring time; each edit is anchored to an exact source string — match the string, not the line.

---

## Objective

Make a non-Kent user able to: sign in via magic link → connect Telegram + Google (Gmail/Calendar) → create a project → click **Install Chief of Staff** on the project dashboard → and be scheduled for a first morning brief within 24h — with **no Kent-specific copy or org-specific constants** in the experience, and **no manual code, seeds, or admin calls** required.

**Critical reframe (read before executing):** A current-state audit shows the self-serve flow is **already implemented and largely tested**. The original spec's "What's missing" and "Open questions" are mostly **stale**. The genuine remaining work is small and bounded: de-Kent the two *default-enabled* Chief of Staff skill prompts that still say "Kent," lock that in with regression coverage, and verify the flow is green. This plan is scoped to that reality rather than rebuilding shipped functionality.

---

## Assumptions and Decisions

Decided without follow-up questions, each grounded in code read during the audit.

1. **Telegram self-serve (spec Open Q1) is already solved — do not rebuild.** `MaraithonWeb.TelegramLink.deep_link/1` produces a signed (`Phoenix.Token`, salt `"telegram-link"`, 15-min TTL) `https://t.me/<bot>?start=<token>` link; `/connectors` surfaces it as **Link Telegram** (`Connections.telegram_card/3`); `InsightNotifications.handle_message_event/1` intercepts `/start <token>`, verifies it, and calls `ConnectedAccounts.upsert_manual(user_id, "telegram", …)`. A `/start your@email.com` fallback exists. No new Telegram flow is in scope.

2. **Connector gating, `project_id`, delivery policy, and `setup_required` are already implemented.** `Agents.install_chief_of_staff/2` computes `Connections.connector_readiness/2`, sets `install_status: "enabled"`/`status: "running"` when ready and `"setup_required"`/`"stopped"` otherwise, attaches a validated `project_id`, and sets `delivery_policy: %{"telegram" => "enabled"}`. `Runtime.start_existing_agent/1` already returns `{:error, :agent_setup_required}` for the gated state.

3. **The dashboard install UI already exists.** `DashboardLive` renders `section#chief-of-staff-install` with connector chips, per-connector "Connect …" links, a **Create project first** disabled state, an **Install Chief of Staff** / **Setup required** button (`phx-click="install_chief_of_staff"`, `phx-value-project_id`), an **Open** button when installed, and a **Morning brief** line with an **Edit** link to `/agents?id=<id>&panel=skills`. `handle_event("install_chief_of_staff", …)` calls `Runtime.install_chief_of_staff/2` with `project_id`.

4. **Brief-time editing already exists.** `AgentsLive` handles `"update_morning_brief_time"` → `BriefingSchedules.update_schedule/2`, reachable from the dashboard. **Decision (Open Q4):** keep the 08:00 / −5h default with post-install editing for v1; no timezone step in the install UI.

5. **Morning brief copy and support email are already generic.** `morning_briefing.md` addresses "the operator"/"the signed-in user" (no "Kent"). `AdminNavigation.support_email/0` defaults to `support@maraithon.app`. `AssistantHarness.build_prompt/1` is generic.

6. **Org constants are already isolated to the primary admin.** Cogniate/Glossier/`runner.now`/`runner-*` live in `@primary_admin_chief_of_staff_config` and are applied **only** via `default_install_config(@chief_of_staff_slug, :primary_admin)`; every other path returns `%{}`. **Decision:** keep this; add a regression assertion that a fresh non-admin install carries none of them.

7. **Auto-install guard already exists (Open Q3).** `AgentMarketplace.ensure_default_installations/0` installs only for `Accounts.primary_admin_email()` with a Telegram destination; self-serve uses the independent `install_chief_of_staff/2` path. Already covered by the smoke test.

8. **The end-to-end smoke test and install doc already exist.** `test/maraithon_web/self_serve_install_smoke_test.exs` covers enabled, `setup_required`, and the non-admin bootstrap guard. `docs/install-chief-of-staff.md` documents the non-Kent flow accurately. **Decision:** verify/extend, don't recreate.

9. **The only genuine code gap: de-Kent two default-enabled prompts.** `Skills.default_enabled_ids/0` = `followthrough, travel_logistics, morning_briefing, commitment_tracker, calendar_check_in, project_scope_alignment, holiday_radar`. Only **`commitment_tracker`** (`commitment_tracker.md` ×8 + `commitment_tracker.ex:426`) and **`calendar_check_in`** (`calendar_check_in.ex` ×5) still contain "Kent"; the other five are clean.

10. **Scope boundary.** Only the self-serve default bundle is in scope. "Draft as Kent" prompts in *other behaviors* (`inbox_calendar_advisor.ex`, `slack_followthrough_agent.ex`, `insights.ex`, `todo_actions.ex`, `open_loops.ex`, `todos/intelligence.ex`, `telegram_conversations.ex`) and the hardcoded internal-domain list in `meeting_enrichment.ex` are **out of scope** (other agents / classification heuristics), recorded under Risks — matching the spec non-goal on deep per-tenant tuning.

11. **De-Kent style:** replace "Kent"/gendered pronouns with "the operator"/"you"/"they" to match the shipped `morning_briefing.md` voice. No new per-user name-templating.

---

## Implementation Plan

### Phase 0 — Establish a green baseline (no code changes)

- [ ] **0.1 Run the shipped smoke test.** `mix test test/maraithon_web/self_serve_install_smoke_test.exs` → expect `3 tests, 0 failures`. If it fails, stop and diagnose as a pre-existing defect (do not paper over).
- [ ] **0.2 Confirm de-Kent targets.** `grep -rn "Kent" priv/agents/skills/chief_of_staff lib/maraithon/chief_of_staff/skills` → expect matches only in `commitment_tracker.md`, `commitment_tracker.ex`, `calendar_check_in.ex`. If different, update Phase 2 lists.

### Phase 1 — Regression guard (TDD: failing test first)

**Create:** `test/maraithon/chief_of_staff/skills/prompt_cleanliness_test.exs`

- [ ] **1.1 Write the failing test.**

```elixir
defmodule Maraithon.ChiefOfStaff.Skills.PromptCleanlinessTest do
  use ExUnit.Case, async: true

  alias Maraithon.ChiefOfStaff.Skills

  @forbidden_terms ["Kent", "runner.now", "Cogniate", "Glossier"]

  @default_enabled_prompt_sources [
    "priv/agents/skills/chief_of_staff/morning_briefing.md",
    "priv/agents/skills/chief_of_staff/commitment_tracker.md",
    "lib/maraithon/chief_of_staff/skills/commitment_tracker.ex",
    "lib/maraithon/chief_of_staff/skills/calendar_check_in.ex"
  ]

  test "default-enabled skills are exactly the audited set" do
    assert Enum.sort(Skills.default_enabled_ids()) ==
             Enum.sort([
               "followthrough",
               "travel_logistics",
               "morning_briefing",
               "commitment_tracker",
               "calendar_check_in",
               "project_scope_alignment",
               "holiday_radar"
             ])
  end

  test "default-enabled chief of staff prompts contain no operator-specific copy" do
    for relative <- @default_enabled_prompt_sources do
      content = File.read!(Path.join(File.cwd!(), relative))

      for term <- @forbidden_terms do
        refute String.contains?(content, term),
               "#{relative} still contains operator-specific term #{inspect(term)}"
      end
    end
  end
end
```

- [ ] **1.2 Run it; confirm it fails for the right reason.** `mix test test/maraithon/chief_of_staff/skills/prompt_cleanliness_test.exs` → cleanliness test FAILS naming the three files with `"Kent"`; the "exactly the audited set" test PASSES.

### Phase 2 — De-Kent the two remaining default-enabled prompts

**Modify:** `priv/agents/skills/chief_of_staff/commitment_tracker.md`, `lib/maraithon/chief_of_staff/skills/commitment_tracker.ex`, `lib/maraithon/chief_of_staff/skills/calendar_check_in.ex`.

- [ ] **2.1 `commitment_tracker.md`** — exact replacements:
  - L7: `You are Kent's accountability system. Find work-related commitments he made or received,` → `You are the operator's accountability system. Find work-related commitments they made or received,`
  - L17: `Someone asked Kent to do something:` → `Someone asked the operator to do something:`
  - L18: `Kent said he would do something:` → `The operator said they would do something:`
  - L19: `Kent agreed to a deadline or deliverable:` → `The operator agreed to a deadline or deliverable:`
  - L20: `someone is waiting on Kent and the message is old enough to matter.` → `someone is waiting on the operator and the message is old enough to matter.`
  - L41: ``…like Kent's human chief of staff, not like a raw import. Use `you` or `Kent`, never `the user`,`` → ``…like the operator's human chief of staff, not like a raw import. Use `you`, never `the user`,``
  - L60: `"summary": "Kent owes Elena the revised Runner ambassador agreement.",` → `"summary": "You owe Elena the revised ambassador agreement.",`
  - L66: `"owner_label": "Kent",` → `"owner_label": "you",`
  - L67: `"source_account_label": "kent@runner.now",` → `"source_account_label": "operator@example.com",`
  - Verify: `grep -n "Kent\|runner.now" priv/agents/skills/chief_of_staff/commitment_tracker.md` → no output.

- [ ] **2.2 `commitment_tracker.ex`** — L426: `             "owner_label": "Kent or named owner",` → `             "owner_label": "the operator or named owner",`

- [ ] **2.3 `calendar_check_in.ex`** — exact replacements:
  - L6: `Kent's calendar and, when there is something useful to say, sends a short` → `the operator's calendar and, when there is something useful to say, sends a short`
  - L8: `concrete things he could tee up (a todo, prep for an upcoming meeting, a` → `concrete things they could tee up (a todo, prep for an upcoming meeting, a`
  - L9: `reply he owes).` → `reply they owe).`
  - L41: `"Looks for openings in the work day and proactively checks in to see if Kent needs anything."` → `"Looks for openings in the work day and proactively checks in to see if you need anything."`
  - L387: `You are Kent's chief of staff, deciding whether to send a short proactive` → `You are the operator's chief of staff, deciding whether to send a short proactive`
  - L390: `It is a work day and Kent has one or more openings in his calendar (see the` → `It is a work day and the operator has one or more openings in their calendar (see the`
  - L392–393: `things he could use the` / `time for — … or a reply he` → `things they could use the` / `time for — … or a reply they`
  - L430: `# A proactive check-in failing should be silent to Kent (no error` → `# A proactive check-in failing should be silent to the operator (no error`
  - Verify: `grep -n "Kent" lib/maraithon/chief_of_staff/skills/calendar_check_in.ex` → no output.

- [ ] **2.4 Run the guard; confirm pass.** `mix test test/maraithon/chief_of_staff/skills/prompt_cleanliness_test.exs` → `2 tests, 0 failures`.
- [ ] **2.5 Commit.**

```bash
git add priv/agents/skills/chief_of_staff/commitment_tracker.md \
        lib/maraithon/chief_of_staff/skills/commitment_tracker.ex \
        lib/maraithon/chief_of_staff/skills/calendar_check_in.ex \
        test/maraithon/chief_of_staff/skills/prompt_cleanliness_test.exs
git commit -m "Genericize default-enabled Chief of Staff skill prompts for self-serve"
```

### Phase 3 — Lock org-constant acceptance into the install smoke test

**Modify:** `test/maraithon_web/self_serve_install_smoke_test.exs` (first test, after `assert agent.config["source_behavior"] == "ai_chief_of_staff"`).

- [ ] **3.1 Add the assertion:**

```elixir
    # A fresh self-serve install must not inherit the primary-admin org tuning.
    config_blob = Jason.encode!(agent.config)
    refute config_blob =~ "runner.now"
    refute config_blob =~ "Cogniate"
    refute config_blob =~ "Glossier"
```

- [ ] **3.2 Run the smoke test.** `mix test test/maraithon_web/self_serve_install_smoke_test.exs` → `3 tests, 0 failures`.
- [ ] **3.3 Commit.**

```bash
git add test/maraithon_web/self_serve_install_smoke_test.exs
git commit -m "Assert fresh Chief of Staff install carries no org-specific config"
```

### Phase 4 — Verify (do not rewrite) the install doc

- [ ] **4.1** Read `docs/install-chief-of-staff.md`; confirm it documents magic-link sign-in, **Connectors → Link Telegram** (+ `/start your@email.com` fallback), Google Gmail+Calendar, **Dashboard → create project → Install Chief of Staff**, the `setup_required` resume path, and the 08:00 default first brief. The audit found it accurate — edit only on real drift.
- [ ] **4.2 (only if edited)** Commit `docs/install-chief-of-staff.md`.

### Phase 5 — Full verification

- [ ] **5.1** `mix precommit` (= `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `test`) → clean.
- [ ] **5.2** Map every acceptance criterion to evidence (table below); return to the relevant phase if any lacks evidence.

---

## Files and Interfaces

**Created**
- `test/maraithon/chief_of_staff/skills/prompt_cleanliness_test.exs` — guard: default-enabled prompts contain none of `["Kent","runner.now","Cogniate","Glossier"]`; tripwire on the default-enabled set.

**Modified (production)**
- `priv/agents/skills/chief_of_staff/commitment_tracker.md` — de-Kent prompt + example email/owner labels.
- `lib/maraithon/chief_of_staff/skills/commitment_tracker.ex` — L426 example `owner_label`.
- `lib/maraithon/chief_of_staff/skills/calendar_check_in.ex` — moduledoc (6,8,9), `description/0` (41), `check_in_prompt/1` (387,390,392,393), comment (430).

**Modified (test)**
- `test/maraithon_web/self_serve_install_smoke_test.exs` — org-constant absence assertions.

**Possibly modified**
- `docs/install-chief-of-staff.md` — only if Phase 4 finds drift.

**Read-only interfaces relied upon (already implemented; do not change)**
- `Agents.install_chief_of_staff/2`; `Runtime.install_chief_of_staff/2`, `Runtime.start_existing_agent/1`
- `Connections.connector_readiness/2`, `telegram_card/3`, `safe_dashboard_snapshot/2`
- `MaraithonWeb.TelegramLink.deep_link/1` + `InsightNotifications.handle_message_event/1`
- `DashboardLive` `section#chief-of-staff-install` + `handle_event("install_chief_of_staff", …)`
- `AgentsLive` `handle_event("update_morning_brief_time", …)` + `BriefingSchedules.update_schedule/2`
- `BriefingSchedules.list_due_morning_agents/1` + `Runtime.BriefingCron.telegram_deliverable?/1`
- `AgentMarketplace.@primary_admin_chief_of_staff_config`, `default_install_config/2`, `ensure_default_installations/0`
- `ChiefOfStaff.Skills.default_enabled_ids/0`

---

## Acceptance Checks

| # | Criterion | Evidence |
|---|-----------|----------|
| 1 | Fresh user: sign-in → connect → project → install → scheduled within 24h, no code changes | `self_serve_install_smoke_test.exs` test 1 (asserts `enabled`, `project_id`, `list_due_morning_agents/1` includes agent) |
| 2 | Blocked / `setup_required` when connectors missing; never silently brief-less running | `self_serve_install_smoke_test.exs` test 2 (`setup_required`, `stopped`, no scheduled brief) |
| 3 | First brief has no "Kent"-specific copy | `morning_briefing.md` already generic; `prompt_cleanliness_test.exs` enforces it (Phases 1–2) |
| 4 | No org-specific constants in a fresh install | `@primary_admin_chief_of_staff_config` isolation (Assumption 6) + Phase 3 config assertion |
| 5 | Self-serve users don't collide with primary-admin auto-install | `self_serve_install_smoke_test.exs` test 3 |
| 6 | E2E smoke passes; `mix precommit` clean | Phase 5 |
| 7 | `docs/install-chief-of-staff.md` exists; a non-Kent user can follow it | Phase 4 |

---

## Proof of Work Expectations

For the Cybrus review packet:

1. **Baseline** — Step 0.1 test output (green *before* changes) + Step 0.2 grep.
2. **Red→green guard** — Step 1.2 (failing, naming the files) and Step 2.4 (passing).
3. **De-Kent diff** — `git diff` of the three prompt files + post-edit `grep -rn "Kent\|runner.now" priv/agents/skills/chief_of_staff lib/maraithon/chief_of_staff/skills` returning **no output**.
4. **Smoke extension** — Step 3.2 showing `3 tests, 0 failures` with the new assertions.
5. **Doc note** — one line confirming `docs/install-chief-of-staff.md` matches the flow (diff if edited).
6. **Final gate** — full `mix precommit` output (zero warnings, green suite).
7. **Acceptance map** — the table above, each row checked with a pointer to evidence.

---

## Risks

- **Stale spec vs. live code (primary).** The spec lists shipped work as "missing"; executing it literally rebuilds the dashboard UI, gating, and Telegram flow — wasted effort and regression risk. *Mitigation:* Phase 0 proves the baseline; do not re-implement anything in Assumptions 1–8. If Phase 0 fails, the failure (not the spec) defines the work.
- **Line-number drift.** *Mitigation:* edits are anchored to exact strings; re-run Step 0.2 first.
- **Over-broad de-Kenting.** Many "Kent" references live outside the default bundle. *Mitigation:* Assumption 10 fences scope; the guard only checks default-bundle files.
- **Declared follow-up (out of scope):** `meeting_enrichment.ex` hardcodes `@internal_email_domains ~w(runner.now voteagora.com agora.xyz)`, affecting meeting-prep internal/external classification for a fresh tenant (does not inject "Kent"/org text into brief copy, so criterion 3 holds). Genericizing needs a per-user "own domains" config — a deliberate follow-up matching the spec non-goal. Flag in the packet.
- **Default −5h timezone (Open Q4).** Non-EST users get a wrong wall-clock first brief until they edit it. *Mitigation:* accepted for v1; dashboard **Edit** path + doc cover it.
- **Tests need Postgres.** `mix test`/`precommit` create/migrate the test DB. *Mitigation:* standard `mix ecto.create`; if the sandbox lacks a DB, surface it explicitly rather than skipping verification.

---

**Summary of what changed vs. the input spec:** I verified the codebase and found the spec's headline scope (dashboard install button, connector gating, `project_id`, Telegram self-serve connect, brief scheduling, de-Kented brief, configurable support email, org-config isolation, auto-install guard, the smoke test, and the install doc) is **already shipped and tested**. The "critical blocker" (Open Q1) is solved. I re-scoped the plan to the one real gap — de-Kenting `commitment_tracker` and `calendar_check_in` (the only default-enabled skills still naming Kent) — plus regression coverage and verification.

One note: I couldn't save the plan to `.claude/plans/` (sandbox blocked writing outside the session root) or run `mix test`/`mix precommit` (they require interactive approval here) — so Phase 0/5 verification is specified for the executing agent rather than run by me. Want me to retry saving the plan to a writable location, or adjust scope (e.g., pull the broader "Draft as Kent" behaviors back in)?