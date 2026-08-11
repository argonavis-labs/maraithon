# Durable, resident Agent runtime

**Status:** Repository-staged design and activation prerequisite; this document
is not evidence of a production deployment or protocol activation. The staged
implementation includes the local Agent and Task capability-digest proof path
specified below. Production admission must remain closed until that path is
independently reviewed, both database protocols are deliberately activated, and
the matching revision interlocks are enabled.
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
3. **Local execution and non-forgeable physical proof.** OTP supervisors,
   monitors, registries, and PubSub make execution responsive. They act only
   while the database proves the exact node, partition, Agent, claim, and task
   incarnation authoritative. A local monitor observation is accepted only
   through a private one-shot VM capability and a database check of an
   unguessable per-incarnation preimage against its persisted SHA-256 digest;
   role membership or a transaction-local setting is never sufficient.

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
- One stable `Maraithon.Runtime.AgentWatcher` monitors the exact
  `{pid, agent_id, owner_token}`. Every `AgentSupervisor` local start requires
  that watcher to prepare its immutable non-NULL 32-byte SHA-256 capability
  digest. Its unadopted preparation is bound to the exact controller process
  and limited by both a short TTL and tighter preparation/per-controller caps.
  A separate hard bound counts every capability-bearing identity across
  preparation, adopted monitoring, and pending durable-DOWN persistence;
  phase transfers preserve that charge, and live or pending identities are
  never evicted. Capacity is freed only after discard or durable disposition.
  Every preimage remains only in watcher-private ETS. Confirmation, discard,
  and first track require that same controller. The
  Agent digest is nullable only for legacy expansion rows or explicitly
  watcherless, external-proof-only `AgentLeases` claims; NULL can never
  authorize local proof. The watcher asks the VM to retire the original
  owner monitor before accepting mailbox `:DOWN` and consumes a private
  one-shot witness. Its local persistence transaction Base64-encodes the
  preimage into a transaction-local GUC; PostgreSQL decodes and hashes it
  against that exact lease row. A delayed `:DOWN` for an old PID cannot fence or
  restart its replacement.
- `Maraithon.Runtime.AgentRestartGuards` persists crash-loop counts, backoff,
  recovery-required state, and operator reset authority.
- `Maraithon.Runtime.AgentLifecycleOperations` makes stop, pause, update,
  upgrade, remove, and delete drain/finalize operations crash-recoverable.
- `Maraithon.Runtime.WakeCoordinator` performs bounded reconciliation of
  expired ownership, incomplete guard/directive transitions, lifecycle work,
  and due recovery generations.

Authority-sensitive writes take the canonical database locks and verify the
exact generation in the same transaction. Agent lease capability preparation
happens before claim locking, so no lease/Agent database lock is ever held across
a Watcher call. An explicit transaction rollback discards preparation. A
DB/COMMIT-ambiguous exception first reacquires the canonical Agent/lease locks as
a commit barrier: the exact owner-token/digest row resumes the handoff, confirmed
absence discards, and mismatch or database unavailability leaves bounded
controller/TTL cleanup to fail closed. Desired-state changes revoke readiness and
persist intent before best-effort process signalling. The capability preimage is
generated from a cryptographically secure source and
exists only in the owning watcher's private ETS until its one-shot use. A real
preparation-controller DOWN or the short handoff TTL scrubs only an unadopted
preimage; neither event claims physical Agent DOWN. A post-COMMIT/pre-monitor
controller loss, TTL expiry, or start/handoff failure therefore has no local
proof path: the non-NULL digest alone is not live local authority, and recovery
must converge through a durable incident plus authenticated external-destruction
proof. After adoption, the monitor keeps only the nonsecret handoff-controller
PID so the same controller can replay a lost track response; controller loss
never removes adopted monitor/proof authority. The preimage never appears in
public API/state, RPC arguments, access
maps, proof terms, logs, or a database column.
The Base64 transaction GUC is only the final local handoff to
PostgreSQL. Its SQL disables Ecto logging and query telemetry, returns only a
boolean, and fails closed in the same transaction unless PostgreSQL bind and
error parameter logging are disabled as specified in the database runbook. A
role plus an arbitrary/copied GUC,
direct call, raw SQL, or fabricated mailbox tuple still fails the VM witness or
exact-row digest check.
This two-boundary contract is a prerequisite to activation, not a claim about
an already activated fleet.

