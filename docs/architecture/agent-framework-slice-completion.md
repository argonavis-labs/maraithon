# Agent framework slice: delivery receipt

September 8, 2026

The shared progress stream is deployed. The Mac app is installed, and the final iPhone build has uploaded successfully to App Store Connect. The [framework report](agent-framework-slice.md) records the 24-run comparison and the decision to keep the existing OTP ownership model.

## Server

- Initial stream rollout revision: `maraithon-00272-9cl`, which served 100% of traffic at this checkpoint. Later releases are recorded in [native todo tools](native-todo-tools.md) and [owned todo workflows](owned-todo-workflows.md).
- Image: `us-central1-docker.pkg.dev/maraithon/maraithon/maraithon:dev-18f7b9aed7fd-20260908182054-1`.
- Cloud Build: `255c79be-c2ba-45b8-85c0-0627093451a5`, successful.
- Migration execution: `maraithon-migrate-5kj69`, successful.
- The initial rollout found an earlier People Network migration missing its durable-catalog registration. The narrowly scoped forward migration passed every protocol readiness check before committing. The final server passed its startup guard.

Live checks against an existing, authorized todo conversation:

| Check | Observed result |
| --- | --- |
| Initial stream | HTTP 200, `text/event-stream`, schema 1, matching payload and event cursors |
| Reconnect with the current cursor and uppercase native UUID | HTTP 200, `: resumed` |
| Reconnect with a stale cursor | HTTP 200, current snapshot |
| No authentication | HTTP 401 |
| One bounded assistant reply from Mac | Stream moved from one message to two with a running run, then three with no active run |
| Completed conversation | Same reply visible on Mac and web; todo remained open |
| Second reply started from web | Both surfaces displayed active progress and then “Progress is connected.” without a refresh |

The initial, resume and stale-cursor responses took 279 ms, 247 ms and 264 ms respectively in this one manual check. These are receipts, not a latency benchmark. No action approval was submitted and no email, calendar event or external message was sent during verification.

The read-only Cloud Run execution `maraithon-todo-validation-7vhlx` recorded 64 ready partitions with live leases, zero assignments awaiting termination, passing durable and privacy catalog checks, and all 120 runtime catalog checks. Recurring jobs had future deadlines, including the brief notifier and daily digest. The Chief of Staff logged recovery, four completed Effects and two checkpoints; four completed Effect outcome records were present, with no `snapshot_persist_failed` event in the sampled 20-minute window. The [runtime receipt](evidence/agent-runtime-receipt-2026-09-08.json) contains the counts and schedule deadlines.

The fast deploy's immediate retirement call returned 409 after cutover. Its later status showed only the new Cloud Run revision alive and zero unready partitions. The statement statistics in the receipt are cumulative: verification accounts for about 34% of recorded execution time. That is a historical signal for follow-up, not a measurement of this release's steady-state cost.

## Native delivery

The signed Mac app is installed at `/Users/kent/Applications/Maraithon.app`. Its existing account pairing and signing identity were preserved. The todo workspace loaded its conversation and displayed the completed assistant reply through the new observation path.

The final iPhone release is **1.0.1 (20260908183200)**, bundle `com.bliss.maraithonmobile`. The upload succeeded with delivery ID `c77b6fa7-3670-47eb-936a-33431c430eb6` at 18:33 UTC. The final build subsequently reached `VALID` and `IN_BETA_TESTING`, verified through App Store Connect. This was the stream-slice build; the newer [owned-workflow release](owned-todo-workflows.md) supersedes it.

The final signed archive and simulator build succeeded. The final native change preserves failure explanations by reading a run's terminal result once its pending marker disappears, retaining the run ID for retry if that read fails. XcodeGen passed. Failure injection and a check on Kent's physical phone were not performed in this slice.

## Workspace and validation

The implementation is on branch `codex/todo-agent-streams` in an isolated worktree and has also been copied into `/Users/kent/bliss/maraithon`. Existing uncommitted work was preserved. Commit `7289444f` captures that preexisting baseline; the implementation diff starts after it. Main was not committed or pushed.

The server compiled with warnings treated as errors, both native apps built, and the requested 24-run model comparison completed. No application test suites were added or run, following the repository's manual-first policy.

The experiment uses existing Google Secret Manager credentials and an isolated, pinned Elixir dependency graph. No new hosted account, database or recurring worker was provisioned. Production dependencies and model routing remain unchanged.
