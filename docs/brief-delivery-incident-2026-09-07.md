# Brief delivery and abandoned runtime reservations

Investigated September 7, 2026 (September 8 UTC). Production APNs is configured,
Kent confirmed a notification appeared on the phone, and all seven stuck briefs
have been delivered automatically. The application recovery and deployment
handoff fixes are deployed on Cloud Run revision `maraithon-00248-x2q`.

## Confirmed cause of the screenshot

Cloud Run diagnostic execution `maraithon-todo-validation-kzrt8` read the
incident recorded at `2026-09-08T00:00:42Z`: seven briefs, oldest age 208,422
seconds (3,473 minutes). This matches the screenshot.

- All seven briefs were still pending. The oldest was scheduled September 5
  at 14:07 UTC. The three morning briefs each had `metadata.email_sent_at`.
- The affected user had an active mobile device. None of these briefs had a
  live/delivered proactive candidate or a push receipt.
- The serving revision was `maraithon-00245-d69`. Neither the combined
  `maraithon` service nor the older `maraithon-runtime` service had APNs
  environment bindings. None of the project's 32 secrets were APNs secrets.
- `brief_notifier` was executing every minute and moving its persisted
  deadline forward. All 64 partitions were ready with live leases. This was
  not evidence that the notifier process had stopped.
- Proactive delivery jobs repeatedly exhausted three attempts with
  `no_push_device`, despite the registered phone. Their readiness predicate
  combined missing APNs configuration and missing device registration into
  the same boolean.

Without Apple push credentials, `unified_push_enabled?/0` returned false and
the broker returned `{:fallback, :disabled}`. Brief dispatch interpreted this
as an intentional pause, leaving the brief pending without a delivery error.
The watchdog then guessed that the notifier was not ticking. The recurring
planner discovery separately selected users with devices, so it continually
created jobs that could not deliver.

## Application changes

- Mobile push readiness distinguishes an explicit pause, missing APNs
  configuration, and a missing device. It exposes no credentials.
- The broker reports missing configuration as `push_not_configured` while
  retaining the explicit pause behavior. This check also applies when push
  has been explicitly enabled; a feature flag cannot substitute for transport
  credentials. Briefs persist actionable, retryable failure copy. The
  existing 15-minute retry backoff applies during the
  outage; once APNs becomes configured, those failures become eligible on
  the next notifier cycle without waiting out that backoff.
- Planner discovery still performs queue hygiene, but does not create model
  work while push cannot operate. Already queued jobs finish with a deferred
  outcome instead of consuming three attempts for a configuration/device
  prerequisite. Subsequent discovery resumes when the prerequisite exists.
- The watchdog continues reporting overdue delivery. Its explanation names
  the missing Apple credentials and distinguishes email from push delivery.
  No brief is marked sent merely because an attempt was skipped.

The evidence did not implicate LLM planning in this incident: the briefs
never reached that step. This repair retains the existing planner and its
delivery receipt protections.

## Separate OTP recovery defect

The first diagnostic also found three background assignments stuck in
`reserved` since 23:31 UTC while recurring work continued. Code inspection
found that `BackgroundJobRunner.coordinated_reservations/6` discarded the
successful prefix of a batch if a later reservation failed. Each prefix
reservation had already committed independently, and its owning runner was
still alive, so owner-DOWN recovery could not release it.

The follow-up execution `maraithon-todo-validation-m9jk8` confirmed all three
were still `reserved`/`not_entered`, their task leases had expired at 23:32,
and their owning node was still ready with a live lease at 00:12 UTC.

The runner now returns the successful prefix on a later claim failure,
including transient database errors, so every returned claim starts its
supervised task. Unexpected runner crashes still use owner-DOWN recovery.

`Coordination.TaskAuthority` also arms a 30-second deadline for each unbound
reservation. Binding or releasing it cancels the timer. If no task has been
bound, the authority cancels activation through `TaskGuardian` and uses its
existing independent never-activated proof/persistence retry queue. The task
authority does not wait for a database write during expiry; a runner might
already hold database locks while requesting another reservation. The timer
does not write an outcome, declare an active process dead, or bypass a
PostgreSQL lease. Late binding is rejected after cancellation. The coordination Session
does not acquire a new synchronous recovery scan in its two-second renewal
loop.

