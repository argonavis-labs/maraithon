# Delegated conversation implementation status

Updated September 15, 2026. The Gmail information and regular calendar paths have passed controlled live evals. The conflict rerun exposed a booking approval bug. Its correction and rich mailbox signatures are deployed in revision `maraithon-00353-79v`; the new conflict eval is in progress. October is connected and configured as the assistant. The full [execution plan](delegated-conversation-execution-plan.md) is not complete.

## Verified

- A real information conversation between `kent@runner.now` and `kent.fenwick@gmail.com` reached Done with the counterparty reply as evidence. Two turns used four Muse calls and cost US$0.001421. [Live evidence](evidence/delegated-conversations/2026-09-15-live-information.json).
- Lost Gmail send responses are reconciled through an exact provider receipt or the original Message-ID inside the frozen thread. Ambiguous delivery holds; it does not resend.
- Web, Mac, and iPhone share delegation controls and scope previews. Charlie-owned work appears under Tracking. The iPhone release workflow passed. The signed Mac app was installed locally, including recovery from a temporary server failure without new pairing.
- A local accelerated eval covered 180 days and 720 quiet wakes with no idle model calls or sends, then admitted one turn for a duplicated late reply. This does not prove a six-month production run, schema upgrades, or whole-app disaster recovery. [Evidence](evidence/delegated-conversations/2026-09-15-longevity-and-native.json).
- A production sample found all 64 partitions ready with live leases, no termination requests, advancing recurring schedules, and completed effects with matching durable outcome evidence. [Runtime evidence](evidence/delegated-conversations/2026-09-15-runtime-followup.json).
- The cost warning checks every six hours and emails `kent.fenwick@gmail.com` above US$6 against the US$3/day projection. The measured 24-hour workload cost US$4.11, about 95% below the old US$87/day baseline. It still exceeds the projection. [Cost evidence](evidence/delegated-conversations/2026-09-15-cost-followup.json).

## Calendar correction and rerun

The first calendar eval sent options and received acceptance, then stopped on a model rate limit. It did not book a meeting. Its email also used assistant wording for the as-user actor, labelled UTC timestamps as Toronto time, and offered tomorrow when the source asked for next week. [Failed-run evidence](evidence/delegated-conversations/2026-09-15-calendar-first-attempt.json).

Commit `ca42e23d` moves the model reservation behind local admission. A local cooldown now schedules an automatic retry using fresh sources, without reserving spend or consuming a model call. Provider-entered failures still retain unknown spend. Offers must use computed local-time labels; the slot list covers later days, and the policy checks actor and requested dates. The live fixture reads the actual recipient email and checks those properties before accepting a time. The server build passed; focused admission, scheduling, policy, receipt, and eval checks passed.

This change deployed successfully in workflow `34993948938`, revision `maraithon-00342-w6c`. The new scheduling eval job is `0e78ba4e-935f-406d-bebb-fa7d9c008234`. It passed: one accepted meeting, verified recipient calendar copy, Waiting todo state, completed cleanup, four calls, and US$0.002783. [Live calendar evidence](evidence/delegated-conversations/2026-09-15-live-calendar.json). The busy-slot conflict scenario must also pass before scheduling is considered verified.

## Conversation workspace correction

Delegated todos now suppress ordinary automatic briefs, primer drafts, and suggested actions across web, Mac, and iPhone. The conversation ledger remains the source of progress. Opening a delegated todo does not enqueue another brief or prepare a separate send. Existing brief content remains stored as history.

The server, signed Mac, and iPhone simulator builds passed. The focused ingress and brief run passed 39 checks. Older brief fixtures now supply the required summary and involvement fields; the lease check confirms that force cannot replace a live generation, and the draft check confirms that stale wording is preserved in storage but hidden from the current projection. The server deployed in workflow `34996287013`. The signed Mac update is installed and visually verified. The iPhone release passed in workflow `34996808880`.

Production web verification found a conditional LiveComponent root that crashed the workspace. Commit `553b59a0` fixes the root and adds the missing last-action line. Its focused workspace check and server build passed. Workflow `34997627342` deployed revision `maraithon-00345-lnn`. The authenticated page now shows Completed, As you, and Booked the agreed meeting, with no competing brief or draft action.

## Assistant account isolation

Commit `ce5a1233` binds OAuth initiation and callbacks to the authenticated user. Assistant setup no longer fails because its link omitted a user ID, and a signed callback cannot attach credentials to a different user.

Commit `6fa6f93a` carries the assistant purpose in signed Google OAuth state and marks the connected account before checking its sending address or creating an identity. Pending setup, reconnects, and previous assistant accounts remain excluded from personal discovery, Gmail and voice reads, user identity, and CRM ingestion. Existing personal accounts cannot be silently converted through the assistant connection link. Cached user identities consult the current exclusion before returning handles. Ordinary Gmail ingestion still routes delegated replies.

