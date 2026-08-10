# Durable payload lifecycle

Maraithon protects durable payloads with two independent key domains:

- **Vault keys** encrypt and authenticate stored bytes with tagged Cloak
  AES-GCM.
- **Binding keys** HMAC the typed table, row identity, scope, and ordered
  plaintext fields. A valid ciphertext therefore cannot be substituted into a
  different row, tenant, Agent, or field set.

Rotating one domain does not rotate the other. Do not combine their evidence,
old-tag counts, or retirement decisions.

## Closed inventories

`Maraithon.DurablePayloadRegistry` is the code-reviewed source of truth for
exactly 18 authenticated encrypted sources:

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
17. `snapshots` (the durable Snapshot source)
18. `agent_work_results`

The registry fixes each table, typed identity, scope, fields, bounds, purge
marker, and binding columns. Verification, retention, erasure, contraction,
and binding rotation share it. Operator input never becomes a SQL identifier.

`Maraithon.VaultCiphertextRegistry` contains every ciphertext column from those
18 sources plus the reviewed OAuth/connected-account and local-data encrypted
fields. It is the authority for Vault old-tag counts. Binding rotation has 19
fixed targets: one payload binding for each source plus the separate
`agent_work_results` authority binding. Verification/proof rows are audit
artifacts, not count authority.

## Keyring configuration

New Vault writes use:

- `CLOAK_CURRENT_KEY_TAG`
- `CLOAK_CURRENT_KEY`
- `CLOAK_PREVIOUS_KEYS` for bounded read-only predecessors

New contextual bindings use:

- `DURABLE_PAYLOAD_BINDING_CURRENT_TAG`
- `DURABLE_PAYLOAD_BINDING_CURRENT_KEY`
- `DURABLE_PAYLOAD_BINDING_PREVIOUS_KEYS`

Keys are canonical Base64 encodings of exactly 32 bytes. Tags are unique
reviewed identifiers of at most 64 bytes. Each previous-key variable is a JSON
array of at most eight objects with string `tag` and `key` members. Production
startup fails closed on a partial current pair, malformed or noncanonical
Base64, a wrong key length, a malformed tag, or a duplicate tag.

`CLOAK_KEY` with the fixed legacy tag `AES.GCM.V1` is rollout compatibility
only; do not use it for a new rotation. Keep key material in the approved
secret manager and out of the repository, database, evidence bundle, command
arguments, shell history, tickets, and logs. Reports may contain tags but never
keys or decrypted content.

## Shared rotation rules

Both mutation paths require Effect mode `generation_fenced_v1`, coordination
mode `partition_fenced_v1`, and the immutable cutover evidence tuple
`{evidence_id, evidence_digest, operator, exact_revision}`. Every transaction
locks and compares that tuple. A confirmation string or cached count cannot
replace the database protocol fence.

For one key domain at a time:

1. Generate a new 32-byte key and unique tag outside the application.
2. Stage the old key as a previous read key and the new key as current on the
   exact activated revision and every relevant operator host.
3. change the keyring nonrollingly so every writer agrees on the current tag;
   a mixed writer fleet can continuously recreate old-tag rows;
4. verify startup and current/configured **tags only**;
5. mutate finite locked batches and inspect content-free counts and closed
   failure classes;
6. rebuild all-source authenticated payload proofs after source mutation;
7. complete backup-aware retirement before removing the previous read key.

Removing the old key is always the final action. A rotation batch, stored proof,
or live count alone is never retirement authority.

## Vault ciphertext rotation

Production Vault rotation loads normal `DATABASE_URL` configuration, then
requires `VAULT_ROTATION_DATABASE_URL` with username
`maraithon_incident_operator`. The operator URL must be distinct from the
runtime credential and rebuild verified TLS for its own hostname. See the
[database guide](database-tls-backup-restore.md).

With the new current Vault key and the old read key configured, count the old
tag across the complete Vault registry:

```bash
MIX_ENV=prod mix maraithon.vault.reencrypt \
  --old-tag "$OLD_VAULT_TAG" --preflight
```

Rotate small locked batches:

```bash
MIX_ENV=prod mix maraithon.vault.reencrypt \
  --old-tag "$OLD_VAULT_TAG" --batch-size 25 --max-batches 20
```

The worker selects only fixed targets with `FOR UPDATE SKIP LOCKED`, verifies
the old tag, authenticates and decrypts the bounded value, encrypts with the
current tag, and compare-and-swaps the exact source value. `--target
TABLE.COLUMN` is for bounded diagnosis of a reviewed registry entry; it is not
a global-zero proof.

Repeat until the global report has `total: 0`, `oversized: 0`, and every durable
failure is deliberately resolved. Do not delete a failure row to make the
report green. Authentication failure, malformed tags, oversized ciphertext,
source change, or unavailable old key fails closed; there is no plaintext
fallback.

Vault re-encryption changes source ciphertext digests and invalidates relevant
payload proofs. Rebuild and check all 18 sources using the separate verifier
credential (`DURABLE_PAYLOAD_VERIFIER_DATABASE_URL`, username
`maraithon_payload_verifier`):

```bash
MIX_ENV=prod mix maraithon.payloads.verify \
  --batch-size 25 --max-batches 1000
MIX_ENV=prod mix maraithon.payloads.verify --preflight
```

The final preflight must report `failures: 0`. A single-table run is diagnostic;
only the global preflight proves the closed registry ready.

## Contextual binding-key rotation

