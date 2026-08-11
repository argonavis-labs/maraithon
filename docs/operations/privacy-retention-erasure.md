# Privacy retention and erasure

This is a guarded operator procedure, not an execution record or evidence that
the exact protocols are active in production.

Retention, erasure, Agent deletion, and logout are different operations:

- **Retention** removes sensitive content from eligible terminal/history rows
  after a policy window while keeping the minimum identity, dedupe, authority,
  and content-free audit facts needed for correctness.
- **Account erasure** publishes an irreversible user write fence, drains exact
  execution authority, revokes credentials, removes the fixed copy surface,
  proves it empty, and issues a content-free receipt.
- **Agent deletion** drains and deletes one Agent through its authenticated
  lifecycle API. It is not an account-erasure receipt for the owning user.
- **Logout** destroys only the current authentication session. It is not a
  retention request, provider revocation, Agent deletion, or erasure request.

Never represent logout as deletion. The browser logout route is
`DELETE /logout`; the mobile logout route is `DELETE /api/mobile/session`.

## Retention policy

The production defaults and accepted configuration ranges are:

| Data families | Default | Allowed range |
| --- | ---: | ---: |
| Effects, Directives, run steps, Agent runs, assistant runs/steps, prepared actions, background jobs, scheduled jobs, work results | 30 days | 7–365 days |
| Events, operator events, ingress receipts, Telegram conversation content | 90 days | 30–365 days |
| Snapshot quarantine reports | 30 days | 1–30 days |
| Completed content-free erasure request/receipt records after their own expiry | 365 days | 30–730 days |

The corresponding `PRIVACY_RETENTION_*_DAYS` variables are defined in
`config/runtime.exs`. Worker and alert bounds are:

- `PRIVACY_RETENTION_BATCH_SIZE`: default 100, range 1–500;
- `PRIVACY_RETENTION_PER_TENANT`: default 5, range 1–50;
- `PRIVACY_RETENTION_ALERT_GRACE_HOURS`: default 24, range 1–168;
- `PRIVACY_RETENTION_CRITICAL_GRACE_HOURS`: default 168, range 24–720.

Unknown settings, an out-of-range value, or a critical threshold below the
warning threshold fails the policy closed. A shorter window is a reviewed
policy change, not an incident-time deletion shortcut.

The closed encrypted-source registry is exhaustive but not every source is
age-expired the same way. Current Snapshots are pruned in the checkpoint
transaction to the newest ten per Agent. Snapshot quarantine reports use the
age window above. Current `user_memory_profiles` and
`operator_memory_summaries` are subject to erasure rather than an independent
history timer. Every other terminal/history source has a fixed retention
handler, including the installed Telegram conversation extension.

A completed erasure receipt carries its own application expiry. The retention
worker later removes the completed coordinator/receipt rows under the separate
bounded `PRIVACY_ERASURE_RECEIPT_DAYS` policy; an `expires_at` timestamp is not
permission for an unbounded delete.

## Retention authority and eligibility

All cutoffs and mutation timestamps come from PostgreSQL. The durable recurring
coordinator starts after a 20-second delay and runs every 15 minutes. Its stable
`background_jobs` row, claim token, next deadline, per-handler cursor, and
status are durable; a worker timer is only a wakeup hint.

Every privacy mutation follows the canonical database-lock prefix: protocol
authority first (runtime before Effect if both are needed), affected `users`
rows next in stable ID order, and only then reviewed source rows in their fixed
registry order. A write-fence trigger that sees different OLD and NEW subject
IDs locks both Users in stable order. No retention, request, contraction,
scrub, or erasure path may lock a source row and then reach backward for a User
or protocol row.

Each fixed handler:

1. takes its transaction-scoped advisory identity and canonical protocol/User
   lock prefix;
2. verifies the exact Effect protocol and installed extension state;
3. selects a finite tenant-fair batch with `FOR UPDATE SKIP LOCKED` only after
   authority has been established;
4. clears only reviewed content columns and binding metadata;
5. records the purge/scrub timestamp, advances its durable cursor, and measures
   the backlog in the same transaction.

No handler accepts an operator-supplied table, predicate, cutoff, or force
flag. Corrupt ciphertext cannot make otherwise eligible content immortal: the
worker selects reviewed identities and tombstones fixed columns without
loading/decrypting the payload. It still fails closed if authority or schema
proof is unavailable.

Eligibility is deliberately conservative:

- Effects require a terminal status, a versioned terminal envelope, terminal
  acknowledgement, and settled cancellation authority.
- Directives and work results require terminal acknowledgement, no ambiguity,
  and no active run lineage.
- run steps and Agent/assistant runs must be terminal and no longer active;
- prepared actions, jobs, schedules, and conversation work must be terminal and
  unclaimed;
- Telegram conversation content remains while an assistant run, outcome-unknown
  action, or linked nonterminal work still needs it;
- Event spend projections must already be complete before Event content is
  cleared.

Expiry removes ciphertext and compatibility plaintext/projections where
applicable. It preserves the identity, dedupe keys, terminal state, authority
lineage, acknowledgements, digests, and content-free timestamps that prevent
replay or fabricated completion.

