# Hardened AI todo runtime: five core slices

Requested September 8, 2026. This checklist tracks the full goal through implementation, deployment and verification. A checked item needs evidence against its acceptance criteria. ReqLLM is optional. Jido remains experimental.

Kent explicitly requested building, deploying and verifying every slice, including failure exercises. Targeted automated tests and controlled failure scenarios are authorised for this work. The normal production deployment path remains `make deploy`; existing ownership, privacy, approval and payload guards stay enabled.

## 1. Resume midway through work

Status: complete. Implemented in `7c2dae52`, deployed as `maraithon-00284-db9`, and verified by 24 focused tests plus a production tool request and ownership audit. See [continuation evidence](evidence/runtime-continuations-2026-09-08.json).

- [x] Persist bounded model/tool continuation and exact source identity.
- [x] Reuse completed tool receipts after restart without repeating their work.
- [x] Recover partial batches while keeping native tool call/result IDs consistent.
- [x] Preserve tool and model budgets across attempts; reject corrupt or incompatible checkpoints.
- [x] Fence checkpoint and receipt writes with the executing job's authority.
- [x] Verify restart recovery, then deploy and record a live receipt.

## 2. Reconcile uncertain actions

Status: complete. Implemented in `3e508610`, deployed as `maraithon-00285-t2f`, and verified by 48 focused tests plus a real queued observation of a controlled browser receipt. No external mutation was dispatched. See [production evidence](evidence/action-reconciliation-2026-09-08.json). See [action reconciliation](action-reconciliation.md).

- [x] Give approved external actions durable execution identities and distinguish intent, provider entry, confirmed result and unknown outcome.
- [x] Reconcile email, calendar and browser outcomes using provider evidence before retrying.
- [x] Retry only when provider semantics or evidence establish that it is safe. Unknown outcomes remain visible and reviewable.
- [x] Apply the todo handoff once after confirmed success, including recovery after a lost acknowledgement.
- [x] Verify dropped responses and partial commits at each relevant boundary, then deploy and record evidence.

## 3. Prove failure recovery

Status: complete. The 112-test combined cohort and six cache tests pass. Production accepted work across a normal rolling deployment, then completed the original run on the replacement with one assignment and one terminal response. All 18 workload requests and duplicate submissions passed their durable receipt audit. The final release is `maraithon-00289-q2f` (`4d41cbaf`), including the erasure repair discovered during fixture cleanup. See the [failure matrix](runtime-failure-recovery.md), [workload health evidence](evidence/runtime-final-health-2026-09-08.json) and [final release audit](evidence/runtime-fixture-erasure-2026-09-08.json).

- [x] Exercise crashes before and after checkpoint, tool and delivery commits.
- [x] Exercise expired ownership, stale workers, duplicate requests and reordered acknowledgements.
- [x] Exercise disconnected providers and recovery after they return.
- [x] Exercise deployment during accepted work, preserving action and response identities.
- [x] Verify cache invalidation races and independent-key publication.
- [x] Record the exact failure matrix and results for the deployed implementation.

## 4. Measure efficiency

Status: complete for the current single-user workload. Two 12-minute database samples, 18 representative requests across a rollout, per-attempt provider cost and 50 unchanged-context reviews are recorded. Acceptance improved from 3.14 seconds to 0.62 seconds median; idle reviews made no model calls or writes. Routing, quota and Gmail evidence fixes are deployed. See [measurements and limits](runtime-efficiency-baseline.md).

- [x] Measure steady-state database statement deltas over multiple cache windows, without resetting production statistics.
- [x] Measure acceptance, queue wait, execution and recovery latency under sustained representative activity.
- [x] Measure model calls and token usage, including retries and unchanged-context reviews.
- [x] Verify bounded concurrency, queue admission, checkpoint size and idle-work cost.
- [x] Fix material bottlenecks revealed by the measurements, deploy changes and repeat the affected measurements.

## 5. Prove complete outcomes

Status: complete. Four local scenarios passed in the 112-test cohort. The production scenario persisted an unknown email outcome in execution `maraithon-todo-validation-56cx4`, then resumed in a separate process on release `maraithon-00286-wq4` (`maraithon-todo-validation-kl8hf`). It recovered from an unavailable mailbox using one synthetic Sent receipt and one execution attempt. Every handoff kept the same goal open until explicit synthetic attendance confirmation. The shared Mac/iPhone model decoded all 11 recorded API projections with matching state and owner labels. See [meeting outcome evidence](evidence/meeting-outcome-2026-09-08.json).

- [x] Exercise a realistic coordination scenario through Kent, Christina, Michael and back to Kent.
- [x] Keep the task open while supporting messages and bookings happen.
- [x] Show the correct owner and next action at every state on the shared client contract.
- [x] Require evidence that the meeting happened before closing the outcome.
- [x] Repeat the scenario across a restart and a provider interruption.
- [x] Record controlled-scenario evidence separately from observations of real user work. Never present simulated participants or evidence as a real meeting.

## Completion record

The baseline is commit `a06bc738`, following the deployed durable conversation slice. Production verification and deployment evidence belongs under `docs/architecture/evidence`. All five slices are implemented, deployed and verified. Final code release: `4d41cbaf`, Cloud Run `maraithon-00289-q2f`, Cloud Build `3f9b74a8-afba-4d19-876d-bd2e18e3e63a`. The controlled meeting scenario used synthetic provider evidence; the load test establishes the current single-user baseline, not multi-tenant capacity. See [fixture cleanup and final health](evidence/runtime-fixture-erasure-2026-09-08.json). The historical migration suite still has separate failures recorded there.
