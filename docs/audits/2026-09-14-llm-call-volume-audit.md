# Model call volume audit

Date: 2026-09-14. Scope: why one user's Maraithon makes ~2,000 model calls a
day, which of them buy nothing, and how the same product outcomes can come
from a fraction of the calls with an event-driven runtime and a slow safety
heartbeat instead of one-minute cron ticks.

Evidence: Cloud Logging (`LLM call completed`, `Calling OpenRouter Chat
Completions API`, per-workload log lines) for Aug 31 to Sep 14, the
`background_jobs`, `source_cycle_items`, `source_decision_receipts`, and
`todo_closure_receipts` tables read through the migrate job's eval path, and
four code surveys of the discovery, closure, agent, brief, and scheduling
paths. File references below are to `main` at `327226aa`.

## 1. Baseline

| Measure (14 days to Sep 14) | Value |
| --- | --- |
| Completed model calls | 54,334, all on `moonshotai/kimi-k3` |
| Spend | $3,608 ($260 to $633 a day Aug 31 to Sep 7; $87 a day Sep 8 to 13) |
| Input / output tokens | 1,036M / 43M (input is ~90% of cost at $2.65 per M) |
| Typical call | 15,000 input tokens, 2 to 10 cents; 7,800 of 11,900 calls Sep 8 to 13 |
| Prompt cache hits | 7% of input tokens |
| Effort split per day | ~60% "none" (chat tier), ~35% "high", ~5% "low" |
| Same traffic on `meta/muse-spark-1.3-contributor` | ~$112 (fixed and live since revision 00322) |

Job rows in 14 days (about 20,000 a day for one user):

| Job family | Rows | Model-backed |
| --- | --- | --- |
| `source_account_discovery` | 71,193 | no (provider fetch) |
| `source_account_closure_acquire` | 39,339 | no (fetch) |
| `source_account_discovery_reason` | 22,278 (+12,628 retry attempts) | yes, effort high |
| `people_network_refresh` | 20,497 | no (DB heavy) |
| `source_account_closure_reason` | 20,268 | yes, effort none, 50 to 65 KB prompts |
| `slack_reconciliation_plan` / `_conversation_reconcile` | 14,522 / 12,580 | no |
| `discovery_finalize` / `closure_finalize` | 8,503 / 5,455 | no |
| `todo_completion` (backstop review) | 7,524 | sometimes |
| `todo_brief_generation` | 2,953 | yes, brief tier, effort high |
| `proactive_check_in` / `nudge` | 923 / 598 | at most one call each |

What the calls produced:

| Outcome (14 days) | Count |
| --- | --- |
| Closure verdicts "still open" / "completed" | 178,367 / 18 |
| Discovery decisions skip / create / update | 20,290 / 1,326 / 606 |
| Open todos today | 91 (44 done, 1,428 dismissed) |
| Discovery jobs a day vs cycles that carried new items | ~5,000 vs 30 to 800 |

So the two reasoning pipelines spend about 3,000 model-backed jobs a day to
produce roughly 140 todo creates or updates and about one completion. The
closure hit rate is one in ten thousand.

## 2. Where the ~2,000 daily calls come from

