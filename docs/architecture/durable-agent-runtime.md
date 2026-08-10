# Durable, resident Agent runtime

**Status:** Implemented. Production admission remains closed until both database
protocols are activated and the matching revision capability interlocks are
enabled.
**Decision date:** 2026-08-10

## Decision

Maraithon Agents remain long-lived OTP processes. OTP owns local liveness,
serialization, isolation, and routing. PostgreSQL owns durable intent,
incarnation authority, recovery facts, checkpoints, work admission, fairness,
and terminal outcomes. A PID, Registry entry, PubSub delivery, mailbox
acknowledgement, timer, or advisory lock is never durable ownership or
completion proof.

This is a state machine with checkpoints, not strict event sourcing. Recovery
restores a bounded, versioned snapshot and reconciles durable work. The event
log is an audit/history surface; behavior handlers are not replayed in a way
that could repeat external side effects.

## Authority layers

The production runtime has three deliberately separate authority layers:

1. **PostgreSQL protocols.** Effect mode moves one way from `legacy` to
   `generation_fenced_v1`; runtime coordination moves one way from `dark` to
   `partition_fenced_v1`. Database rows, triggers, catalog fingerprints, and
   exact transaction locks enforce these modes.
2. **Revision capabilities.** `EXACT_AGENT_RUNTIME_ENABLED` and
   `MULTINODE_COORDINATION_ENABLED` allow a compatible revision to participate.
   They cannot activate either protocol and are not stopped-fleet evidence. A
   node registration must also present the exact `GIT_SHA` stored by the
   activation evidence; a different revision cannot join the activated epoch.
3. **Local execution.** OTP supervisors, monitors, registries, and PubSub make
   execution responsive. They act only while the database proves the exact
   node, partition, Agent, claim, and task incarnation authoritative.

`Maraithon.Runtime.BootGate` starts closed whenever background workers start.
It opens only after the coordination session is ready, wake reconciliation has
completed, desired Agents have taken the preclaim path, and readiness is
rechecked. BootGate is a local admission barrier, not proof that another
revision is absent.

## Resident Agent lifecycle

- One `Maraithon.Runtime.Agent` `gen_statem` serializes each resident Agent's
  `recovering`, `idle`, `working`, and `waiting_effect` states.
- `Maraithon.Runtime.AgentSupervisor` starts exact children as `:temporary`.
  Restarting stale supervisor arguments cannot reuse authority; a replacement
  must acquire a fresh database owner generation.
- `Maraithon.Runtime.AgentRegistry` is a local routing index. Its owner-token
  metadata is useful for routing but is not authority.
- `Maraithon.Runtime.AgentLeases` claims and renews a UUID owner generation
  using the PostgreSQL clock. The Agent is marked ready only after recovery,
  subscriptions, timers, checkpoint state, and monitoring are installed.
- `Maraithon.Runtime.AgentWatcher` monitors the exact
  `{pid, agent_id, owner_token}`. A delayed `:DOWN` for an old PID cannot fence
  or restart its replacement.
- `Maraithon.Runtime.AgentRestartGuards` persists crash-loop counts, backoff,
  recovery-required state, and operator reset authority.
- `Maraithon.Runtime.AgentLifecycleOperations` makes stop, pause, update,
  upgrade, remove, and delete drain/finalize operations crash-recoverable.
- `Maraithon.Runtime.WakeCoordinator` performs bounded reconciliation of
  expired ownership, incomplete guard/directive transitions, lifecycle work,
  and due recovery generations.

Authority-sensitive writes take the canonical database locks and verify the
exact generation in the same transaction. Desired-state changes revoke
readiness and persist intent before best-effort process signalling.

## Durable Directives

`Maraithon.Runtime.AgentDirectives` is the durable inbox for Agent demand. A
Directive is bounded and encrypted, is idempotent on
`{agent_id, dedupe_key}`, may have a future `available_at`, and is claimed only
by a live, ready exact owner generation. Claim renewal and settlement remain
fenced by that generation and claim token.

The shipped paths no longer treat mailbox acceptance as durable demand:

- exact `Maraithon.Runtime.send_message/3` enqueues a `message` Directive;
- topic and connector fan-out commits Directives before acknowledging ingress;
- scheduled wakeups commit a Directive and acknowledge the scheduled row in the
  same transaction.

After commit, an ID-only PubSub notification reduces latency. A missing
subscriber or dropped notification is harmless because resident Agents and
wake reconciliation poll PostgreSQL. Processing, active run/effect lineage,
terminal state, terminal acknowledgement, and ambiguity are durable. Reusing a
dedupe key with different input conflicts instead of silently becoming a new
request.

