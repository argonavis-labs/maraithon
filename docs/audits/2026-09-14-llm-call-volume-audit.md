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
