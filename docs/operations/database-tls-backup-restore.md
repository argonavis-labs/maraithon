# Database TLS, backup, and restore

This runbook defines the PostgreSQL role, connection, migration, forward-repair,
backup, PITR, and restore boundaries for the durable runtime. It is an operator
procedure, not evidence that a revision was deployed, a migration was applied,
or a protocol was activated. Keep database URLs, passwords, Fly tokens, key
material, backup manifests, and provider credentials outside the repository and
command output.

## Canonical PostgreSQL roles

Provision these exact six roles in the database control plane before applying
the runtime-coordination migration. The database readiness proof rejects a
missing role, extra membership among the canonical roles, or any canonical
role with superuser, `CREATEROLE`, `CREATEDB`, replication, or `BYPASSRLS`.

| Role | Login | Purpose |
| --- | --- | --- |
| `maraithon_object_owner` | no | Owns `public` and the reviewed tables, functions, triggers, constraints, and indexes. It is never an application credential. |
| `maraithon_migrator` | yes | The sole member of `maraithon_object_owner`; applies reviewed DDL and finalizes the partition backfill. |
| `maraithon_runtime` | yes | Ordinary application DML and runtime locks. It cannot own objects, activate a protocol, manufacture incident evidence, verify payloads, or perform DDL. |
| `maraithon_payload_verifier` | yes | Reads registered payload material and writes only content-free verification/failure proofs. |
| `maraithon_activation_operator` | yes | Pre-attests the stopped fleet, performs evidence-bound payload contraction, and makes the two one-way protocol transitions. |
| `maraithon_incident_operator` | yes | Records reviewed physical-termination and key-lifecycle evidence and performs bounded key rotation. It cannot delete Agent leases or own protocol objects. |

The only canonical membership is `maraithon_migrator` in
`maraithon_object_owner`. Do not collapse roles into a database owner, grant one
canonical role to another, or reuse the runtime password. Provisioning belongs
in a separately controlled database bootstrap. Only a reviewed migration or
release process may receive the migrator credential; ordinary runtime work must
not use it.

### Fly Managed Postgres staging compatibility

Fly Managed Postgres authenticates named users but exposes fixed provider roles
such as `schema_admin` to PostgreSQL and does not allow customers to create the
six canonical roles. On a `*.flympg.net` migration connection, the additive
migrations map their DDL authority to `schema_admin` so the reviewed revision can
be staged in production. `runtime_coordination_roles_ready()` remains hard-false
in this mode: Effect and runtime coordination activation, operator promotion,
and claims of separated-role readiness are forbidden. Moving either protocol
out of its feature-dark legacy state still requires a database platform that can
provision the canonical topology above.

## Canonical connection variables

Each URL must identify the exact username in its URL userinfo:

| Environment variable | Required username | Consumer |
| --- | --- | --- |
| `DATABASE_URL` | `maraithon_runtime` | Pooled application and ordinary runtime storage operations |
| `DIRECT_DATABASE_URL` | `maraithon_migrator` | Direct release-command migration transport only |
| `MARAITHON_MIGRATOR_DATABASE_URL` | `maraithon_migrator` | Storage-only DDL, Snapshot migration, and `maraithon.coordination.backfill` |
| `DURABLE_PAYLOAD_VERIFIER_DATABASE_URL` | `maraithon_payload_verifier` | All-source payload verifier |
| `MARAITHON_ACTIVATION_DATABASE_URL` | `maraithon_activation_operator` | Cutover attestation, contraction, and activation |
| `MARAITHON_INCIDENT_DATABASE_URL` | `maraithon_incident_operator` | Physical task/Agent termination evidence only |
| `VAULT_ROTATION_DATABASE_URL` | `maraithon_incident_operator` | Vault re-encryption, payload-binding rotation, and backup-aware key retirement |

`VAULT_ROTATION_DATABASE_URL` is a separately named binding to the incident
role, not a seventh role. The three lifecycle CLIs—
`maraithon.vault.reencrypt`, `maraithon.payload_bindings`, and
`maraithon.key_retirement`—all require it. They must not fall back to
`MARAITHON_INCIDENT_DATABASE_URL`; that name is reserved for termination
commands. Operator tasks load production configuration, select their dedicated
URL, verify the expected username is distinct from `DATABASE_URL`, and rebuild
transport options for that URL.

`DIRECT_DATABASE_URL` describes an endpoint, not authority. If a provider
requires a direct rather than pooled endpoint, its URL must still use the role
for the operation. In particular, a migration/release process promotes the
direct endpoint as `maraithon_migrator`; the ordinary application Repo must
still connect only as `maraithon_runtime`. There is no canonical
`MARAITHON_RUNTIME_DATABASE_URL`—the runtime variable is `DATABASE_URL`.

## Verified TLS for every URL