| Workload | Calls a day | Mechanism |
| --- | --- | --- |
| Closure reasoning | ~1,450 | Every non-empty evidence delta (about 390 a day, one every 3.7 minutes) fans out `ceil(open todos / 40) × source partitions` reason jobs, each prompting the model with the whole todo batch. The snapshot is every open todo for the user, on purpose (`todo_completion_sweep.ex:118-147`); the only gate before the model is a timestamp (`cross_source_completion.ex:1425-1438`). One email about todo 7 asks about todos 1 to 60, about four times over. |
| Closure backstop | ~300 to 500 | `review_memo` hashes all evidence globally (`cross_source_completion.ex:229-243`), so any new item invalidates every todo's memo and the per-minute `todo_completion` review re-prompts. Failures retry up to three times, each a fresh 50 to 65 KB prompt. |
| Discovery reasoning | ~1,590 jobs × 1.57 attempts | Acquisition re-fetches a one-hour overlap (`acquisition.ex:42,53`) and the revision digest hashes the whole provider record, labels, read state, and thread context included (`source_account_discovery.ex:496-508`). Reading or archiving a message, or a reply landing in its thread, makes an already-reasoned message look new. Partitions hold 5 items (`:32`), so 600 cycles become 1,590 jobs. `IntakeSnapshot` fingerprints the entire todo table (`intake_snapshot.ex:10-40`); sibling fanouts and the sweeps invalidate it, the call is already paid, and `ingest_many` pays again (`intelligence.ex:135-141`), then the job retries. |
| Chief of Staff effects | ~250 to 290 | 144 wakes a day. The cycle memo fires whenever any source item arrived (`ai_chief_of_staff.ex:750-757`), up to 144 calls; `local_pattern_review` has no cooldown or fingerprint (`local_pattern_review.ex:95-134`), ~100 calls; the six gated skills add ~6. `commitment_tracker` runs at 32,000 tokens and effort high. The Sep 7 jump from 40 to 280 is the 10-minute cadence finally firing after `cb580599` fixed wake starvation, not new work. |
| Todo briefs | ~210 | Enqueued on every todo write, including unchanged rows in `upsert_many` (`todos.ex:388`), with a fingerprint over pipeline-written fields (`Workflow.current`, `action_plan`, `next_action`, excerpts; `brief.ex:351`) that the sweeps rewrite, plus a blanket six-hour expiry and a first-three prefetch on every list load. |
| Delivery planner, nudges, chat | ≤144, ≤48, small | Well gated. Not the problem. |

The sum exceeds 2,000 because many closure and discovery jobs short-circuit
before calling the model; the ranges above are the observed upper ends.

## 3. Cron versus pub-sub: what already exists

The event path is already built and already correct in shape:

- Gmail push lands at `POST /webhooks/google/gmail` and enqueues
  `gmail_incremental_sync`; completion calls `wake_source_account`
  (`background_job_handler.ex:390-393`).
- Slack Events land at `/webhooks/slack` and call `wake_source_account` on
  content-bearing messages (`connectors/slack.ex:257`).
- Companion ingest calls `wake_todo_workflows` with a 20-second coalescing
  delay (`companion_controller.ex:570`, `periodic_jobs.ex:91-103`).
- Agent directives (`AgentDirectiveIngress`) are the durable, transactional,
  multi-node bus; `Phoenix.PubSub` is explicitly not trusted across nodes
  (`event_controller.ex:47-50`).

Three things make the ticks redundant and the wakes wasteful:

1. `source_account_discovery` and `todo_completion_sweep` enqueue one job per
   account every minute unconditionally; 86 to 88% of those acquisitions find
   nothing. Together they are 43% of all job rows.
2. Dedupe suppresses only while a job is live (`background_jobs.ex:585-592`);
   there is no "not more than once per N minutes" primitive, only two ad-hoc
   cooldowns.
3. The wakes ignore counts: Gmail sync wakes discovery even when `count` is 0;
   companion ingest wakes on `accepted + duplicate`.

Every Chief of Staff skill also refuses event triggers
(`interested_in?` returns false for `:pubsub_event` in all seven skills), so
an event-driven cycle would run zero skills today.

## 4. Plan, ranked by calls saved per unit of work