## Durable Directives

`Maraithon.Runtime.AgentDirectives` is the durable inbox for Agent demand. A
Directive is bounded and encrypted, is idempotent on
`{agent_id, dedupe_key}`, may have a future `available_at`, and is claimed only
by a live, ready exact owner generation. Claim renewal and settlement remain
fenced by that generation and claim token.

The repository-staged exact paths do not treat mailbox acceptance as durable
demand:

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

`Maraithon.Runtime.TaskGuardian` is a private authority process, not a lookup
service. Every `runtime_task_assignments` row has an immutable non-null 32-byte
SHA-256 capability digest. The Guardian installs the original monitors on the
exact Task.Supervisor and task PIDs, VM-authenticates retirement of those refs,
and keeps each unguessable preimage only in private ETS. A local `task_down` or
`supervisor_down` transition is accepted only after its one-shot witness sets
the Base64 preimage in the local persistence transaction and PostgreSQL hashes
it against the exact assignment. The preimage never enters public state, API or
RPC arguments, proof terms, or bounded proof history. A copied access map,
direct persistence/settlement call, arbitrary GUC, fabricated `:DOWN`, raw SQL,
lookup failure, `:not_found`, RPC failure, node disconnect, timeout, lease
expiry, supervisor restart, or missing Registry name is not proof.

Coordinated reservations allocate the durable assignment ID before the physical
reservation and bind it into the Guardian generation. Uncoordinated legacy
Effects receive no task capability. Each generation is bound on first open to
the exact authority/controller PID; a foreign controller cannot reopen it, and
new reservations stop after the controller or Task.Supervisor is down while
historical proof, cancellation, and persistence remain available. The
reservation owner binds the exact supervised child PID before activation. The
child waits behind an owner-controlled gate, and both durable readiness and
provider-entry paths ask the PID-bound authority before taking database locks.
During the finite preflight gap after Guardian activation but before durable
Task activation, the heartbeat path may recognize only the exact locked
`reserved/not_entered/ready_at NULL` assignment with unexpired Effect and Task
leases plus matching live-ready node, partition, and Agent authority. After all
of those exact rows are locked, one final PostgreSQL-clock statement rechecks
the complete Effect/assignment identity and every relevant lease and ready
shape; an earlier lease-cap result is never treated as fresh authority.
Recognition extends neither lease and writes no heartbeat or timestamp; the
original local physical-teardown deadline remains in force across repeated
ticks. Expiry, state or identity drift, or stale authority fails closed and
tears down the coupled task group.
Supported APIs therefore reject ordinary local identity replay. Arbitrary
malicious same-VM system-protocol injection (including raw `:'$gen_call'`) and
unrestricted `Process.exit/2` are outside the SQL-role threat boundary and
require host/BEAM code-execution controls.

Guardian persistence is hard-wired rather than caller-supplied. Production and
development builds compile only direct calls to the concrete Effect or
coordination persistence modules; there is no callback module, dynamic `apply`,
or secret-receiving adapter. The test build has one pre-secret seam for unnamed
Guardians only. It can inject only a bounded `0..1000ms` delay or an atom error,
never success, a disposition, capability clearing, or a capability preimage.

The deduplicated FIFO retry queue retains pending capability entries, processes
each initial entry at most once per fixed 1,000 ms tick in batches of 32, and
deletes private ETS state only after a durable acknowledgement. Every Guardian
database entry path uses an outer 500 ms DBConnection checkout/callback deadline.
Its first statement also sets transaction-local PostgreSQL `lock_timeout` and
`statement_timeout` to 500 ms as a server-side bound before any read, lock, or
secret bind. The canonical runtime/Effect pair helper locks and attests each
protocol exactly once per transaction before installing the transaction-local
Effect writer marker; it never repeats the catalog attestation inside this fixed
budget. Running/requested work commits request plus proof atomically. Reserved
work commits proof only; ordinary reconciliation performs later work settlement.