## Effect execution and the provider boundary

Effects are durable outbox work. Exact claims carry the Agent owner generation,
claim token, owner node, Task.Supervisor generation, and local task identity.
The claim is checked again under database authority immediately before command
entry.

Under partition-fenced coordination, each physical execution also has a
`runtime_task_assignments` row. Its durable provider boundary is explicit:
`not_entered` before command entry, `entered` before provider code may run,
`outcome_known` when an exact returned outcome is durably settled, and
`outcome_unknown` when termination is requested after entry without a durable
outcome. This is the retry rule:

- cancellation with physical proof while `not_entered` may settle as
  `cancelled_before_provider` and release safely;
- after `entered`, loss without a durable outcome becomes
  `provider_outcome_ambiguous`/`outcome_unknown` and must not replay
  non-idempotent work;
- a provider response is not completion until the exact Effect terminal record,
  coordinated task outcome evidence, and claim settlement are durable;
- result notification is a replayable delivery hint. Durable dispatch
  reservation and acknowledgement remain separate from the terminal outcome.

Tool calls are especially conservative: only policy/validation failures proven
before command entry are ordinary failures. Transport failure, task loss,
response failure, or inability to persist a returned success after entry is
ambiguous. Provider idempotency keys should still be used where available, but
they do not weaken the runtime fence.

## Physical termination proof

Authority expiry and physical termination are different facts.

### Effect and coordinated tasks

`Maraithon.Runtime.TaskGuardian` installs monitors on exact Task.Supervisor and
task PIDs and retains bounded proof history. Only its exact monitor-derived
`:DOWN` observation (or cancellation before activation) is local physical
proof. Lookup failure, `:not_found`, RPC failure, node disconnect, timeout,
lease expiry, supervisor restart, or missing Registry name is not proof.

If the original monitor can never return, a separately authenticated incident
operator may record external destruction evidence bound to the activation and
partition epochs, assignment/work identity, claim token, node incarnation,
Task.Supervisor generation, and local task ID. The role-specific database
trigger rejects stale or incomplete identity. Reconciliation preserves
provider ambiguity after the entry boundary; it never invents success or
releases the Effect for replay.

### Agent processes

An expired Agent lease or ambiguous route/supervisor result creates an
`agent_termination_incidents` row and blocks successor claims. A replacement is
admitted only after either:

- the stable original `AgentWatcher` observes the exact local `:DOWN`; or
- an incident operator supplies a SHA-256-addressed, Ed25519-signed external
  node-destruction attestation over the stored activation epoch, node
  incarnation, partition epoch, Agent ID, and lease token.

The incident role cannot delete leases or manufacture a local watcher proof.
The runtime reconciler consumes proven evidence, writes the restart guard,
removes only the matching lease, and marks the incident reconciled in a fenced
transaction.

## PostgreSQL partition and scheduling authority

Active coordination uses 64 stable tenant partitions. PostgreSQL owns:

- the activation epoch and exact node incarnations;
- ready-last node and partition leases plus monotonic ownership epochs;
- leader planning, bounded assignment, drain, steal, and rebalance transitions;
- physical task assignments, provider-boundary state, outcomes, and termination
  proofs;
- tenant concurrency limits, PostgreSQL-clock token refills, and deterministic
  per-partition service sequences;
- durable provider/account lane watermarks, per-key concurrency, rate-limit
  cooldowns, and `Retry-After` deadlines.

The 64-way tenant mapping and every background/scheduled job's `tenant_key` and
`partition_id` are database facts prepared before activation. A worker may
select only work in its ready database-owned partitions. Every settlement
repeats node, partition epoch, task assignment, and claim-token checks. Local
registries and timers are wakeup hints. Transaction-scoped
advisory locks serialize narrow operations but do not survive as ownership
facts.

Readiness is continuous, not a startup receipt. Exact admission re-evaluates
both protocol modes, catalog/manifest/role/ACL readiness, and the local
ready-last coordination session. The session publishes database node readiness
only after scoped workers exist, renews node/partition authority with the
PostgreSQL clock, and revokes readiness before graceful local shutdown. Any
uncertain renewal or protocol/catalog mismatch closes new admission and fences
local execution; an old `ready_at` value is not permission to continue.

## Durable jobs and periodic work

