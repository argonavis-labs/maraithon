# State-machine review against open todos

The six states cover the current open work. The important distinction is what finishes each outcome. Sending a URL can finish a todo. Sending an invoice question cannot establish that a disputed balance was resolved. One prospect replying cannot finish monitoring a whole outreach batch.

The September 8, 2026 review read all 36 open todos through the admin API and checked their stored workflows in Cloud Run execution `maraithon-todo-validation-x69vk`. It found 33 in You own the action, one Working, one They own the action and one Waiting. The meeting is the only item with an explicit stored workflow. The other 35 derive their initial state from the existing status, direction and counterparty, then gain a versioned workflow on their first transition.

## Representative outcomes

These are proposed paths through the actual open work, not claims that any action was performed. An older title is a provisional outcome. When it is ambiguous, the assistant should use the source context and the user's direction to establish the intended result before treating an intermediate reply as completion.

| Open work | How the ball moves | What counts as done |
| --- | --- | --- |
| DOZR overdue balance | Kent works on payment or the dispute. Madison can own the review after receiving a query. Kent regains the ball when she needs a reference or decision. | If the outcome is resolving the balance, a settled payment or an agreed resolution. The current “pay or respond” title needs that scope made explicit. |
| Give Sarah edit access | Kent grants the permission. If acceptance is required, wait for Sarah once her identity is verified. A missing permission returns the ball to Kent. | The requested edit access is active. An invitation alone may be insufficient. |
| Investigate Podlog errors | Kent investigates, works on the fix and waits for recovery evidence. | An investigation-only goal can finish with a supported diagnosis. A service-recovery goal needs evidence that the fault is resolved. Do not silently broaden the former into the latter. |
| Send the requested page URL or movie link | Kent finds it, prepares a reply and sends the requested content. | Confirmed delivery of the requested link. There is no need to wait for an unrelated future conversation. |
| Deliver the draft promised to Kevin | Kent clarifies the exact promise, writes the draft and delivers it. | Delivery of the promised draft, unless the actual request also requires acceptance or another result. |
| Watch outreach replies and schedule meetings for Charlie | Kent owns the monitoring responsibility. Each prospect can have a separate coordination todo with its own owner. The monitoring item returns to Waiting between actionable replies. | The agreed batch or monitoring scope is finished. One reply or booking does not finish the whole responsibility. |
| Staff the Shoppers activation | Kent or a verified staffing lead owns the work. Each filled position is progress. | The specified staffing target is satisfied, or the user explicitly changes or cancels that goal. |
| Follow up with Michele | Michele currently has the next reply. Kent takes the ball when a follow-up is due, then hands it back after confirmed delivery. | A reply can finish an answer-seeking goal. It does not automatically finish fundraising or a later investor decision. |
| Accept the updated security policies | Kent reviews and accepts the required policies; the browser helps perform the work through the existing approval flow. | The portal confirms the required acceptances. Merely opening it is not completion. Three open items overlap here; a state transition does not itself deduplicate them. |

The group-feedback item has no single verified person assigned. Waiting with Kent accountable for follow-up is representable now. The model must resolve a real person before using They own the action. A group label or raw Slack mention is not enough to invent an owner. Likewise, batch work can have one accountable owner while individual obligations live in separate todos. This review does not add parallel owners or an automatic subtask planner.

## Defect found and repaired

The exact Gmail/Slack review combined multiple evidence chunks by retaining only completion and acknowledgment decisions. A valid `completed:false` response with a `workflow_transition` could disappear before the transition handler saw it. The periodic review had a handler for progress, but the account-delta path could discard that progress first.

The combiner now retains a cited intermediate transition. When chunks propose different moves, the newest supporting source timestamp wins. Conflicting plans at the same timestamp leave ownership unchanged. A completion claim missing required outcome confirmation cannot suppress a valid handoff. Existing evidence matching, confidence, account/source boundaries, verified People lookup and workflow revision checks remain active.

The review prompt now explicitly covers payments, access, service recovery, narrow delivery tasks and ongoing or batch work. Its counterparty-reply rule compares the reply to the outcome, not merely the latest next action. The exact-response and empty-response instructions now retain grounded progress decisions too.

## Verification

Nineteen new controlled checks exercise seven non-meeting patterns through both Gmail and Slack, partial progress, final outcome evidence, source ordering, conflicting owners, invalid People IDs and due Waiting reviews. The combined new checks, existing cross-source suite and existing meeting scenarios pass **40 tests with zero failures**. The server compiles with warnings treated as errors.

The checks use synthetic source messages and controlled model responses. They prove transition handling and its boundaries, not a measured accuracy rate for live model judgments. The production preview uses actual open todos in a database-enforced read-only transaction and advances copies in memory. No reviewed todo is reassigned, completed or cancelled by that preview. No real message, payment, permission change or policy acceptance is executed.

Deployment and read-only preview evidence are recorded in [the review receipt](evidence/open-todo-workflow-review-2026-09-08.json).

Commit `1155d25e` is deployed as `maraithon-00290-95f`, serving all traffic after Cloud Build `739e0ea1-f68b-423e-8015-3e5ea717098d`. Production execution `maraithon-todo-validation-f75qd` successfully previewed 30 transitions across eight actual todos inside a repeatable-read, read-only transaction. All eight persisted records remained unchanged in that transaction. The final runtime check reported 64 admitting partitions, zero unready partitions and zero unproven tasks. This change requires no schema migration or native-client update.