`never_activated` is a separate capability-backed durable fact, not a synonym
for DOWN. It is permitted only while the assignment is still `reserved`, the
provider boundary is `not_entered`, and durable readiness/activation was never
recorded. A claimed Effect may first move to `cancelling/requested` while that
assignment remains pristine `reserved` only for the exact Effect/claim/physical
identity and live ready-or-draining Agent, partition, and node authority. That
Effect transition records cancellation intent, not task proof or settlement.
The same private Guardian capability first moves that exact assignment to
`termination_proven`; ordinary fenced reconciliation then moves it to
`settled`. A deterministic command-preflight refusal follows this same
proof-first path: the runner persists a bounded failure or retry outcome intent
without releasing the claim, retains its monitor until the VM-authenticated
exact `:DOWN`, and lets Guardian-backed reconciliation apply that exact terminal
or retry outcome only after physical proof. It never enters the provider
boundary and cannot recycle as `effect_task_exited_without_outcome`. Direct raw
settlement is rejected.

Each pre-provider failure, retry, or internal-abort intent is an exact closed
five-key map. Its kind-specific key is `terminal_envelope`, `error_code`, or
`reason`; the other four keys are `attempt`, `intent`, `provenance`, and
`version`. `provenance` itself is exactly `{"attempt": null, "code": null}` or
an exact two-key prior failure whose bounded code and nonnegative attempt are
valid for the current attempt. The durable marker, outer reason/error, attempt,
kind, nested terminal envelope, and complete key sets must all agree. Corruption
fails closed without exposing a staged terminal result or preserving a staged
internal marker. A proof-safe retry/internal abort restores the trusted prior
`last_failure_code` and `last_failure_attempt` so timeout-driven fallback choice
does not change; a proven terminal failure may replace them. Entered/unknown
settlement clears them and remains ambiguous.

Coordinated `cancelled` Effects also have two deliberately distinct durable
shapes. Work cancelled before any claim has no claim/task identity and no linked
assignment. A claimed cancellation settled by exact physical proof retains its
claim token, owner, supervisor/task identity, cancellation target, and linked
`settled/not_entered/cancelled_before_provider` assignment while clearing only
the transient `claimed_by`/`claimed_at` fields. This preserves the proof join and
prevents a claimed cancellation from masquerading as never claimed. Once a task
is ready/running or provider entry can have occurred, termination requires
monitor-derived or external physical proof and preserves ambiguity.

Normal coordinated completion is not a termination proof row. Only an
authenticated exact task DOWN plus exact durable terminal-assignment
acknowledgement consumes the capability; an early completion message is only a
hint, and a nonterminal assignment is reclassified to unexpected-DOWN
persistence. Replay returns the actual durable disposition—`completion`,
`never_activated`, `supervisor_down`, `external_destroyed`, `uncoordinated`, or
serialized-absence `uncommitted`—rather than a caller-requested label. An exact
proof row wins over an attempted kind. Commit-unknown reservations retain their
capability and retry behind canonical locks: an exact committed Effect/assignment
pair becomes `never_activated`; authoritative assignment absence with pristine
or clearly different work authority becomes `uncommitted`; partial identity,
mismatch, or database unavailability remains pending and fails closed.

If the original monitor can never return, a separately authenticated incident
operator may record external destruction evidence bound to the activation and
partition epochs, assignment/work identity, claim token, node incarnation,
Task.Supervisor generation, and local task ID. For a coordinated Effect the
incident transaction locks protocol, Effect, assignment, and work authority in
canonical order, writes the immutable Effect attestation and exact
`external_destroyed` Task proof atomically, and advances reserved/requested work
to `termination_proven`. The command performs no runtime Effect settlement;
ordinary runtime reconciliation settles later. Fully uncoordinated transitional
Effects receive only their attestation, while partial coordination identity
fails closed. Lost-response replay accepts only the identical attestation plus
the matching historical assignment/proof. Reconciliation preserves provider
ambiguity after the entry boundary; it never invents success or releases the
Effect for replay.

### Agent processes

