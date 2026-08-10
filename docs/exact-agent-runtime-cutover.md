# Exact Agent runtime production cutover

This runbook is the one-time transition from Effect protocol `legacy` and
runtime coordination `dark` to Effect `generation_fenced_v1` and coordination
`partition_fenced_v1`.

It is deliberately **feature-dark, nonrolling, stopped-fleet, and
revision-bound**. Both database promotions are one-way. They are not feature
flags and cannot be rolled back. After the first promotion, every failure is
fix-forward while application execution remains closed.

## Invariants

- `EXACT_AGENT_RUNTIME_ENABLED` and `MULTINODE_COORDINATION_ENABLED` are false
  on every running process during preparation. They are capability interlocks,
  not activation authority or fleet-absence evidence.
- Effect activation happens first while `Maraithon.Runtime.BootGate` remains
  closed and no application fleet exists. Coordination activation happens
  second with no process started between them.
- The stopped-fleet evidence ID, SHA-256 digest, operator, and exact revision are
  identical for pre-attestation and both promotions.
- The exact revision is a 40- or 64-character lowercase hexadecimal artifact
  revision. It becomes the only revision allowed to register after activation.
- A BootGate state, Registry lookup, discovery response, lease expiry,
  `runtime_node_incarnations` row, or absence of a local PID does not prove physical fleet
  absence. Evidence must come from the external compute and producer control
  planes.
- Storage-only tasks start config, Ecto SQL, Vault, and Repo only. They never
  start `Maraithon.Application`, supervisors, runtime workers, connectors, or
  provider code.
- Never print database URLs, passwords, Fly tokens, payloads, signatures, or key
  material. Evidence is content-free and stored outside the repository.

## Ownership and operator connections

Assign separate application/Fly, database migration, payload verification,
activation, incident/security, and evidence-review operators. Require a second
reviewer before fleet destruction, pre-attestation, and each promotion.

Use the exact connection bindings below. Every URL independently rebuilds
verified TLS for its own hostname with `DATABASE_TLS_MODE=verify_peer`; a
runtime socket/SNI option must not be copied to an operator URL.

| Variable | Exact username | Use |
| --- | --- | --- |
| `DATABASE_URL` | `maraithon_runtime` | ordinary application only |
| `MARAITHON_MIGRATOR_DATABASE_URL` | `maraithon_migrator` | migrations and partition finalization |
| `DURABLE_PAYLOAD_VERIFIER_DATABASE_URL` | `maraithon_payload_verifier` | all-source proof writer |
| `MARAITHON_ACTIVATION_DATABASE_URL` | `maraithon_activation_operator` | stopped-fleet attestation, contraction, promotions |
| `MARAITHON_INCIDENT_DATABASE_URL` | `maraithon_incident_operator` | reviewed incident evidence only |
| `VAULT_ROTATION_DATABASE_URL` | `maraithon_incident_operator` | separate Vault lifecycle binding; not used in this cutover |

The canonical object owner is the non-login `maraithon_object_owner`; only
`maraithon_migrator` is its member. Provision the six-role topology before
migration and do not share credentials. See [Database TLS, backup, and
restore](operations/database-tls-backup-restore.md).

Fly commands require a short-lived token exported only as `FLY_API_TOKEN`,
scoped to the pinned production application and the exact actions in this
window. Set `MARAITHON_FLY_APP` explicitly on every app command. Never rely on
an active `flyctl` account, legacy `FLY_APP`, or `--access-token`.

## Change record

Before touching production, record these content-free values in the restricted
change system:

- `EXACT_REVISION`, the reviewed source/artifact digest, image reference, and
  configuration digest;
- `EVIDENCE_ID`, `EVIDENCE_DIGEST` (exactly 64 lowercase hexadecimal
  characters), and `ACTIVATED_BY` (the same actor for all three database
  operations);
- the pinned Fly organization/application, every process group, external worker
  app, region, Machine/revision inventory, and desired post-cutover count;
- database/cluster identifier, current migration set, current Effect and
  coordination modes, and catalog/role proof results;
- connector, webhook, scheduled producer, CI, release-job, and operator-session
  owners;
- backup, WAL/PITR, monitoring, incident, and abort/fix-forward owners.

Make `EVIDENCE_ID` a stable content-free identifier no longer than 128 bytes,
using letters, digits, `.`, `_`, `:`, or `-`, so later lifecycle evidence may
refer to it. Do not put a credential, signature, payload, subject identifier,
or raw URL in any field.

