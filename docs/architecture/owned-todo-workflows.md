# Todos track outcomes, states and owners

A todo stays open until its outcome happens. Sending availability, receiving a reply and booking time are steps toward a meeting. They don't prove the meeting happened.

Every state carries an owner, the outcome, the owner's next action, a reason for the change, a revision and an optional waiting review date. Mac, iPhone and web use the same transition API. The AI uses that API too.

Every todo row and detail header makes ownership prominent: **Your move**, **Christina Giannone’s move**, or **Michael Lippi’s move**, beside its work state. Waiting shows **You own follow-up** or names the person who owns it. Closed items retain their last owner without implying that another move is due. List rows pair this with the next action, and the full name remains available for disambiguation. Native labels wrap at narrow widths and expose both owner and state to VoiceOver.

| State | Owner | Meaning |
| --- | --- | --- |
| You own the action | You | Your next move is clear. |
| Working | You or a named person | That owner is actively moving the work forward. |
| Waiting | You or a named person | That owner is accountable while a date or condition is pending. |
| They own the action | A verified person | That person has the next move. |
| Cancelled | Retained owner | The outcome has been abandoned. |
| Done | Retained owner | The actual outcome happened. |

Active states can move between one another when new evidence or a user decision supports the change. Done and Cancelled must reopen to You own the action before work resumes.

For Kent's meeting with Christina and Michael, the intended sequence is:

| Event | State | Owner | Next action |
| --- | --- | --- | --- |
| Start coordinating | Working | Kent | Confirm evenings with Christina. |
| Kent sends the request | They own the action | Christina | Confirm which evenings work. |
| Christina supplies evenings | You own the action | Kent | Send those options to Michael. |
| Kent sends the options | They own the action | Michael | Pick a time. |
| Michael proposes a time | You own the action | Kent | Confirm it. |
| Everyone confirms the booking | Waiting | Kent | Attend the meeting. |
| The meeting actually happens | Done | Kent | Outcome achieved. |

This table is the intended workflow, not a claim that those messages or the meeting have happened.

## Persistence and recovery

`Maraithon.Todos.Workflow` is a pure state machine. PostgreSQL holds `todos.workflow` and the transition journal in `todo_activity_events`. A transaction locks the todo, verifies the expected revision, resolves the owner within the user's People records, and writes the state and journal together. An exact retry of the latest request returns its existing result. Older requests cannot overwrite a later version. A reused request ID with different contents is rejected.

The existing OTP runtime still owns agent execution, leases, deadlines and recovery. There is no process per todo and no second agent scheduler.

A prepared Gmail or Slack send or supported calendar write can include a planned handoff. The plan stays inside the encrypted prepared-action payload. Its preview describes the owner and next move. It becomes eligible only after the existing executor durably records success. The handoff and its applied marker commit together, independently of the send receipt. The per-user completion sweep repairs pending handoffs after a restart without repeating the external action. A small indexed state column selects pending receipts without searching encrypted content.

A newer todo revision supersedes the planned handoff. Editing the outbound action invalidates its old semantic plan and leaves ownership for a fresh review. Opening Messages and running a browser step are not delivery receipts and do not automatically delegate the todo.

The completion sweep also returns due Waiting items to their user for review. Time passing never marks them Done. Cross-source review can advance the state from fresh, quoted evidence, using verified people and the current todo version. It needs explicit outcome evidence to close tracked work. Discovery refreshes cannot replace an explicit outcome or handoff.

## Continuous context review

Each todo should keep moving toward its outcome. The existing one-minute recurring sweep now wakes a bounded review for each user with open work. Successful companion ingests and Google Calendar syncs also request a review, with a 20-second delay to coalesce batches. Gmail and Slack retain their exact account-delta closure workers. All model work shares the existing fair per-user lane.

`Runtime.TodoWorkflowReview` reuses the completion sweep. Every wake repairs eligible action handoffs and brings due Waiting items back to the user. It reads bounded synced context and checks semantic fingerprints before calling the model. The fingerprint includes the todo's outcome, owner, workflow revision, next action, linked people and available evidence. Fetch timestamps and source counts do not count as new evidence. Unchanged inputs require zero model calls. Ordinary idle reviews also avoid rewriting todo check timestamps; only a full 500-item scan rotates unchanged rows to expose its tail. New todos no longer wait for the old 30-minute minimum age.

Google Calendar evidence is reused until its sync cursor or account access changes, or 30 minutes pass. Companion context is read from the synced local-source tables on each wake. Local calendar evidence carries the source event's creation and modification timestamps plus its scheduled start and end. Repeated ingestion does not make an old booking new evidence. This does not make a disconnected phone or Mac sync faster. The review only knows what reached the server.

Successful fingerprints and cached calendar evidence live in the encrypted background-job result. The existing fenced runner commits that result. A complete acquisition failure or incomplete model decisions do not advance the memo. Partial source failures are recorded, while valid evidence from other sources can still move work forward. Each wake retries source acquisition; failed calendar reads are not reused. The worker retries using the existing bounded retry policy, and the recurring sweep supplies another chance after retries are exhausted. A wake received while a review is running may coalesce into that review; the next recurring pass reads the latest context again.

Each pass scans at most 500 open todos and submits at most 40 for model review. Successful decisions, including unchanged inputs, advance the existing rotation so larger lists keep making progress. Prompt limits can reduce a batch further. Unreviewed todos remain eligible for the next pass. These are bounded context reviews, not an exhaustive history scan of every local source.

There is no timer or agent process per todo, no new queue, and no database migration. A fresh quoted reply can change who has the ball. A deadline can ask Kent to review progress. Neither one proves that the meeting happened. External messages and bookings retain their existing approval requirements.

