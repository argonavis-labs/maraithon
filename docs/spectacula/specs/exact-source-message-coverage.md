# Exact Source Message Coverage

Status: In progress
Purpose: Guarantee and prove that every readable Gmail and Slack item in a bounded window receives a durable Chief-of-Staff discovery decision, and every eligible todo receives a durable completion decision, without sacrificing the cheap OTP fan-out model.

## 1. Outcome

For every connected Gmail mailbox and Slack workspace, Maraithon must be able to prove these equalities for a requested `[from, to)` window:

```text
provider-authoritative source items
= durably acquired source item revisions
= terminal discovery decisions

eligible todo revisions
= terminal completion decisions
```

The account workers remain short-lived, partitioned OTP work. Quiet deltas cost no model calls. Deterministic decisions remain cheap. High-intelligence model calls receive small bounded groups, but pagination, batching, and prompt limits must never make the account cursor skip unprocessed work.

## 2. Current gaps

The 2026-08-30 audit found that the current implementation cannot prove full coverage and can permanently omit work:

- Gmail reads one `messages.list` page, treats `nextPageToken` as a safe bounded result, and can advance over later pages.
- Gmail body hydration, behavior scan limits, and handoff compaction can omit messages before cursor advancement.
- the Gmail watch is inbox-only, so sent-only changes depend on anti-entropy polling.
- Slack reads only the first twelve prioritized conversations, one history page, six threads, and one reply page, while individual errors still allow the workspace watermark to advance.
- Slack replies on old thread roots are not reconstructable from a recent `conversations.history` window alone; Events ingress must be durable and anti-entropy must reconcile known changed threads.
- discovery persists positive todo/insight outcomes but no terminal `no_todo` receipt.
- completion considers only bounded todo subsets, then can advance the evidence cursor.
- the account scheduler can repeatedly select the first batch of accounts without a durable rotation cursor.
- Activity shows only the latest row per dedupe key and cannot correlate or count every provider, reasoning, and finalization fan-out.

## 3. Coverage contract

### 3.1 Canonical identities

| Provider | Item identity | Revision identity |
|---|---|---|
| Gmail | connected account + Gmail message id | message id + history/internal-date revision |
| Slack | connected account + team id + channel id + message `ts` | item identity + edit/event timestamp |
| Completion | todo id | todo id + todo revision captured at closure-window start |

Thread roots and replies are individual items. `INBOX` and `SENT` are classifications, not separate identities. Duplicate appearances in searches, histories, thread responses, or mentions collapse to one canonical revision.

### 3.2 Terminal discovery decisions

Every acquired revision has exactly one terminal discovery disposition:

- `todo_created`
- `todo_updated`
- `duplicate`
- `resolved_existing`
- `no_todo`

Each receipt records whether the decision was deterministic or model-assisted, the source-account cycle, background job, and safe scalar timing/count metadata. A fetch failure, timeout, deferred item, or missing body is not terminal and cannot contribute to the numerator.

### 3.3 Terminal completion decisions

Every todo revision eligible for a closure window has exactly one terminal disposition:

- `closed`
- `kept_open`
- `not_applicable`

`deferred`, `fetch_error`, and `model_error` are nonterminal. The closure cursor cannot pass the window until all snapshots are terminal.

## 4. Durable model

The existing exact Chief acquisition tables remain the canonical acquisition manifest:

- `chief_acquisition_runs` owns one source-account window and immutable start frontier.
- `chief_acquisition_pages` proves contiguous provider pagination.
- `chief_source_envelopes` stores each canonical source revision.
- `chief_acquisition_envelopes` relates every item to its page and run.

Add two account-scoped contracts:

### 4.1 `chief_item_decisions`

| Field | Contract |
|---|---|
| `source_envelope_id` | required for discovery receipts |
| `completion_snapshot_id` | required for completion receipts |
| `role` | `discovery` or `completion` |
| `status` | one of the terminal/nonterminal dispositions above |
| `terminal` | true only for accepted numerator states |
| `evaluator` | `rule` or `model` |
| `background_job_id` | exact fan-out execution |
| `cycle_id` | correlation id shared by the account run |
| `decision_key` | stable idempotency digest |
| `metadata` | bounded safe scalar metadata only |

Unique indexes enforce one terminal discovery receipt per envelope revision and one terminal completion receipt per todo snapshot.

### 4.2 `chief_completion_todo_snapshots`

One immutable row per open/snoozed todo revision included at closure-window start. It records account, provider, todo revision digest, evidence window, and cycle id. It contains no copied message body.

## 5. Gmail acquisition

1. Enumerate every `users.messages.list` page for the exact account and bounded query.
2. Fetch every listed message in full. Any point-read failure makes the acquisition incomplete.
3. Preserve labels, direction, message id, thread id, `internalDate`, and safe bounded excerpts.
4. Fetch the full thread for each referenced thread before terminal discovery when the decision needs conversation state. Thread fetch failure is nonterminal.
5. Treat inbox, sent, and replies uniformly as message revisions; sent-only activity is recovered by the one-minute anti-entropy worker even if push does not wake it.
6. Expired history recovery paginates the entire configured bounded window before moving to the mailbox head.
7. Never seal complete or propose a semantic cursor while a Gmail page, message, or required thread is missing.

## 6. Slack acquisition