Production policy is `DATABASE_TLS_MODE=verify_peer` for the runtime and every
operator URL.

- The certificate chain and URL hostname are both verified.
- Server Name Indication is derived independently from each URL. Never reuse
  the runtime host's TLS options for an operator host.
- Use the operating-system CA trust store or set
  `DATABASE_TLS_CA_CERT_PATH` to an absolute readable CA bundle.
- A URL query cannot weaken policy. If it contains `sslmode`, it must be
  `verify-full`; if it contains `ssl`, it must be `true`.
- Keep DNS names in URLs aligned with certificate identities. Do not replace a
  hostname with a raw address to make verification pass.
- Treat CA rotation like credential rotation: stage trust, verify every role
  and endpoint, switch, and only then remove obsolete trust.

A connection failure is not permission to disable verification. Do not put an
unverified override procedure in the normal runbook or copy runtime socket/SNI
options into a storage-only task.

## Pooling and connection budgets

Use the pooled `DATABASE_URL` for ordinary traffic. With transaction-pooled
PgBouncer, set `DATABASE_POOL_MODE=transaction`; Postgrex then uses unnamed
prepared statements. Use a verified direct endpoint for DDL, catalog
inspection, backup control-plane work, and restore drills when required.

Budget runtime and operator pools together. A storage-only task is bounded but
still consumes connections. Do not start multiple contraction, verifier,
migration, rotation, or retention batches merely because each individual pool
fits its default. Cutover pre-attestation, contraction, and both activations are
strictly serialized; their shared authority paths acquire the canonical runtime
protocol then Effect protocol lock order even though Effect is the first mode
promoted.

## Migration and partition preparation

Before a production migration:

1. confirm a healthy backup and continuous WAL/PITR window;
2. verify the six-role topology, exact grants, database name, TLS hostname, and
   artifact revision without printing URLs;
3. confirm the migration is expansion-safe for the currently running revision;
4. run the reviewed artifact with only the migrator credential;
5. run the migration-specific content-free backfill/readiness check;
6. remove the migrator URL from that process and return application work to
   `DATABASE_URL`.

A source-artifact invocation scopes the credential to one process:

```bash
DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
  MIX_ENV=prod mix ecto.migrate

MIX_ENV=prod mix maraithon.coordination.backfill --batch-size 100
```

The coordination task itself requires
`MARAITHON_MIGRATOR_DATABASE_URL`, runs bounded `SKIP LOCKED` batches for
`background_jobs` and `scheduled_jobs`, proves no null tenant/partition
assignments remain, and finalizes the prepared constraints/catalog. It never
starts the application or runtime workers.

Snapshot migration is deliberately different: keep `DATABASE_URL` bound to
`maraithon_runtime` and provide `MARAITHON_MIGRATOR_DATABASE_URL` separately.
`maraithon.snapshots.migrate` selects and revalidates the latter itself; do not
promote or override `DATABASE_URL` for this task:

```bash
MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
MIX_ENV=prod mix maraithon.snapshots.migrate --batch-size 25 --max-batches 100
MIX_ENV=prod mix maraithon.snapshots.migrate --preflight
MIX_ENV=prod mix maraithon.snapshots.migrate --finalize
```

The initial privacy-retention constraint finalizer still uses a separately
reviewed process-scoped migrator Repo as documented in the
[privacy guide](privacy-retention-erasure.md). Ongoing snapshot writes,
retention cycles, and privacy requests use the runtime role.

### Forward-only repair for recorded expansion migrations

A database that already recorded `20260810140004`, `20260810140005`, or
`20260810140007` before the retry-safe definitions were complete must be
repaired only by the later migration
`20260811000420_repair_durable_runtime_authority.exs`. Run the normal reviewed
artifact migration command; do not invoke a migration module by hand:

```bash
DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
  MIX_ENV=prod mix ecto.migrate
```

`000420` is forward-only. Before it runs any repair, it requires runtime `dark`
and Effect `legacy`, takes the session advisory lock `(20260811, 420)`, reads all
three source files, and validates all three pinned SHA-256 hashes before it
invokes any definition:

- `140004`: `2c57f6a55466e3857bd24b7c5329ca7e88dd036276c871728e9da5a4909e6f8d`
- `140005`: `d7ef75cd9d056782eca274a7fda2d33c1de9bca8d457e0d4c8d02182f76c3102`
- `140007`: `05e34d1a54f3a435e172913b7cb93f615fd6bc2e42c6f5e56a227d1273afec99`

Only after all three pass does it rerun their retry-safe `up/0` definitions. It
then lets Ecto record `20260811000420` normally.

Never delete or edit a `schema_migrations` row, never manually load/apply one of
the `140004`/`140005`/`140007` modules, and never copy SQL fragments out of the
migration. `scripts/verify_durable_runtime_forward_repair.sh` is a destructive
disposable-database verifier only: every database and credential it provisions
is verification-only and must be destroyed. It must never point at production
or a retained restore. If the pair is not dark/legacy or any source hash differs,
stop and review a new forward migration rather than bypassing `000420`.

