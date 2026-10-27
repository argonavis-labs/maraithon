# Recovering uncertain actions

Maraithon now checks whether an approved email, calendar change or browser command happened after its response was lost. It records success only when it finds matching evidence. A missing result keeps the action uncertain and the todo open.

## Execution and recovery

Confirmation freezes a server-generated action identity, the connected account and the approved payload hash. The same transaction queues one delayed observation job on the existing provider queue. No new supervisor, process per todo or framework is required.

The observer starts after one minute. It makes at most 12 checks, backing off to 15 minutes between checks. Job execution failures have the existing three-attempt limit. Checks use the job's durable result counter, so rescheduling does not reset the observation budget.

An approval with zero execution attempts and no claim can start through the normal atomic claim. This repairs a crash between saving approval and entering the provider. Once an owner has entered, lease expiry never authorises another sender or click. The observer can only read evidence and settle the result. An unknown outcome remains reviewable after observation ends.

All prepared-action writes made by a background job are fenced by its current task assignment and job claim. Provider I/O runs outside database transactions. The result is checked again under the action lock before it is saved. Handoffs use the existing action ID and expected todo revision, so a supporting action neither closes the outcome nor overwrites a later handoff.

## Evidence

| Action | Required evidence |
| --- | --- |
| Gmail send | Exact frozen RFC Message-ID in Sent, one matching result, expected recipient and subject headers, same connected account. |
| Edited Gmail draft | The same identity check. Frozen MIME content and the identity travel in one `drafts.send` request, removing the separate update/send gap. |
| Existing Gmail draft | Captured Message-ID plus a fingerprint of the frozen MIME content. Missing identity or a content mismatch leaves the outcome uncertain. |
| Calendar create | Exact deterministic event ID, Maraithon ownership markers and matching approved title, description and times. Recovery can recognise a booking after its start time. |
| Calendar update | Exact owned event and matching requested fields. |
| Calendar cancel | The exact event is cancelled or absent in the same account. This proves the requested postcondition, not which actor removed it. |
| Browser command | Completed paired-device receipt for the exact action ID, user, todo, operation and arguments. No browser step is repeated to infer success. |

Positive reconciliation stores a small encrypted receipt with provider IDs, observation time and the approved payload hash. It does not copy mailbox bodies or browser snapshots into the receipt.

Gmail's API supports [replacing draft content in the send request](https://developers.google.com/workspace/gmail/api/guides/drafts). [Message search](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/messages/list) supports the RFC Message-ID lookup. Search absence is not proof that a message was never sent.

## Limits and verification

The observation identity applies to newly confirmed actions. Legacy unknown actions without it stay reviewable. Attachments or provider normalisation can prevent an existing draft fingerprint from matching; this causes a conservative unknown result. This does not provide exactly-once guarantees for arbitrary browser side effects without a device receipt.

Focused tests cover lost responses, duplicate or missing search results, changed draft content, changed accounts, tampered approvals, calendar recovery, browser command mismatch, active and expired senders, unentered approval recovery, stale task authority and a handoff applied once. The prepared-action fixtures now use valid envelope bindings when exercising the separate approval hash. Failure injectors use test-session DDL authority, then return to the runtime role before exercising application code.

Implemented in `3e508610`, deployed as `maraithon-00285-t2f`, and verified by 48 focused tests plus a controlled production observation. The real provider queue settled an uncertain browser action from its saved receipt with one execution attempt, one observation and matching task outcome evidence. The todo stayed open. The browser receipt was synthetic; no external action was dispatched. See [recorded evidence](evidence/action-reconciliation-2026-09-08.json). See the [five-slice checklist](runtime-hardening-checklist.md).
