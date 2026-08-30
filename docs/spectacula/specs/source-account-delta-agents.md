# Source-Account Delta Agents

Status: In progress
Purpose: Replace broad repeated connector reasoning with cheap, bounded OTP work per connected Gmail account and Slack workspace. Each source worker reads only the durable delta since its last successful run, creates or updates trustworthy todos, and has a paired closure worker that marks those todos done only when new evidence proves completion.
Depends on:
- [AI Chief of Staff Skill-Orchestrated Agent Architecture](/Users/kent/bliss/maraithon/docs/spectacula/specs/ai-chief-of-staff-skill-orchestration.md)
- [Chief of Staff Shared Acquisition and Attention Arbitration](/Users/kent/bliss/maraithon/docs/spectacula/specs/chief-of-staff-shared-acquisition-and-attention-arbitration.md)
- [Chief of Staff Fresh-Start Intelligent Source Monitoring](/Users/kent/bliss/maraithon/docs/spectacula/specs/chief-of-staff-fresh-start-intelligent-source-monitoring.md)

## 1. Outcome

Maraithon should behave like a small Erlang system whose workers wake for bounded work and disappear:

- one discovery identity for each connected Gmail mailbox
- one discovery identity for each connected Slack workspace
- one closure identity for each connected Gmail mailbox
- one closure identity for each connected Slack workspace
- one per-user Chief of Staff that ranks the resulting todos and writes briefs, without re-fetching every source

These are logical agents implemented as exact, durable background assignments and short-lived supervised BEAM tasks. They are not extra long-lived `Agent` rows or a second ownership system. PostgreSQL remains authoritative; the process is only a leased executor.

## 2. Goals

- Fetch only messages newer than the last role-specific committed cursor.
- Start work immediately from push/webhook ingress and use a one-minute recurring sweep only as anti-entropy.
- Spend no model tokens when a delta is empty or deterministic rules settle every candidate.
- Use at most one high-intelligence model call for a non-empty discovery batch and at most one for an ambiguous closure batch.
- Keep each account isolated for retries, rate limits, observability, and failures.
- Advance a cursor only after the corresponding todo writes or closure evidence commit durably.
- Keep the top-level Chief of Staff fast: rank current todos, arbitrate attention, and brief; do not repeat account acquisition.

## 3. Non-goals

- Creating a persistent `gen_statem` and checkpoint stream for every mailbox and workspace.
- Allowing two workers to share a consumption cursor.
- Replacing exact runtime task assignments, provider rate limits, or tenant fairness.
- Closing todos from weak semantic similarity, acknowledgements, or an absence of messages.
- Removing the periodic deep reconciliation pass before the account pipeline has production parity.

## 4. Worker Topology

```text
push ingress / recurring anti-entropy
                 |
                 v
      account acquisition assignment
      (provider lane, one account)
                 |
       sealed normalized delta
          /                 \
         v                   v
 discovery reasoning   closure reasoning
 (model lane)          (model lane)
         |                   |
  todo upserts         evidence-backed closes
          \                 /
           v               v
            Chief of Staff
       rank, arbitrate, brief
```

### 4.1 Durable identity

Every logical worker is addressed by:

| Field | Meaning |
|---|---|
| `user_id` | tenant authority and fairness key |
| `connected_account_id` | exact account row |
| `provider_family` | `gmail` or `slack` |
| `role` | `acquire`, `discover`, or `close` |
| `cursor_frontier` | immutable start frontier for this attempt |

The active-job dedupe key includes account and role. Acquisition, discovery, and closure for the same account use the same provider-account partition key where mutation ordering matters. Tenant fairness still caps aggregate model pressure from a user with many accounts.

### 4.2 OTP execution

- `RecurringJobs` owns durable schedule rows.
- `PeriodicJobs` discovers bounded account work and enqueues it.
- `BackgroundJobRunner` and the exact runtime task supervisor start a short-lived process for each claimed assignment.
- Provider calls stay in `runtime_provider_account`.
- Model work stays in the fair model lane, partitioned by source account while retaining the user tenant key.
- A crash leaves the job and cursor retryable; no process-local success is authoritative.