## Phase 0 — prove preparation and recovery

1. Announce a write outage. Block unrelated deploys, schema changes, key
   rotations, retention overrides, and manual job mutation.
2. Create and verify a fresh physical backup and continuous WAL/PITR coverage.
   Confirm an isolated restore drill and all required Vault/binding read tags.
   This is recovery evidence, **not** permission to downgrade an activated
   protocol from a pre-activation snapshot.
3. Verify the reviewed checkout/artifact is exactly `EXACT_REVISION` and clean.
4. Verify all six roles, exact grants/membership, database name, TLS hostnames,
   CA trust, and operator URL usernames without displaying URLs.
5. Confirm production reports Effect `legacy`, coordination `dark`, and both
   capability interlocks false. If either protocol is already promoted, stop:
   this initial-cutover runbook no longer applies.
6. Validate telemetry and alerts for database readiness, node/partition lease
   renewal, BootGate, task ambiguity, stuck directives/effects/jobs, proof
   failures, and provider/inbound traffic.

## Phase 1 — expand storage and stage the dark revision

The expansion schema must be present before final preparation, but the existing
legacy fleet must remain available to finish already accepted Agent work.

1. Stage (do not deploy) false interlocks and the reviewed revision:

   ```bash
   : "${FLY_API_TOKEN:?scoped Fly token required}"
   : "${MARAITHON_FLY_APP:?pinned production app required}"
   : "${EXACT_REVISION:?reviewed exact revision required}"

   flyctl secrets set --stage --app "$MARAITHON_FLY_APP" \
     EXACT_AGENT_RUNTIME_ENABLED=false \
     MULTINODE_COORDINATION_ENABLED=false \
     GIT_SHA="$EXACT_REVISION"
   ```

2. From that exact source artifact, apply every additive migration with only the
   migrator URL:

   ```bash
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix ecto.migrate
   ```

3. Recheck migration versions, exact catalog and role/ACL readiness, Effect
   `legacy`, coordination `dark`, and both false capability values. The existing
   fleet remains the only execution fleet for Phase 2. Do not deploy the dark
   revision or finalize a format that an older reader cannot consume until the
   semantic drain is complete.

## Phase 2 — quiesce demand on the legacy fleet

Do this while the current legacy Agents and workers can still finish and
acknowledge their accepted work.

1. Pause inbound traffic at authoritative external control planes: webhook and
   connector delivery, provider discovery, schedules, CI automation, release
   jobs, and every other app or worker that can write durable demand. A local
   application maintenance page alone is insufficient.
2. Allow claimed Directives, Agent runs/steps, Effects, assistant runs/steps,
   prepared actions, jobs, and dispatch acknowledgements to settle normally.
3. Cancel only through their owning authenticated/domain operations and exact
   claim/terminal transitions. Never delete queue rows, null a claim, forge an
   acknowledgement, rewrite provider-boundary state, or bulk-mark work terminal.
4. Resolve pre-entry cancellation only with physical task proof. Work that
   crossed provider entry without a durable result remains outcome-ambiguous;
   it is not safe to replay or relabel. Complete incident review before
   cutover.
5. Obtain explicit product-owner approval for future scheduled or queued work
   that cannot finish. Preserve its idempotent source reference before normal
   domain cancellation so it can be deliberately recreated after activation.

Before replacing this fleet, require zero processing Directives, running Agent
runs, requested steps, active Effects, active assistant work, nonterminal
prepared actions, dispatched schedules, provisional results, and physically
running background work. Stable future/recurring job rows may remain pending at
this point; they are cancelled through a reviewed storage-only domain operation
only after the feature-dark fleet is zero, when they cannot repopulate.

Capture the last externally accepted ingress positions and provider heads. Do
not pre-attest fleet absence yet.

## Phase 3 — deploy dark, finalize storage, and remove the fleet

1. Immediately deploy the capable revision with both flags still false using
   the normal token-scoped production path:

   ```bash
   make deploy
   ```

   `make deploy` uses the required immediate strategy. Its Fly release command
   must use the verified direct migrator transport; the application Repo must
   still use `DATABASE_URL` as `maraithon_runtime`. Prove every Machine now runs
   the single reviewed image and `GIT_SHA`, both capabilities remain false,
   Effect remains `legacy`, coordination remains `dark`, and exact Agent
   admission/BootGate remain closed. Do not continue with mixed revisions.