## Operating retention

Ordinary expiry should run through the durable coordinator. The storage-only
operator task is appropriate for a bounded repair cycle or one fixed-lane
diagnosis. Ordinary preflight/expiry uses the normal runtime database role with
independently verified TLS; the initial constraint finalizer is separately
migrator-scoped below. The task starts Repo dependencies only:

```bash
MIX_ENV=prod mix maraithon.privacy_retention preflight
MIX_ENV=prod mix maraithon.privacy_retention run \
  --batch-size 100 --per-tenant 5
MIX_ENV=prod mix maraithon.privacy_retention handler effects \
  --batch-size 25 --per-tenant 5
```

During the initial additive privacy migration only, clean the content-free
legacy Snapshot report metadata and validate the prepared constraints after
preflight is clean:

```bash
DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
  MIX_ENV=prod mix maraithon.privacy_retention cleanup-legacy --batch-size 100
DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
  MIX_ENV=prod mix maraithon.privacy_retention preflight
DATABASE_URL="$MARAITHON_MIGRATOR_DATABASE_URL" \
  MIX_ENV=prod mix maraithon.privacy_retention finalize-constraints
```

Keep that credential promotion scoped to these one-time storage processes; do
not leave an operator shell or application Repo bound to the migrator URL.
Preflight must report `activation_ready: true`, zero legacy Snapshot payload
digests, zero quarantine orphans, and every recorded extension ready. Output is
limited to handler names, counts, cursors, closed status/error codes, and
PostgreSQL timestamps.

Monitor every `privacy_retention_statuses` row for stale
`last_succeeded_at`, increasing `consecutive_failures`, backlog age beyond its
warning/critical grace, unexpected intentional exceptions, and a required
extension becoming unavailable. A failed handler rolls its tombstones and
cursor back together. Fix the prerequisite and rerun a normal bounded cycle;
do not update cursors, status rows, or source content by hand.

These retention operations are not subject erasure. Do not use a handler or a
shortened retention setting as a substitute for an erasure request.

### Stopped-fleet cutover preflights are deliberately disjoint

Do not combine or reinterpret the two contraction reports:

- `maraithon.payload_privacy preflight` owns only legacy payload copies in
  `events`, `agent_run_steps`, and `snapshots` (plus its explicit
  non-deferrable-work safety proof). Require
  `legacy_events = legacy_run_steps = legacy_snapshots = 0`,
  `deferred_run_steps = 0`, and `in_flight.total = 0` after its contraction.
- `maraithon.conversation_privacy preflight` owns the 13-family conversation,
  prepared-action, run, work-result, job, schedule, response, and identity
  rollout. Require every family `eligible`, `deferred`, and `blocked` count to
  be zero after its contraction and require its registry/receipt checks clean.

