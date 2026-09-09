# Runtime efficiency

The efficiency slice is verified for Maraithon's current single-user workload. Eighteen read-only requests ran for 13 minutes while normal discovery continued and a production deployment replaced the serving process. Every request completed. Every duplicate submission reused its original run.

## Measured results

| Measurement | Result |
| --- | --- |
| Request acceptance before routing fix | 3.14 seconds median, 4 requests |
| Request acceptance after routing fix | 0.62 seconds median, 0.85 seconds maximum, 14 requests |
| Duplicate acceptance after routing fix | 0.41 seconds median |
| Queue wait after rollout backlog cleared | 1.17 seconds median, 3.42 seconds maximum, 11 requests |
| Execution after rollout backlog cleared | 13.92 seconds median, 22.02 seconds maximum |
| Request accepted across deployment | 87.95 seconds queued, 108.82 seconds from acceptance to completion |
| Instrumented workload model use | 30 calls across 15 requests, 721,470 input tokens, 3,719 output tokens |
| Provider-reported workload cost | US$1.11955324 total, about 7.5 cents per covered request |
| Cached input tokens | 355,776 |
| Fifty unchanged-context reviews | Zero model calls, zero writes, 150 read queries |
| Unchanged-review query time | 464.9 milliseconds total for all 50 reviews |
| Retained Agent checkpoint | 80,720 ciphertext bytes at final audit, below the 1 MiB limit |

The first three workload requests ran before per-attempt instrumentation was deployed. They are excluded from cost totals. The initial request that crossed the rollout executed entirely on the instrumented replacement. Todo digests can contain item replies before their single terminal response. The audit checks one user turn, one task assignment and one terminal response per request.

## Database load

Both samples contain 13 snapshots across 12 minutes and 520 complete log chunks. Neither sample reset or evicted PostgreSQL statistics. Repeated visible query IDs and redacted IDs are summed by role and category before taking deltas. This corrects an initial parser that overwrote some redacted rows.

| Window | Statement calls | Aggregate statement time | Storage verification |
| --- | --- | --- | --- |
| Organic production baseline | 157,552 | 65.47 seconds | 3.15 seconds, 4.81% |
| Representative workload including rollout | 171,330 | 106.47 seconds | 4.16 seconds, 3.91% |
| After rollout, final nine minutes | 126,747 | 67.89 seconds | 2.86 seconds, 4.22% |

Aggregate statement time is not CPU utilisation. PostgreSQL can count nested statements at more than one level, and the measurement queries contributed 4.18 seconds during the loaded window. These are mixed production windows, not an isolated before/after benchmark. Ownership locks cost more during deployment. The existing leases and transaction fences remain enabled.

One-minute samples observed at most three running task assignments during the measured load, one or two active database sessions including the collector, and no lingering termination-requested assignment. All 64 partitions recovered by the third sample. Every schedule due during the window advanced; daily and longer-interval schedules retained valid future due times. Samples cannot prove the peak between observations. Local authority tests cover bounded concurrency, independent source lanes, ordered work within one account and fair admission under backlog.

## Changes kept

Acceptance no longer runs a provider routing classifier. New, duplicate and conflicting acceptance make no model calls. Execution routes once. This change shipped with `57190f5a` as `maraithon-00286-wq4` and the production workload measured its effect.

OpenRouter attempts now retain reported tokens and cost even when response validation fails. The loaded window includes two failed background attempts with US$0.0157524 of reported cost. They remain in the accounting. Provider-reported cost and a static estimate use separate fields; absent usage remains unknown. Streaming records the final usage chunk once. Each assistant run carries a bounded correlation ID. This adds no database writes or polling. The contract follows [OpenRouter usage accounting](https://openrouter.ai/docs/cookbook/administration/usage-accounting).

The source checks also exposed raw Gmail timestamps being treated as missing evidence. Review now accepts millisecond integers, millisecond strings and normalized ISO dates. All three formats invoked review and kept the controlled todo open in the deployed validation job. That fix shipped with `56ef99ac` as `maraithon-00287-rcz`. Gmail's timestamp unit is documented in the [messages resource](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users.messages).

Continuation state is bounded at 64,000 bytes and removed after terminal completion. Completed-run receipts therefore do not measure its peak size. Controlled tests cover oversized or invalid checkpoints, replay budgets and lost model responses. Agent checkpoint persistence is separately capped at 1 MiB and retains ten snapshots.

This verifies the intended single-user workload and failure boundaries. It does not establish capacity for many tenants or saturation traffic.

Evidence: [baseline](evidence/runtime-efficiency-baseline-2026-09-08.json), [loaded database sample](evidence/runtime-efficiency-loaded-2026-09-08.json), [workload receipts](evidence/runtime-workload-receipts-2026-09-08.json), [model usage](evidence/runtime-model-usage-2026-09-08.json), [idle review](evidence/runtime-idle-review-2026-09-08.json), and [deployed health and Gmail formats](evidence/runtime-final-health-2026-09-08.json).