The focused isolation, scope, Gmail, ingress, and OAuth run passed 46 checks. Seven identity checks passed after the final primary-address validation. The server build passed. Workflow `34998552598` deployed this change. Calendar and travel fallback reads use the same exclusion in commit `0d865e4b`; its seven identity checks and server build passed. That change reached production in revision `maraithon-00347-7nx`, although its deployment workflow reported failure during temporary health-check 503s. Both serving URLs subsequently returned HTTP 200.

Commit `fa9574b6` appends the frozen signature in server code and gives the independent policy review the exact resulting email body. It respects the saved assistant disclosure, converts Gmail's HTML signature to plain text, and avoids appending the same footer twice. The source mailbox's verified email is also excluded when deriving an assistant conversation's counterparties. The focused identity, policy, and ingress run passed 50 checks, and the server build passed. Workflow `35000512614` successfully deployed revision `maraithon-00348-8dc`.

Commit `6411d152` closes the lower-level Gmail API fallback: ordinary tools exclude assistant mailboxes; identity setup and delivery reconciliation read only the exact account already bound to that operation. The focused identity and reconciliation run passed 22 checks, with seven identity checks passing after the final exact-provider correction.

Commit `bb66b0dd` excludes assistant accounts from personal chat context, user-memory source inventory, connector prerequisites, and source-health reads. It also fixes an invalid dynamic expression in the shared exclusion query. Ten focused identity and connector checks passed. The connector fixtures now use current tool names instead of removed dotted aliases. The ordinary test database hit a pre-existing catalog mismatch before tests ran; validation used the existing `_delegation_ready_eval` test partition without changing its integrity checks.

Commit `d453c00e` implements the saved first-message copy setting. The grant preview shows the source user's address; the first prepared email freezes that Cc, and later sends omit it unless the user explicitly added a permanent Cc. A manual reply from the source user pauses an assistant conversation and cannot prove the counterparty's outcome. The controlled eval gate also validates the extra recipient. The focused policy, gate, and ingress run passed 47 checks, the preview and isolation run passed nine checks, and the server build passed. Server deployment `35001963170` passed, serving revision `maraithon-00349-xpk`. The shared native preview in `2aa70f8e` passed signed Mac and iPhone builds. The signed Mac app is installed; iPhone release `35002441909` passed.

This completes the central isolation, signature, and first-message copy paths, not the full assistant slice. The remaining work includes account-specific voice and an audit of other direct provider read paths. October connected on September 15; live actor verification is still required.

## Conflict recovery and retention

A malformed message body gets one durable repair attempt, followed by the same independent policy review. A second malformed response holds. Early conflict detection now counts a changed offer toward the single-reoffer limit. The focused admission, policy, and calendar run passed 50 checks.

The next conflict run stopped on an OpenRouter rate limit during its second turn. Four provider entries reported US$0.002103, plus a retained reservation for the rejected request. Calendar cleanup completed. Commit `2c40b9ae` records a capacity outcome and retries from fresh sources after the provider cooldown. Replaying the worker cannot enter another call, and unresolved spend stays reserved. Its 33 focused ingress checks and server build passed. [Rate-limit evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-rate-limit.json).

The following run, job `88ad8513-f3de-422c-a6ca-f8fbb5e12a59`, used revision `maraithon-00348-8dc`. Its first turn reached `policy_review_required` after two Muse calls costing US$0.001305. It sent no agent email, and the fixture stopped the conversation and completed calendar cleanup. The verdict incorrectly rejected the authorized mailbox signature because it applied the composition instruction to the final signed body. Commit `01172cde` clarifies that review receives the final body, and that the frozen signature is expected. It also removes fixture sign-offs and uses the actual sending mailbox signature for eval and assistant emails, unless the assistant has an explicit override. [Evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-signature.json).

Retention also keeps stopped conversations with unresolved model reservations. Its focused check verifies that cleanup preserves the turn and its reservation, and that settled spend restores eligibility. This is separate from user-requested privacy erasure.

Commit `3aff247f` also carries the frozen mailbox display name into the From header alongside the verified address. Nine Gmail transport checks passed, including rejection of header injection through the name. The server build passed.

## Booking approval and mailbox formatting

The conflict rerun on revision `maraithon-00351-j2n` sent two offers and received acceptance of the replacement time. The independent reviewer returned `allowed=true`, with a reason confirming explicit counterparty acceptance and current availability. It correctly returned `outcome_proven=false` because no calendar event existed yet. `Policy.approved?/2` incorrectly required that flag for booking as well as completion. No invite was sent. The fixture stopped and cleaned up its temporary calendar entries. Six calls cost US$0.004518. [Evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-booking-approval.json).

Commit `0bbf7c4a` requires semantic approval before booking and reserves outcome proof for a complete decision. Counterparty evidence, the offered slot, fresh availability, and the provider receipt remain required by their existing checks. The two leased-booking cases passed with outcome proof false before creation, including refusal when the slot becomes busy. The 32 policy, calendar transport, and scheduling checks passed, and the server build passed. A new live rerun is still required.

