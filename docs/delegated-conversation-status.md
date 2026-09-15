# Delegated conversation implementation status

Updated September 15, 2026. The Gmail information path has passed a controlled live eval. Calendar testing is in progress. The full [execution plan](delegated-conversation-execution-plan.md) is not complete.

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

This change deployed successfully in workflow `34993948938`, revision `maraithon-00342-w6c`. The new scheduling eval job is `0e78ba4e-935f-406d-bebb-fa7d9c008234`. Booking, invitation delivery, cleanup, and cost are pending verification. The busy-slot conflict scenario must also pass before scheduling is considered verified.

## Remaining work

1. Finish live scheduling and conflict evals, and record the actual invitation and cost evidence.
2. Complete assistant identity isolation, signatures, voice, and settings across clients. The production account check found no assistant identity and no connected `october@ewakened.com` account. Connecting it alone does not establish the assistant-account slice.
3. Implement and verify Slack ingress, sending, authorship, and reconciliation for both actors. Slack autonomous sends remain disabled.
4. Add delegation proposals, brief reporting, and the idle coordinator stop after seven days with no live conversations.
5. Finish mailbox-wide quota coordination, the whole-app recovery and race checks, schema evolution, and a real longevity canary.
6. Stop ordinary todo briefs and fallback chat draft cards from competing with an active delegation. The live Mac check still showed a separate draft suggestion from the wrong mailbox; it was not the delegation's frozen send.
7. Reduce model calls per turn and daily workload volume. The information eval used two calls per turn, above the plan's target below 1.3. The measured day had 1,542 attempts, above the earlier 300 to 500 target.

The live gate remains restricted to the labelled Kent-pair eval. The code and evidence do not justify enabling general autonomous outreach yet.