A same-name index, trigger, constraint, function, or role is not sufficient.
Activation and ongoing readiness compare recorded migration versions, exact
catalog counts, role/ACL proofs, and manifest fingerprints. Do not repair a
failed proof by editing `schema_migrations`, manifests, or catalog objects by
hand. The exact-runtime transition additionally requires the stopped-fleet
[cutover runbook](../exact-agent-runtime-cutover.md); an ordinary migration may
never activate either protocol.

## Local physical-proof database boundary

Catalog readiness must include the hardened local-proof columns and triggers.
`agent_runtime_leases.termination_capability_digest` is nullable only for legacy
expansion rows or explicitly watcherless, external-proof-only claims; NULL never
authorizes local proof. Every AgentSupervisor local start requires a
watcher-owned immutable non-null 32-byte SHA-256 digest. Every
`runtime_task_assignments.termination_capability_digest` is immutable, non-null,
and exactly 32 bytes.

The corresponding AgentWatcher or TaskGuardian generates the unguessable
preimage and keeps it only in private ETS. AgentWatcher additionally binds an
unadopted preparation to its exact controller PID and bounds it with a short TTL
plus tighter preparation/per-controller caps. Its hard total limit counts
preparation, adopted-monitor, and pending-DOWN identities together; phase
transfers preserve the charge, live or pending authority is never evicted, and
only discard or durable disposition frees capacity. Controller loss or expiry
scrubs unadopted preparation only and is not Agent DOWN. After VM-authenticated monitor
retirement, its one-shot local persistence transaction Base64-encodes that
preimage into a transaction-local GUC. PostgreSQL decodes and hashes it against
the exact lease/assignment row. Secret-bearing GUC statements disable both
Ecto logging and query telemetry and return only a boolean, never the GUC value.
In the same proof transaction, the runtime resets
`log_parameter_max_length_on_error` to `0` and fails closed unless both effective
parameter-length settings are `0` before it sends the preimage. The PostgreSQL
service/bootstrap must preconfigure the superuser-only
`log_parameter_max_length = 0` and retain
`log_parameter_max_length_on_error = 0`; verify both settings on every runtime
and operator endpoint before exact activation so bind values cannot enter
server statement or error logs.

Public API/state, RPC arguments, access/proof terms, logs, and database rows
never expose the preimage. A role plus an arbitrary GUC, raw SQL, direct
settlement, fabricated mailbox tuple, expiry/restart/absence, or `:not_found`
is not physical proof.