2. Backfill and finalize PostgreSQL-owned tenant partitions:

   ```bash
   MIX_ENV=prod mix maraithon.coordination.backfill --batch-size 100
   ```

   The task requires `MARAITHON_MIGRATOR_DATABASE_URL`. Its final report must
   show no missing tenant/partition keys or unbackfillable scheduled rows and
   must validate the prepared constraints/catalog.

3. Convert legacy Snapshot envelopes in finite batches, prove the backlog zero,
   and validate the format constraint. The finalizer performs DDL, so scope the
   migrator credential to these storage-only processes:

   ```bash
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.snapshots.migrate --batch-size 25 --max-batches 100
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.snapshots.migrate --finalize
   ```

   Repeat bounded conversion when needed. Investigate every invalid/oversized or
   active-without-fresh-checkpoint result through policy; do not hide it by
   deleting a quarantine/failure row.

4. Run the one-time retention legacy cleanup and finalize its prepared
   constraints with the migrator credential:

   ```bash
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.privacy_retention cleanup-legacy --batch-size 25
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.privacy_retention preflight
   DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
     MIX_ENV=prod mix maraithon.privacy_retention finalize-constraints
   ```

   Repeat bounded cleanup until preflight reports zero legacy Snapshot payload
   digests and quarantine/attestation orphans, `activation_ready: true`, and
   every installed extension ready.

5. Confirm no dark-revision background task is physically running. Record the
   desired post-cutover count and a pre-stop JSON inventory under a restrictive
   umask, then scale the repository's `app` process group to zero:

   ```bash
   umask 077
   flyctl status --app "$MARAITHON_FLY_APP" --all --json > "$STATUS_BEFORE_FILE"
   flyctl machine list --app "$MARAITHON_FLY_APP" --json > "$MACHINES_BEFORE_FILE"
   flyctl scale count 0 --process-group app --yes --app "$MARAITHON_FLY_APP"
   flyctl machine list --app "$MARAITHON_FLY_APP" --json > "$MACHINES_AFTER_FILE"
   ```

   Repeat explicit zero/destroy operations for every inventoried Fly process
   group and external worker app. Review any remaining Machine ID individually,
   capture its control-plane state and image, and destroy it explicitly; do not
   pipe an unreviewed list into `machine destroy`. Prove no deploy/release
   Machine remains and no auto-start/minimum-count policy can recreate one.

6. With every producer absent, cancel only the approved pending recurring and
   future scheduled rows through their reviewed storage-only domain APIs. Such
   tooling may start config, Ecto SQL, Vault, and Repo only; it must not boot
   `Maraithon.Application` or use raw SQL. Exact startup reconciliation recreates
   the stable recurring coordinators. If no reviewed storage-only path exists,
   the cutover is blocked.

If fleet shutdown killed any task, do not infer termination from Machine
absence. Resolve its exact task/Agent physical proof and provider ambiguity. A
restart of the feature-dark revision invalidates this fleet-absence attempt:
finish reconciliation, return to zero, collect a new inventory/evidence
interval, and repeat the durable preflight.

Obtain independent content-free attestations from:

- Fly compute/deployment/Machine history for every relevant app and region;
- connector, webhook, scheduler, CI, and provider control planes;
- host/orchestrator inventory for any non-Fly producer;
- the change controller confirming no operator task can start the application.

The evidence must identify every stopped revision and physical compute identity
and cover the entire interval through both activations. Store raw signed
attestations externally. Database leases, a closed BootGate, local discovery,
and the following durable preflight are supplementary checks, never substitutes
for external physical evidence.

## Phase 4 — prove the durable drain before attestation

With the fleet absent, run the activation-role preflight:

```bash
MIX_ENV=prod mix maraithon.payload_privacy preflight
```

It must report zero across the complete contraction drain: active Directives,
run steps, Effects, Agent/assistant runs and steps, prepared actions,
background/scheduled jobs, provisional work results, coordination nodes,
leaders, non-unassigned partitions, incomplete transitions/rebalances, and
active/proven task assignments. `in_flight.total` must be zero.

Also run:

```bash
MIX_ENV=prod mix maraithon.conversation_privacy preflight
```

