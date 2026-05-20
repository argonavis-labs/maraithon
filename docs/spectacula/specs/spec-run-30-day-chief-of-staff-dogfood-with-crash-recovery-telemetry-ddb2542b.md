---
created_at: 2026-05-14T18:42:56Z
created_by: cybrus
cybrus_task_id: DDB2542B-A1F6-4125-A931-4C93D6A836B1
project: Maraithon App
status: inprogress
---
# Spec: Run 30-day Chief of Staff dogfood with crash-recovery telemetry

Status: In progress - runtime telemetry code checkpoint implemented; 30-day production run and report pending
Purpose: Provide a durable Spectacula planning artifact for local Cybrus execution.

## Task Context

- Project: Maraithon App
- Repository: /Users/kent/bliss/maraithon
- Task ID: DDB2542B-A1F6-4125-A931-4C93D6A836B1
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

Stand up structured crash-recovery telemetry for the Chief of Staff agent, add a minimal agent-recovery monitor so a mid-cycle crash doesn't go unmeasured, ship a daily Telegram uptime digest, then run the agent continuously on Kent's production deployment for 30 days and write a wrap-up report with at least one demo-able crash-and-recover artifact.

This is a **stability + observability** ticket. Deliverables are telemetry, a digest, and a report — plus exactly one intentional behavior change (the recovery monitor). No new agent skills, no snapshot/replay system.

---

## Assumptions and Decisions

- **Recovery monitor is in scope and will be built.** Open question #1 is decided: without it, a `:temporary` agent that crashes mid-cycle stays dead until the next node restart, so a 30-day "crash-recovery" run would measure almost nothing. It is built entirely on the existing `Runtime` resume path — no new agent capability.
- **Crash-loop thresholds:** re-resume on abnormal `:DOWN` with backoff `5s, 15s, 30s`; trip the circuit breaker after **3 crashes in 10 minutes** for the same agent, record `agent_stopped_unexpectedly`, and stop re-resuming until the next node boot. Values are config keys so they can be tuned without a deploy-blocking code change.
- **Digest delivery time:** **07:30 America/Toronto**, ahead of the existing morning briefing, as a config key (`:dogfood_digest_hour`). Trailing-24h window.
- **"Survived a restart" definition:** an `effect` / `scheduled_job` / `agent_run` counts as *survived* if it was non-terminal immediately before a restart and reached a terminal state afterward, attributable to the same logical work item (same row id). This is the definition used in both the digest and the report.
- **Day-0 baseline** is captured by a one-off mix task run at deploy time and stored as a `node_boot` incident's metadata so digest deltas are meaningful from day one.
- **Stale `erl_crash.dump`:** investigate its timestamp/contents for a one-line note in the report, then `.gitignore` `*.dump` and `erl_crash.dump` and `git rm --cached` it before the run starts.
- **No new UI.** Telegram digest is the only surface. A read-only admin view of `runtime_incidents` is explicitly a follow-up ticket.
- **Single tenant** — Kent's production accounts only.
- Incident writes must be **best-effort and non-blocking**: a failure to record an incident must never crash the runtime path being instrumented (wrap in a rescue, log on failure).

---

## Implementation Plan

### Phase 1 — Incident log foundation

1. **Migration** `create_runtime_incidents` — table per the schema below, with indexes on `(occurred_at)`, `(kind, occurred_at)`, and `(agent_id, occurred_at)`.
2. **Schema** `Maraithon.Runtime.RuntimeIncident` — Ecto schema, `binary_id`, `kind` validated against the enum, `metadata` as `:map`.
3. **Context** `Maraithon.Runtime.IncidentLog` — `record/1` (best-effort, rescue-wrapped), plus query helpers the digest and report need: `since/1`, `by_kind/2`, `uptime_segments/1`, `count_by_kind/1`.
4. Unit tests for the context: recording each kind, query helpers, and that a DB error in `record/1` is swallowed and logged.

### Phase 2 — Instrument existing hook points

Wire `IncidentLog.record/1` into existing code — do **not** duplicate data already in `effects` / `agent_runs`:

