# Exact Agent runtime production cutover

This runbook specifies the one-time transition from Effect protocol `legacy`
and runtime coordination `dark` to Effect `generation_fenced_v1` and
coordination `partition_fenced_v1`. It is a procedure, not evidence that this
revision has been deployed, pre-attested, or activated.

It is deliberately **feature-dark, nonrolling, stopped-fleet, and
revision-bound**. Both database promotions are one-way. They are not feature
flags and cannot be rolled back. After the first promotion, every failure is
fix-forward while application execution remains closed.

## Invariants

- `EXACT_AGENT_RUNTIME_ENABLED` and `MULTINODE_COORDINATION_ENABLED` are false
  on every running process during preparation. They are capability interlocks,
  not activation authority or fleet-absence evidence.
- Do not begin this runbook until review confirms the capability-digest
  hardening is present: the Agent digest is nullable only for legacy expansion
  rows or explicitly watcherless external-proof-only claims, which cannot
  authorize local proof; every AgentSupervisor local start requires a
  watcher-owned immutable non-null 32-byte digest; every task assignment has an
  immutable non-null 32-byte digest; and stable AgentWatcher/TaskGuardian
  processes VM-authenticate monitor retirement and keep unguessable preimages
  only in private ETS. AgentWatcher preparations are caller-bound and governed
  by short TTL plus tighter preparation/per-controller limits. A separate hard
  limit counts preparation, adopted-monitor, and pending-DOWN identities
  together; transfers preserve the charge, live/pending authority is never
  evicted, and only discard or durable disposition frees it. Controller loss
  scrubs only unadopted preparation. A post-COMMIT/pre-monitor controller loss,
  TTL expiry, or start/handoff failure
  has no local proof path: a non-null digest alone is not live local authority,
  and recovery requires a durable incident plus authenticated
  external-destruction proof. Their one-shot local persistence
  transaction uses a Base64 GUC
  which PostgreSQL decodes and hashes against the exact row. No preimage crosses
  a public API/state boundary, RPC, access/proof term, or log; role plus an
  arbitrary GUC, public call, raw SQL, or fabricated mailbox tuple is not proof.
- The operations are strictly nonconcurrent. Commit the stopped-fleet
  pre-attestation; activate Effect first while `Maraithon.Runtime.BootGate`
  remains closed and no application fleet exists; then activate coordination
  with no process started between them. Every shared database path nevertheless
  takes protocol locks in canonical runtime-then-Effect order.
- The stopped-fleet evidence ID, SHA-256 digest, operator, and exact revision are
  identical for pre-attestation and both promotions. The digest is computed over
  the exact immutable canonical evidence bytes. Hex is CLI transport only; the
  tasks decode 64 hex characters and PostgreSQL stores/compares 32 raw bytes.
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
| `DATABASE_URL` | `maraithon_runtime` | pooled ordinary application only |
| `DIRECT_DATABASE_URL` | `maraithon_migrator` | direct release-migration transport only; never a runtime fallback |
| `MARAITHON_MIGRATOR_DATABASE_URL` | `maraithon_migrator` | storage-only migrations, Snapshot migration, and partition finalization |
| `DURABLE_PAYLOAD_VERIFIER_DATABASE_URL` | `maraithon_payload_verifier` | all-source proof writer |
| `MARAITHON_ACTIVATION_DATABASE_URL` | `maraithon_activation_operator` | stopped-fleet attestation, contraction, promotions |
| `MARAITHON_INCIDENT_DATABASE_URL` | `maraithon_incident_operator` | external Agent/Task physical-termination evidence only |
| `VAULT_ROTATION_DATABASE_URL` | `maraithon_incident_operator` | Vault re-encryption, payload-binding rotation, and key retirement; not a termination fallback |

The canonical object owner is the non-login `maraithon_object_owner`; only
`maraithon_migrator` is its member. Provision the six-role topology before
migration and do not share credentials. See [Database TLS, backup, and
restore](operations/database-tls-backup-restore.md). Fly Managed Postgres may
stage the additive schema through its documented `schema_admin` compatibility
lane, but its role-readiness proof remains false and this cutover must not
advance there.

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

Freeze one immutable canonical evidence artifact and hash its bytes once:

