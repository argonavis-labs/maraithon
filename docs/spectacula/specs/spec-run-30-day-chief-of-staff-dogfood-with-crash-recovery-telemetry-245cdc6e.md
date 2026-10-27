---
created_at: 2026-05-20T13:45:28Z
created_by: cybrus
cybrus_task_id: 245CDC6E-E228-4E66-A975-652A097AA732
project: Maraithon App
status: ready
---
# Spec: Run 30-day Chief of Staff dogfood with crash-recovery telemetry

Status: Ready for human approval
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: 245CDC6E-E228-4E66-A975-652A097AA732
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

The write was gated by permissions — that's fine, since the primary deliverable is the returned Markdown. Here is the complete refined plan.

---

## Planning note (important)

While verifying the codebase anchors, I found that **the entire code scope this ticket asks to *build* (Scopes 1–3) is already implemented and tested in the working tree** — `IncidentLog`, `AgentWatcher` (with recovery + crash-loop breaker), `ShutdownReporter`, `DogfoodDigest`, the `runtime_incidents` migration, config keys, and tests all exist; `.gitignore` already covers crash dumps; and the agent restart policy is `:transient`, not `:temporary` as the original spec assumed. The plan below pivots accordingly: **verify → close small gaps → ship → run → report**, rather than build from scratch.

---

# Plan: Run 30-day Chief of Staff dogfood with crash-recovery telemetry

**Ticket:** EFAA7D26 · **Repo:** `/Users/kent/bliss/maraithon` · **Planned:** 2026-05-20

## Objective

Deliver a 30-day continuous production run of the Chief of Staff agent on Kent's single-tenant deployment (`maraithon.com`), backed by structured crash-recovery telemetry and a daily Telegram digest, ending in a written report plus one demo-able crash-and-recover capture.

**Material change from the original spec:** the telemetry/recovery/digest code the ticket asks to *build* is **already present and tested**. Verified during planning:

- `runtime_incidents` table + migration — `priv/repo/migrations/20260520104440_create_runtime_incidents.exs`
- `Maraithon.Runtime.RuntimeIncident` schema (`kinds/0`) and `Maraithon.Runtime.IncidentLog` (`record/2`, `since/2`, `by_kind/2`, `count_by_kind/1`, `uptime_segments/2`, `backlog_snapshot/1`)
- Incident wiring: `node_boot` (`Bootstrap`), `node_shutdown` (`ShutdownReporter`), `agent_crash`/`agent_resumed`/`agent_stopped_unexpectedly` (`AgentWatcher`), `db_outage`/`db_recovered` (`HealthReporter`)
- Minimal recovery monitor + crash-loop circuit breaker (`AgentWatcher` + `Runtime.resume_agent_after_crash/2`)
- `Maraithon.Runtime.DogfoodDigest` GenServer (`compose/2`, `deliver/2`, `next_fire_after/4`, daily self-scheduling), wired into `Maraithon.Runtime.Supervisor`
- Config keys + env vars defaulted in `config/runtime.exs`
- Tests: `test/maraithon/runtime/{incident_log,agent_watcher,dogfood_digest}_test.exs`

This remains a **stability + observability** effort: no new agent behavior.

---

## Assumptions and Decisions

1. **Code scope is already built; do not rebuild it.** Read the existing modules first and treat this as verify-and-finish work. Re-implementing `IncidentLog`/`AgentWatcher`/`DogfoodDigest` would regress working, tested code.
2. **First action is reconciliation, not coding.** Planning could not run `git`. Confirm the implementation is committed on the integration branch / `main`; commit/merge anything outstanding. The ticket prose describes a pre-implementation world — trust the code.
3. **Original open questions are resolved by the shipped code** (recorded as decisions):
   - *Recovery monitor:* **built and kept** — `AgentWatcher` records `agent_crash`, waits a backoff, and re-resumes via `Runtime.resume_agent_after_crash/2` only if still down.
   - *Crash-loop thresholds:* **3 crashes / 600 s**, backoffs `[5 s, 15 s, 30 s]`; on threshold records `agent_stopped_unexpectedly` and stops. Tunable via `AGENT_CRASH_LOOP_MAX`, `AGENT_CRASH_LOOP_WINDOW_MS`, `AGENT_RERESUME_BACKOFFS`.
   - *Digest time:* **07:30 America/Toronto** (`DOGFOOD_DIGEST_HOUR=7`, `_MINUTE=30`, offset `-4`).
   - *Day-0 baseline:* automatic — `Bootstrap` stamps every `node_boot` with `IncidentLog.backlog_snapshot()`; digest surfaces it as "Last boot baseline".
   - *"Survived restarts":* an effect/job/run non-terminal before a restart and terminal after, same logical work item. Digest approximates via "Last boot baseline" vs "Backlog now".
   - *Stale `erl_crash.dump`:* already `.gitignore`d (`erl_crash.dump`, `*.dump`); none present. No action.
