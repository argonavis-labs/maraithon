# Durable payload lifecycle

This is a guarded operator procedure for repository-staged capability; it is
not evidence that the revision is deployed, either protocol is active, or a key
has been retired.

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
locks and compares that tuple. The evidence digest is SHA-256 of the original
immutable canonical evidence bytes. Its 64 lowercase hex CLI form is decoded to
and compared as the same 32 raw bytes in PostgreSQL; never hash or persist the
ASCII hex as the evidence. A confirmation string or cached count cannot replace
the database protocol fence.

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

## Database-enforced operator mutation authority

Role membership and a session marker do not authorize a source mutation by
themselves. The `ENABLE ALWAYS`
`guard_durable_payload_operator_mutation_trigger` is installed `BEFORE INSERT OR
UPDATE OR DELETE` on all 18 durable sources and on the six additional
Vault-only relations (`connected_accounts`, `oauth_tokens`,
`local_browser_visits`, `local_calendar_events`, `local_files`, and
`memory_items`). For an operator role it passes four facts to
`public.durable_payload_operator_row_mutation_authorized(regclass, text, jsonb,
jsonb)`: exact `TG_RELID`, `TG_OP`, `to_jsonb(OLD)`, and `to_jsonb(NEW)`.
`public.durable_payload_operator_row_mutation_authorized()` is retained only as
a compatibility tombstone and always returns false.

The closed OLD→NEW authority is:

| Path | Protocol/role marker | Exact accepted operation and row delta |
| --- | --- | --- |
| Vault re-encryption | active exact pair; incident operator; only `VAULT_REENCRYPT_V1` | `UPDATE` one reviewed relation; only its registered ciphertext column(s) may differ, ciphertext NULL/non-NULL presence must be unchanged, and the relation's encryption-version field may stay unchanged or become `1` |
| Binding rotation | active exact pair; incident operator; only `BINDING_KEY_ROTATION_V1` | `UPDATE` one of the 18 source payload triples, or the separate `agent_work_results` authority triple; exactly one complete `{version, key_tag, MAC/digest}` triple changes and every other OLD/NEW field is identical |
| Stopped-fleet contraction | runtime `dark`, Effect `legacy`, matching pre-attested evidence; activation operator; only `STOPPED_FLEET_EVIDENCE_V1` | `UPDATE` one reviewed binding triple, or one exact legacy projection on `effects`, `agent_directives`, `events`, `agent_run_steps`, an eligible `background_jobs` privacy-erasure row, or `snapshots` to its specified ciphertext-only shape |

Every other relation, `INSERT`, `DELETE`, mixed marker, nullness change, partial
binding triple, lifecycle/status change, or unrelated OLD→NEW difference is
rejected. A source payload triple and the `agent_work_results` authority triple
can never change in the same authorized mutation. Direct SQL with the correct
role and a copied GUC therefore cannot widen the operation.
The dedicated source trigger also remains subject to each relation's lifecycle,
privacy, Snapshot, and execution-authority triggers.

## Vault ciphertext rotation