The `eligible` values are the expected legacy encryption backlog for Phase 6;
they need not be zero yet. Require `in_flight.total: 0` and every `deferred` and
`blocked` value zero before attestation. Record the eligible baseline. If any
work/deferred/blocked count is nonzero, use a reviewed storage-only domain
operation while exact authority is still available, or restart only the same
feature-dark revision to reconcile it. A restart invalidates this fleet-absence
attempt: stop and inventory the fleet again, obtain new external evidence, and
rerun every preflight. Never contract around active, ambiguous, or oversized
work.

When all drain/deferred/blocked counts are zero, seal the external evidence
bundle, verify its
reviewed SHA-256 digest, actor, exact revision, time interval, and signatures,
and keep it immutable. The activation task receives only its content-free ID
and digest, not the bundle or signatures.

## Phase 5 — pre-attest the stopped fleet

This is the first immutable database commitment. Run it exactly once, still in
Effect `legacy` and coordination `dark`:

```bash
MIX_ENV=prod mix maraithon.effects.attest_activation \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-digest "$EVIDENCE_DIGEST" \
  --activated-by "$ACTIVATED_BY" \
  --exact-revision "$EXACT_REVISION"
```

The task uses `MARAITHON_ACTIVATION_DATABASE_URL` as
`maraithon_activation_operator`, independently revalidates TLS and the evidence
shape, locks the coordination and Effect protocol rows, requires the exact
`dark`/`legacy` pair, and records the tuple on the Effect singleton. The drain
and full storage gates are rechecked transactionally by every contraction and
promotion; this attestation does not replace those checks.

A retry must use the identical ID, digest, actor, and revision. If any external
producer or application process starts afterward, the attestation is no longer
truthful and cannot be silently replaced. Keep execution closed and escalate to
a reviewed fix-forward protocol migration; never reuse or edit the row.

## Phase 6 — contract and prove all durable payloads

Every contraction invocation uses the activation role, takes the stopped-fleet
and protocol locks, rechecks the exact evidence tuple and complete durable drain,
and completes its bounded mutation in one transaction. Its maximum allowed
transaction timeout is 180 seconds. Start with small batches and repeat; never
increase a timeout to work around blocking.

### Effect and Directive payloads

```bash
MIX_ENV=prod mix maraithon.payloads.backfill_effects \
  --batch-size 25 --max-batches 100 \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" \
  --revision "$EXACT_REVISION" \
  --confirm
```

Repeat until a pass migrates zero Effect and Directive payloads and reports no
closed failures.

### Events, run steps, and Snapshots

```bash
MIX_ENV=prod mix maraithon.payload_privacy backfill \
  --batch-size 25 --max-batches 100 \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" \
  --revision "$EXACT_REVISION" \
  --confirm
MIX_ENV=prod mix maraithon.payload_privacy preflight
```

Repeat until every family reports `eligible: 0`, `deferred: 0`, and
`blocked: 0`, and `in_flight.total` remains zero. Invalid or oversized content
is a blocker to resolve, never an excluded row or accepted disposition.

### Conversation and operator payloads

```bash
MIX_ENV=prod mix maraithon.conversation_privacy backfill \
  --batch-size 25 --max-batches 100 \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" \
  --revision "$EXACT_REVISION" \
  --confirm
MIX_ENV=prod mix maraithon.conversation_privacy preflight
```

Repeat until every one of its 13 registered families reports `eligible: 0`,
`deferred: 0`, and `blocked: 0`.

### Contextual binding readiness

Run `Maraithon.DurablePayloadBindingMigration.preflight/0` through the reviewed
storage-only activation runner. Require `registry_sources: 18`,
`binding_targets: 19`, and zero `missing`, `incomplete`, and `purged_invalid`.
If migration is required, invoke only
`Maraithon.DurablePayloadBindingMigration.rebind/1` in bounded batches with the
same complete evidence tuple. Its targets come only from the closed registry;
there is no arbitrary-table or raw-SQL path. If the reviewed runner is not
available, activation is blocked.

### Global authenticated proof

Switch to the independently authenticated payload-verifier URL. Verify all 18
closed registry sources, including Snapshot; a table-scoped run is diagnostic
and cannot activate production:

```bash
MIX_ENV=prod mix maraithon.payloads.verify \
  --batch-size 25 --max-batches 1000
MIX_ENV=prod mix maraithon.payloads.verify --preflight
```

Repeat the bounded verifier until the global preflight reports `failures: 0`.
Preserve content-free failure classes for investigation. Do not expose decrypted
content or delete failure/proof rows to synthesize readiness.

