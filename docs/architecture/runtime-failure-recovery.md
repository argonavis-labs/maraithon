# Runtime failure recovery

The runtime keeps accepted work and action identity through a restart. It refuses stale writes and checks uncertain provider outcomes before retrying a mutation. This slice is verified by controlled failure tests and a production rollout with accepted work waiting in the queue.

## Failure matrix

| Boundary | Failure exercised | Required result | Evidence |
| --- | --- | --- | --- |
| Model entry | Response lost before it can be saved | Original call budget and elapsed time stay charged after restart | `continuation_test.exs`: model entry, lost response and deadline cases |
| Model decision | Restart after saving a final decision | Finish delivery without another model call | `continuation_test.exs`: saved final decision |
| Tool batch | Worker stops after one tool receipt | Reuse the receipt and finish only the missing work | `continuation_test.exs`: partial native batch |
| Tool process | Owning process dies during execution | Its in-flight child tasks terminate | `runner_test.exs`: killed run owner |
| Mutation entry | Gmail returns 503, loses its response, or succeeds before local persistence fails | Preserve an unknown outcome; do not send again without evidence | `action_reconciliation_test.exs` and `prepared_action_state_test.exs` |
| Provider recovery | Mailbox is unavailable, then exact Sent evidence appears | Keep the current owner until proof arrives; settle one execution | Production meeting scenario across two separate maintenance processes |
| Provider identity | Wrong account, MIME, calendar fields or browser scope | Reject mismatched evidence and keep the action uncertain | `action_reconciliation_test.exs` |
| Delivery | Only a prefix of a todo digest is persisted | Resume the missing suffix and produce one terminal response | `runner_test.exs`: partial digest |
| Ownership | Node/task lease expires or a stale worker tries to commit | Reject the write; preserve the database fence | 27 `authority_test.exs` cases and stale continuation/reconciliation cases |
| Reservation | Owner dies before physical activation; reserve commit is unknown | Prove termination or locked absence before admitting replacement work | `authority_test.exs`: reservation, supervisor restart and commit-unknown cases |
| Ordering | Duplicate confirmation, late receipt, stale edit or conflicting workflow revision | One action settlement; no rollback of the current owner | Prepared-action races and four outcome workflow scenarios |
| Verification cache | Expiry races, invalidation during verification, independent-key publication | One valid proof per key; never reuse an invalidated or failed proof | Six cache tests pass |
| Deployment | Request accepted before the old revision drains | Replacement executes the original run and emits one terminal response | Run `38e02fbc-ec60-4494-9b85-836c4ba1d510`, release `maraithon-00286-wq4` |
| Duplicate ingress | Resubmit every workload request with the same client ID | Same run, one user turn, one task assignment and one terminal response | All 18 production workload requests |

The combined continuation, runner, prepared-action, reconciliation, authority, outcome and model-accounting cohort passed 112 tests. The six cache tests also passed. A final 12-test continuation run additionally verifies that an oversized model decision leaves the previous resumable checkpoint intact. The broader source closure and evidence cohort passed 26 tests and exposed the Gmail millisecond timestamp fix deployed in `56ef99ac`.

The deployment-spanning request waited 87.95 seconds in the queue and finished 108.82 seconds after durable acceptance. It executed on the replacement revision with one settled assignment and matching outcome evidence. Once the backlog cleared, median queue wait was 1.17 seconds across 11 requests. All 64 partitions returned to ready and recurring schedules advanced. No manual ownership change or termination attestation was needed.

The production rollout exercised queued accepted work. Mid-tool crashes and provider failures were controlled tests; no real email or calendar action was deliberately interrupted. The persisted meeting scenario used synthetic participants and provider receipts. It does not claim a real meeting took place.

See [workload receipts](evidence/runtime-workload-receipts-2026-09-08.json), [local verification](evidence/runtime-failure-recovery-local-2026-09-08.json), [meeting outcome](evidence/meeting-outcome-2026-09-08.json) and the [hardening checklist](runtime-hardening-checklist.md).

Cleanup exercised the real central privacy-erasure adapter and found incorrectly encoded UUID parameters plus missing per-table purge context. Commits `e1887fc2` and `4d41cbaf` fix those boundaries and pass 11 erasure and race tests. A second production check showed that terminal background jobs must be removed by the central deletion phase after draining, because their user fence rejects an intermediate payload update. The integration case includes a conversation, completed run, executed action and background job. The database still checks the central claim, terminal authority and allowed payload changes. See [erasure recovery evidence](evidence/runtime-fixture-erasure-2026-09-08.json).

The final audit, `maraithon-todo-validation-htq8t`, confirmed both fixture users were absent and both erasure requests completed on `maraithon-00289-q2f`. All 64 partitions were ready with live leases and the new Agent recovered. The effect receipts and checkpoint history in that audit retain their actual timestamps and executing revisions; they are observations from the preceding releases. The synthetic connected account had no live credentials and retained an unverified remote-revocation result, separately from its successful local erasure.

A broader diagnostic run also encountered five unrelated failures in dormant legacy privacy tests. Their old backfill authority, ciphertext-fixture and legacy retention-mode assumptions are recorded in the erasure evidence. Those tests remain unchanged. This completion record does not claim the entire historical migration suite passes.