The provider reader verified all five emails against the frozen mailbox signatures. Kent's screenshots revealed that the evidence renderer had exposed link annotations in outgoing signatures. Commit `c98b50ee` preserves the mailbox HTML signature in a multipart email and supplies a clean plain-text alternative. Model evidence still retains its link annotations. It also falls back to the account's saved display name when send-as omits one. The email formatter escapes the composed body and appends the frozen footer once. The 36 focused identity, policy, transport, settings, and category checks passed; the follow-up identity and native contract run passed 11 checks.

## Native assistant settings

Commits `6e23e6aa` and `9eb9c2ac` give Mac and iPhone a shared assistant form using the same account choices, timezones, numeric limits, identity, and preferences as web. The server returns account labels without loading credentials. Both device authentication paths passed the settings contract check. Native account and delegation requests also remove a duplicate `/api/mobile` prefix that would have prevented the iPhone from reaching those endpoints.

Signed Mac and iPhone simulator builds passed, with XcodeGen regeneration. The focused iPhone request test could not run because the dormant test target references the removed `TodayViewCopy` type. An earlier compile failure in the todo-count fixture was updated to include the current action, watching, and snoozed counts. The native test target remains unverified; no test was deleted, skipped in the project, or replaced with a passing stub.

Server workflow `35007994634` passed, serving revision `maraithon-00353-79v`. iPhone workflow `35007994545` built and uploaded to TestFlight successfully. The signed Mac app is installed. Its preferences saved through the shared API, and web showed the same values. After October was configured on web, Mac loaded its name, verified address, and disclosure setting. Simulator inspection was unavailable through the app-control connection, so the iPhone screen has not been visually verified.

## October eval preparation

Kent connected `october@ewakened.com`, account 9. Web verified its sending address and saved the assistant name October with the mailbox signature, AI disclosure enabled, and first-message Cc left off. Mac loaded the same identity.

The eval extension supports the frozen actor and permits October only as the assistant sender on labelled Kent-pair conversations. Preflight checks its verified identity, sending scope, and exclusion from personal source accounts. The reply fixture resolves the latest executed send into the recipient's actual mailbox by RFC Message-ID, then replies in that mailbox's thread. It checks the sender address, display name, and frozen signature before replying. The server build and 12 focused gate, offer, and isolation tests passed. The leased fixture retry check also passed, confirming that replay does not send the initial email twice. This extension still needs deployment and a live assistant run.

## Personal and work accounts

Commit `ced148f9` adds account categories and an All / Personal / Work filter. The filter uses the task's source account, so changing an account updates existing tasks without model calls or rewriting todos. Unassigned accounts and tasks without a source account appear under All. Provider token refreshes cannot overwrite the category. Account and assistant settings are available to signed-in users without admin access.

Web, Mac, and iPhone use the same saved categories. The native apps share the account settings form and category enum; the iPhone stores the optional category through an additive SwiftData field and refreshes it on sync. The server migration registers the reviewed column and constraint in the durable and privacy catalogs and checks that all other proofs remain valid. The focused domain, signature, policy, eval, settings and API checks passed 29 tests. Server, signed Mac, and iPhone simulator builds passed. Server workflow `35003898249` passed, serving revision `maraithon-00350-qk8`; production migration `maraithon-migrate-tt86z` passed. The signed Mac app is installed. A temporary category change saved from Mac produced seven existing tasks in the web Personal filter, then was restored to Unassigned. Commit `07b95afa` replaces provider IDs with readable account labels and avoids loading OAuth credentials for category reads. Its three regression checks and server build passed. Follow-up deployment `35004585260` passed, serving revision `maraithon-00351-j2n`. Google email addresses and Agora / Runner account names are verified in production. iPhone release `35004585337` passed. [Category evidence](evidence/delegated-conversations/2026-09-15-account-categories.json).

The post-rollout sample at 18:13 to 18:14 UTC found all 64 partitions ready with live leases, no termination requests, and advancing recurring work. Renewal and storage verification did not dominate query time. Recovery logs are present, but the sample contained no recent effect or checkpoint events, so it does not prove every runtime health criterion. [Recovery evidence](evidence/delegated-conversations/2026-09-15-category-runtime-recovery.json).

## Remaining work

1. Finish the busy-slot rerun, job `582b343d-555c-4148-bedd-a9abf69cd998`, on the deployed booking correction. The earlier run stopped before booking. All failed conflict fixtures completed cleanup. The regular scheduling eval has passed.
2. Complete assistant identity isolation, signatures, voice, and settings across clients. October is connected and configured; the assistant eval is next. Connecting it alone does not establish the assistant-account slice.
3. Implement and verify Slack ingress, sending, authorship, and reconciliation for both actors. Slack autonomous sends remain disabled.
4. Add delegation proposals, brief reporting, and the idle coordinator stop after seven days with no live conversations.
5. Finish mailbox-wide quota coordination, the whole-app recovery and race checks, schema evolution, and a real longevity canary.
6. Reduce model calls per turn and daily workload volume. The information eval used two calls per turn, above the plan's target below 1.3. The measured day had 1,542 attempts, above the earlier 300 to 500 target.

The live gate remains restricted to the labelled Kent-pair eval. The code and evidence do not justify enabling general autonomous outreach yet.