Run the payload/conversation preflights once more and revalidate Effect legacy,
coordination dark, exact catalog/role/ACL manifests, and the unchanged stopped-
fleet evidence tuple. This is the last point at which those contraction tasks
can run.

## Phase 7 — activate exact Effect protocol with BootGate closed

Do not start an application Machine. The absent fleet is stronger than a local
gate check; logically and operationally BootGate remains closed, and this
storage-only task cannot open it.

```bash
MIX_ENV=prod mix maraithon.effects.activate_generation_fenced \
  --confirm NON_ROLLING_FLEET_DRAINED \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --revision "$EXACT_REVISION"
```

The single transaction locks and rechecks the protocol singleton and every
registered payload source, exact migrations/catalog/role/ACL manifests, the
stopped-fleet evidence, absence of runtime leases and active Agent/legacy Effect
work, Effect/Directive encryption, and all-source proof completeness, then
changes only `legacy` to `generation_fenced_v1`.

From this commit onward, rollback is forbidden. If the command's result is
uncertain, query through the approved read-only operator path and retry only the
same envelope. Never restore a pre-activation database, run legacy code, change
the evidence tuple, or hand-edit the singleton.

## Phase 8 — activate exact runtime coordination

Without starting any code or changing evidence, run:

```bash
MIX_ENV=prod mix maraithon.coordination.activate \
  --confirm NON_ROLLING_MULTINODE_FLEET_DRAINED \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-digest "$EVIDENCE_DIGEST" \
  --activated-by "$ACTIVATED_BY" \
  --exact-revision "$EXACT_REVISION"
```

The activation-role transaction verifies Effect is already exact with the same
ID, digest, actor, and revision; locks the stopped-fleet and payload authorities;
repeats the durable drain and exact catalog/partition/role checks; advances the
activation epoch; and changes only `dark` to `partition_fenced_v1`.

A repeat succeeds only for the identical immutable envelope. A mismatched
actor, digest, evidence ID, or revision fails with activation-evidence mismatch.
If this phase fails after Effect activation, keep the fleet at zero, correct
only the failed prerequisite through reviewed forward operations, and retry the
same envelope. There is no mixed-mode application fallback.

## Phase 9 — nonrolling start of the exact revision

Stage both capabilities only after both promotions:

```bash
flyctl secrets set --stage --app "$MARAITHON_FLY_APP" \
  EXACT_AGENT_RUNTIME_ENABLED=true \
  MULTINODE_COORDINATION_ENABLED=true \
  GIT_SHA="$EXACT_REVISION"
```

Reprove the Fly Machine count is still zero and the latest deployed release is
the exact feature-dark image recorded in the evidence bundle. Do not rebuild,
redeploy, run a release command, or weaken the normal deployment guard. Create
one `app` Machine from that already deployed release with explicit values that
agree with the staged configuration:

```bash
flyctl scale count 1 --process-group app --yes \
  --app "$MARAITHON_FLY_APP" \
  --env "GIT_SHA=$EXACT_REVISION" \
  --env "EXACT_AGENT_RUNTIME_ENABLED=true" \
  --env "MULTINODE_COORDINATION_ENABLED=true"
```

There is no old Machine to overlap, so this is a zero-to-one nonrolling start,
not a deployment. If the Machine uses a different image, revision, database,
TLS mode, or capability value, immediately return `app` to zero and preserve
incident evidence. Do not start an old revision.

After the first node is continuously ready and Phase 10 passes, scale only the
same deployed exact image to the recorded desired count (skip this when the
desired count is one):

```bash
: "${DESIRED_APP_COUNT:?reviewed post-cutover count required}"
flyctl scale count "$DESIRED_APP_COUNT" --process-group app --yes \
  --app "$MARAITHON_FLY_APP"
```

Verify every additional node before restoring ingress. Any future build with a
different revision requires a separately reviewed compatible forward protocol
procedure before the normal `make deploy` path may be used.

## Phase 10 — continuous readiness and ingress restoration

Readiness is not a startup checkbox. Confirm continuously through the canary
window and alert thereafter:

- Effect is `generation_fenced_v1`; coordination is `partition_fenced_v1`; both
  persist the same evidence tuple and exact revision.
- Every process presents that exact `GIT_SHA`, both capability interlocks true,
  verified TLS, and `maraithon_runtime`—never an operator credential.
- Exact migration, catalog fingerprint, function/trigger/constraint/index,
  canonical role/membership, and ACL proofs remain valid.