## Compatibility and migration

Existing todos derive their initial state and owner from status, direction and counterparty until their first explicit workflow transition. Their title supplies the provisional outcome. The model and user can refine that outcome with a versioned transition. New workflow data uses the existing status field for older clients: active states map to open, Done to done, and Cancelled to dismissed.

The migration adds a non-null JSON object to todos and a nullable recovery-state field to prepared actions. It checks the protocol catalogs before editing either table, admits only the reviewed schema and index fingerprints, and checks all catalogs again before commit. Runtime role and lease guards remain unchanged. The iPhone model adds one optional Data field for the workflow, allowing the existing SwiftData store to migrate with a nil default.

Fresh linked-todo state travels in the shared resumable progress snapshot. Mac and web refresh the selected todo when its workflow changes. iPhone applies the current snapshot after historical messages and rejects older revisions. Ordinary list sync also carries the workflow.

## Delivery checks

The server compiled with warnings treated as errors. Mac and iPhone builds passed, and the companion Swift package compiled. XcodeGen passed. No application tests were added or run under the repository's manual-first policy.

The schema migration ran successfully as `maraithon-migrate-j7mtp`. The first workflow release served all traffic at `maraithon-00276-x6j`. The stale-handoff and snooze corrections followed in `maraithon-00277-wzh`, image `dev-d69f810e7a9e-20260908194303-1`.

The signed Mac build is installed at `/Users/kent/Applications/Maraithon.app`, with its existing pairing retained. Its outcome header, state editor and People owner picker were inspected in the running app. The iPhone release is **1.0.1 (20260908195700)**. The ownership-label upload succeeded with delivery ID `b3aeb2e7-7ba5-42d8-b7ca-d360412df38c`. App Store Connect reports `VALID` and `IN_BETA_TESTING`. A physical-phone interaction check was not performed.

On the live meeting todo, saving the outcome and owner on the web immediately updated the open Mac workspace through the shared stream. A stale version was rejected with HTTP 409 and did not overwrite the current state. Both surfaces regenerated the meeting brief with Christina and Michael and the correct completion condition: hold the meeting.

A conversational rename exposed missing workflow data in the legacy todo tool serializers. The title changed, but the agent could not read the new revision and its follow-up transition was rejected. The read and update tool projections now return the workflow, and the harness explicitly separates dependent mutations and uses the returned revision. The concurrency check remains intact. After the correction, the live Mac request updated the next action at revision 3 and then moved the same todo to Working at revision 4 with Kent as owner. Run `922052e7-d0e7-4e63-845d-a93c2bca884c` completed. The stored outcome still requires the meeting to happen.

No real message was sent and no event was booked. The prepared-action recovery path was compiled and reviewed; crash recovery after an actual send was not fault-injected in this manual-first slice.


The read-only [runtime receipt](evidence/owned-workflow-runtime-2026-09-08.json) recorded 64 ready partitions with live leases, no assignments awaiting termination, passing privacy and durable checks, and all 120 runtime catalog checks. Recurring jobs had future deadlines. Four completed Effects had matching outcome counts in the sampled 20-minute window. No checkpoint or snapshot-failure events appeared in that window, so this receipt alone is not a complete checkpoint-recovery verification. It was sampled before the final ownership-label UI rollout. Cumulative verification-query cost remains a follow-up item from the earlier slice.


The final ownership-label release is `maraithon-00279-x55`, serving 100% of web traffic with image `dev-60fd1dbbaeca-20260908195455-1` and successful Cloud Build `e8d82b93-cae7-4785-a62e-2d5f3adad4c6`. The live web detail and list were inspected after cutover. They showed “Your move” for Kent, a named person's move on delegated work, and “You own follow-up” on waiting work. The installed Mac displayed the same labels and the live meeting's Working state. No additional schema migration was required for these labels.

The rolling cutover initially left partitions draining while the prior execution ownership cleared. The final runtime status showed only `maraithon-00279-x55` alive, 64 owned and admitting partitions, and zero unready partitions. No lease or termination guard was bypassed.

## Continuous-review delivery checks

The [live review receipt](evidence/continuous-workflow-review-2026-09-08.json) sampled four completed minute-spaced reviews on `maraithon-00280-t9h`. Two consecutive reviews recognized all 33 open todos as unchanged, made zero model calls, reused calendar context, and completed within two seconds of job creation. The meeting todo remained Working at revision 4 with Kent holding the ball. The recurring sweep had its next scheduled run and no current error.

The server compiled with warnings treated as errors. No tests were added or run, and native apps did not need a rebuild. The read-only audit explicitly starts the encryption vault in maintenance mode and uses a Cloud Run execution with `POOL_SIZE=2`. Partial-source and crash recovery behavior was reviewed in code; this slice did not inject provider failures or perform external actions.

The final release is `maraithon-00282-km8`, serving 100% of traffic with image `dev-d8ddc7c26859-20260908213047-1` and successful Cloud Build `59418016-8824-4e9a-8f4c-32bebd1fc169`. The [final receipt](evidence/continuous-workflow-review-final-2026-09-08.json) confirms the calendar cache contains at most 120 provider events plus its coverage summary, with saved results around 60 KB. CRM calendar observations are reread from their source window and do not accumulate in the cache. An unchanged pass again made zero model calls across 33 todos. The live meeting remained Working at revision 4.

The final runtime status listed only the new revision, 64 owned and admitting partitions, and zero unready partitions. The rolling retirement warning cleared through normal ownership recovery. No lease or outcome guard was bypassed. These receipts verify this review path and current admission, not every item in the full runtime-health checklist.