4. **Agent restart policy is `:transient`, not `:temporary`** (`agent.ex` `child_spec`). DynamicSupervisor is the first recovery layer; `AgentWatcher` is the second (records + re-resumes only if still down). Intended design — do not revert.
5. **Single tenant.** `DOGFOOD_USER_ID` falls back to `PRIMARY_ADMIN_EMAIL` (Kent). Digest only sends if that user has a connected Telegram destination; otherwise it skips silently.
6. **Plain-text digest is intentional.** `Telegram.send_message/3` converts markdown→HTML by default; the digest is plain text with newlines (no fragile tables).
7. **`AGENTS.md` rules apply** (`Req` for HTTP, predicate naming, `start_supervised!`, no `Process.sleep` polling). `DESIGN.md` does not apply (no UI).
8. **Out of scope (unchanged):** no new agent capabilities, no snapshot/replay (the `agent.ex:119` "load recent events" TODO stays), no new dashboards/UI, no external alerting, no multi-tenant.

---

## Implementation Plan

### Phase 0 — Reconcile and verify (no code yet)
1. Read shipped modules: `lib/maraithon/runtime/{incident_log,agent_watcher,dogfood_digest,shutdown_reporter,bootstrap,supervisor,runtime_incident,health_reporter}.ex`, `lib/maraithon/health.ex`, and `lib/maraithon/runtime.ex` (`resume_all_agents/0`, `resume_agent_after_crash/2`, `start_agent_process/2`, `maybe_record_agent_resumed/*`).
2. Confirm all of it is committed on the integration branch / `main`; commit or merge anything outstanding.
3. Run and gate: targeted runtime tests, then full `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --unused`, `format`, `test`) — must be clean.

### Phase 1 — Close small, concrete gaps (the only code changes)
1. **Digest: per-crash recovery outcome.** Spec wants "one line per `agent_crash` (cause + whether re-resume succeeded)". `DogfoodDigest.crash_lines/1` prints only time/agent_id/reason. Correlate each `agent_crash` with the next `agent_resumed` (`resume_trigger == "targeted_reresume"`) or `agent_stopped_unexpectedly` for the same `agent_id` in-window; append `→ recovered` / `→ not recovered`. Add a `compose/2` test for both outcomes.
2. **Digest: memory in Health line.** Add `health.checks.memory_mb` to the `Health:` line. Extend the compose test.
3. **`ShutdownReporter` test (new).** No test exists. `start_supervised!` → `stop_supervised` → assert a `node_shutdown` incident is recorded (reporter traps exit and records in `terminate/2`).
4. **DB outage/recovery test (new).** Assert `db_outage` then `db_recovered` are recorded and de-duped via the persistent-term path; prefer a behavioral test, fall back to unit-testing the mark/clear helpers if flaky (document why).
5. **Node-boot resume test (optional, recommended).** The required integration test (crash → `agent_crash` + `agent_resumed`) already exists in `agent_watcher_test`. Optionally add: `resume_all_agents/0` records `agent_resumed` with `resume_trigger == "node_boot"`.
6. **Config documentation.** Keys are defaulted in `config/runtime.exs` but undocumented. Add a "Dogfood / crash-recovery telemetry" section (`docs/dogfood/README.md`) listing each env var, default, and meaning: `AGENT_WATCHER_POLL_INTERVAL_MS`, `AGENT_CRASH_LOOP_MAX`, `AGENT_CRASH_LOOP_WINDOW_MS`, `AGENT_RERESUME_BACKOFFS`, `DOGFOOD_USER_ID`, `DOGFOOD_DIGEST_HOUR`, `DOGFOOD_DIGEST_MINUTE`, `DOGFOOD_DIGEST_TIMEZONE`, `DOGFOOD_DIGEST_TIMEZONE_OFFSET_HOURS`.
7. Re-run `mix precommit`.