Fifteen ordinary recurring coordinators are stable `background_jobs` rows:
brief and insight notification, briefing discovery, assistant recovery,
Telegram run reaping, token and watch renewal, freshness, proactive check-in,
todo completion, nudging, staleness triage, the wall-clock dogfood digest,
erasure-job discovery, and privacy retention. A successful claim-token-fenced
cycle moves the same row back to `pending` with its next PostgreSQL-clock
deadline. Reconciliation repairs missing schedules under a transaction-scoped
lock; no scheduler PID owns the deadline.

Provider discovery emits one bounded account/cursor/token unit into
`runtime_provider_account`; model discovery emits one bounded user unit into
`runtime_model_user`. Durable lane watermarks, partition keys, and rate keys
prevent one account, provider family, or hot tenant from monopolizing capacity.
In active coordination, the global fair scheduler chooses only a ready owned
partition, enforces the tenant's active-task limit and PostgreSQL-clock token
bucket, and advances the partition service sequence and tenant cursor in the
same transaction as the exact job/task reservation. It applies that authority
to heterogeneous background work while preserving Telegram's per-bot committed
update head.

`DogfoodDigest` persists a validated named timezone and exact next-fire instant.
PostgreSQL timezone data resolves DST gaps and folds; invalid zones fail closed
rather than falling back to UTC.

`HealthReporter` and `StuckStateWatchdog` remain resident independent observers
so a wedged queue cannot silence its own alarm. `Scheduler`, `EffectRunner`,
`WakeCoordinator`, `AgentWatcher`, and the coordination session are durable
executors/reconcilers rather than ordinary periodic business work.

## Snapshots and encrypted durable payloads

Snapshots use bounded tagged JSON, carry schema versions, and are encrypted and
context-bound like the other durable payload sources. Tagged JSON v1 is the
only write format; the migration-only legacy reader is bounded and safe-decoded
and never executes arbitrary ETF. A checkpoint insertion prunes the same Agent
to its newest ten Snapshots in the transaction. Snapshot quarantine and
retention metadata are content-free.

`Maraithon.DurablePayloadRegistry` is the closed source of truth for exactly 18
authenticated encrypted payload sources:

1. `effects`
2. `agent_directives`
3. `events`
4. `agent_run_steps`
5. `telegram_conversation_turns`
6. `telegram_conversations`
7. `telegram_assistant_runs`
8. `telegram_assistant_steps`
9. `telegram_prepared_actions`
10. `agent_runs`
11. `operator_events`
12. `user_memory_profiles`
13. `operator_memory_summaries`
14. `background_jobs`
15. `scheduled_jobs`
16. `runtime_ingress_receipts`
17. `snapshots` (Snapshot state and budget)
18. `agent_work_results`

Cloak AES-GCM authenticates ciphertext bytes. A separate versioned HMAC binds
the ordered plaintext fields to their table, typed row identity, and tenant or
Agent context, preventing valid ciphertext substitution. Verification,
binding migration/rotation, Vault re-encryption, retention, and erasure share
the reviewed registry; arbitrary table names never enter those operations.
Source mutation invalidates its proof under the same advisory identity used by
the verifier.

## Privacy lifecycle

Retention is bounded, fair per tenant, and based on the PostgreSQL clock. The
durable retention coordinator runs every 15 minutes after a 20-second initial
delay. Eligibility fails closed for active, requested, outcome-ambiguous, or
unacknowledged work; expiry clears content while preserving the minimum
identity, dedupe, authority, and audit facts required by the protocol.

Erasure-job discovery runs every minute after a 10-second initial delay. User
and Agent erasure is a durable claim-token-fenced state machine: publish the
write fence, drain Agent/effect authority, revoke local credentials and request
provider revocation, erase bounded copies, prove the fixed surfaces clean, then
write a content-free receipt. Provider non-confirmation produces
`partial_unverified`; it does not undo verified local deletion. Logging out only
ends a session and is not an erasure request.

See the operations guides for the executable policy:

- [Durable payload lifecycle](../operations/durable-payload-lifecycle.md)
- [Privacy retention and erasure](../operations/privacy-retention-erasure.md)
- [Database TLS, backup, and restore](../operations/database-tls-backup-restore.md)

## Production activation

Neither capability flag may be enabled by a normal rolling deployment. The
initial transition is a feature-dark, stopped-fleet, revision-bound procedure
with external fleet evidence, all-source payload proofs, and two irreversible
database activations. The evidence and exact revision become immutable; after
the first activation there is no flag or SQL downgrade, only retry with the
same envelope or a separately reviewed fix-forward protocol change. See [Exact
Agent runtime production cutover](../exact-agent-runtime-cutover.md).