| # | Change | Calls a day saved | Effort | Risk |
| --- | --- | --- | --- | --- |
| 0 | Model switch to muse-spark contributor (done) | 0, but 35× cheaper per call | done | moderated endpoint; watch for content refusals |
| 1 | Closure: intersect the todo snapshot with the delta's linkage using the existing `evidence_identifiers/1`, `evidence_linked?/2`, `counterparty_label_linked?/2` (`cross_source_completion.ex:545-595`) plus a `counterparty_person_id` join; keep one unlinked exhaustive pass a day on the staleness cadence | ~1,300 | 2 days | Coverage proofs (`resolve_todo_decision_manifest/3`, `cross_source_complete?/2`, `validate_child_results`) assume total coverage; redefine them over the linked set or watermarks stall |
| 2 | Closure: per-todo evidence digest memo. Read the `evidence_digest` and `decision_digest` already written to `todo_closure_receipts` and skip todos whose `(revision, evidence set)` already returned still open; replace the global backstop hash with a per-todo hash | ~300 | 1 day | Stale memo suppressing a real close; expire on `completion_evidence_after` movement |
| 3 | Discovery: narrow `source_revision_digest/1` to content fields (id, date, subject, from, to, body, thread message ids); version the `SourceCycleItem` proofs so old rows are not all "unsettled" on first run | ~1,000 | 1 day + backfill | Deliberate reversal of the wide-hash comment at `:498-502`; a label-only change no longer re-reasons |
| 4 | Discovery: serialize reason jobs per user (partition key on user, not fanout index) and raise `@handoff_item_limit` toward 15 to 20 under the 96 KB cap | ~600 attempts | 0.5 day | Bigger batches trip `ingest_smaller_batches` more often; raise incrementally |
| 5 | Retries: classify deterministic failures (`invalid_response`, coverage violations, budget errors) as discard instead of retry on `todo_completion` and closure reason (`periodic_jobs.ex:1350`, `:2255`) | ~100 to 200 | 0.5 day | None material |
| 6 | Cadence: gate `wake_source_account` and the companion wake on a positive new-item count; add a cooldown check modelled on `recent_slack_reconciliation_plan/2`; raise `TODO_COMPLETION_SWEEP_INTERVAL_MS` to 15 to 30 minutes (env only) and add the same env for `source_account_discovery_interval_ms` (currently hardcoded at `recurring_jobs.ex:87-91`); `people_network_discovery` cutoff 6 hours; Slack plan every 15 minutes with a larger batch | few model calls, ~11,750 job rows a day, most provider API traffic, and CPU on the 1-vCPU instance | 1 day | Worst-case detection latency becomes one heartbeat if a webhook lapses; `watch_renewer` and `freshness_sweep` already repair that |
| 7 | Agent: memo only when a skill emitted (`cycle_worth_memo?/1` on `pending_emits`), a cooldown and input fingerprint on `local_pattern_review`, `commitment_tracker` to 8 to 12k tokens at effort medium | ~240 | 0.5 day | Low; the decision ledger is independent of the memo |
| 8 | Agent: wake on events with a 30 to 60 minute heartbeat; let time-boxed skills return absolute next-due times; accept `:pubsub_event` only in delta-driven skills | ~100 acquisition cycles; enables the rest | 1 to 2 days | This is the mechanism `cb580599` just repaired; keep `preserve_earlier` and `briefing_cron`'s morning wake |
| 9 | Briefs: fingerprint only user-meaningful fields; expire only todos due inside the horizon; prefetch top 1 or generate on detail open; enqueue only changed rows in `upsert_many` | ~150 | 0.5 day | A workflow transition should still force a refresh; keep `transition_workflow` explicit |
| 10 | Instrumentation: bind `job_type`, agent, and skill into Logger metadata at the job runner and effect runner so every `LLM call completed` line is attributable; a daily cost line per workload | 0 | 0.5 day | None |

Expected end state: roughly 300 to 500 calls a day instead of 2,000, and about
7,000 job rows a day instead of 20,000, with todos still created within minutes
of a push notification and completions still detected when linked evidence
arrives. At the current model's prices that is a few dollars a day.

## 4a. Implementation status (Sep 14)

- Items 0, 3, 4, 5, 6, 7, 9, 10 shipped in `824bb123` (revision
  `maraithon-00323-jzn`): 15-minute heartbeats for discovery and the
  completion sweep (the discovery interval is now `SOURCE_ACCOUNT_DISCOVERY_INTERVAL_MS`),
  count-gated Gmail and companion wakes, 15-minute Slack plan and backstop
  cooldowns, six-hour people-network cutoff, content-only revision digest,
  12-item discovery partitions, one retry on reasoning jobs, memo only on
  decisions or daily, pattern-review cooldown, commitment tracker at 12k and
  medium, brief fingerprint on user-meaningful fields with due-soon-only
  expiry and top-1 prefetch, and `job_type` / `prompt_kind` on every model
  call log line.
