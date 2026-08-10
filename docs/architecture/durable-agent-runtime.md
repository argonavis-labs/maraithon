# Durable, resident Agent runtime

**Status:** Implemented behind the `EXACT_AGENT_RUNTIME_ENABLED` production interlock.
**Decision date:** 2026-08-10

## Decision

Maraithon Agents remain long-lived OTP processes. OTP owns local liveness,
serialization, isolation, and routing; PostgreSQL owns durable intent,
incarnation authority, recovery facts, checkpoints, and work records. A PID,
Registry entry, PubSub delivery, or mailbox acknowledgement is never treated as
durable ownership or completion proof.

This is a state-machine-with-checkpoints architecture, not strict event
sourcing. The event log is an audit/history surface. Recovery restores a
versioned snapshot and reconciles durable work instead of replaying behavior
handlers and risking repeated external side effects.

## Runtime shape

- One `Maraithon.Runtime.Agent` `gen_statem` process serializes each resident
  Agent's `recovering`, `idle`, `working`, and `waiting_effect` states.
- `Maraithon.Runtime.AgentSupervisor` dynamically starts Agent incarnations.
  Exact children are `:temporary`: a restart must first acquire a fresh database
  ownership generation instead of reusing stale supervisor arguments.
- `Maraithon.Runtime.AgentRegistry` is a local routing index. Its metadata
  carries the exact owner token, but it is not authority.
- `Maraithon.Runtime.AgentLeases` claims and renews one UUID generation using
  the PostgreSQL clock. Readiness is written last, after recovery, subscriptions,
  timers, and checkpoint state are installed.
- `Maraithon.Runtime.AgentWatcher` monitors `{pid, agent_id, owner_token}` and
  records a crash only when that exact generation still owns the durable lease.
  Recovery launches run under `Maraithon.Runtime.AgentRecoveryTaskSupervisor`.
- `Maraithon.Runtime.AgentRestartGuards` persists crash-loop counts, backoff,
  recovery-required state, and operator reset authority.
- `Maraithon.Runtime.WakeCoordinator` performs bounded reconciliation of
  expired ownership, incomplete guard/directive transitions, pending lifecycle
  operations, and due recovery generations.
- `Maraithon.Runtime.AgentLifecycleOperations` makes stop, update, pause,
  remove, upgrade, and delete drain/finalize operations crash-recoverable.
- Snapshots, scheduled jobs, background jobs, effects, runs, and incidents are
  stored in PostgreSQL. Task supervisors isolate effect, tool, background-job,
  and recovery execution from their coordinating GenServers.

## Required invariants

1. **Preclaim before spawn.** No production Agent process starts without a
   fresh durable lease token.
2. **Ready last.** A process cannot accept workload until recovery is complete
   and its exact lease is marked ready.
3. **Generation fencing.** Every authority-sensitive write verifies the exact
   owner token in the same database transaction.
4. **Monitor exact incarnations.** A delayed `:DOWN` for an old PID cannot fence
   or restart its replacement.
5. **Temporary children, durable restart policy.** The DynamicSupervisor does
   not blindly restart stale launch arguments. Watcher + restart guard + wake
   reconciliation admit a replacement generation.
6. **Desired state is durable.** Stop/update/delete operations first revoke
   readiness and persist intent, then signal processes outside database locks.
7. **Mailbox delivery is only a hint.** Durable producers may use PubSub to
   reduce latency, but acceptance and terminal state belong in PostgreSQL.
8. **External effects are outbox work.** Provider success, unknown outcome,
   local checkpoint, cancellation, and acknowledgement must remain distinct.

## Current boundaries and next work

The exact lifecycle closes the competing Bootstrap/DynamicSupervisor/Watcher
restart policies and makes one database generation authoritative. It does not
make every existing producer durable by itself.

Before claiming end-to-end durable Agent work, complete these follow-ups:

1. Cut generic `Runtime.send_message/3`, connector events, and scheduled wakeups
   over to the existing `AgentDirectives` inbox with ACK-last semantics. The
   process notification should contain only a directive ID and remain a hint.
2. Finish generation-fenced Effect cancellation and explicit provider-outcome
   ambiguity handling before allowing retries to resend non-idempotent work.
3. Replace safely decoded ETF snapshots with a bounded, language-neutral
   versioned format and define retention/encryption for event, effect, run-step,
   and turn payloads.
4. Add explicit partition authority for any future external-work lane before
   scaling that lane beyond its configured bounds.

### Periodic service consolidation

All thirteen ordinary recurring services execute through stable
`Maraithon.Runtime.RecurringJobs` rows and `BackgroundJobRunner`; none retains a
scheduler GenServer. The original five stateless cycles are:

- `Maraithon.Runtime.BriefingCron`
- `Maraithon.Runtime.BriefNotifier`
- `Maraithon.Runtime.InsightNotifier`
- `Maraithon.AssistantChat.RunRecovery`
- `Maraithon.TelegramAssistant.RunReaper`

The final eight are `TokenRefresher`, `WatchRenewer`, `FreshnessSweep`,
`ProactiveCheckIn`, `TodoCompletionSweep`, `NudgeSweep`,
`StalenessTriageSweep`, and `DogfoodDigest`. Each recurring coordinator has one
stable active dedupe key. A successful claim-token-fenced cycle moves that same
row back to `pending` using the PostgreSQL clock, so success and the next
deadline are one durable compare-and-set rather than a mailbox timer. Missing
schedules are repaired under a transaction-scoped PostgreSQL advisory lock.
Poll timers and PIDs are wakeup hints only.

Provider discovery coordinators enqueue one bounded account/cursor/token unit
into `runtime_provider_account`. Its dedicated runner rotates partitions by a
durable `last_started_at` watermark, enforces one in-flight job for a logical
provider account, serializes provider-family capacity, and persists
`Retry-After` as a provider cooldown. Model discovery coordinators enqueue one
bounded tenant unit into `runtime_model_user`; its separate runner applies the
same durable rotation with one in-flight model job per user, so a hot tenant
cannot starve a tenant that has never run. The generic runner excludes both
queues, preventing provider or model work from consuming the other lanes.
Expired claims are reclaimed by their fenced durable rows after a runner crash.

`DogfoodDigest` persists the validated named timezone, hour, and minute in its
recurring row and stores each exact next-fire instant. PostgreSQL timezone data
is authoritative across DST: nonexistent spring-gap wall times use the
pre-transition standard offset, and ambiguous fall-fold wall times resolve to
the later standard-time occurrence. An invalid named timezone is rejected with
a content-free alert; it never falls back to UTC or overwrites an existing
validated row.

`HealthReporter` and `StuckStateWatchdog` deliberately remain resident
observers. Moving either into the queue it diagnoses could silence the only
health signal when every durable runner is stopped or wedged. They own no
business deadline or delivery authority. `Scheduler`, `EffectRunner`,
`WakeCoordinator`, and `AgentWatcher` also remain durable executors or
reconcilers rather than ordinary periodic business work. Startup retry and
process-local UI/session timers are outside this consolidation, as are resident
Agent heartbeat, checkpoint, directive-poll, and wakeup hints.

## Production activation

Production defaults to `EXACT_AGENT_RUNTIME_ENABLED=false`. Activation is a
non-rolling protocol, not a normal feature-flag flip. Apply the additive
migrations, stop every legacy runtime revision, prove durable work quiescence,
and then start the sole exact-runtime revision with the gate enabled. See
[`docs/exact-agent-runtime-cutover.md`](../exact-agent-runtime-cutover.md).