Binding rotation changes only the binding version, key tag, and MAC. It first
verifies the persisted old MAC over the typed context and ordered plaintext,
then signs with the current binding key. It does **not** re-encrypt Vault
ciphertext or alter payload, projection, lifecycle, or execution-authority
fields.

Run the reviewed storage-only operator environment with
`MARAITHON_INCIDENT_DATABASE_URL` authenticated as
`maraithon_incident_operator`, the current and previous binding keys, and
independently verified TLS. The public operations are:

1. `Maraithon.DurablePayloadBindingRotation.preflight/1`
2. `Maraithon.DurablePayloadBindingRotation.rotate/2`
3. the all-source payload verifier shown above

`rotate/2` accepts bounded `limit`/`max_batches` options and the exact activation
evidence tuple. It may select only `DurablePayloadRegistry.binding_targets/0`.
Run until the global old-tag count and all closed failures are zero, then make
the verifier global preflight zero again.

There is no production CLI that accepts an arbitrary table or raw SQL
expression for binding rotation. Do not improvise one. An operator wrapper must
start only config, Ecto SQL, Vault, and Repo with the incident credential; it
must not boot `Maraithon.Application` or runtime workers.

## Backup-aware key retirement

Live rotation does not remove an old tag from base backups, WAL, PITR, or an
isolated restore. Vault and binding retirement therefore use the same
`Maraithon.KeyRetirement` protocol but separate `key_kind`, tag, registry, and
proof rows.

### 1. Persist an authoritative live-zero proof

Only after the domain-wide old-tag preflight is zero, call the matching wrapper
with the exact activation evidence:

- Vault: `Maraithon.VaultReencryption.prove_live_zero/2`
- Binding: `Maraithon.DurablePayloadBindingRotation.prove_live_zero/2`

The incident-role transaction locks every fixed source, recounts the registry,
and writes a PostgreSQL-clock proof ID and source-registry digest. It refuses
the current tag or a tag whose read key is unavailable. Save the content-free
proof ID in the restricted change record.

### 2. Move every recovery horizon past that proof

**After** the proof time, create a fresh full content-free backup and retain its
provider receipt. Capture content-free SHA-256 digests and timestamps for:

- the backup catalog and its oldest recoverable point;
- the WAL catalog and its oldest recoverable point;
- the PITR catalog and its oldest recoverable point;
- a successful isolated restore-drill report and recovered-through time.

Every oldest/recovered-through point must be strictly later than the database
proof time. A new backup is insufficient while an older base backup or retained
WAL can still recover a pre-proof state. Raw manifests, WAL listings, restore
logs, and credentials remain in the external evidence system; PostgreSQL stores
only bounded references, digests, actors, and times.

### 3. Attest the post-proof recovery evidence

Call the matching wrapper's `attest_backup_evidence/2` with the original proof
ID, exact activation tuple, the backup/WAL/PITR catalog digests and capture
times, each oldest recoverable point, the restore digest/completion and
recovered-through times, and an explicit evidence expiry.

The evidence is append-only and is accepted only if all recovery points are
strictly newer than the locked zero proof. Use the procedure in the [database
backup and restore guide](database-tls-backup-restore.md); a successful upload
without catalog and restore evidence is not sufficient.

### 4. Obtain a fresh authoritative live-zero recount

Immediately before key removal call:

- Vault: `Maraithon.VaultReencryption.retirement_preflight/2`
- Binding: `Maraithon.DurablePayloadBindingRotation.retirement_preflight/2`

Supply the original proof ID, the backup evidence ID, and the exact activation
tuple. This is the required fresh live-zero proof at retirement time: it locks
all current registry sources and recounts them again. It is not a read of the
old stored count and it does not replace the original temporal proof ID to
which the post-proof backup evidence is bound.

The preflight also requires the registry digest to remain unchanged and the
matching recovery evidence to be unexpired. Any nonzero row, new registry
target, evidence/revision/operator mismatch, pre-proof recovery point, missing
restore drill, or expired evidence fails closed. Fix the cause and repeat from
the appropriate earlier step.

### 5. Remove only that domain's previous key

Only after the fresh retirement preflight succeeds may the old entry be removed
from the corresponding `*_PREVIOUS_KEYS` variable. Apply the keyring change
nonrollingly to the app and every operator host, validate configured tags,
rerun the domain-wide old-tag preflight, and retain the evidence according to
security policy.

Do not remove a Vault key because binding rotation is complete, or vice versa.
Do not treat `maraithon.vault.reencrypt --preflight`, a stored zero-proof row,
a verification row, or a successful batch count by itself as authorization.
The current closed registry recount is authoritative.

## Failure handling

- Preserve authentication, oversized, source-changed, binding-mismatch, and
  registry-change evidence. Investigate the source; do not bypass validation.
- If an old read key is lost while live rows or recoverable backups still carry
  its tag, stop and invoke the security incident plan. A new key with the same
  tag cannot decrypt the data.
- If either database protocol or catalog/ACL readiness becomes blocked, stop
  mutation. Never hand-edit protocol singletons, manifests, proof rows,
  bindings, or failure rows.
- A key configuration failure after activation is a fix-forward incident. Keep
  the affected execution admission closed until every required read key and
  verified operator path is restored.

See [Privacy retention and erasure](privacy-retention-erasure.md) for content
deletion and [Exact Agent runtime production cutover](../exact-agent-runtime-cutover.md)
for the activation evidence origin.