This preserves the OTP supervision boundary: work runs in supervised tasks,
local monitors and cancellation supply physical evidence, PostgreSQL fences
durable outcomes, and proof persistence retries independently. See the
[Erlang supervision principles](https://www.erlang.org/doc/system/sup_princ.html)
and the existing `docs/architecture/durable-agent-runtime.md`.

## Verification approach

`make build` compiled Phoenix with warnings treated as errors. Automated tests
were not run or changed, following `docs/development-mode.md`. Production
database diagnostics used Cloud Run `eval` executions with `POOL_SIZE=2`,
never a laptop database connection. The one deliberate phone notification and
the targeted runtime drain are recorded below.

Two initial `pg_stat_statements` snapshots about five minutes apart showed no
new calls to the most expensive historical runtime verification query. The
next verification query ran twice, adding 441 ms in total. Node renewal ran
280 times, adding 151 ms. Those cumulative totals did not demonstrate an
active verification bottleneck in that observation window.

## Production activation — September 8, 2026 UTC

Apple Developer's Keys page confirms key `SXL6NX65AG` belongs to team
`PS5W7BFTQ2`, is **Team Scoped (All topics)**, and permits **Sandbox &
Production**. It covers `com.bliss.maraithonmobile`; no Apple permission
change or key rotation was needed.

The existing PEM passed the local private-key validity check and was uploaded
directly from its existing location to Google Secret Manager as
`maraithon-apns-private-key`, version `1`. No private key material was copied
into either checkout. The existing runtime service account already had secret
access. Cloud Run binds that version to `APNS_PRIVATE_KEY`, with the matching
key/team IDs, Maraithon's topic, and production environment.

The ten recovery source files were isolated from the unrelated People/CRM
working changes in branch `codex/apns-delivery-recovery`, commit `40549d3abb73`.
`make build` passed; automated tests were not run under the current development
mode. `make deploy` built image
`us-central1-docker.pkg.dev/maraithon/maraithon/maraithon:dev-40549d3abb73-20260908003124-1`
and deployed it as revision `maraithon-00247-gs9`, serving 100% of traffic.
Migrations were unchanged and skipped. The combined-service health check passed.

Cloud Run diagnostic execution `maraithon-todo-validation-zjkhd` used the
deployed image and secret binding to send one notification to Kent's most
recent active device, with automatic job retries disabled. The application
APNs client returned `:ok`, which corresponds to Apple HTTP 200 acceptance,
using the production endpoint. The notification title was
**Maraithon notifications are ready**. This proves provider acceptance; it
does not by itself prove iOS displayed the banner.

Kent confirmed in the task: **Notification appears**. End-to-end production
push delivery is therefore verified on the physical phone.


## Retired runtime still holding work

The post-deployment read-only audit
`maraithon-todo-validation-vhzm7` found all 64 partitions ready with live
leases, two new completed Effect outcomes, and a new Agent checkpoint.
However, the seven original briefs were still pending and the recurring
schedules had stopped advancing at about 00:31 UTC. Revision
`maraithon-00245-d69` was still renewing its original node lease and owned
assignment `7e16f24e-a313-49ad-af76-285c6d7bfd48`, reserved since 00:31:31
with an expired task lease and `provider_boundary=not_entered`. It was still
running the old code and lacked the newly configured APNs environment.

A temporary zero-traffic tag for that retired revision reached a newly started
instance rather than the stranded original incarnation. The identity check
prevented treating them as the same process. The newly started instance was
then asked to drain; the temporary tag was removed. The old revision was
deleted, and Cloud Run's subsequent describe returned not found. The current
repair retained 100% of traffic. Its predecessor image remains in Artifact
Registry.

The original retired process continued logging and renewing after revision
deletion. Therefore **revision deletion alone is not sufficient physical
termination evidence while that process is still alive**. No task proof was
fabricated and no database ownership row was deleted. An outstanding request
may be keeping that process alive; Kent was asked to close existing Maraithon
web tabs and quit the desktop app briefly. That client-close request was unnecessary: the existing database-side drain
control, described below, reaches the original incarnation directly.

A second audit, `maraithon-todo-validation-8cqdm`, at 00:48 UTC confirmed
that the original deleted-revision incarnation was still renewing its lease,
all seven briefs were still pending, and no natural push receipt had yet
been created. The old assignment was still reserved. Automatic delivery
recovery must not be reported complete from the successful phone test alone.


## Root recovery and deployment handoff

The old Session already recognizes a database-side node transition to
`draining` as an explicit retirement request. On renewal, it stops admitting
work and completes local task termination and durable proof persistence,
without registering a new incarnation. HTTP routing is unnecessary for this
control path.

Cloud Run execution `maraithon-todo-validation-rhgfs` checked that node
`ce1c35bf-e3eb-46dd-840d-3b409cc2e901` belonged to service `maraithon`, revision
`maraithon-00245-d69`, and called the existing `Authority.begin_node_drain/1`.
It returned `{:error, :partition_authority_lost}` during workload revocation,
but its preceding topology transaction had committed `state=draining`.
The owner observed that fence and completed ordinary cleanup. No termination
attestation, ownership-row deletion, or fabricated outcome was used.

At 00:59 UTC, read-only execution `maraithon-todo-validation-lcd6d` confirmed:

- All **seven original briefs were sent**, with the latest completion at
  00:55:59 UTC. Three brief receipts were `sent_now`; four were `merged` into
  a delivered digest. No pending brief remained. The 24 previously failed
  historical briefs were not rewritten.
- All 64 partitions were ready with live leases on the replacement revision.
  No reserved, running, or termination-requested assignment remained.
- Recurring schedules had resumed and were advancing at their configured
  intervals, including the one-minute brief notifier.
- New background outcomes were being recorded. The Chief of Staff logged
  recovery to idle at 00:54:37 UTC.

Commit `f4316dea8ba2` makes the handoff part of the normal fast deploy:

- Runtime status lists live physical revisions for the same Cloud Run service.
- Before replacement, deploy captures that revision list. After the ordinary
  health check, it sends a bounded, authenticated `/api/v1/runtime/retire`
  request to the replacement with the explicit pre-deploy revision list.
- The endpoint verifies the receiving revision matches the expected replacement,
  refuses to retire that revision, and uses existing node drain authority.
  Each old Session retains responsibility for termination evidence.
- This remains a best-effort retirement command. It adds no drain-proof gate,
  migration, deployment lock, or synthetic task proof.

`make build` and the deployment script's shell syntax check passed. Normal
`make deploy` built image
`us-central1-docker.pkg.dev/maraithon/maraithon/maraithon:dev-f4316dea8ba2-20260908005703-1`
and deployed `maraithon-00248-x2q` at 100% traffic. The initial routed health
requests timed out while Cloud Run adjusted instances; the existing retry
succeeded, the retirement request succeeded, and the deploy exited zero.
The source changes were also copied back into Kent's original checkout while
preserving the unrelated People/CRM work. The repair branch was not pushed.


## Final production observation

Read-only execution `maraithon-todo-validation-mftsh`, using the final deployed
image, observed the database at 01:03:45 UTC. Only revision
`maraithon-00248-x2q` had a live node; all 64 partitions were ready with live
leases. The seven original briefs remained sent with delivery receipts and no
errors. The brief notifier had advanced to 01:04:11 UTC; other recurring rows
were likewise scheduled forward on their configured intervals.

No abandoned reservation or termination-requested task remained. One normal
background task was running, created 22 seconds before the observation with a
live lease. Across the repair window, six Effect completions had matching
outcome evidence, two checkpoints were recorded, and no snapshot persistence
failure event was present. The final revision logged Chief of Staff recovery
to idle at 01:02:24 UTC. The query-cost snapshot still contains historical
cumulative verification costs; it is not a fresh latency measurement.

This closes the seven-brief delivery incident. Historical failed briefs and
ambiguous outcomes outside this incident were preserved.