Lease expiry or an ambiguous route/supervisor result creates or refreshes a
requested `agent_termination_incidents` row and blocks successor claims. Expiry
is only a request for proof: it never proves physical termination, removes the
lease, or advances a restart guard. A replacement is admitted only after
either:

- the stable original `AgentWatcher` VM-authenticates the exact monitor
  retirement, consumes its private one-shot witness, and its local transaction
  Base64 handoff lets the database hash the private-ETS preimage against the
  exact lease's immutable SHA-256 digest; or
- an incident operator supplies a SHA-256-addressed, Ed25519-signed external
  node-destruction attestation over the stored activation epoch, node
  incarnation, partition epoch, Agent ID, and lease token.

The incident role cannot delete leases or manufacture a local watcher proof.
The runtime reconciler consumes proven evidence, writes the restart guard,
removes only the matching lease, and marks the incident reconciled in a fenced
transaction. Merely setting a transaction GUC without the watcher-owned
one-shot witness and exact private preimage is still rejected.

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
registries and timers are wakeup hints. Transaction-scoped advisory locks
serialize narrow operations but do not survive as ownership facts.

Wake and reconciliation discovery is partition-exact **inside SQL and before
`ORDER BY`/`LIMIT`**. Each bounded page joins or existentially proves the current
activation epoch, ready node incarnation, ready owned partition and ownership
epoch, PostgreSQL-clock leases, and `runtime_partition_for('user:' || user_id)`;
lease-scoped pages additionally match the lease's complete coordination tuple.
The runtime does not fetch a global page and filter foreign partitions in the
BEAM. Due Directive, recovery, unowned/bootstrap, expired-claim/ownership, and
recorded-generation pages therefore return no rows as soon as node readiness or
partition ownership changes.

Readiness is continuous, not a startup receipt. Exact admission re-evaluates
both protocol modes, catalog/manifest/role/ACL readiness, and the local
ready-last coordination session. The session publishes database node readiness
only after scoped workers exist, renews node/partition authority with the
PostgreSQL clock, and revokes readiness before graceful local shutdown. Any
uncertain renewal or protocol/catalog mismatch closes new admission and fences
local execution; an old `ready_at` value is not permission to continue.

Drain and release use phase-separated, convergent locks. Phase one commits only
the runtime/Effect protocol prefix and topology fence (leader, node, then sorted
partitions); it never waits for Agent leases, Effects, or task assignments while
holding topology. Agent lease revocation then runs without topology locks.
Effect cancellation runs as ordered Effect rows before node, partition, and
assignment, while non-Effect termination uses a separate topology-to-assignment
transaction. A provider holding an Agent lease therefore observes the committed
draining topology and fails closed rather than forming a lease/topology cycle.

Each draining partition carries an ownership-epoch-bound Effect-drain marker.
The marker can advance only for that exact draining/blocked epoch in a separate
`READ COMMITTED` command after an Effect-first sweep has moved every scoped
pending/claimed/executing row to a terminal or cancelling state. The trigger
uses a plain MVCC emptiness check and never takes Effect locks after topology.
Release takes the canonical protocol pair, exact leader, sorted nonterminal
Effects, and partition; it rejects remaining Effects,
requires the marker plus zero unresolved assignments and Agent leases, clears
the marker, and only then makes the partition unassigned. The partition trigger
rechecks the marker transition and release invariant, so direct runtime SQL
cannot exploit the phase boundary after an Agent proof deletes a lease.

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
and never executes arbitrary ETF.

In exact mode the `snapshots` trigger does not trust the runtime marker alone.
For every insert and bounded history prune it verifies, under database locks,
the exact owner token and ready unexpired Agent lease; activation epoch; ready
unexpired node and owned partition/ownership epoch; User-to-partition mapping;
unfenced User; matching enabled/runnable Agent; active isolation binding;
clear restart guard; and absence of lifecycle work or an open termination
incident. Exact rows must also have current encrypted/bound payload shape.
Lifecycle deletion requires its persisted delete operation, while ordinary
prune deletes only a row with at least ten strictly newer recovery boundaries.

