# Resuming todo work after a restart

September 8, 2026. Slice 1 of the runtime hardening checklist.

A conversation can now recover between tool steps. If a people lookup finishes and a second lookup is interrupted, the next owner loads the first result and finishes the second lookup. It keeps the same request, run, source turn and reply identity.

## What is saved

The existing encrypted, bound Run summary holds a versioned checkpoint capped at 64 KB. It contains the exact source identity, model profile, deadline, counters and current public model decision. Tool results stay in the encrypted Step ledger. Recovery rebuilds public tool history from those receipts, bounded to 24 steps.

The phases are `ready`, `model_entered` and `decision`. A model call consumes its turn and reserves its step sequence before provider entry. A public decision is saved before tools execute. Losing a model response can require another model call, but cannot reset the call budget. The original wall-clock deadline includes restart and queue delays. An already saved final decision can still drain after that deadline.

Native tool call IDs remain attached to the saved decision and tool receipts. On recovery, the next model request starts from public tool history with no partial native exchange. Provider-private reasoning is never part of the checkpoint. In-process execution retains the existing native adapter.

Escalation to the reasoning model now continues the same mobile-surface run and saved history. It grants the reasoning tier's bounded limits once and keeps calls already spent. It cannot create a fresh loop that repeats completed work. The same mobile surface serves web, Mac and iPhone conversations.

## Ownership and uncertain actions

Parallel tool tasks inherit their parent's immutable job authority explicitly. Checkpoint and Step writes verify that authority and the current job claim in the write transaction. Provider work remains outside those transactions. Linked tasks still die with their owner, and the existing scheduler requires termination proof before assigning a retry.

A completed tool receipt is reused only if its run, sequence, tool, arguments and call ID match. An interrupted read may run again under the existing bounded job retry policy. A mutating tool with no confirmed receipt pauses for review, including a dropped response reported as a network error. It is not presented to the model as a clean failure that invites another write. Provider reconciliation for that uncertainty is slice 2.

Preflight can restart only when the run explicitly records model preparation and has no model or action entry. This does not treat an interrupted deterministic action as an unstarted model request. Unsupported checkpoint versions, invalid shapes, missing receipts and changed identities fail closed.

## Verification

The focused suite exercises a process kill halfway through a native tool batch, saved final delivery after a deadline, a lost model response, expired tool execution, unknown mutation outcomes, stale-worker receipt writes, same-run model escalation and invalid checkpoint identity/version. It also runs the existing delivery recovery suite and concurrent cache invalidation/publication checks.

All 24 focused tests passed. The server also compiled with warnings treated as errors. This slice does not establish exactly-once external effects, the full failure matrix, sustained efficiency measurements or a completed meeting scenario. Those remain explicit items in the [five-slice checklist](runtime-hardening-checklist.md).

## Production evidence

Commit `7c2dae52` deployed as `maraithon-00284-db9`, serving 100% of traffic. Cloud Build `c30c296e-2a00-4e66-8b39-122aba91f084` succeeded. No migration or native rebuild was needed. The changes are synced into `~/bliss/maraithon`, preserving unrelated edits.

The production request was accepted with HTTP 202 in 3.199 seconds. Run `9926ed40-cec6-43ea-a031-22bee94a725b` completed with two model calls and one saved `list_todos` result. Its single task assignment settled with durable outcome evidence and no retry. The existing todo-digest formatter produced three assistant turns. This is evidence of a completed multi-part delivery, not a claim of one reply or a production process-kill exercise.

Read-only Cloud Run execution `maraithon-todo-validation-v2k4g` confirmed the exact run/source/job binding and all six completed steps. It found all 64 partitions ready. A separate runtime snapshot reported one Agent lease and one open, unproven task; the limited snapshot does not establish full runtime health. The [release receipt](evidence/runtime-continuations-2026-09-08.json) records the checks and their limits.