## 5. Cursor Contract

Discovery and closure never consume the same cursor. Required cursor kinds are role-specific:

- `gmail_discovery_watermark`
- `gmail_closure_watermark`
- `slack_discovery_watermark`
- `slack_closure_watermark`

Provider-native sync cursors such as `gmail_history_id` remain connector-ingestion cursors and are not repurposed as semantic-work cursors.

Cursor rules:

1. Lock the account, cursor, and result identity in the write transaction.
2. Record the immutable start cursor on the acquisition/result.
3. Seal all bounded pages before reasoning can read them.
4. Persist todo upserts or closure evidence idempotently.
5. Advance only that role's cursor in the same settlement transaction.
6. On timeout, partial pagination, ambiguous task outcome, or write failure, leave the cursor unchanged.
7. Cursor updates are monotonic where the provider frontier is ordered.

## 6. Acquisition Agent

The acquisition agent performs no semantic model call.

For Gmail it uses the mailbox-specific provider token and history/search frontier. For Slack it uses one workspace and its user/bot token pair. It stores a bounded normalized delta with source ids, thread ids, timestamps, direction/self identity, account identity, and the minimum excerpts needed by the reasoning workers.

An empty, complete delta is a successful result and may advance the acquisition frontier. A partial delta is never presented as complete and never advances a semantic cursor.

## 7. Discovery Agent

The discovery agent reads one sealed account delta and the existing open todos for that account.

Execution order:

1. Apply deterministic filters for noise, already-completed threads, duplicate source ids, and existing dedupe keys.
2. Resolve hard completion evidence discovered in the same conversation before creating anything new.
3. If no unresolved candidate remains, commit a zero-model-call result.
4. Otherwise make one bounded high-intelligence model call over the candidate batch.
5. Upsert todos with `source_account_id`, `source_account_label`, `source_item_id`, `source_occurred_at`, and a stable dedupe key.
6. Persist evidence and model decision metadata, then settle and advance the discovery cursor.

The model selects and explains; it does not invent source identity or write arbitrary todos.

## 8. Closure Agent

The closure agent reads only open or snoozed todos attached to its account plus the new closure delta.

Execution order:

1. Close from hard same-thread evidence first: a later self-sent Gmail message, later self-authored Slack reply/delivery, or another canonical provider completion signal.
2. Remove deterministically settled todos from the model batch.
3. Skip the model entirely when no ambiguous candidate remains.
4. Use one bounded model call for the remaining candidates, requiring an exact evidence item and quote.
5. Mark done through `Todos.mark_done/3`, preserving resolution reason and evidence lineage.
6. Treat acknowledgements and weak similarity as still open.
7. Advance the closure cursor only after every accepted close is durable.

## 9. Chief of Staff Role After Cutover

The per-user `AIChiefOfStaff` remains a `gen_statem` and becomes the attention coordinator:

- reads current todos and recent account-worker summaries
- ranks and deduplicates across sources
- prepares the brief and interruption plan
- performs a bounded deep reconciliation periodically
- does not fetch Gmail or Slack again on ordinary scheduled cycles

Reactive ingress may nudge the Chief after source workers settle, but never before their todo/result transaction is durable.

## 10. Efficiency Budgets

| Budget | Target |
|---|---|
| recurring discovery interval | 1 minute anti-entropy |
| webhook-to-account-job enqueue | under 2 seconds |
| empty delta model calls | 0 |
| discovery model calls per non-empty account batch | at most 1 |
| closure model calls per ambiguous account batch | at most 1 |
| prompt input | bounded candidate excerpts only |
| provider concurrency | bounded by provider family and durable cooldown |
| account failure blast radius | one account partition |

High intelligence is the default for the one call that remains. Cheapness comes from delta selection, deterministic gates, batching, and zero-call quiet cycles—not from lowering decision quality.

## 11. Failure Handling