### Phase 2 — Ship and verify live
1. Deploy the integration branch to Fly (Actions → Fly → `Maraithon.Release.migrate/0`); confirm the `create_runtime_incidents` migration applied.
2. Set/confirm Fly secrets/env so `DOGFOOD_USER_ID`/`PRIMARY_ADMIN_EMAIL` resolves to Kent and that user has a Telegram destination (`ConnectedAccounts.telegram_destination/1` non-nil); confirm `DOGFOOD_DIGEST_*`.
3. Remote-IEx smoke test: `DogfoodDigest.deliver/2` sends to Telegram; `IncidentLog.since/1` shows the boot's `node_boot` with a `baseline`; `Health.check/0` healthy.
4. **Capture day-0 baseline** (boot baseline backlog + `Health.check/0`) for the report.

### Phase 3 — 30-day operational run
1. Run 30 calendar days; no manual agent fix-ups — an unrecovered agent is a finding.
2. Each morning: read the digest, archive it under `docs/dogfood/digests/`, note anomalies (crashes, unrecovered agents, regressions).
3. **Capture ≥1 real crash-and-recover** as a clip/transcript (the `agent_crash` line + `agent_resumed` follow-up, or a capture of the agent resuming and completing previously in-flight effects/jobs).

### Phase 4 — Wrap-up report
1. Write `docs/dogfood/2026-chief-of-staff-30-day.md`: total uptime % + longest streak, incident counts by kind, MTBF/MTTR; every crash (cause, recovery outcome, in-flight preserved vs lost); user-visible regressions; what worked/broke; explicit list of what the runtime still needs before external users (snapshot/replay for `agent.ex:119`, whether `:transient` + watcher suffices, crash-loop tuning); link to clip + archived digests.
2. Final `mix precommit`; commit report + digests.

---

## Files and Interfaces

### Existing — verify, do not rebuild

| Path | Role |
|---|---|
| `lib/maraithon/runtime/runtime_incident.ex` | Ecto schema (binary_id), `kinds/0` enum |
| `lib/maraithon/runtime/incident_log.ex` | `record/2`, `since/2`, `by_kind/2`, `count_by_kind/1`, `uptime_segments/2`, `backlog_snapshot/1` (best-effort) |
| `lib/maraithon/runtime/agent_watcher.ex` | monitors agents; records `agent_crash`; re-resumes; breaker → `agent_stopped_unexpectedly` |
| `lib/maraithon/runtime/shutdown_reporter.ex` | traps exit; records `node_shutdown` in `terminate/2` |
| `lib/maraithon/runtime/dogfood_digest.ex` | `compose/2`, `deliver/2`, `next_fire_after/4`, daily scheduler |
| `lib/maraithon/runtime/bootstrap.ex` | records `node_boot` (+ baseline); calls `resume_all_agents/0` |
| `lib/maraithon/runtime.ex` | `resume_all_agents/0`, `resume_agent_after_crash/2`, `start_agent_process/2`, `maybe_record_agent_resumed/*` |
| `lib/maraithon/runtime/health_reporter.ex` | records `db_outage`/`db_recovered` via persistent-term de-dupe |
| `lib/maraithon/runtime/supervisor.ex` | wires `AgentWatcher`, `ShutdownReporter`, `DogfoodDigest` |
| `priv/repo/migrations/20260520104440_create_runtime_incidents.exs` | table |
| `config/runtime.exs` (~lines 231–247) | dogfood + watcher config + env vars |

### To change

| Path | Change |
|---|---|
| `lib/maraithon/runtime/dogfood_digest.ex` | `crash_lines/1` recovery outcome; `compose/2` Health line `memory_mb` |
| `test/maraithon/runtime/dogfood_digest_test.exs` | assert recovery-outcome lines + memory |
| `test/maraithon/runtime/shutdown_reporter_test.exs` (new) | assert `node_shutdown` on terminate |
| `test/maraithon/runtime/health_reporter_test.exs` (new/existing) | assert `db_outage`→`db_recovered`, de-duped |
| `docs/dogfood/README.md` (new) | document env vars + defaults |
| `docs/dogfood/2026-chief-of-staff-30-day.md` (new) | wrap-up report |
| `docs/dogfood/digests/` (new) | archived daily digests |