Production Vault rotation keeps normal `DATABASE_URL` runtime configuration,
then requires `VAULT_ROTATION_DATABASE_URL` with username
`maraithon_incident_operator`. The operator URL must be distinct from the
runtime credential and rebuild verified TLS for its own hostname. It never
falls back to `MARAITHON_INCIDENT_DATABASE_URL`; that binding is reserved for
physical-termination commands. See the
[database guide](database-tls-backup-restore.md#canonical-connection-variables).

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
`VAULT_ROTATION_DATABASE_URL` authenticated as
`maraithon_incident_operator`, the current and previous binding keys, and
independently verified TLS. Keep `DATABASE_URL` bound to the runtime role. The
first-party CLI starts only config, Ecto SQL, Vault, and Repo; it does not boot
`Maraithon.Application` or runtime workers.

Count the old binding tag globally:

```bash
MIX_ENV=prod mix maraithon.payload_bindings \
  --old-tag "$OLD_BINDING_TAG" --preflight
```

Rotate bounded batches with the immutable activation tuple:

```bash
MIX_ENV=prod mix maraithon.payload_bindings \
  --old-tag "$OLD_BINDING_TAG" \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" \
  --revision "$EXACT_REVISION" \
  --batch-size 25 --max-batches 20
```

The CLI may select only `DurablePayloadRegistry.binding_targets/0`. `--table`
and `--binding payload|authority` narrow a run to one reviewed target for
diagnosis; they never turn operator text into a SQL identifier and never prove
global zero. Run the unscoped preflight until the global old-tag count and every
closed failure are zero, then make the separate all-source verifier preflight
zero again. There is no arbitrary-table or raw-expression rotation path; do not
improvise one or invoke the module directly in production.

## Backup-aware key retirement

Live rotation does not remove an old tag from base backups, WAL, PITR, or an
isolated restore. Vault and binding retirement use the same closed protocol but
separate `kind`, tag, registry, zero proof, fence, and authorization row. Every
command below keeps `DATABASE_URL` as runtime and uses
`VAULT_ROTATION_DATABASE_URL`; `MARAITHON_INCIDENT_DATABASE_URL` is not a
key-lifecycle fallback.

Set content-free shell variables from the reviewed change record (never put key
material in them):

```bash
: "${KEY_KIND:?vault or binding}"
: "${OLD_KEY_TAG:?reviewed previous tag}"
: "${EVIDENCE_ID:?immutable activation evidence id}"
: "${EVIDENCE_DIGEST:?64 lowercase hex SHA-256}"
: "${ACTIVATED_BY:?immutable activation operator}"
: "${EXACT_REVISION:?immutable activated revision}"
```

### 1. Prove live zero and irreversibly fence the old tag

First make the matching global rotation preflight zero, then persist the
PostgreSQL-clock proof:

```bash
MIX_ENV=prod mix maraithon.key_retirement prove-zero --confirm \
  --kind "$KEY_KIND" \
  --old-tag "$OLD_KEY_TAG" \
  --evidence-id "$EVIDENCE_ID" \
  --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" \
  --revision "$EXACT_REVISION"
```

The transaction locks every fixed source, recounts the complete kind-specific
registry, refuses the current tag or an unavailable read key, and persists a
`key_retirement_zero_proofs` row. Its AFTER trigger also advances
`durable_payload_key_fence_state` for this exact `{kind, old_tag, proof_id}`.
Save the returned `proof_id` and `write_fenced_at`.

**That write fence is irreversible.** From this commit onward PostgreSQL
rejects any new or mutated source row carrying the fenced tag, including a
stale writer. Boot/catalog guards also reject a configured current write tag
that is fenced or retired, so a current writer cannot silently reintroduce it.
Failure or expiry in a later step does not undo the fence; keep the old key
configured only as a previous/read key while repairing. The zero proof does
**not** authorize removal from the external keyring.

### 2. Move every recovery horizon past the proof

Only after `write_fenced_at`, create a fresh full backup and retain its provider
receipt. Capture content-free SHA-256 digests and timestamps for:

- the backup catalog and its oldest recoverable point;
- the WAL catalog and its oldest recoverable point;
- the PITR catalog and its oldest recoverable point;
- a successful isolated restore-drill report and recovered-through time.

Every oldest/recovered-through point must be strictly later than the database
proof time. A new backup is insufficient while an older base backup or retained
WAL can still recover a pre-proof state. Raw manifests, WAL listings, restore
logs, and credentials remain in the external evidence system; PostgreSQL stores
only bounded references, digests, actors, and times.

### 3. Persist the post-proof recovery attestation

Use the original proof and exact activation tuple. All timestamp arguments are
UTC ISO 8601 values. Every `*-sha256` argument is 64 lowercase hex only as CLI
transport and is decoded to a canonical raw 32-byte database digest:

```bash
MIX_ENV=prod mix maraithon.key_retirement attest-backup --confirm \
  --kind "$KEY_KIND" --old-tag "$OLD_KEY_TAG" --proof-id "$PROOF_ID" \
  --evidence-id "$EVIDENCE_ID" --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" --revision "$EXACT_REVISION" \
  --backup-catalog-sha256 "$BACKUP_CATALOG_SHA256" \
  --backup-catalog-captured-at "$BACKUP_CATALOG_CAPTURED_AT" \
  --backup-oldest-recoverable-at "$BACKUP_OLDEST_RECOVERABLE_AT" \
  --wal-catalog-sha256 "$WAL_CATALOG_SHA256" \
  --wal-catalog-captured-at "$WAL_CATALOG_CAPTURED_AT" \
  --wal-oldest-recoverable-at "$WAL_OLDEST_RECOVERABLE_AT" \
  --pitr-catalog-sha256 "$PITR_CATALOG_SHA256" \
  --pitr-catalog-captured-at "$PITR_CATALOG_CAPTURED_AT" \
  --pitr-oldest-recoverable-at "$PITR_OLDEST_RECOVERABLE_AT" \
  --restore-drill-sha256 "$RESTORE_DRILL_SHA256" \
  --restore-drill-completed-at "$RESTORE_DRILL_COMPLETED_AT" \
  --restore-drill-recovered-through-at "$RESTORE_RECOVERED_THROUGH_AT" \
  --evidence-expires-at "$EVIDENCE_EXPIRES_AT"
```

The append-only evidence is accepted only when every recovery point is strictly
newer than the locked zero proof. Use the procedure in the
[database backup and restore guide](database-tls-backup-restore.md#isolated-restore-drill);
a successful upload without catalog and restore evidence is insufficient. The
current implementation keys this attestation by the immutable activation
`EVIDENCE_ID`, so use that same value as `BACKUP_EVIDENCE_ID` below.

### 4. Run the advisory retirement preflight

Immediately before authorization, retake every current source lock and recount:

```bash
BACKUP_EVIDENCE_ID="$EVIDENCE_ID"

MIX_ENV=prod mix maraithon.key_retirement preflight \
  --kind "$KEY_KIND" --old-tag "$OLD_KEY_TAG" --proof-id "$PROOF_ID" \
  --backup-evidence-id "$BACKUP_EVIDENCE_ID" \
  --evidence-id "$EVIDENCE_ID" --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" --revision "$EXACT_REVISION"
```

This is a fresh global recount, not a read of the old stored count. It also
requires an unchanged registry digest, the same activation tuple, strictly
post-proof recovery evidence, and an unexpired attestation. A clean report is
**advisory only** and deliberately says:

```json
{"external_key_removal_authorized": false}
```

Do not remove a key after this command.

### 5. Persist final external-removal authorization

With no intervening source/key/catalog change, run the confirmed operation with
the identical envelope:

```bash
MIX_ENV=prod mix maraithon.key_retirement authorize --confirm \
  --kind "$KEY_KIND" --old-tag "$OLD_KEY_TAG" --proof-id "$PROOF_ID" \
  --backup-evidence-id "$BACKUP_EVIDENCE_ID" \
  --evidence-id "$EVIDENCE_ID" --evidence-sha256 "$EVIDENCE_DIGEST" \
  --operator "$ACTIVATED_BY" --revision "$EXACT_REVISION"
```

This command repeats the locks, live-zero count, fence identity, source digest,
protocol/catalog authority, recovery ordering, and expiry checks. Only then does
it insert the append-only `retired_durable_payload_keys` row and finalize the
fence generation. Require the committed result to contain the expected kind,
tag, proof/evidence IDs, `authorized_at`, `fence_generation`, and exactly:

```json
{"external_key_removal_authorized": true}
```

An identical retry is idempotent; a different tuple conflicts. Neither the
preflight nor a manually inserted row/GUC can synthesize this authorization.

### 6. Remove only that domain's previous read key

Only after step 5 commits and reports `true` may the old entry be removed from
the corresponding `*_PREVIOUS_KEYS` variable in the external secret manager.
Apply the keyring change nonrollingly to the app and every operator host,
validate configured tags, rerun the domain-wide old-tag count, and retain the
evidence under security policy.

Do not remove a Vault key because binding rotation is complete, or vice versa.
Do not treat `maraithon.vault.reencrypt --preflight`,
`maraithon.payload_bindings --preflight`, a stored zero proof, a verifier row, a
successful batch, or the advisory retirement preflight as authorization.

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

See the [durable runtime architecture](../architecture/durable-agent-runtime.md),
[database TLS/backup/restore guide](database-tls-backup-restore.md),
[privacy retention and erasure guide](privacy-retention-erasure.md), and
[exact Agent runtime production cutover](../exact-agent-runtime-cutover.md) for
the activation evidence origin.