An exact checkpoint appends `checkpoint_created`, inserts the Snapshot, and
prunes beyond the newest ten in one outer transaction. Any event, trigger,
binding, authority, insert, or prune failure rolls the complete checkpoint
back. Snapshot quarantine and retention metadata remain content-free.

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

An `ENABLE ALWAYS` source trigger passes the exact relation, SQL operation, and
`to_jsonb(OLD)`/`to_jsonb(NEW)` pair to the reviewed authorization function.
Operator paths are UPDATE-only: Vault rotation may change only the registered
ciphertext fields without changing presence, binding rotation may replace only
one complete binding triple, and stopped-fleet contraction may make only its
fixed plaintext-to-ciphertext projection. INSERT, DELETE, mixed markers,
unregistered relations, or any other OLD→NEW difference are rejected even when
the caller has an operator role and can set a GUC.

Backup-aware retirement is another database protocol, not a secret-manager
checklist: confirmed live-zero proof irreversibly fences the old tag, later
backup/WAL/PITR and restore evidence must move beyond that proof, preflight is
advisory, and only confirmed authorization persists the retired-key row and
permits external removal. See the [durable-payload lifecycle authority
matrix](../operations/durable-payload-lifecycle.md#database-enforced-operator-mutation-authority)
and [key-retirement procedure](../operations/durable-payload-lifecycle.md#backup-aware-key-retirement).

## Privacy lifecycle

Retention is bounded, fair per tenant, and based on the PostgreSQL clock. The
durable retention coordinator runs every 15 minutes after a 20-second initial
delay. Eligibility fails closed for active, requested, outcome-ambiguous, or
unacknowledged work; expiry clears content while preserving the minimum
identity, dedupe, authority, and audit facts required by the protocol.

Privacy-sensitive transactions follow one lock prefix: runtime protocol, Effect
protocol, affected User rows in stable order, then fixed source rows. The User
write-fence triggers take the same ordered User locks for OLD and NEW subject
IDs. A path must not lock a source and then reach backward for a protocol or
User row.

Erasure-job discovery runs every minute after a 10-second initial delay. User
and Agent erasure is a durable claim-token-fenced state machine: publish the
write fence, drain Agent/effect authority, revoke local credentials and request
provider revocation, erase bounded copies, prove the fixed surfaces clean, then
write a content-free receipt. The `privacy_erasure` job itself is never
cancelled to manufacture a cutover drain. Stopped-fleet contraction preserves
an exact pending/unclaimed job, encrypts its payload, and atomically writes an
append-only `privacy_erasure_job_deferral_v1` receipt bound to the active
request. That receipt is the only cutover exception to the non-deferrable work
zero. Provider non-confirmation produces `partial_unverified`; it does not undo
verified local deletion. Logging out only ends a session and is not an erasure
request.

See the operations guides for the executable policy:

- [Durable payload lifecycle](../operations/durable-payload-lifecycle.md)
- [Privacy retention and erasure](../operations/privacy-retention-erasure.md)
- [Database TLS, backup, and restore](../operations/database-tls-backup-restore.md)

## Production activation

Neither capability flag may be enabled by a normal rolling deployment. The
initial transition is a feature-dark, stopped-fleet, revision-bound procedure
with external fleet evidence, all-source payload proofs, and two irreversible
database activations. Its canonical, nonconcurrent order is: commit one evidence
attestation; activate Effect `generation_fenced_v1`; then activate runtime
coordination `partition_fenced_v1`; only then perform a zero-to-one start of the
already reviewed revision. Every authority path takes protocol locks in runtime
→ Effect order even though the Effect mode transition commits first.

The evidence digest is SHA-256 of the exact immutable canonical evidence bytes.
Lowercase hexadecimal is only CLI transport; tasks decode it and PostgreSQL
persists/compares the same 32 raw bytes. Never hash the printed hex, a Base64
encoding, or a reserialized representation. The evidence and exact revision
become immutable; after the first activation there is no flag or SQL downgrade,
only retry with the same envelope or a separately reviewed fix-forward protocol
change. This section specifies a procedure and does not assert that it has run.
See [Exact Agent runtime production cutover](../exact-agent-runtime-cutover.md).