Task `never_activated` is a separate capability-backed transition limited to a
`reserved`, provider-`not_entered`, never-ready assignment. An exact claimed
Effect may become `cancelling/requested` while the assignment stays reserved
only under matching ready-or-draining owner, partition, and node authority; the
transition is intent, not proof. Guardian then advances the assignment to
`termination_proven`, after which ordinary reconciliation may settle it. It is
not DOWN, and raw settlement is rejected. External physical-destruction evidence
uses only `MARAITHON_INCIDENT_DATABASE_URL`; it cannot synthesize either local
path.
See the [architecture proof
contract](../architecture/durable-agent-runtime.md#physical-termination-proof).

## Backup and PITR policy

Durable Agents are not production-ready without all of the following:

- automated encrypted physical backups in a separate failure domain;
- continuous WAL archiving with monitored gaps and an auditable oldest
  recoverable point;
- point-in-time recovery with measured RPO and RTO;
- an auditable catalog for retention, deletion, and legal holds;
- scheduled isolated restore drills on the same PostgreSQL major version and
  required extensions.

Alert on failed or stale backups, WAL gaps/lag, a shrinking PITR window,
capacity exhaustion, replication failure, and a restore drill older than
policy. A successful upload is not a restore proof.

Database backups must not be the only location of the keys needed to read them.
Vault and binding previous keys remain in the approved secret manager for every
retained recovery point that can contain their tags, with independent recovery
and access audit.

## Fly Managed Postgres backup boundary

Use a short-lived Fly token created for the maintenance window and restricted
to the required organization, Managed Postgres cluster, and backup/list/restore
actions. Inject it only as `FLY_API_TOKEN`; never pass it with
`--access-token`, persist it in the repo, reuse the active `flyctl` login, or
reuse an app-wide deploy token. Revoke it as soon as the evidence is captured.

Pin production application operations with the canonical
`MARAITHON_FLY_APP`. Pin database operations with an explicitly reviewed
cluster ID; never infer the cluster from an active account or similarly named
app:

```bash
: "${FLY_API_TOKEN:?short-lived scoped token required}"
: "${MARAITHON_FLY_APP:?pinned production app required}"
: "${MPG_CLUSTER_ID:?reviewed production MPG cluster id required}"

flyctl mpg backup create "$MPG_CLUSTER_ID" --type full
flyctl mpg backup list "$MPG_CLUSTER_ID" --all --json
```

Keep the JSON and provider receipt in the restricted external evidence system;
do not paste them into a public log or repository. Record the selected backup
ID, creation/completion time, source cluster, provider status, and a SHA-256
digest. Obtain the WAL and PITR catalogs and oldest recoverable points from the
provider control plane as well—the backup list alone does not prove continuous
recovery.

All app-side Fly commands, including status, logs, Machines, deploy, and SSH,
must use `FLY_API_TOKEN` from the scoped operator environment and explicitly
pass `--app "$MARAITHON_FLY_APP"`. Prefer `MARAITHON_FLY_APP`; do not rely on
legacy `FLY_APP` or the active `flyctl` account. Ordinary deployments use
`make deploy`; the one-time zero-fleet activation uses the explicitly manual
path in the cutover runbook.

## Isolated restore drill

Never restore over production. `flyctl mpg restore` restores the selected
backup into a separate Managed Postgres cluster. Keep it unattached to the
production app and place every application, connector, webhook, email, push,
and provider path in an egress-disabled drill network.

```bash
: "${BACKUP_ID:?reviewed backup id required}"
flyctl mpg restore "$MPG_CLUSTER_ID" --backup-id "$BACKUP_ID"
```

Record the returned restore cluster ID without attaching it. For each drill:

1. record the intended backup and target recovery point;
2. restore the base backup and, where applicable, replay WAL through the target;
3. record the actual recovered-through time;
4. verify schema migration records, required extensions, canonical role/ACL
   topology, protocol manifests, catalog fingerprints, and content-free table
   and proof counts;
5. verify every required Vault and binding **tag** is available without logging
   key material or decrypted content;
6. prove all app/provider egress remained disabled;
7. digest the backup, WAL, PITR, and restore reports with their capture and
   completion times;
8. destroy the isolated cluster and drill credentials under policy.

If cleanup requires a permission outside the backup/restore token, obtain a
second short-lived cleanup token rather than broadening or retaining the first.
Raw manifests and logs remain external. PostgreSQL key-retirement evidence
stores only bounded references, 32-byte digests, actors, and PostgreSQL-clock
attestation times.

## Backup-aware key retirement

Removing an old Vault or binding read key is safe only after live storage and
every recoverable historical path have moved past it. All lifecycle commands
use `VAULT_ROTATION_DATABASE_URL`. The mandatory order is:

1. run confirmed `maraithon.key_retirement prove-zero`; while holding every
   fixed source lock it persists the PostgreSQL-clock zero proof and advances
   the durable write fence for that `{kind, tag}`;
2. **after** that proof, create a fresh full backup and capture backup, WAL, and
   PITR catalogs whose oldest recoverable points are strictly newer;
3. complete an isolated restore recovered through a point strictly newer than
   the proof and persist confirmed `attest-backup` evidence with an expiry;
4. run `maraithon.key_retirement preflight` for a fresh locked recount. This is
   advisory and must report `external_key_removal_authorized: false`;
5. run `maraithon.key_retirement authorize --confirm` with the identical proof,
   backup evidence, and activation tuple. It must persist
   `retired_durable_payload_keys` and report
   `external_key_removal_authorized: true`;
6. only after that committed report remove that domain's previous read key from
   the external secret manager/keyring.

The write fence created in step 1 is irreversible even if later evidence fails
or expires; restore the old tag only as a read key while repairing the
procedure, never as a writer. An old proof row, cached count, successful
preflight, expired attestation, pre-proof backup, or backup without a successful
restore is not external-removal authority. See [Durable payload
lifecycle](durable-payload-lifecycle.md#backup-aware-key-retirement) for the
executable examples and evidence tuple.

## Restore or database incident

- Fence application/provider egress before opening a restored database.
- Keep both exact runtime capability interlocks closed until protocol and
  catalog readiness have been proven on the intended production database.
- Reapply post-recovery erasure fences and reconcile content-free receipts
  before any restored subject data can return to service.
- Never downgrade an activated protocol or edit its revision/evidence row.
  Restore the required catalog/role/key prerequisites or execute a separately
  reviewed forward protocol migration.
- Record only content-free incident and recovery evidence. Do not include URLs,
  passwords, tokens, signatures, payloads, or key material.

## Related guides

- [Durable runtime architecture](../architecture/durable-agent-runtime.md)
- [Exact production cutover](../exact-agent-runtime-cutover.md)
- [Durable payload lifecycle and key retirement](durable-payload-lifecycle.md)
- [Privacy retention, erasure, and cutover deferral](privacy-retention-erasure.md)