```bash
: "${CANONICAL_EVIDENCE_FILE:?immutable content-free evidence artifact}"
EVIDENCE_DIGEST="$(openssl dgst -sha256 -binary "$CANONICAL_EVIDENCE_FILE" | \
  od -An -tx1 | tr -d ' \n')"
case "$EVIDENCE_DIGEST" in
  (*[!0-9a-f]*|'') echo "invalid evidence digest" >&2; exit 1 ;;
esac
[ "${#EVIDENCE_DIGEST}" -eq 64 ] || exit 1
export EVIDENCE_DIGEST
```

Do not hash the printed hexadecimal, Base64, a JSON pretty-print, or another
serialization. Store the exact artifact immutably; every CLI receives the same
64-hex transport and decodes it to the canonical raw 32-byte digest.

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

   If `140004`, `140005`, or `140007` was already recorded from an incomplete
   expansion, this same normal command—and only this command—must apply forward
   repair `20260811000420_repair_durable_runtime_authority.exs`. `000420`
   requires runtime `dark` plus Effect `legacy`, holds session advisory lock
   `(20260811, 420)`, validates all three source hashes before doing any repair,
   and then reruns their retry-safe definitions:

   - `140004`: `2c57f6a55466e3857bd24b7c5329ca7e88dd036276c871728e9da5a4909e6f8d`
   - `140005`: `d7ef75cd9d056782eca274a7fda2d33c1de9bca8d457e0d4c8d02182f76c3102`
   - `140007`: `05e34d1a54f3a435e172913b7cb93f615fd6bc2e42c6f5e56a227d1273afec99`

   Never delete/edit `schema_migrations`, manually invoke a migration module,
   or copy its SQL. The forward-repair verifier uses disposable
   verification-only credentials and a throwaway database; it is never a
   production repair command. See the [database forward-repair
   rule](operations/database-tls-backup-restore.md#forward-only-repair-for-recorded-expansion-migrations).

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
   claim/terminal transitions. Never cancel an active `privacy_erasure` job;
   preserve it for the reviewed deferral contraction. Never delete queue rows,
   null a claim, forge an acknowledgement, rewrite provider-boundary state, or
   bulk-mark work terminal.
4. Resolve a Task DOWN only when the private TaskGuardian VM-authenticates the
   original monitor retirement and consumes its one-shot capability. The
   unguessable preimage stays in Guardian-owned private ETS; only its local
   persistence transaction Base64-encodes it into a transaction GUC for
   PostgreSQL to hash against the assignment's immutable digest. It never
   crosses RPC or appears in public state/proof terms. `never_activated` is a
   different capability-backed proof and is permitted only for work still
   `reserved`, with provider boundary `not_entered`, and with
   readiness/activation never recorded. The exact Effect may first record
   `cancelling/requested` while that assignment remains reserved only under its
   matching ready-or-draining owner, partition, and node authority; this is
   intent, not proof. Guardian then moves it to `termination_proven`, ordinary
   reconciliation may move it to `settled`, and direct raw settlement is
   rejected. It is not a generic DOWN proof. Work that
   crossed provider entry without a durable result remains outcome-ambiguous;
   complete incident review before cutover.
5. Obtain explicit product-owner approval for future scheduled or queued work
   that cannot finish. Preserve its idempotent source reference before normal
   domain cancellation so it can be deliberately recreated after activation.

Before replacing this fleet, require zero processing Directives, running Agent
runs, requested steps, active Effects, active assistant work, nonterminal
prepared actions, dispatched schedules, provisional results, and physically
running background work. Stable future/recurring non-privacy job rows may remain pending at this point;
they are cancelled through a reviewed storage-only domain operation only after
the feature-dark fleet is zero, when they cannot repopulate. A
`privacy_erasure` job is preserved and deferred, never cancelled for this
cutover.

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
   and validate the format constraint. Keep `DATABASE_URL` bound to
   `maraithon_runtime` and set `MARAITHON_MIGRATOR_DATABASE_URL` separately; the
   Snapshot task selects and validates its dedicated migrator Repo itself. Do
   **not** invoke it with a shell override of `DATABASE_URL`:

   ```bash
   MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
   MIX_ENV=prod mix maraithon.snapshots.migrate --batch-size 25 --max-batches 100
   MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
   MIX_ENV=prod mix maraithon.snapshots.migrate --finalize
   ```

   Repeat bounded conversion when needed. Investigate every invalid/oversized or
   active-without-fresh-checkpoint result through policy; do not hide it by
   deleting a quarantine/failure row. Finalization success is a format/catalog
   proof, not Snapshot write authority; exact checkpoint authority is verified
   transactionally in Phase 10.

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

6. With every producer absent, cancel only approved non-privacy pending
   recurring and future scheduled rows through their reviewed storage-only
   domain APIs. Never cancel or delete a `privacy_erasure` job; Phase 6 encrypts
   it in place and records its deferral receipt. Tooling may start config, Ecto
   SQL, Vault, and Repo only; it must not boot `Maraithon.Application` or use raw
   SQL. Exact startup reconciliation recreates the stable recurring
   coordinators. If no reviewed storage-only path exists, the cutover is
   blocked.

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

This task owns the Event/RunStep/Snapshot legacy-copy rollout and the shared
non-deferrable-work safety proof. Require `in_flight.total: 0` across active
Directives, steps, Effects, runs, prepared actions, jobs/schedules, provisional
results, coordination ownership, and active/proven task assignments. Require
`deferred_run_steps: 0`. The `legacy_events`, `legacy_run_steps`, and
`legacy_snapshots` counts are the expected Phase 6 backlog and may be nonzero;
record their baseline. This preflight does not own the conversation families.

Also run the disjoint conversation registry preflight:

```bash
MIX_ENV=prod mix maraithon.conversation_privacy preflight
```

Its 13 family `eligible` counts are the expected legacy encryption backlog for
Phase 6 and may be nonzero, including an exact pending/unclaimed
`privacy_erasure` job. Require every family `deferred` and `blocked` count zero
and record the eligible baseline. This report does not define a second
`in_flight.total`; do not invent one by summing eligible privacy work.

If the payload report has non-deferrable work or either report has a genuine
deferred/blocked condition, use a reviewed storage-only domain operation while
exact authority is still available, or restart only the same feature-dark
revision to reconcile it. Never cancel a `privacy_erasure` job to make a count
zero. A restart invalidates this fleet-absence attempt: stop and inventory the
fleet again, obtain new external evidence, and rerun every preflight. Never
contract around active, ambiguous, or oversized work.

When non-deferrable, deferred, and blocked counts are zero, seal the external
evidence bundle. Hash the same canonical bytes frozen in the change record;
verify its actor, exact revision, time interval, and signatures, and keep the
bytes immutable. The activation task receives only the content-free ID and the
64-hex transport for the raw 32-byte SHA-256 digest, not the bundle or
signatures.

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

Run one contraction process at a time and wait for its transaction and result
to finish before starting the next. Every invocation uses the activation role,
takes the shared canonical runtime-then-Effect protocol locks, rechecks the
stopped-fleet evidence tuple and complete durable drain, and completes its
bounded mutation in one transaction. Its maximum allowed transaction timeout is
180 seconds. Start with small batches and repeat; never increase a timeout or
start parallel contractions to work around blocking.

For every row, the `ENABLE ALWAYS` guard supplies exact relation, operation,
`OLD`, and `NEW` JSON to the four-argument database authorization function. It
accepts only the registered UPDATE and fixed OLD→NEW contraction shape; the
zero-argument helper is a false compatibility tombstone. Activation role plus a
copied GUC, INSERT/DELETE, a mixed marker, or an unrelated column change fails.
See the [operator authority
matrix](operations/durable-payload-lifecycle.md#database-enforced-operator-mutation-authority).

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

Repeat until `legacy_events`, `legacy_run_steps`, and `legacy_snapshots` are
zero, `deferred_run_steps` is zero, and the non-deferrable
`in_flight.total` remains zero. This task does not report or own the 13
conversation families. Invalid or oversized content is a blocker to resolve,
never an excluded row or accepted disposition.

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
`deferred: 0`, and `blocked: 0`. An exact pending/unclaimed
`privacy_erasure` job is encrypted in place, not cancelled: the same
transaction keeps it pending and writes an append-only content-free
`privacy_erasure_job_deferral_v1` receipt bound to the active request and this
evidence tuple. Require the receipt registry checks clean. The receipt is the
only reviewed explanation for that job's exclusion from non-deferrable work;
it is not an erasure-completion receipt.

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
storage-only task cannot open it. Prove every contraction/verifier transaction
has exited and admit exactly one activation session. The database uses the same
canonical authority-lock regime; never race an activation with a contraction,
other activation, migration, or protocol verifier.

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

Wait for and independently read back the committed Phase 7 result. Without
starting any code, changing canonical evidence bytes, or allowing another
operator transaction, run:

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
- Every bounded wake/reconciliation page applies current activation, ready node
  incarnation/lease, ready partition owner/epoch/lease, and
  `runtime_partition_for('user:' || user_id)` predicates in SQL **before**
  `ORDER BY`/`LIMIT`. Verify this for due Directive and recovery Agent IDs,
  bootstrap/unowned Agents, expired claims, expired Agent/partition ownership,
  and recorded-generation reconciliation. There is no global BEAM-filtered page
  that another partition can consume.
- Exact checkpoint telemetry proves one outer transaction for ready lease fence,
  `checkpoint_created` Event, Snapshot insert, and newest-ten pruning. The
  Snapshot trigger rechecks exact lease token; Agent/User identity and state;
  activation/node/partition incarnation, readiness and PostgreSQL-clock expiry;
  current payload binding; clear restart guard; lifecycle/termination
  exclusions; and the precise insert/prune/delete operation.
- BootGate opens only after the session is ready, wake reconciliation completes,
  desired Agents take the exact preclaim path, and readiness is rechecked.
- The Agent digest is nullable only for legacy expansion rows or explicitly
  watcherless external-proof-only claims, which cannot take local proof. Every
  AgentSupervisor local start requires a watcher-owned immutable non-null
  32-byte digest. Task assignments have immutable non-null 32-byte digests. Only
  their stable AgentWatcher/TaskGuardian processes keep preimages in private ETS
  and own the one-shot VM witnesses. Agent preparation is bound to its controller
  PID and
  bounded by capacity and a short TTL. The final local transaction uses a
  Base64 GUC solely for PostgreSQL's exact-row hash check. APIs, public state,
  RPC, access/proof terms, and logs expose no preimage; arbitrary GUCs, direct
  calls/settlements, raw SQL, and fabricated mailbox tuples fail closed.
- Directive/Effect claims, provider entry, terminal outcomes, fair-job tenant
  quota/token/service sequence, and dispatch acknowledgements all carry current
  database authority.
- Preserved privacy-erasure jobs have clean deferral receipts and resume through
  the ordinary claim-fenced worker; none was cancelled to satisfy cutover.
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
Agent lease expiry only creates/refreshes the exact requested incident and
blocks a successor; it does not prove DOWN or remove the lease.

The ordinary local path is stronger than an API call. Reservation owners bind
the exact `Task.Supervisor` child PID before activation; the child waits behind
an owner-controlled gate, and only that bound PID may register or pass durable
readiness/provider-entry authorization. Supported API caller checks reject
ordinary local identity replay. Arbitrary malicious same-VM system-protocol
injection (including raw `:'$gen_call'`) and unrestricted `Process.exit/2` are
outside the SQL-role threat boundary and require host/BEAM code-execution
controls.

The stable original AgentWatcher or TaskGuardian asks the VM to retire its
original monitor and consumes a private one-shot witness. The unguessable preimage exists only in its
private ETS; its final local persistence transaction Base64-encodes it into a
transaction GUC so PostgreSQL can hash it against the exact row's immutable
32-byte digest. It never crosses RPC or appears in public state, API/access/proof
terms, or logs. A copied access map, fabricated mailbox tuple, public call, raw
SQL, or arbitrary GUC cannot settle the proof. An Agent lease with a NULL digest
has no local path and must converge only through separately authenticated
external destruction evidence. For tasks, `never_activated`
remains a distinct capability-backed outcome only for `reserved`,
provider-boundary `not_entered`, never-ready/never-activated work; it advances
`termination_proven` then `settled`, and direct raw settlement is rejected.

Only when that original local proof is permanently unavailable may the external
operator use `MARAITHON_INCIDENT_DATABASE_URL`. The Vault lifecycle binding is
not accepted for these commands. For an Effect task, obtain the complete stored
claim/physical identity and use
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

The incident transaction locks the runtime protocol, Effect protocol, exact
`cancelling/requested` Effect, and immutable Task assignment in canonical
order. For coordinated work it atomically records the immutable attestation and
an `external_destroyed` Task proof, promoting the exact assignment to
`termination_proven`. Transitional uncoordinated exact Effects receive only the
attestation; no Task row is invented. The command performs no ordinary Effect
settlement DML. Runtime reconciliation verifies the proof and settles later.
Lost-response replay accepts only the identical attestation and matching
historical Task proof.

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

Migration `000420` is only the pre-activation forward repair for the recorded
expansion migrations and refuses any pair other than dark/legacy. It is not a
post-activation incident escape hatch. Never delete a migration ledger row or
manually invoke an older migration to make it run.

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