| Failure | Required behavior |
|---|---|
| provider 429 | durable `retry_after`, provider-family cooldown, cursor unchanged |
| one mailbox auth failure | flag only that account; other accounts continue |
| partial pagination | seal incomplete, retry from start frontier |
| model timeout | retry model job without provider re-fetch |
| ambiguous exact outcome | fail closed; do not advance cursor |
| duplicate webhook and sweep | active-job dedupe plus idempotent result/todo keys |
| worker crash after todo write | settlement transaction determines whether cursor moved; replay is idempotent |
| account disconnected | stop new work and leave historical todo evidence intact |

## 12. Observability

Each account cycle emits safe scalar telemetry:

- account fingerprint and provider family
- role and cursor-lag seconds
- delta item and candidate counts
- deterministic decisions and model-call count
- todos created, updated, closed, or held open
- provider latency, model latency, and total latency
- retry/cooldown/failure code

Activity shows logical account-worker runs using account labels, but never message bodies, tokens, raw prompts, or provider error payloads.

## 13. Rollout

1. Make existing consumers bundle-first and eliminate duplicate connector fetches.
2. Add explicit live/configured source-scope intersection so one worker can address exactly one account.
3. Add account discovery and closure cursor kinds and account-filtered todo queries.
4. Add provider acquisition jobs and sealed deltas in shadow mode.
5. Add discovery reasoning for one Gmail account, then all Gmail accounts, then Slack workspaces.
6. Add paired closure reasoning with conservative evidence thresholds.
7. Switch ordinary Chief cycles to persisted-results mode; retain deep reconciliation as a safety net.
8. Remove legacy broad fetches only after cursor lag, todo parity, and auto-close precision remain healthy in production.

### 13.1 Current implementation checkpoint

Implemented as of 2026-08-30:

- Gmail and Slack consumers treat a supplied source bundle, including an empty bundle, as authoritative and do not fetch the provider twice.
- Live source scope can be intersected down to one connected Gmail account or one canonical Slack workspace.
- New todos resolve exact `source_account_id` lineage and discovery/closure cursors are independent and monotonic.
- Closure jobs fan out by account on ingress and on the configured 30-minute anti-entropy cadence, using the closure cursor with a zero-model quiet path.
- One-minute discovery jobs fan out in `runtime_provider_account`, acquire only the discovery delta, and seal non-empty bounded bundles in encrypted durable payloads for `runtime_model_user`.
- Discovery reasoning uses the existing Follow-through intelligence path, makes at most one todo-triage model call, defers secondary relationship learning, and advances only after the reasoning job settles its writes.
- Gmail incremental-sync completion and Slack message/mention ingress wake the exact account immediately; active-job dedupe collapses bursts and the one-minute schedule remains anti-entropy.
- Closure acquisition now runs in `runtime_provider_account`; empty deltas advance with zero model calls, while non-empty bounded deltas are sealed for account-scoped completion reasoning in `runtime_model_user`.
- Closure cursors advance only after the model-side completion pass settles. The previous direct model job remains executable during revision drain, but no new work is scheduled through it.
- Account discovery inherits an enabled Chief's Follow-through configuration when present. If a user has no Chief row, the cheap account assignment still runs with safe default Follow-through intelligence; an explicitly paused or unavailable Chief remains respected.

Still required for cutover:

- prove production parity, then stop ordinary Chief cycles from repeating Gmail/Slack acquisition

## 14. Verification

- A user with two Gmail accounts and one Slack workspace produces three independent acquisition assignments and three independent discovery/closure identities.
- One account failure does not block the other two.
- The second quiet pass fetches from the prior frontier and makes zero model calls.
- A crash before settlement replays the same delta and creates no duplicate todo.
- A later self reply closes the linked todo; an acknowledgement does not.
- Gmail and Slack follow-through consume the shared bundle and perform no duplicate provider scan.
- Recurring rows keep advancing, exact task outcomes have matching evidence, and no account job remains stuck in termination request.

## 15. Definition of Done

- Ordinary Gmail and Slack discovery is account-partitioned and delta-only.
- Every supported account has an independent closure path.
- Empty deltas cost zero model calls.
- Todo writes and closure writes carry exact account/source lineage.
- Cursors advance only with durable accepted outcomes.
- The Chief of Staff ranks and briefs from persisted results instead of repeating provider acquisition.
- Production telemetry proves bounded latency, low duplicate work, and conservative close precision.