- Items 1 and 2 shipped in `91299461`: the exact closure path prompts only
  todos linked to the delta or overdue for a daily check and records
  `unlinked_source_evidence` policy receipts for the rest; the backstop memo
  hashes each todo's linked evidence.
- Item 8 (event-driven agent wake) is not implemented; it saves acquisition
  cycles rather than model calls and carries the starvation risk noted above.
- `5ac7db1a` fixes a regression the cheaper endpoint exposed rather than a
  call-volume item: the provider cooldown was global, so a 429 earned by a
  background sweep also blocked the chat bucket. Cooldowns are now lane
  scoped, background against background and chat against chat.

### Measured after the cutover

Thirty minutes on revision `maraithon-00324-8l6`, all traffic on
`meta/muse-spark-1.3-contributor`:

| Metric | Before (Sep 8-13 average) | After |
| --- | --- | --- |
| Model calls per day | ~2,000 | ~670 |
| Spend per day | ~$87 | under $1 |
| Background job rows per day | ~20,000 | ~12,600 |

Closure receipts over 90 minutes: 827 model verdicts and 174
`unlinked_source_evidence` policy receipts, so only one todo in six skipped
the model. `0683210b` explains the rest: item 1 matched counterparty labels
as substrings, and those labels are generated prose. Twenty-three of the
sixty labelled open todos contain the word "teammate" and a dozen more carry
the workspace name, so nearly every Slack message linked to nearly every
todo. Tokens now match whole, generic role and platform words are dropped, a
token counts only while it stays rare in the open pool, and a plain word has
to match the sender rather than the subject. Against the live labels, chatter
in a shared channel falls from seventeen matches to one while a named sender
and a Slack id still match exactly the todos they belong to. Gmail ingest still reaches discovery reasoning in
about three seconds, and a sync that ingested nothing no longer wakes
anything.

## 4b. Independent follow-up and cost warning (Sep 14, 17:51 UTC)

The cheaper model and lower call volume reduce the bill, but the latest quiet
period is not proof that the product is working at the projected cost.

Fresh Cloud Logging reads and a read-only Cloud Run execution
(`maraithon-migrate-l9xnt`, `POOL_SIZE=2`) produced these observations:

| Window or measure | Observed result |
| --- | --- |
| 13:00 to 14:00 UTC on revision `00324` | 41 OpenRouter attempts, 40 completed, US$0.065204 in provider-reported charges |
| Same hour at a constant daily rate | About 960 completed calls and US$1.56/day, versus the earlier baseline of about 2,000 calls and US$87/day |
| Models in that hour | 39 Muse attempts costing US$0.051880; two Kimi attempts costing US$0.013324 |
| Revision `00325-tfj` | Created at 14:06:48 UTC and serving 100% of traffic |
| 14:10 to approximately 17:49 UTC | No model-attempt or model-completion logs, despite recurring work continuing |
| OpenRouter billing counter at approximately 17:51 UTC | US$7.669780 for the current UTC day, including spend before the cost changes |

The one-hour sample is about 98% cheaper than the previous daily baseline when
extrapolated. It is not a full-day measurement, and the failed attempt has no
reported charge. The provider's daily counter is a separate whole-day total;
it cannot isolate the latest revision. The earlier "under US$1/day" projection
was based on a shorter window and should not be treated as a settled result.

Production still defaults to Kimi in the deployment environment. Muse comes
from the user's `assistant_model` setting. Requests without that user binding
can still use Kimi, as the two calls above show. The warning counts every model
using the app's OpenRouter key, so those calls are included.

The latest lane-scoped rate limiter also defaults a missing lane's deadline to
zero, then subtracts `System.monotonic_time/1`. BEAM's monotonic origin may be
negative, so a lane that has never been rate-limited is incorrectly blocked
for years. This explains the absence of model attempts and is a regression in
`5ac7db1a`, not a saving. The local fix treats a missing deadline as no remaining
cooldown in both admission and status reporting, while retaining separate
background and chat lanes. A second read-only execution
(`maraithon-migrate-jn72v`) found 78 relationship-ingestion failures and 16
completion failures labelled `rate_limited` since 14:10 UTC. All 64 partitions
were `ready`; this observation alone is not a full runtime-health proof.

