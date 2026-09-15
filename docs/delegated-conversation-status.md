# Delegated conversation implementation status

Updated September 15, 2026. The Gmail information and regular calendar paths have passed controlled live evals. The conflict formatting fix has shipped and its live rerun is underway. The full [execution plan](delegated-conversation-execution-plan.md) is not complete.

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

The focused isolation, scope, Gmail, ingress, and OAuth run passed 46 checks. Seven identity checks passed after the final primary-address validation. The server build passed. Workflow `34998552598` is deploying this change. Calendar and travel fallback reads now use the same exclusion in commit `0d865e4b`; its seven identity checks and server build passed, and deployment is pending.

This completes the central isolation path, not the full assistant slice. The remaining work includes signatures, account-specific voice, native settings, and an audit of other direct provider read paths. No October account is connected in production yet.

## Conflict recovery and retention

A malformed message body gets one durable repair attempt, followed by the same independent policy review. A second malformed response holds. Early conflict detection now counts a changed offer toward the single-reoffer limit. The focused admission, policy, and calendar run passed 50 checks.

Retention also keeps stopped conversations with unresolved model reservations. Its focused check verifies that cleanup preserves the turn and its reservation, and that settled spend restores eligibility. This is separate from user-requested privacy erasure.

## Remaining work

1. Finish the busy-slot conflict rerun, job `f4dac5ff-fefc-4296-9742-6955a3a33a7d`, started on revision `maraithon-00345-lnn`. The first conflict run noticed the busy slot but omitted the replacement email body, so validation held before another send. Three calls cost US$0.002116; cleanup completed. [Failure evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-first-attempt.json). The regular scheduling eval has passed.
2. Complete assistant identity isolation, signatures, voice, and settings across clients. The production account check found no assistant identity and no connected `october@ewakened.com` account. Connecting it alone does not establish the assistant-account slice.
3. Implement and verify Slack ingress, sending, authorship, and reconciliation for both actors. Slack autonomous sends remain disabled.
4. Add delegation proposals, brief reporting, and the idle coordinator stop after seven days with no live conversations.
5. Finish mailbox-wide quota coordination, the whole-app recovery and race checks, schema evolution, and a real longevity canary.
6. Reduce model calls per turn and daily workload volume. The information eval used two calls per turn, above the plan's target below 1.3. The measured day had 1,542 attempts, above the earlier 300 to 500 target.

The live gate remains restricted to the labelled Kent-pair eval. The code and evidence do not justify enabling general autonomous outreach yet.