`in_flight.total` means **non-deferrable** active/proven work. Its required zero
must never be restated as “cancel every privacy job.” An exact pending,
unclaimed `privacy_erasure` job belongs to the privacy protocol and must be
preserved; the contraction path moves its payload to ciphertext and atomically
records the content-free deferral receipt described below. See the
[cutover phases](../exact-agent-runtime-cutover.md#phase-6--contract-and-prove-all-durable-payloads).

## Requesting account erasure

Production account erasure begins only at an authenticated subject endpoint:

| Client | Request | Content-free status |
| --- | --- | --- |
| Browser session | `POST /api/account-erasure` (with the normal CSRF protection) | `GET /api/account-erasure` |
| Mobile session | `POST /api/mobile/account-erasure` | `GET /api/mobile/account-erasure` |

The request accepts an `Idempotency-Key` header (or the documented
`idempotency_key` body field). The controller derives the user ID from the
authenticated session; it never accepts an arbitrary user ID. The accepted
response contains the content-free request projection. Do not put session
cookies, bearer tokens, request bodies, subject identifiers, or provider
credentials in tickets, examples, shell history, or broad logs.

The write fence revokes session/device access immediately, so a client must
retain the accepted response and must not assume it can continue polling after
its session is destroyed. The status routes remain authenticated and are never
an unauthenticated request-ID oracle. Restricted privacy operations may observe
the same content-free projection through the approved internal monitoring
surface.

**Do not run standalone production erase or scrub Mix commands.** In
particular, do not use `maraithon.privacy_erasure`, conversation scrub helpers,
`mix run`, release RPC, or raw SQL to create, advance, enqueue, reset, or
complete a production subject request. Those are storage/internal interfaces,
not authenticated user authorization. The authenticated API commits the fence
and durable job atomically; the normal exact-runtime worker is the only path
that advances it. If that path is unavailable, restore it or escalate the case
rather than bypassing it.

The separately authenticated `DELETE /api/v1/agents/:id` lifecycle endpoint
removes one Agent through `Runtime.delete_agent/1`. It does not erase its owner
or issue an account-erasure receipt. Do not describe Agent deletion as account
erasure.

## Durable erasure state machine

The authenticated user request transaction:

1. locks protocol authority and the User in canonical order, then publishes
   `privacy_erasure_requested_at`, fencing new subject writes;
2. revokes/settles only reviewed non-erasure subject work and deletes sessions,
   device keys, pairings, push registrations, and magic links; it never cancels
   an existing `privacy_erasure` coordinator/job;
3. snapshots the exact Agent targets and local provider credential references;
4. commits or reuses one deduplicated durable `privacy_erasure` background job.

There is no supported cancel or unfence operation, including during cutover.
Each worker attempt uses a
PostgreSQL-clock claim token and advances at most one bounded unit. Expired
claims are reclaimable. The request progresses through `requested`,
`draining`, `revoking_credentials`, `erasing`, and `completed`.

### Privacy-job deferral during stopped-fleet contraction

An active erasure request survives cutover. When the exact stopped-fleet
contraction encounters its `privacy_erasure` job, the only eligible shape is
`pending`, unclaimed, unassigned, provider-unentered work bound to that active
request. In one locked transaction the database verifies the dark/legacy
protocol and immutable activation evidence, encrypts and binds the job payload,
clears only its compatibility plaintext, leaves the job pending, and inserts an
append-only content-free `privacy_erasure_job_deferral_v1` receipt for the exact
job/request/evidence tuple.

Deletion, retention expiry, or generic cancellation of that job is not a drain.
The reviewed path defers it and leaves the durable receipt; a mismatch, claimed
job, missing active request, prior incompatible receipt, or unrelated OLD→NEW
change blocks contraction. After exact activation the normal claim-fenced
worker resumes the same job. The receipt proves why this one privacy job is not
counted as non-deferrable active work; it does not prove erasure completion and
cannot replace the final account-erasure receipt.

For each Agent target the worker calls `Runtime.delete_agent/1`. That durable
lifecycle drains Directives, runs, Effects, schedules, and exact Agent
authority before removing non-authoritative copies. Erasure never raw-deletes a
lease and never converts lease expiry, node absence, RPC failure, Registry
absence, or `:not_found` into physical-termination proof. Exact task/Agent
incidents must be resolved through the proof paths in the [cutover
runbook](../exact-agent-runtime-cutover.md). `never_activated` is available only
as the TaskGuardian's private capability-backed proof for a `reserved`,
provider-`not_entered`, never-ready assignment; it advances through
`termination_proven` before `settled`. Erasure code cannot raw-settle it or
transport the preimage over RPC.

For user scope, the worker then attempts provider credential revocation and
always removes the local credential copy. The content-free provider outcome is:

- `confirmed` when every captured provider revocation confirmed;
- `not_applicable` when no credential existed;
- `partial_unverified` when local deletion succeeded but at least one external
  provider outcome was unavailable or unconfirmed.

`partial_unverified` does not restore a deleted credential and does not mean the
local proof failed. Record the external uncertainty in the restricted privacy
case and follow provider-specific policy without reconstructing secrets.

Fixed child-first plans then remove bounded user/domain copies. Finalization
locks and proves every captured Agent, credential, user-copy, and execution
surface empty. Only that proof may delete the user and atomically create the
`content_free_erasure_authority_v1` receipt. Completion clears subject IDs and
the idempotency digest from the coordinator; the projection retains only
scope, state/outcome, counts, closed blocker/provider codes, and times.

## Progress, blockers, and repair

The authenticated status response exposes only `state`, `blocker_code`, target
and pending-Agent counts, request/completion times, provider outcome, and the
content-free receipt. Treat a blocker as a durable safety result:

- `effect_termination_proof_required` and Agent-drain blockers require the exact
  task or Agent physical proof; do not infer it from infrastructure silence.
- `operator_drain_proof_required` requires the reviewed external lifecycle
  drain evidence for the stored operation.
- prepared-action external-proof blockers preserve a potentially sent provider
  operation rather than inventing an outcome.
- copy, authority, target, or fence blockers require investigation of the named
  fixed surface, not deletion of proof, lease, request, or source rows.

Erasure-job discovery is itself a durable recurring job. It starts after ten
seconds, runs every minute, and repairs an accidentally missing job for an
active request. That recovery behavior is not permission to cancel or delete a
privacy job during a drain. Operators monitor that coordinator and the request's
content-free status; they do not manually invoke its internal enqueue/perform
functions in production. Repair the exact runtime, resolve genuine blockers,
and allow the claim-token-fenced worker to converge.

## Backups and restored environments

Live erasure does not rewrite historical physical backups or WAL. Backup/PITR
retention, legal holds, access controls, and key retirement must make expired
recovery points unavailable on policy. Until then, restrict backup access and
retain every read key needed for an authorized restore.

Restore only to an isolated, egress-disabled environment. Before restored data
could ever return to service, reapply all post-recovery erasure fences and
receipts and prove the fixed surfaces clean. Never restore an old backup over
production to bypass retention, erasure, contraction, or protocol activation.

See the [durable runtime architecture](../architecture/durable-agent-runtime.md),
[exact cutover procedure](../exact-agent-runtime-cutover.md),
[database TLS/backup/restore guide](database-tls-backup-restore.md), and
[durable payload lifecycle](durable-payload-lifecycle.md).