- The coordination session publishes node readiness last and revokes it first.
  Its PostgreSQL-clock node lease, incarnation, activation epoch, and revision
  renew without gaps.
- All 64 partitions have only current-epoch database owners and monotonically
  fenced ownership epochs; leader/assignment/rebalance transitions converge
  without stale owners.
- BootGate opens only after the session is ready, wake reconciliation completes,
  desired Agents take the exact preclaim path, and readiness is rechecked.
- New Agent leases, Directive/Effect claims, task assignments, provider entry,
  terminal outcomes, fair-job tenant quota/token/service sequence, and dispatch
  acknowledgements all carry current database authority.
- No termination, outcome-ambiguous, provider-boundary, stuck-work, proof,
  retention, erasure, or ingress-order alert is unexplained.
- Recurring schedules are repaired as current claim-fenced rows and Telegram
  resumes from the last committed per-bot head.

Restore ingress one source at a time. Verify its committed receipt/dedupe head
and bounded backlog before enabling the next. Keep the old compute identities
destroyed; never use them as rollback capacity.

## Physical-termination incident path (not a cutover shortcut)

Do not use incident attestations to manufacture the zero drain required above.
Use them only when independent infrastructure evidence proves that the exact
stored physical incarnation cannot still execute; an absent Machine, expired
lease, timeout, RPC failure, `:not_found`, or empty Registry is not that proof.

For an Effect task, obtain the complete stored claim/physical identity and use
the incident role:

```bash
MIX_ENV=prod mix maraithon.effects.attest_terminated \
  --effect-id EFFECT_UUID \
  --claim-token CLAIM_UUID \
  --owner-node OWNER_NODE \
  --supervisor-id SUPERVISOR_UUID \
  --task-id TASK_UUID \
  --evidence-id EXTERNAL_EVIDENCE_REFERENCE \
  --attested-by INCIDENT_OPERATOR \
  --confirm PHYSICAL_TASK_TERMINATED
```

This proves only physical task destruction. It never claims a provider outcome;
reconciliation preserves `provider_outcome_ambiguous` after durable provider
entry and does not replay the Effect.

For an Agent whose original exact `AgentWatcher` monitor proof is permanently
unavailable, the external incident system must sign the canonical
`maraithon-agent-termination-v1` payload. That payload includes the stored
activation epoch, node incarnation, partition ID/epoch, Agent ID, lease token,
evidence ID/digest, and operator. The app holds only the Ed25519 public key:

```bash
MIX_ENV=prod mix maraithon.agents.attest_terminated \
  --incident-id INCIDENT_UUID \
  --evidence-id EXTERNAL_EVIDENCE_REFERENCE \
  --evidence-digest-hex EVIDENCE_SHA256 \
  --signature-base64 DETACHED_ED25519_SIGNATURE \
  --proved-by INCIDENT_OPERATOR
```

The incident role writes append-only proof and cannot delete the lease. A
runtime-role reconciliation pass rechecks expiry and the complete identity,
consumes the proof, records the restart guard, and removes only the matching
lease. Keep raw evidence and signatures in the restricted incident system, not
the repository or broad command logs.

## Abort and fix-forward boundaries

Before pre-attestation, an unsafe precondition may abort back to the same
feature-dark revision after obtaining fresh fleet evidence. Pre-attestation is
immutable evidence commitment; neither it nor either later promotion may be
rewritten.

After Effect promotion, the only safe states are: fleet absent while repairing,
or the exact activated revision admitted by both protocols. Coordination
promotion and final boot failures use the same evidence/revision for retry.
Configuration, CA, role, catalog, or operator-path faults are repaired forward
without opening BootGate.

If the activated code revision itself is defective, keep the fleet fenced and
introduce a separately reviewed one-way protocol/schema change that explicitly
preserves or advances all Effect, coordination, evidence, task, and revision
fences before any replacement revision starts. Never edit the stored revision,
downgrade a mode, restore a pre-activation snapshot over production, or deploy a
legacy/unknown image. Preserve content-free evidence and follow the incident
plan.

## Related guides

- [Durable resident Agent runtime](architecture/durable-agent-runtime.md)
- [Durable payload lifecycle](operations/durable-payload-lifecycle.md)
- [Privacy retention and erasure](operations/privacy-retention-erasure.md)
- [Database TLS, backup, and restore](operations/database-tls-backup-restore.md)