1. Use the user token where available so public/private channels, DMs, and MPIMs are visible according to granted scopes; fall back to the bot token only with an explicit reduced-scope receipt.
2. Paginate every `conversations.list` page. Do not prioritize away conversations.
3. Paginate every `conversations.history` page for `[from, to)` with an overlap/inclusive boundary, then deduplicate by exact decimal timestamp identity.
4. For every discovered thread root, paginate all `conversations.replies` pages.
5. Persist Events API message/reply/edit ingress before acknowledgement. The anti-entropy worker reconciles changed old-root threads referenced by ingress so a new reply is not hidden behind an old parent timestamp.
6. Any inaccessible conversation, history page, or reply page makes the acquisition incomplete unless the provider proves it is outside the account's granted readable scope.
7. Archived conversations referenced during the window remain part of the manifest when the connected token can still read them.

## 7. Cheap reasoning fan-out

Completed acquisition pages fan out into small decision batches. The default batch is five canonical revisions so existing high-intelligence output bounds cannot silently discard a sixth actionable item.

Each batch:

1. applies deterministic noise, duplicate, existing-todo, and hard-resolution rules;
2. writes terminal rule receipts immediately;
3. sends only unresolved candidates to one high-intelligence model call;
4. writes a terminal positive or `no_todo` receipt for every remaining item;
5. returns actual item count, terminal decision count, todo mutations, and model calls.

A no-model finalizer waits for every expected batch job. It advances the discovery cursor only when acquisition pagination is exhausted and terminal decisions equal source envelopes. Failed or missing children leave the cursor unchanged and allow idempotent replay.

## 8. Completion fan-out

At closure-window start, snapshot every eligible account-scoped todo revision. Fan the snapshots out in small batches without an age exclusion.

Each batch applies hard Gmail/Slack same-thread evidence first, then uses one model call only for ambiguous items. It writes one terminal decision per snapshot. The finalizer advances the closure cursor only when terminal decisions equal snapshots and every required evidence page is complete.

## 9. Scheduler fairness

Recurring discovery and completion use durable account rotation cursors. Selection must advance past the last considered account even when an enqueue fails, while the failure receives its own expected-fan-out/activity record. A fleet larger than the batch size must eventually schedule every eligible account.

## 10. Activity and observability

Activity displays every fan-out execution for the selected window, not only the latest row per stable dedupe key. Provider acquisition, each decision batch, each completion batch, and each finalizer share `cycle_id` and account identity.

Each row exposes only safe scalars:

- provider/account label, role, stage, and batch ordinal/count
- acquired denominator, terminal numerator, and missing count
- actual model-call count
- failure/retry count and safe failure class
- cursor start/end and lag, without message text

Empty deltas and skipped/no-open-todo roles still create an explicit visible terminal execution or expectation receipt.

## 11. Failure and cursor rules

- Any partial provider enumeration, body/thread fetch failure, model failure, missing terminal receipt, or failed child job prevents cursor advancement.
- Replays are idempotent by provider revision and decision key.
- Cursor boundaries overlap; canonical identities deduplicate the overlap.
- Provider 429s use durable cooldown and preserve the start frontier.
- An account failure never blocks other account partitions.
- Payload size is controlled by paging and five-item batches, never by dropping source items.

## 12. Verification

For a production Cloud Run verification job and explicit `[from, to)` window, compare an independently enumerated provider manifest with durable acquisition and decision rows.

| Gate | Required result |
|---|---|
| Gmail provider ids vs envelopes | exact identity equality |
| Slack provider/event ids vs envelopes | exact identity equality |
| discovery terminal receipts vs envelopes | `missing = 0`, no conflicts |
| completion receipts vs eligible snapshots | `missing = 0`, no conflicts |
| incomplete pages/runs | `0` |
| failed/exhausted jobs | `0` |
| expected fan-outs vs Activity executions | exact identity equality |
| cursor frontier | at or beyond `to` only after all prior gates pass |

The verifier emits missing canonical ids and job ids, not only a percentage.

## 13. Rollout

1. Add durable receipts, cycle correlation, and Activity support in shadow mode.
2. Remove Gmail list/body and Slack conversation/history/thread truncation; fail closed on partial acquisition.
3. Add small decision batches and cursor finalizers for discovery.
4. Add exhaustive todo snapshots, completion batches, and closure finalizers.
5. Add durable Slack reply/edit ingress reconciliation.
6. Run a one-day provider-authoritative production reconciliation. Repair every missing identity and rerun until all gates are exact.
7. Enable cursor advancement through the new finalizers and retire the lossy direct path.

## 14. Definition of done

- Every connected Gmail new/sent/reply message in the chosen day is fully fetched and has one terminal discovery receipt.
- Every readable Slack channel, DM, MPIM, root message, and thread reply in the chosen day has one terminal discovery receipt.
- Every eligible open/snoozed todo revision has one terminal completion receipt for the same evidence window.
- No item is dropped to satisfy a list, prompt, result, payload, or time cap.
- Cursor advancement is gated by exact numerator/denominator equality.
- Every expected provider, decision, completion, and finalizer fan-out appears in Activity with actual counts and model calls.
- Production reconciliation reports exact equality, no incomplete acquisitions, no failed work, and healthy exact OTP runtime state.

## 15. Assumptions

- “100%” means every item readable under the scopes of each connected account; inaccessible provider data is outside the denominator but must be reported explicitly.
- The requested bounded verification window is one local calendar day unless the operator supplies exact UTC bounds.
- Provider retention or workspace-plan limits that make older content unavailable are reported as external coverage constraints and cannot be represented as success.
- Plain Spectacula review policy applies; final vetting is off unless explicitly requested later.