- **`node_boot`** — emit from `Maraithon.Runtime.Bootstrap` (runs once on startup). Metadata includes the day-0 / per-boot backlog snapshot: pending+failed `effects`, pending `scheduled_jobs`, `running` `agent_runs`.
- **`node_shutdown`** — add a dedicated `Maraithon.Runtime.ShutdownReporter` GenServer whose `terminate/2` records the incident (Application stop hooks are unreliable for this; a supervised GenServer's terminate is the proven pattern). Best-effort, short timeout.
- **`agent_resumed`** — emit from `Runtime.resume_all_agents/0` and `Runtime.start_agent_process/1`, with metadata `resume_trigger: :node_boot | :targeted_reresume`.
- **`db_outage` / `db_recovered`** — emit from the failure-marking path in `Maraithon.Health` (it already tracks a failure timestamp in `:persistent_term`); record `db_outage` on first observed failure, `db_recovered` on the transition back, deduped via the persistent_term state so we don't log every 60s tick.

### Phase 3 — AgentWatcher (crash detection + minimal recovery)

`Maraithon.Runtime.AgentWatcher` GenServer, added to the runtime supervision tree:

- On start, `Process.monitor/1` every currently-running agent; subscribe to agent start/stop so the monitor set stays current (hook into `start_agent_process/1` / agent stop path, or poll the `AgentSupervisor` children on a short interval if no event bus exists).
- On `:DOWN` with reason `:normal` / `:shutdown` → record nothing (clean stop).
- On `:DOWN` with an abnormal reason:
  1. Record `agent_crash` with `reason`, and metadata: behavior, uptime-at-crash, last `sequence_num` / `agent_run` id if recoverable, restart count in window.
  2. Check the crash-loop circuit breaker for that `agent_id`. If under threshold → schedule a re-resume via the existing `Runtime` resume path after the staged backoff; the resume itself emits `agent_resumed` with `resume_trigger: :targeted_reresume`.
  3. If over threshold → record `agent_stopped_unexpectedly` and stop re-resuming that agent until next node boot.
- Crash-window state is in-process (`Map` of `agent_id => [crash timestamps]`), pruned to the configured window.

### Phase 4 — DogfoodDigest

`Maraithon.Runtime.DogfoodDigest` GenServer, same shape as `BriefNotifier` / `BriefingCron`:

- Schedules itself for the next configured local hour; on fire, composes the trailing-24h summary and re-schedules.
- Content: uptime % + longest continuous streak (from `node_boot`/`node_shutdown` segments), `count_by_kind`, one line per `agent_crash` (cause + whether re-resume succeeded), in-flight survival deltas (pre/post each restart in the window), and the current `Maraithon.Health.check/0` snapshot.
- Sends via `Maraithon.Connectors.Telegram.send_message/3` to `Maraithon.ConnectedAccounts.telegram_destination(user_id)`. Telegram-friendly: short, no fragile tables, plain lines.
- Tested with a fake Telegram client asserting message shape against seeded `runtime_incidents` / `effects` / `scheduled_jobs` / `agent_runs`.

### Phase 5 — Config, hygiene, integration test

- Config keys with defaults, all documented in `config/runtime.exs` (or wherever runtime config lives): `:dogfood_digest_hour`, `:dogfood_digest_timezone`, `:agent_crash_loop_max`, `:agent_crash_loop_window_ms`, `:agent_reresume_backoffs`.
- `.gitignore` `erl_crash.dump` / `*.dump`; `git rm --cached` the stale dump; note its origin in the report.
- **Integration test:** start an agent, kill its process with an abnormal reason, assert an `agent_crash` incident is recorded *and* an `agent_resumed` (`:targeted_reresume`) follows; separately, crash one past the threshold and assert `agent_stopped_unexpectedly` and that no further re-resume occurs.
- `mix precommit` clean.

### Phase 6 — The 30-day run + report

- Deploy to production; mix task captures the day-0 baseline into the first `node_boot`.
- Run 30 calendar days, no manual agent fixes — an unrecovered crash is a finding. Spot-check the digest each morning.
- Capture at least one real crash-and-recover (digest line + Telegram thread, or screen capture of the agent resuming in-flight work).
- Day 30: write `docs/dogfood/2026-chief-of-staff-30-day.md` per the report outline below.

---

## Files and Interfaces

**New:**
- `priv/repo/migrations/<ts>_create_runtime_incidents.exs`
- `lib/maraithon/runtime/runtime_incident.ex` — Ecto schema
- `lib/maraithon/runtime/incident_log.ex` — context: `record/1`, `since/1`, `by_kind/2`, `count_by_kind/1`, `uptime_segments/1`
- `lib/maraithon/runtime/agent_watcher.ex` — GenServer: crash detection + re-resume + circuit breaker
- `lib/maraithon/runtime/shutdown_reporter.ex` — GenServer: `node_shutdown` via `terminate/2`
- `lib/maraithon/runtime/dogfood_digest.ex` — GenServer: daily Telegram digest
- `lib/mix/tasks/maraithon.dogfood_baseline.ex` (optional) — one-off day-0 backlog snapshot
- `test/maraithon/runtime/incident_log_test.exs`
- `test/maraithon/runtime/agent_watcher_test.exs` — includes the crash → resume integration test
- `test/maraithon/runtime/dogfood_digest_test.exs`
- `docs/dogfood/2026-chief-of-staff-30-day.md` (end of run)

**Modified:**
- `lib/maraithon/runtime/bootstrap.ex` — emit `node_boot` + baseline snapshot
- `lib/maraithon/runtime.ex` — emit `agent_resumed` in `resume_all_agents/0` / `start_agent_process/1`; expose an agent start/stop notification for `AgentWatcher`
- `lib/maraithon/health.ex` — emit `db_outage` / `db_recovered` on the failure-state transition
- runtime supervision tree (application supervisor) — add `AgentWatcher`, `ShutdownReporter`, `DogfoodDigest`
- `config/runtime.exs` (or equivalent) — new config keys + docs
- `.gitignore` — `erl_crash.dump`, `*.dump`

**`runtime_incidents` schema:**

| column | type | notes |
|---|---|---|
| `id` | binary_id | PK |
| `kind` | string | `node_boot`, `node_shutdown`, `agent_crash`, `agent_resumed`, `agent_stopped_unexpectedly`, `db_outage`, `db_recovered` |
| `agent_id` | binary_id, nullable | null for node/db-level incidents |
| `reason` | text, nullable | crash reason / exit signal / cause |
| `metadata` | map | uptime, memory, restart count, behavior, last `sequence_num`, `resume_trigger`, backlog snapshot |
| `node` | string | node name |
| `occurred_at` | utc_datetime_usec | |
| `inserted_at` | utc_datetime_usec | |

---

## Acceptance Checks

- [x] `runtime_incidents` migration + `RuntimeIncident` schema + `IncidentLog` context, with unit tests including the best-effort/rescue path.
- [x] Incidents recorded for `node_boot`, `node_shutdown`, `agent_crash`, `agent_resumed`, `db_outage`, `db_recovered` at the instrumented hook points.
- [x] Integration test: crashing an agent abnormally produces an `agent_crash` + `agent_resumed` (`:targeted_reresume`) pair.
- [x] `AgentWatcher` re-resumes an abnormally-crashed agent with staged backoff and trips its circuit breaker after the configured threshold, recording `agent_stopped_unexpectedly`.
- [x] `DogfoodDigest` sends a correct trailing-24h Telegram summary; covered by a test with a fake Telegram client.
- [x] All new config keys defaulted and documented; `mix precommit` clean.
- [x] `erl_crash.dump` gitignored and confirmed untracked; its origin is captured in the manifest for the final report.
- [ ] 30-day run completed with daily digests archived.
- [ ] At least one real crash-and-recover captured as clip/transcript.
- [ ] Wrap-up report committed under `docs/dogfood/`.

---

## Proof of Work Expectations

Cybrus writes a local review packet. For the human reviewer moving the task Planned → Approved → Done:

- **Pre-run (code review checkpoint):** diff of all new/modified files; `mix precommit` output clean; full test run output, with the crash → resume integration test result called out explicitly; the migration shown applied locally (`mix ecto.migrate` output); a sample `DogfoodDigest` message body rendered from seeded data.
- **Deploy:** confirmation the release deployed to `maraithon.fly.dev`, the day-0 `node_boot` incident row with its baseline metadata, and the first digest delivered to Telegram.
- **During run:** archived daily digests (the running record).
- **End of run:** the captured crash-and-recover clip/transcript, and the committed `docs/dogfood/2026-chief-of-staff-30-day.md` covering — total uptime, incident counts by kind, MTBF/MTTR, every crash (cause + recovery outcome + in-flight work lost vs. preserved), user-visible regressions, what worked / what broke, and the explicit list of what the runtime still needs before external users (snapshot/replay, supervisor restart strategy, crash-loop handling).

---

## Risks

- **`AgentWatcher` monitor-set drift.** If there's no existing agent start/stop event bus, the watcher must poll `AgentSupervisor` children — a poll gap could miss a crash. Mitigation: poll on a short interval and reconcile monitors each tick; prefer hooking the start/stop path directly if feasible.
- **Re-resume masking real instability.** The recovery monitor could quietly paper over a chronically crashing agent. Mitigation: the circuit breaker, and every crash + resume is logged — the digest surfaces crash frequency daily so it can't hide.
- **`node_shutdown` not always captured.** Hard kills (OOM, Fly SIGKILL, power loss) won't run `terminate/2`. Mitigation: treat a missing `node_shutdown` before a `node_boot` as an "unclean shutdown" in the uptime calculation rather than assuming continuous uptime.
- **Incident writes on a degraded DB.** `db_outage` can't be written if the DB is the thing that's down. Mitigation: best-effort writes, and reconstruct outage windows in the report from the `db_recovered` incident + first post-recovery `node_boot`.
- **Crash-loop thresholds wrong for real traffic.** Defaults are guesses. Mitigation: config keys, tunable without a code change; revisit after week one of the run.
- **Under-measurement.** If the runtime is simply very stable for 30 days, there may be no organic crash to capture. Mitigation: if no real crash occurs by ~day 20, stage one controlled production crash during a low-impact window to capture the demo artifact, and document it as staged.
- **Codebase references unverified in this environment.** Line numbers and module names come from the ticket's verified-state section; the executing agent should confirm them against the live repo before wiring hooks, and adjust if the code has moved.