The latest revision logged eleven `KeyError: key :reviewed_at not found`
Agent crashes in the inspected period. The cooldown change added fields to
new `LocalPatternReview` state but used map-update syntax on restored snapshots
that lacked those fields. The local follow-up changes that update to
`Map.merge/2`, which adds the missing fields on first use. There were also
effect timeouts and rejected requests, failed completion jobs, pending
discovery reasoning, and no new closure receipts in this window. Deployment
and a fresh observation of useful model work are still needed before calling
the latest runtime healthy or treating its near-zero activity as savings.

### Warning deployed

Kent selected a fixed **US$3/day projection**, with an email above **US$6** to
**kent.fenwick@gmail.com**. `Maraithon.LLM.CostMonitor` runs through the existing
durable recurring-job system every six hours, about four checks per day, plus
an initial check when monitoring first starts. It reads OpenRouter's
[current-key billing counters](https://openrouter.ai/docs/api/api-reference/api-keys/get-current-key)
using the app's existing key. It makes no model calls and does not rely on the
agent-effects spend dashboard, which excludes other workloads.

- Alert when either the provider's current UTC-day total or observed rolling
  spend exceeds twice the fixed projection. All amounts are USD.
- Rolling spend uses differences in the provider's cumulative counter over up
  to 24 hours. It starts collecting at activation and omits the partial interval
  before the oldest retained sample, normally less than six hours. The daily
  counter gives immediate coverage during that initial collection period.
- Keep at most six samples and the last successful email time in the recurring
  job's encrypted result. Existing lease-fenced settlement persists the state;
  there is no new table, coordinator, or process-local ownership mechanism.
- Send through the existing Postmark transport. Retry provider or email
  failures next cycle, preserve history and the last successful notification,
  and log the failure explicitly. A failed usage read is never treated as zero.
- Suppress repeat warnings for 24 hours after a successful send. As with the
  existing email path, delivery followed by a crash before durable settlement
  can produce a duplicate on recovery.
- Keep the assistant running. This is a warning, not a spending cap.

`LLM_PROJECTED_DAILY_USD` defaults to `3.00`; the multiplier is fixed at two.
The normal deploy script preserves an existing projection or accepts an
explicit override. Monitoring is enabled in production and stays disabled in
development. The initial US$7.67 daily total triggered a warning on the first successful
production check, including charges incurred before the fixes.

Validation: `make build` passed with warnings treated as errors. A manual
`mix run --no-start` inspection confirmed that a fresh limiter admits work with
a negative monotonic clock, a background cooldown leaves chat available, and
the old snapshot shape gains the cooldown fields without crashing. This made
no provider or database calls. The deploy script passed `bash -n`, and
`git diff --check` passed. Automated tests were not run under the manual-first
development policy. The warning, rate-limiter fix, and snapshot fix first went
live on revision `maraithon-00326-4w8`. At 18:45:12 UTC, the monitor read the current
US$7.669780 daily bill and successfully emailed the US$6 threshold warning.

## 4c. Fresh start for kent@runner.now (Sep 14)

Kent requested deletion of all his todos and morning briefings, followed by a
fresh run and a cost measurement. The Chief of Staff was paused for the reset.
The scoped transaction completed at **18:44:45 UTC (14:44:45 Toronto)**:

- Deleted 1,563 todos: 91 open, 45 done, and 1,427 dismissed.
- Deleted 17 morning briefings. Other briefing cadences were preserved.
- Verified zero todos and zero morning briefings for this user inside the
  transaction. Other users, connections, source data, and runtime proofs were
  outside the deletion scope.
- Confirmed the selected model is `meta/muse-spark-1.3-contributor`.

The billing baseline was read at **18:44:44 UTC**: cumulative OpenRouter key
usage **US$5,029.431418189**, and current UTC-day usage **US$7.669780475**.
Incremental cost is the later cumulative counter minus this baseline. It
includes all traffic using the app's key during the observation window, not
just the manual rebuild, and the initial rebuild is a one-time cost rather
than a steady daily rate.

Revision `00326-4w8` includes commits `6c010919` and `1e6697d7`. Manual rebuilds
now bind the requested user's model, and morning briefing generation checks
the stored brief instead of letting an old snapshot suppress a deleted brief.
Both changes passed `make build`.

The 14-day open-work rebuild was queued at **18:45:54 UTC** as
`62911cdc-88ef-4d99-b1fd-ccc9864a6303`. Its first Muse analysis returned eight
candidates at 18:50:23 UTC for US$0.0072873. The subsequent ownership check timed
out after five minutes and queued durable todo ingestion. The rebuild API
reported `completed` with zero saved items while that retry was pending, so
that status alone was not evidence that regeneration had finished.

The durable Muse retry completed at 18:59:42 UTC for US$0.005411 and saved six
todos: five open and one snoozed. Source acquisition covered three Google
accounts, Slack, and connected local sources. Gmail coverage was partial:
180 messages, 40 full bodies, and 140 without full bodies. This was a bounded
14-day review, not an exhaustive rescan of every message.

The Chief of Staff resumed at 18:55:44 UTC. The fresh cycle exposed another
model-setting gap: effect workers were spawned by the outbox runner and did
not inherit the Agent's user binding. They therefore used the deployment's
Kimi default. Commit `2ae9c4ae` restores the durable effect owner's model
binding in the worker. Kent explicitly confirmed Muse, so commit `b43e1288`
also changes the OpenRouter defaults and all production model routes to
`meta/muse-spark-1.3-contributor`. No distinct fallback model is configured.
The Chief was paused again at 19:01:06 UTC to prevent additional Kimi effects
during deployment. Both changes passed `make build`; shell syntax and diff
checks passed. Automated tests were not run under the manual-first policy.

At **19:04:47 UTC**, OpenRouter reported cumulative usage of
**US$5,029.876939195**, an increase of **US$0.44552101** since the reset. The
six todos were saved, the durable ingestion job was completed, and no morning
briefing existed yet. The next cost check was pending for **00:45:12 UTC on
Sep 15 (20:45 Toronto on Sep 14)**.

Revision `maraithon-00327-wk8` reached 100% traffic at approximately 19:07 UTC.
All four production model routes now select Muse, with no alternate fallback
configured. The Chief of Staff recovered at 19:07:40 UTC and subsequent
observed requests used Muse. The first start request briefly returned
`partition_not_owned` during the rolling handoff; normal recovery resumed the
Agent seconds later.

The operator wakeup was queued at **19:14:17 UTC** through the normal durable
scheduler. The first maintenance attempt lacked the signing-key tag and made
no write; the retry supplied the existing production tag through an execution
override. No runtime proof or ownership check was bypassed.

The fresh morning briefing, `9cb47b78-d56d-45a4-ac78-921a67362d8d`, was saved
at **19:17:30 UTC** with `generation_mode=llm`, Muse in its request metadata,
and no generation error. Its email timestamp is **19:17:38 UTC (15:17:38
Toronto)**. The three successful Chief of Staff model calls in this cycle
reported a combined **US$0.0088102**.

The delivery check at **19:17:44 UTC** found:

| Measure | Result |
| --- | --- |
| Cumulative OpenRouter key bill | US$5,029.898978995 |
| Billed since the 18:44:44 baseline | **US$0.46756081** |
| Current UTC-day bill, including earlier activity | US$8.137341281 |
| Todos now stored | Seven: five open, one snoozed, one done |
| Morning briefing | Generated with Muse and emailed |
| Chief of Staff | Running |
| Next US$6 cost-warning check | 00:45:12 UTC, Sep 15 |

The attempt logs contain 34 Muse attempts (32 completed, US$0.069799066 in
reported charges) and three Kimi attempts (two completed, US$0.232937948149017
in reported charges). Each model had one failed attempt without a reported
charge. All measured attempts on revision `00327-wk8` used Muse. These are
different workloads, not a controlled model comparison; the billing-counter
difference remains the authoritative total.

## 4d. Full-day follow-up and live conversation cost (Sep 15)

The changes have reduced costs, but the earlier under-US$1/day estimate has
not held. From September 14 at 16:00 UTC to September 15 at 16:00 UTC, attempt
logs recorded **1,542 attempts and US$4.112878 in provider-reported charges**.
That is about 95% below the old US$87/day baseline. Six attempts have no reported
price, so this is not the complete bill. The window also includes the requested
todo and briefing rebuild, deployment interruptions, and the first live eval.

The three Kimi attempts were on revision `00326`, before the final model
cutover. Every measured attempt after 19:07 UTC on September 14 used
`meta/muse-spark-1.3-contributor`. Discovery reasoning accounted for 733
attempts, relationship ingestion for 474, and todo briefs for 156. Call volume
still needs work; these measurements do not support the earlier 300 to 500
calls/day target.

A read-only Cloud Run check at 15:50 UTC found US$2.667109 on the provider's
current UTC-day counter and US$4.267680 billed since the September 14 reset.
The latest scheduled warning check, at 12:45 UTC, was within budget. Its next
check was scheduled for 18:45 UTC. The fixed projection remains **US$3/day**,
the alert threshold **US$6**, and the interval **six hours**. The observed
full-day charges exceed the projection but remain below the alert threshold.

The first live information delegation between the two Kent accounts passed.
It sent one autonomous email, received the counterpart's answer, and marked
the todo Done with a citation to that exact inbound message. Two turns made
four Muse calls for **US$0.001421**. This proves the controlled information
case, not the remaining calendar, Slack, or assistant-identity cases. Two
model calls per turn exceeded the plan's target at the time, below 1.3.

Evidence: [cost follow-up](../evidence/delegated-conversations/2026-09-15-cost-followup.json)
and [live information eval](../evidence/delegated-conversations/2026-09-15-live-information.json).

The billed increase includes the earlier Kimi attempts, timed-out calls, and
background activity during the reset experiment. It is not a Muse-only price
for rebuilding todos. The morning briefing's follow-on todo reconciliation
was still running at the delivery check, and normal discovery continues, so
later charges are outside this measurement. The warning remains active.

These observations confirm useful work at materially lower measured model
costs. They do not establish a full-day production cost below US$3. Keep the
fixed projection and check the next full day with the billing counter.

### September 16 decision and scheduling measurement

Kent kept independent model review and replaced the call-count target. An
ordinary substantive turn targets two calls: composition and independent
review. Research or repair has a three-call ceiling, including final review.
Waiting and ignored acknowledgements use zero calls and are counted separately.
This decision keeps Muse Spark Contributor and does not change the spending
warning or normal US$7 pause.

The controlled October scheduling case passed with three settled research
calls and two booking calls, costing **US$0.002583** in total. It verified the
recipient's invitation and its description, then cancelled the test event.
There were no unresolved reservations. This is evidence for those two turns,
not a new daily cost projection or proof of the remaining repair path.
[Scheduling receipts](../evidence/delegated-conversations/2026-09-16-requested-scheduling-passed.json).

## 5. What must not change

- The source-account fence, one live acquisition per role per account, the
  deferred watermark commit, and the `expected_lower_value` CAS on advance.
- Coverage proofs and finalizer digests; if the closure set narrows, the
  proofs narrow with it in the same change.
- Events go through durable rows (`BackgroundJobs.enqueue` or
  `AgentDirectiveIngress`), never a PubSub-only path.
- The recurring reconcile stays as the fallback at a slower cadence;
  `AGENTS.md`'s "wakes every 10 minutes" and "1 to 30 minutes" lines are the
  policy to update alongside items 6 and 8.

## 6. Product-goal check

Todos still appear within minutes: Gmail push and Slack events already wake
discovery, so the tick change does not add latency. Completions are still
found: the linked-evidence check runs on every delta that touches a todo's
thread, counterparty, or account, and the daily exhaustive pass catches
cross-source acknowledgements. The morning brief, commitment review, and
calendar check-in keep their schedules. Briefs stay fresh when the user or a
workflow transition changes the todo, not when a sweep rewrites a hidden field.