### Key signatures
- `Maraithon.Connectors.Telegram.send_message(chat_id, text, opts \\ [])`
- `Maraithon.ConnectedAccounts.telegram_destination(user_id) :: binary | nil`
- `Maraithon.Health.check/0 :: %{status:, checks: %{database:, agents: %{running, degraded, stopped}, memory_mb:, uptime_seconds:}, ...}`
- `IncidentLog.record(attrs, opts \\ [])` — kinds: `node_boot`, `node_shutdown`, `agent_crash`, `agent_resumed`, `agent_stopped_unexpectedly`, `db_outage`, `db_recovered`
- Test base `use Maraithon.DataCase, async: false`; Telegram doubles `Maraithon.TestSupport.{FakeTelegram, CapturingTelegram}`; HTTP mock `Bypass`

---

## Acceptance Checks

Mapped to the ticket's criteria, with status:

- [x] `runtime_incidents` table + `IncidentLog` + migration + tests — **present; verify green.**
- [x] Incidents for node boot/shutdown, agent crash, agent resume, DB outage/recovery; integration test crashes an agent and asserts `agent_crash` + `agent_resumed` — **present in `agent_watcher_test`; add `shutdown_reporter` + `db_outage/recovered` tests (Phase 1).**
- [x] `AgentWatcher` re-resumes and trips the breaker at threshold — **present; both tests exist.**
- [x] `DogfoodDigest` sends a correct daily summary with a fake Telegram client — **present; extend for recovery-outcome + memory.**
- [ ] All new config keys documented and defaulted — **defaulted; documentation in Phase 1.**
- [ ] `mix precommit` clean — **run and confirm.**
- [ ] 30-day run completed with daily digests archived — **operational (Phase 3).**
- [ ] ≥1 real crash-and-recover captured — **operational.**
- [ ] Wrap-up report committed under `docs/dogfood/` — **Phase 4.**

**Phase-1 gate (verifiable now):** `mix precommit` clean; digest shows per-crash recovery outcome + memory; `ShutdownReporter` records `node_shutdown`; `HealthReporter` records/de-dupes `db_outage`/`db_recovered`; post-deploy `DogfoodDigest.deliver/2` reaches Kent's Telegram and a `node_boot` (with baseline) exists.

---

## Proof of Work Expectations

For the Cybrus review packet:
1. **Reconciliation note** — git status of the telemetry modules (committed/branch/merged), confirming finish-work, not a rebuild.
2. **Test output** — `mix precommit` clean run + targeted runtime tests, pasted.
3. **Diff** — only the Phase-1 changes (digest recovery-outcome + memory, new tests, config docs); no churn in shipped modules beyond the named edits.
4. **Production verification** — captured `DogfoodDigest.deliver/2` Telegram message, the post-deploy `node_boot` incident (with baseline), and the day-0 baseline snapshot.
5. **Operational artifacts (end of run)** — archived daily digests under `docs/dogfood/digests/`, the crash-and-recover clip/transcript, and the committed report.

---

## Risks

1. **Ticket/code mismatch** — ticket reads pre-implementation; code is built. → Phase 0 reconciliation; don't rebuild.
2. **Uncommitted/unmerged work** — could regress on deploy. → confirm/merge before Phase 2.
3. **Digest never delivers** — if the dogfood user isn't Telegram-connected, the digest skips silently and the run has no daily record. → Phase 2 `deliver/2` smoke test.
4. **Timezone/DST drift** — fixed offset `-4` is correct for Toronto summer; crossing the DST boundary shifts the hour by one. → note it; adjust `DOGFOOD_DIGEST_TIMEZONE_OFFSET_HOURS` if the window spans the change.
5. **Crash-loop breaker masks a real defect** — a broken agent trips the breaker (3/600 s) and stays down (correct), leaving a gap until the morning digest. → treat `agent_stopped_unexpectedly` as a must-read line; consider tightening the window during the run.
6. **Recovery without replay** — re-resumed agents start fresh (`agent.ex:119` TODO). Durable work (effects/jobs) survives via outbox/scheduler; transient mid-cycle agent state does not. → this is what the run measures; record losses explicitly.
7. **DB outage test brittleness** — driving the persistent-term path deterministically is fiddly. → prefer behavioral test; fall back to unit-testing mark/clear helpers and document.
8. **OOM kills bypass `terminate/2`** — a hard node kill leaves an *open* uptime segment (no `node_shutdown`), correctly counted as unclean by `uptime_segments/2`. → cross-check Fly machine restarts against `node_boot` incidents when reconciling the report.

---

Note: I attempted to save this plan to `/Users/kent/bliss/maraithon/.claude/plans/EFAA7D26-chief-of-staff-30-day-dogfood.md` (per your global instruction to store plans in-project), but the write was blocked by file permissions. Approve that path or tell me where to write it and I'll save it as the proof-of-work artifact.