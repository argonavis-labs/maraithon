# Todo architecture review — September 6, 2026

Objective: discover actionable commitments and decisions from connected apps,
rank them beside manually added work, and automatically close work when fresh
evidence proves it was handled. Ship small changes to the single-user test app
for `kent@runner.now`, using the manual-first development policy.

Latest delivery (September 7): revision `maraithon-00236-cm5`,
code `248bd58e`, successful workflow `34087225973`. Intake now retrieves older
matching work before deciding whether a reminder needs a new todo, and requires
source-backed personal ownership rather than defaulting team work to Kent.
The latest prompt also excludes earlier generated copy as ownership proof; its
natural model behavior remains to be observed. Chat works; expired briefs
refresh; named email drafts no longer target digest senders; explicit mailboxes
are retained; exhausted model retries can reuse completed closure batches.
Gmail account 1's 276-batch backlog settled at 05:18:49, advancing its closure
cursor from September 2 to September 7 04:05:17 UTC. Its next deltas also
settled, and the cursor was current by 05:21:19. The reviewed reminder cleanup is complete: 725 duplicates consolidated into
311 originals, with all 1,036 rows independently verified and 499 active todos
remaining. The open scope question is whether routine team-owned Uride
escalations belong on Kent's personal list (finding 62).
Revision 233's scheduled runtime cycle passed the production checks; revision
235 passed its recovery, scheduled Effects, checkpoint, source-delta, and
SQL checks in observer `ltv7q`. Account 2 and Slack have completed catch-up
and subsequent deltas. Browser and narrow compile checks passed; no test
suites were run. Detailed findings and chronological evidence follow.

## Completion audit against the original goal

This is a current requirement check, not a declaration that the goal is complete.
Historical “pending” notes below describe what was known at that point in the
investigation; the remaining gaps are stated here.

| Requirement | Authoritative evidence inspected | Current result |
| --- | --- | --- |
| Discover commitments and decisions from connected apps using deltas. | Current `PeriodicJobs`, `SourceAccountDiscovery`, and `SourceCycleSettlement` paths; production discovery cursors for both Gmail accounts and Slack; source-backed Chrome todo details. | Discovery is advancing. Gmail account 1 discovery is advancing in the September 7 05:19 window. Its closure backlog and following deltas settled, and its cursor is current. |
| Rank sourced work alongside manually entered todos and make it actionable. | Signed-in `/todos`, successful priority chat run `62321861`, original source threads in the Michael/Uride/DuraServ details, and the recorded Mac create/edit/complete round trip. Current shared reply routing and brief projections were inspected again. | Manual todo actions and sampled priorities were verified. The 725 reviewed reminders are consolidated, with notes and source links retained and zero read-back mismatches. The latest ownership prompt is deployed; the intended scope of team escalations and its natural intake behavior remain open. No third-party message was sent. |
| Wake regularly and fan work out without blocking OTP ownership. | Current one-minute discovery/completion schedules, ten-minute Chief default, independent non-mailbox completion backstop, workload/account rotation, and completed observer `ltv7q`. | Revision 235 recovered at 05:12:07. Scheduled Effects completed at 05:16:06 and 05:26:41, and its checkpoint persisted at 05:22:07. All eight samples retained 64 ready/live partitions, with no pending termination and no missing Effect evidence. |
| Close work only on current, matching evidence and keep the list current. | Current quote/time/relationship checks, row-locked stale-result rejection, immutable source-cycle settlement, sampled Abe Choi closure evidence from `f7ztc`, completed account-2/Slack cycles, and current Gmail graph status. | Evidence-backed sampled closures and two accounts' settled deltas are verified. Gmail account 1's 276-child backlog completed and its cursor advanced at 05:18:49. The following four-source, fifteen-child delta also settled; by 05:21:19 closure and discovery cursors were advancing through empty deltas. |
| Reduce repeated reads/model work and recover unfinished work efficiently. | Recorded card serialization and Mac refresh timings, bounded fanout/prompt packing, live provider cache counters, completed-child reuse, and timeout-recovery projection `btwjn`. | Implemented and measured where noted. The timeout projection retained 297 results and retried two children; production recovery retained all 214 completed results at 05:06. The full 276-child recovered graph settled at 05:18:49; its successor uses a new delta and the smaller todo snapshot. |
| Ship small changes to the test app without staging or added deployment gates. | All prior delivery commits plus ownership fixes `afeeb604` and `248bd58e` are in the deployed history; current `Makefile` maps `make deploy` to `deploy-fast`; workflow `34087225973` completed through the normal cached deployment path. | Shipped to revision 236 at 100% traffic; its Chief recovered at 05:36:54. The complete runtime cycle was verified on revision 235 immediately before this prompt-only deployment. Compile/manual checks followed `docs/development-mode.md`; no test suites were run. |
| Update native clients where the todo loop needs changes. | Latest companion source change is `19e358dc`; the installed Mac executable was built September 6 at 20:53 local time. Latest iPhone source change is `1ba7bb51`, matching successful release workflow `34067357201`; current paging, manual-entry, and completion-display code was inspected. | Mac update is installed and previously exercised while paired. TestFlight 1.0.1 (20260906233635) is available to Kent. Physical iPhone behavior was not exercised in this session; no further native change is currently needed by the server fixes. |

## Architecture to retain

- PostgreSQL owns runtime leases, task outcomes, and source progress. OTP
  processes schedule and execute work without replacing durable authority.
- `RecurringJobs` discovers work; `PeriodicJobs` creates per-account provider
  jobs and bounded model jobs. Gmail/Slack discovery and closure have separate
  cursors, encrypted source handoffs, and finalizers that require full coverage.
- `AIChiefOfStaff` coordinates skills and attention every ten minutes. Its
  regular cycles can reuse account-worker results instead of refetching every
  mailbox. OpenRouter calls use bounded shared model capacity.
- Completion already checks quoted evidence, timestamps, and todo ownership.
  The public todo APIs serve web, mobile, and companion clients.

## Findings and work list

1. **Calendar and companion completion coverage disappears for connected users.**
   The recurring sweep selects only users without connected Gmail/Slack for
   its general completion pass. Account closure acquisitions explicitly fetch
   Gmail or Slack; they cannot replace calendar, reminder, or local-message
   evidence. Add an independent, bounded user backstop that reads those sources
   without duplicating mailbox or Slack acquisition. Also propagate completion
   errors to the durable runner so failed model calls retry.
   Status: implemented in `581e8fa5`; build passed; deployed in
   `maraithon-00195-x7j`. The independent backstop completed at 19:23:48 UTC
   with no retries or recorded error.

2. **Fast deploy contains a drain-proof gate contrary to development policy.**
   It polls up to 48 times and refuses replacement without a strong drain
   proof. Keep a best-effort drain request to give graceful shutdown a head
   start, but continue the rolling replacement. Preserve database fences and
   the rejoin-on-failed-replacement recovery.
   Status: fixed in `6160e520`; shell syntax checked and deployed successfully.

3. **Cross-source completion is restricted by same-source linkage.**
   `CrossSourceCompletion.matching_evidence/4` requires an item-ID match or
   matching source channel, account label, and counterparty text. A real Slack
   reply normally has a different ID and channel from a Gmail todo, so a valid
   model decision can be rejected. Replace this with evidence-grounded
   cross-source relationship validation while retaining quote and time checks.
   Status: implemented with a quoted, distinctive shared relationship
   anchor for cross-source/manual work, while retaining confidence, exact quote,
   timestamp, account, and stale-row checks. Thread context now keeps each
   reply's actual timestamp and sender instead of inheriting the delta timestamp.
   Calendar evidence uses creation/update time rather than a future event start.
   Build passed; deployed in workflow `34054801166`, revision
   `maraithon-00199-6vt`.

4. **Automatic closure needs explicit provenance and stale-decision protection.**
   Cross-source completion writes a free-text resolution note through ordinary
   `mark_done/3`. That call locks the current row but does not compare it with
   the todo the model evaluated. Record the verified evidence and method, and
   prevent a delayed model response from closing work the user changed.
   Review reopening and feedback across clients as part of this change.
   Status: provenance and row-locked snapshot protection implemented in
   `93bf5406`; build passed and deployed in `maraithon-00196-k5d`.
   Reopening now records a correction and requires newer evidence across
   deterministic and model checks. Existing mobile and companion reopen
   actions use this shared server path; build passed and deployed in
   `maraithon-00197-thz`.

5. **Completion rotation stops at a fixed 500-row pool.**
   The general cross-source pass loads the oldest-updated 500 todos before
   rotating by `last_completion_checked_at`. Checking does not change
   `updated_at`, so todos outside that pool can remain excluded indefinitely.
   Order or page the durable candidate pool by completion coverage itself.
   Status: fixed in `c109e4e3`; the query orders by the completion-check stamp
   before applying its bound and applies the age filter in SQL. Build passed
   and deployed in `maraithon-00196-k5d`.

6. **Live Gmail catch-up and runtime health require current evidence.**
   The September 5 report explicitly left Gmail catch-up unfinished. Inspect
   current source cursors, pending/failed graphs, schedule advancement,
   checkpoints, exact outcome evidence, and interval database load before
   calling this complete. Repair underlying causes instead of advancing
   unevaluated cursors or relabeling ambiguous outcomes.
   Initial status: **unhealthy**, verified at 18:56 UTC on revision
   `maraithon-00194-xqs`. One partition is draining with an expired lease;
   63 are ready/live. Gmail and Slack source queues have pending work dating
   to September 5 at 21:05–21:09. Gmail discovery cursors last advanced on
   September 2 (account 1) and September 5 (account 2); Gmail closure cursors
   are still on September 2. There are 626 open todos, so the scan-limit
   problem is relevant to Kent's actual account. All 18 active recurring
   schedules had no persisted error, which alone is insufficient evidence
   that their child work is running.

   Cloud SQL and application logs show 30-second database timeouts at
   September 5 21:07 and 21:11, followed by coordination-process crashes.
   One trigger rejected revival of an expired node incarnation. `3b62894f`
   catches database failures in the coordination tick, retains the incarnation
   for cleanup, and publishes uncertainty before cleanup; build passed.
   Deployed in `maraithon-00196-k5d`. The stranded partition was recovered
   as described below; source catch-up remains in progress.

7. **Verify the complete product loop for Kent.**
   Confirm source-backed discovery and closure, ranked manual work, useful
   explanations and corrections, and current mobile/companion consumption of
   server state. Native changes should follow demonstrated gaps, with narrow
   builds and installation/release only for affected apps.
   The Mac client ignored pagination after its first 200 todos. It now fetches
   every page before replacing the list, deduplicates overlapping rows, and
   rejects malformed/nonterminating pagination. Swift build passed; the signed
   local app was rebuilt, installed, and launched at `~/Applications/Maraithon.app`.
   iPhone pagination and manual create/reopen paths already use the shared API.
   Direct Mac verification initially showed 627 active work items; a refresh at
   20:33 UTC showed 941 after further source discovery.
   Source catch-up remains in progress.

8. **Todo deduplication blocks the Agent's lease renewal.**
   At 19:14:11 UTC the Chief completed an effect, then entered another model
   call inside a skill's result callback. At 19:15:55 its next write failed
   with `runtime_lease_expired`. Morning briefing, commitment tracker, and
   holiday ingestion all contain this synchronous path. Move those ingestions
   to the durable model queue, retaining encrypted candidates and idempotent
   queue keys; attach results to the originating brief after ingestion.
   Yield between skills and renew authority at each continuation boundary.
   Status: implemented in `97362cfd`; build passed; deployed in workflow
   `34054609844`, revision `maraithon-00198-pzq`.

9. **Closure repeats source context too often for a large todo list.**
   The exact matrix used batches of ten todos. Increase both the fanout and
   inner checker batch to twenty and scale the response-token allowance with
   the admitted todo count. Existing prompt splitting and complete coverage
   requirements remain; Kent's 626-item list needs 32 batches instead of 63
   per source partition. Status: implemented in `a2d9dedc`; build passed;
   deployed in `maraithon-00200-zm4`.

10. **Planner leadership expires before otherwise valid worker leases.**
    Cloud SQL reported `expired leader incarnation cannot be revived` at
    19:25:27 UTC. Leadership had a 15-second lease while node and partition
    leases lasted 30 seconds; one coordination tick can also publish partitions
    and reconcile task proofs. Match the leader window to 30 seconds, bound
    proof reconciliation to ten assignments per tick, and renew leadership
    immediately before planning. An actually expired ready leader still needs
    a fresh node identity: detect that condition explicitly and retain the old
    identity for fenced cleanup instead of attempting a prohibited revival.
    Status: implemented in `a1f71b75`; build passed; deployed in
    `maraithon-00200-zm4`. Sustained runtime verification remains in progress.

11. **A transient post-deploy health request falsely reports rollout failure.**
    Workflow `34055148827` built and deployed revision `maraithon-00200-zm4`
    to 100% of traffic, then its single 15-second health request timed out.
    Both service URLs subsequently returned `ok` with the combined process
    role. Retry transient health transport/HTTP failures up to twice, and avoid
    an additional traffic update when the service already sends 100% to the
    latest revision. Retain the response-content check and a bounded retry
    window. Status: shell syntax verified; deployed in successful workflow
    `34055535413`, revision `maraithon-00201-srb`.

12. **Lease-loss cleanup skips reserved tasks and can strand a partition.**
    The 19:46:54 UTC snapshot isolated a new reserved, never-entered assignment
    `e398451c-7524-4eb8-9903-63663b0f57c8` on partition 31, epoch 166. Its
    expired node `b75c14e2-28c0-4dff-8a6e-2606f8c565c4` records the hosting
    revision `maraithon-00200-zm4`. Cleanup tried a running-only termination
    transition for reservations, then skipped the guardian when that failed.
    Route every local assignment through its exact guardian; it already
    persists never-activated proof or atomic termination intent plus monitored
    proof. Attempt all identities even when one proof must retry. Avoid repeating
    the already-completed workload-drain phases during normal shutdown.

    The same recovery showed a node expiry after slow coordination work.
    Refresh node, partition, and leader ownership before planning whenever
    preparation consumed a renewal interval. Reject expired provider-entry
    attempts with an ordinary authority-loss result before the trigger rejects
    them. Status: implemented in `03765c85`; `make build` passed; workflow
    `34056034289` deployed successfully as `maraithon-00202-fg4`.

    The Chief of Staff's three-failure guard tripped at 19:25:29 UTC and left it
    stopped. Its normal explicit start action checks that prior leases,
    operations, processing directives, and termination incidents are clear before
    resetting the guard. The normal start action reset the guard at 19:55:51 UTC;
    the Agent recovered at 19:55:59. Its snapshot advanced at 20:14:20 with
    zero subsequent crashes. Periodic-cycle verification exposed finding 14.

13. **An interrupted iPhone sync can retain a validator for unsaved data.**
    The first todo page stores the collection ETag before later pages and the
    SwiftData merge finish. A failure can then receive 304 on retry while the
    local todo list is still old. Clear that validator unless the complete list
    was fetched and saved; preserve a valid 304 response. The same cleanup also
    applies to a capped listing and local save failure. Bump the todo validator
    cache version so installed apps refetch any previously incomplete list.
    Simulator app build
    passed on iOS 26.4; no project generation was needed and tests were not run.
    Status: implemented in `5d8a42e2` and `26191c62`; workflow `34057077032`
    delivered TestFlight `1.0.1` build `20260906200907` and verified Founders
    access for Kent at 20:13:34 UTC.

14. **Source activity postpones the periodic Chief of Staff scan indefinitely.**
    At 20:14:28 UTC, the recovered Agent was running and had processed 105
    runs since the first recovery, but no new scheduled wakeup or Effect had
    occurred since 19:18. Every completed PubSub run replaced its pending
    periodic wakeup with another ten-minute delay. Continuous discovery traffic
    therefore prevented a full scheduled skill cycle. Preserve an earlier
    active wakeup within the periodic scope, atomically cancelling duplicates;
    still allow an earlier deadline and preserve unrelated one-shot scopes.
    Status: implemented in `cb580599`; `make build` passed. Workflow
    `34057595625` deployed `maraithon-00203-llz` successfully. Live periodic
    cycle verification remains pending.

15. **A source-event backlog delays already-delivered maintenance and scans.**
    At 20:19:21 UTC, checkpoint and heartbeat jobs due at 20:05 and 20:10 were
    delivered as durable Directives but still pending. At 20:22:21, 46 source
    events remained queued behind work from 19:21. Strict global oldest-first
    selection delays maintenance until the whole backlog drains. After eight
    ordinary directives, give the oldest due scheduled directive a turn, then
    resume ordinary selection. Keep all queued events and existing exact
    claim/settlement fences. Status: implemented in `89284da8`; `make build`
    passed; workflow `34057858237` deployed `maraithon-00204-r9k`.
    The 20:42:30 UTC observation had no pending/processing directives; fresh
    periodic-cycle and maintenance evidence on that worker remains pending.

16. **Native todo refresh spends most of its time building action cards.**
    The Mac's five 200-item pages took about a minute to load at 20:32 UTC.
    A Cloud Run read profile measured 617 ms for the 200-row list, 122 ms for
    source health, 47 ms for timezone, and 43 ms for related people. Serialization
    without cards took 813 ms; with cards it took 8,967 ms. Preserve the card's
    source evidence and actions while removing the repeated work identified by
    a narrower profile. The narrower sample found no per-item database queries:
    action cards took 6,843 ms, including a repeated 1,048 ms ranking pass.
    Reuse each card's ranking and sanitized metadata, and compile the public
    text-boundary expression once (`7e13bea0`). `make build` passed. A local synthetic
    200-card profile fell from 768 ms to 484 ms. The same 200 production rows
    serialized in 5,359 ms instead of 7,866 ms (32% faster), with all output
    maps identical. Workflow `34059096574` deployed `maraithon-00205-lj6`.

17. **A model-work backlog postpones other kinds of todo maintenance.**
    At 20:51:22 UTC, 68 discovery reasoning jobs still awaited their first turn
    since 20:15, while closure reasoning advanced from 65 to 82 completions.
    Another 88 todo briefs and a new Agent ingestion were pending. Exact tenant
    fairness preserves oldest-first ordering within one user, so an older
    fanout can occupy all model capacity before discovery or ingestion starts.
    Rotate model job types using the existing durable scheduling-watermark
    table, updated atomically with the exact reservation under the tenant lock.
    Preserve due-time admission, FIFO within each type, tenant quotas, urgent
    nudge/push precedence, and every execution-partition/task fence.
    Status: implemented in `40f630f9`; `make build` passed; workflow
    `34059463117` deployed revision `maraithon-00206-f8l`. At 21:01:45 UTC,
    durable workload watermarks covered eight job types. Since 20:56, discovery,
    closure, completion backstop, ingestion, and brief generation all completed
    work, proving rotation across the catch-up backlog.

18. **A drained process can rejoin after a later coordination error.**
    A database-side drain stopped node `d31038e4` from owning partitions, but
    its Session continued attempting leadership. At 20:50:45 UTC PostgreSQL
    rejected that attempt because the node was draining. The generic error
    recovery registered a fresh incarnation (`ee73283c`) at 20:50:49, which
    later owned 30 partitions despite the intended retirement. Persist local
    drain intent as a non-admitting `drain_pending` phase; observe a draining
    node on renewal, retry cleanup without leadership, and only allow explicit
    rejoin after drain completes. Retain the exact local proof and task fences.
    Status: implemented in `9ce17d46`; `make build` passed; workflow
    `34059647528` deployed `maraithon-00207-8zf` successfully at 21:02:37 UTC.

19. **The Mac bulk list fetches rich context it only needs in the inspector.**
    Request base todos for every list page and fetch one action card when its
    inspector opens. Preserve complete-list replacement, protect detail results
    against selection/refresh races, and display source evidence, the original
    source link, and a copyable suggested reply. `swift build` and the signed
    `make deploy-companion` build passed. Manual inspection showed 953 active
    items and loaded Gmail context in 0.324 seconds. A normal refresh took
    6.792 seconds, versus the earlier 37.305-second refresh with bulk cards;
    refreshing with the inspector open correctly reloaded its context.
    No todo was changed and no reply was sent during inspection.

20. **Local source cursor checks repeatedly deserialize the whole cursor.**
    The first Mac refresh still took 24.891 seconds. Its first HTTP page took
    0.986 seconds, but page two began about 20.6 seconds after page one.
    Calendar and Contacts scans completed during that gap. Both source loops
    call `shouldPush` for every record; each call reads and rebuilds the entire
    UserDefaults cursor on the main actor (4,213 calendar occurrences against
    6,899 cursor entries, plus 2,166 contacts). Snapshot each cursor once per
    cycle while retaining advancement only after acknowledged ingestion.
    Status: each scan now reuses a single cursor snapshot. Existing single-item
    callers retain their behavior, and acknowledged batches still advance the
    persisted cursor. `swift build` and signed `make deploy-companion` passed.
    The 21:09 startup fetched all 953 todos in 7.098 seconds; Calendar and
    Contacts retained the same scanned/tracked counts without new uploads.

21. **Mobile hides refreshed work until every rich-card page has arrived.**
    Today and Todos need card fields for their decision filters, so dropping
    cards from their list would change the product. Stream 200-item pages into
    SwiftData as they arrive, retaining full cards and the existing 5,000-item
    bound. Show a refresh indicator while later pages remain. Reconcile absent
    rows and retain the collection validator only after complete pagination;
    interrupted or capped listings retain useful pages and require another
    fetch. Reject late pages after sign-out, ignore rows older than local edits,
    and preserve locally created/changed items during deletion reconciliation.
    Validation: iOS 26.4 iPhone 17 simulator build passed. No project regeneration
    or schema change was needed. The app launched to sign-in; authenticated
    paging was not exercised locally because this simulator has no saved session.
    Tests were not run under the manual-first policy. Implemented in `871e245c`;
    successful workflow `34060595850` delivered TestFlight `1.0.1` build
    `20260906211723` and verified Founders access for Kent at 21:22:33 UTC.

22. **Large source graphs hold the User fence long enough to expire runtime leases.**
    Fresh stalls at 21:18:48 and 21:22:35 disproved sustained health. The live
    lock watch (`maraithon-todo-validation-q6l49`) captured the cause at 21:28:
    backend 1106004 kept one graph-preparation transaction open while repeatedly
    looking up and inserting child jobs. Its User lock blocked backend 1105011,
    which retained runtime authority locks and blocked node renewal on backend
    1106080. At 21:28:31, graph preparation had held its transaction for 27.35
    seconds; node renewal expired at 21:28:34. The Chief's restart guard tripped
    after three recent failures.

    Prepare child jobs in individual short transactions. Mark new children as
    staged and admit them only when the parent has completed and its exact
    outcome transaction has published their IDs. Failed preparation abandons
    that parent; staged children discard after parent failure, and a fresh
    source cycle retries. Reject reuse of a changed handoff. Finalizers retain
    the existing complete-coverage proof and atomic watermark settlement.
    Status: implemented in `49ab9b6b`; `make build` passed. Tests were not run
    under the manual-first policy. Workflow `34061363751` deployed revision
    `maraithon-00208-tvb` successfully at 21:35:23 UTC. The normal Agent start
    endpoint returned 200 and cleared its restart guard at 21:36:58; the Chief
    recovered to idle at 21:37:03. Live graph and sustained lease verification
    are pending.

23. **Contended renewals spend the next lease before it is committed.**
    Revision 208 lost ownership again at 21:42:29. The lock watch
    `maraithon-todo-validation-gbtr4` captured renewal backend 1106519 waiting
    18.63 seconds behind changing short transactions, rather than one long
    graph transaction. New shared lockers kept entering while renewal waited.
    The node UPDATE calculated its next deadline before acquiring the row lock;
    the Session then committed and entered a second lock queue to renew its
    partitions. Both waits depleted the available ownership window.

    Lock the live node before calculating its new deadline and retain that
    lock through partition renewal in the same transaction. Preserve the
    existing state, epoch, action-token, and database-clock expiry checks;
    expired incarnations still cannot be revived. This removes avoidable lease
    loss from the two renewal waits, but does not claim that arbitrary lock
    starvation is impossible. Status: implemented in `6ed443ba`; `make build`
    passed. Tests were not run under the manual-first policy. Workflow
    `34062219205` successfully deployed revision `maraithon-00209-mw8` at
    21:53 UTC. Fresh sustained processing evidence is pending.

24. **Failed source graphs keep consuming model capacity.**
    Execution `maraithon-todo-validation-gnrlk` confirmed that Gmail acquisition
    `2029a98b` had four ambiguous children and a failed finalizer, yet 21 children
    were pending and one was running. Slack acquisition `845cd582` likewise had
    17 ambiguous children, a failed finalizer, eight pending children, and two
    running children. These graphs cannot finalize, but their old reasoning
    jobs keep blocking healthy newer work and fresh recovery cycles.

    Before model execution, check the completed acquisition's published child
    and finalizer IDs for a terminal failure. Settle remaining work as
    `source_graph_abandoned` through the ordinary exact runner, without a model
    call. Apply this to staged graphs and older graphs with a proven child list.
    Preserve ambiguous outcomes, completed results, and cursors. The recurring
    scheduler can admit a fresh cycle when the abandoned work has cleared.
    Status: implemented; `make build` passed. Tests were not run under the
    manual-first policy. Workflow `34063346361` deployed `1f5cd979` in revision
    `maraithon-00210-5p8`. Execution `maraithon-todo-validation-2xv88` observed
    `source_graph_abandoned` settlements at 22:17 UTC. Replacement cycles and
    source catch-up remain in progress.

25. **Unchanged closure decisions generate unnecessary prose.** Exact closure
    sweeps require one explicit decision per todo, but the prompt also requested
    a reason for every negative decision. The sampled Slack batches made nine
    model calls for each group of 20 todos and found no supported completion.
    The prompt now requests only `todo_id` and `completed: false` for unchanged
    work without an acknowledgment. Completed work and acknowledgment-only
    replies retain full cited evidence, and the existing validator still requires
    the exact input todo-ID set with a Boolean decision for every item.
    **Status: implemented in `a37bfe8d`; compile passed and deployed in revision
    210.** This reduces
    requested output; latency and token savings have not yet been measured.

26. **The Mac todo list has no manual-entry action.** The paired-device API
    only exposes reads and done/dismiss/reopen, so users must switch surfaces
    to add their own work. Add a small native New Todo sheet with title, notes,
    next action, priority, and optional due time. Keep failed drafts available
    for retry, use one device-scoped UUID per draft to avoid duplicate rows,
    and retain ordinary ranking, briefs, and user activity records. The server
    allows only manual-entry fields; identity and source come from the server.
    Status: server endpoint implemented in `70589a6d` and `make build` passed.
    Native UI in `ce4b1fd1` passed `swift build` and signed `make build-companion`
    packaging with the same Apple Development identity as the installed app.
    Workflow `34063974077` deployed revision `maraithon-00211-94n`; the signed
    Mac app was installed at 22:30 UTC. Its native sheet saved manual check
    `a4471e76-f955-49b1-b1fb-d07783a4ff79` at 22:31:15, and a fresh list load
    retained it at 22:32:45. The first refresh received a transient Cloud Run
    `429 Rate exceeded`; the explicit retry succeeded. No tests were run.
    Manual entry exposed the wording defect in finding 27.

27. **Copy cleanup rewrites manually entered todos.** The live Mac entry check
    submitted `Verify Mac manual todo entry`, but the server stored and
    returned `Verify Mac manual work item entry`. The common copy-polishing
    path runs on both writes and public projections, including user text.
    Preserve wording and line breaks for `manual` and `mobile` sources, while
    retaining cleanup for generated work. Partial updates use the persisted
    source when the input omits it. Status: implemented; `make build` passed.
    Workflow `34064359869` deployed `d12529a8` as `maraithon-00212-c5r`.
    Live check `5afac5a2-3299-4c29-9cf2-658d262bdfba` retained its exact title
    (`Verify exact todo wording`) and two note lines after a fresh server load
    at 22:37:51 UTC. The Mac also now prefers a manual todo's saved next action
    over a generated card suggestion; that follow-up passed `swift build` and
    signed packaging. Tests were not run.

28. **Completed Mac todos still ask for action.** The live manual check moved
    to Done but retained `Needs action` and `Next:` labels. Completed rows also
    retained urgent priority styling and could say `Overdue`. Gate those cues
    on active status; retain the recorded due date and the Reopen action.
    The same detail review found that the Mac decoder omitted saved notes,
    so it now preserves and displays them in a selectable Notes section.
    Status: implemented in `0afa3d1f`; `swift build` and signed
    `make build-companion` packaging passed. Installed and visually verified
    at 22:36 UTC: the completed row had no attention/next-step cue, the inspector
    showed Done and Notes, and Reopen remained available. Tests were not run.

29. **Closure scans underfill model requests.** Execution
    `maraithon-todo-validation-wf5kw` observed eight completed closure batches
    averaging 113 seconds at 22:48 UTC. The six newest sampled Slack results
    each used 13 model calls for 468 source items and 20 todos, with complete
    coverage and no fetch/evaluation error. There were 940 pending closure
    batches across the three connected source accounts.

    Share the checker's existing 40-todo limit with both batching callers.
    Exact scans now use the available evidence space and let the existing
    final serialized-request check split/repack at 96,000 bytes, instead of
    reserving half the space for worst-case escaping as well. Selective scans
    retain that reserve. Source-reference coverage, exact todo-ID validation,
    response limits, and the final request-size check remain intact. Existing
    20-todo handoffs stay valid; newly acquired graphs use the shared limit.
    Status: implemented in `cf6b6cc0`; `make build` passed. Tests were not run
    under the manual-first policy. Workflow `34065190230` successfully deployed
    revision `maraithon-00213-vbb` with 100% traffic. On revision 214, the first
    three fresh Slack batches each checked 40 todos against 472 source items
    in nine model calls, with complete coverage and no evaluation/fetch error.
    The preceding Slack sample checked 20 todos against 468 items in 13 calls.
    This demonstrates fewer calls per todo, but does not establish a latency
    improvement; time before and during model execution still needs profiling.

30. **One source account monopolizes its model-workload turn.** At 23:00 UTC,
    execution `maraithon-todo-validation-wf5kw` observed Gmail account 2 using
    all three running source slots, with eight of its 350 children completed.
    All 550 Gmail account 1 children still awaited their first turn. Slack's
    failed graph retained one pending child, delaying its replacement cycle.
    Job-type rotation works, but FIFO within a type lets one account's entire
    fanout precede another account's work.

    Add a second scheduling watermark for the source account within discovery
    and closure reasoning workloads. Sort first by the existing workload turn,
    then the source-account turn, then FIFO. Record both watermarks atomically
    with the exact reservation under the existing tenant lock. This preserves
    tenant quotas, job-type fairness, due-time admission, execution partitions,
    and task fences; it adds no ownership table or permission change.
    Status: implemented in `b5722b36`; `make build` passed. Tests were not run
    under the manual-first policy. Workflow `34065675520` successfully deployed
    revision `maraithon-00214-47d`, serving 100% of traffic. Execution `xr547`
    observed closure starts for accounts 2, 1, and 6 at 23:06:03, 23:06:07, and
    23:06:10 respectively. Gmail account 1 completed its first batch at
    23:07:00. Slack's last abandoned child cleared and its replacement acquired
    a 25-batch graph at 23:06:51. Account rotation is verified; source catch-up
    remains in progress.

31. **Exact prompt packing repeatedly rebuilds the whole request.** Execution
    `maraithon-todo-validation-t4g6s` measured the first three 40-todo Slack
    batches at 309 seconds on average, versus 107 seconds for the preceding
    fifteen 20-todo batches. Fewer model calls did not translate into faster
    processing. Inspection found that both evidence splitting and candidate
    packing rebuilt the todo projection, serialized the growing prompt, and
    parsed its evidence JSON for every candidate item.

    Compute the empty-request budget once, measure each evidence fragment's
    exact outer JSON escaping once, and accumulate fragment/separator sizes
    in one pass. Preserve fragment order, UTF-8 splitting, source-reference
    coverage, and the existing complete-request check before every model call.
    Emit a preparation-time/count log for each successfully packed batch so
    further latency analysis can distinguish preparation from model execution.
    Status: implemented in `8f4d5f35`; `make build` passed. Tests were not run
    under the manual-first policy. Workflow `34066652859` successfully deployed
    revision `maraithon-00215-64f`, serving 100% of traffic. Preparation-time
    measurements and completed-batch latency remain to verify.

32. **The Mac inspector keeps recommending action after a todo is done.** The
    first newly proven automatic closure appeared in Done, but its inspector
    still advised keeping it active and offered an obsolete suggested reply.
    Decode the existing public `metadata.resolution_note` and `closed_at`
    fields, lead completed detail with the resolution and completion date,
    label the original request as historical context, and restrict next-action
    advice and suggested replies to active work. Keep the source link and
    Reopen action available.

    Status: `swift build` and signed `make build-companion` passed. Installed
    the signed development build at `~/Applications/Maraithon.app`. A live
    inspection of todo `087525a5-1d38-4e71-85cb-0ee79858d68c` verified its source
    completion quote, completed date, original request, and absence of stale
    action advice or reply controls. Reopen remained available. Returned the
    app to the unfiltered Active list (993 items). No tests were run.

33. **Failed source graphs release model slots one child at a time.** At
    23:30 UTC, Gmail's abandoned graphs still retained 289 and 506 pending
    children. Only thirteen children cleared in two minutes, delaying fresh
    scans even though those graphs can no longer advance a cursor.

    A running sibling now cancels up to 64 unclaimed children in one short transaction. It rechecks a terminal sibling failure,
    retains the User privacy fence, and proves its exact task lease before and
    after the writes. Candidates must still be pending with no claim identity
    or assignment; locked rows are skipped. Running tasks, previously assigned
    retries, completed results, and ambiguous outcomes retain their normal
    settlement path. A 500 ms lock timeout lets a later sibling retry cleanup
    rather than holding up lease renewal behind another writer.
    Status: implemented in `fcf33862`; compile passed. Workflow `34067235556`
    deployed revision `maraithon-00216-gkc` successfully. Initial live logs
    recorded 769 cancellations in fourteen short batches, with a maximum
    measured call duration of 2,765 ms. Previously settled and ambiguous
    outcomes remained intact. Full replacement-cycle completion remains to
    verify. No tests were run under the manual-first policy.

34. **iPhone completion detail also retains stale actions.** The iOS decoder
    ignores the public resolution note, while completed rows and detail still
    use active recommendations, urgency signals, suggested replies, and action
    prompts. Persist the existing `metadata.resolution_note`, show it with the
    completed date and historical request, and limit active recommendations
    and drafts to open/snoozed work. Preserve the original source link, work
    chat, and Reopen action.

    The added SwiftData string is optional for lightweight migration. Advance
    the todo ETag cache key to v5 so unchanged existing rows receive their note
    on the first refresh. No server payload change is required. `make
    build-mobile` regenerated the Xcode project and passed its simulator app
    build; no generated project is committed. Tests were not run under the
    manual-first policy. Workflow `34067357201` successfully published code through `1ba7bb51` as
    TestFlight `1.0.1` build `20260906233635`. Founders access and Kent’s tester
    membership were verified in the release logs. The available simulator is signed out, so the
    updated detail view has not yet been inspected with a live iPhone session.

35. **Repeated thread context survives evidence deduplication.** A Gmail
    batch with seventeen acquired messages produced 284 evidence records and
    six model calls. Thread replies inherit each acquired delta's coverage
    reference, and the existing dedupe key includes that reference, so
    otherwise identical activity is repeated in the exact prompt.

    Coalesce exact evidence records only when every field other than the
    coverage reference matches. Preserve every acquired reference in
    `source_refs`, retain a scalar reference for completion provenance, and
    verify that the packed prompts still cover the original reference set.
    Sender, timestamp, account, source ID, thread, subject, and full text must
    all match. Different evidence remains separate. The prompt identifies
    aliases as one activity, not independent confirmations; byte limits and
    todo coverage checks are unchanged. Log original and unique record counts.
    Status: deployed through `d5cc439c` in revision `maraithon-00217-wx6`,
    successful workflow `34068079615`; `make build` passed. Live logs reduced
    one 297-record Gmail input to 238 unique records and four prompt chunks
    (previously seven for that record count), and another 284-record input to
    218 unique records and two chunks (previously six). Each had 40 todos;
    todo text can differ between batches, so this is not an isolated benchmark.
    Preparation took 70 ms in both cases. Slack's 703 records coalesced to 698
    and still required ten chunks. No tests were run. Gmail acquisition
    `993c7be3` published its child list by the 23:47 observation, so deployment
    no longer needs to wait for that graph to finish staging.

36. **One oversized closure handoff discards packing for the entire scan.**
    Gmail acquisition `993c7be3` published 1,800 children for 290 source items
    and 993 todos: 72 source partitions times 25 todo batches. The previous
    280-item scan used eleven source partitions. Code inspection found an
    all-or-nothing fallback: any packed handoff failure retries the complete
    matrix with the original small discovery partitions. Packing checks the
    source bundle alone; the full job also contains todo snapshots, references,
    and fanout metadata. The production result suggests this fallback was
    taken; the original payload failure was not logged.

    Reuse discovery's existing source-record splitter for the offending
    partition only, then rebuild the matrix with final indices and counts.
    Other packed partitions stay packed, all source records remain covered,
    and the existing durable payload bounds and replay fanout cap still apply.
    A single unsplittable record still fails explicitly. Status: deployed in
    revision `maraithon-00217-wx6`, successful workflow `34068079615`;
    `make build` passed, with no tests run under the manual-first policy.
    The replacement production graph `b871ad9e` published 300 children for
    294 source items and 997 todos (twelve partitions times 25 batches),
    verified at 00:25:16. Its first two workers completed with full coverage.

37. **Surviving legacy graphs keep the old oversized layout after deployment.**
    Gmail account 1's 1,800-child graph survived revision 217's rollout, with
    only nine children completed by 00:00:19. The new prompt code applies to
    its workers, but the packed graph shape is fixed at acquisition. Read-only
    execution `flbtj` replayed its exact stored 290 source items and 993 todo
    snapshots through the new packer: twelve source partitions times 25 todo
    batches produced 300 handoffs in 35,644 ms, instead of 1,800. The handoffs
    totaled 122,742,863 encoded bytes. It made no provider/model calls or writes
    and completed successfully at 00:03:24.

    Version newly acquired closure graphs. For unversioned graphs with at
    least 1,000 children and less than 10% completed, a claimed reason worker
    discards itself before making a model call. Its ordinary exact settlement
    triggers the existing fenced cleanup; normal acquisition then rebuilds
    from the unchanged source cursor. Completed outcomes and any ambiguous
    outcomes are retained. Versioned graphs and substantially completed legacy
    graphs continue normally. Status: deployed through `61edd26f` in revision
    `maraithon-00218-p5q`, successful workflow `34068694257`; `make build`
    passed, with no tests run. The old graph was fully terminal by 00:21:14,
    with its fourteen completed outcomes retained. Replacement `b871ad9e`
    published 300 children with partitioning version 1 and had two completed
    workers by 00:25:16. Full cycle settlement still remains to observe.

38. **Source finalization repeats reads while holding the User fence.**
    `SourceCycleSettlement` loads every todo separately when building receipts
    and restores every child source bundle, even though closure's todo batches
    share identical bundles. A 993-todo closure therefore performs up to 993
    todo queries in the cursor-settlement transaction; the measured packed
    graph still carries 25 copies of each source partition.

    Load the needed todos with one user-scoped query selecting only receipt
    fields, keep the existing ownership checks, and restore/hash identical
    source bundles once after every job payload binding has been validated.
    Proof construction, receipt validation, the cursor write, and exact outcome
    settlement remain in the same fenced transaction. Status: deployed in
    `maraithon-00219-lxk` through `5ac6467a`, successful workflow `34069227776`;
    `make build` passed. No tests were run. Discovery cursors advanced after
    deployment; full closure finalization remains to observe.

39. **Cleanup yields its worker after only 64 cancellations.** Revision 218
    correctly discarded a legacy Gmail reason worker as
    `source_graph_repacking_required` at 00:10:04.533, but only 128 unclaimed
    children had been cancelled by 00:11:42. Long model calls on other sources
    delayed admission of the next cleanup worker despite the cleanup transaction
    itself taking less than a second.

    Let a live cleanup worker execute at most eight independent 64-row
    transactions, stopping between batches once ten seconds have elapsed or a
    batch is partial.
    Reject an enclosing transaction so each batch releases its User fence.
    Every batch rechecks the failed graph and the task lease before and after
    writes. A lock timeout stops the loop. Claimed work and outcomes remain
    untouched. Status: deployed in `maraithon-00219-lxk`, successful workflow
    `34069227776`; `make build` passed. No tests were run. Live logs recorded
    1,414 cancellations in about 26 seconds across five workers, including two
    eight-batch workers that each cancelled 512 jobs. The slowest transaction
    took 1,486 ms. The old Gmail graph's remaining claimed retries then retired
    normally; all children were terminal by 00:21:14.

40. **Shared model names collapse interactive and background capacity.**
    Production points primary, chat, fast, and routing tiers at the same model.
    Model-based classification therefore sends all of these requests to the
    three-slot reasoning bucket, despite the existing separate chat budget.
    The assistant's streaming client and default harness also call the generic
    completion API instead of its chat counterpart.

    Explicit chat and routing APIs now select chat capacity independently of
    model identity. Both streaming and non-streaming assistant paths use them;
    streaming fallback retains the same capacity class. Generic requests and
    durable Effects retain model-based classification. Provider cooldowns stay
    shared across buckets. Status: deployed in revision `maraithon-00220-k78`
    through `62c40c63`, successful workflow `34070458277`; compile passed.
    No tests run under the manual-first policy. Interactive chat has not yet
    been manually exercised under source load.

41. **Source catch-up uses only three background model workers.**
    At 00:35:54, replacement Gmail graphs had completed only eight of 300 and
    eight of 175 children; Slack had eleven of 25. No replacement child had
    failed. The one-minute SQL window totaled 6.85 seconds, all 64 partitions
    retained live leases, and scheduled checkpoint, wakeup, and heartbeat
    events persisted. No provider rate-limit or application error was returned
    by the revision-219 log check from 00:20 onward.

    Make model-worker concurrency configurable at runtime. The combined
    deployment will use six model workers, six source-tenant slots per queue,
    and eight reasoning slots, leaving two slots beyond the model-worker
    ceiling for direct calls such as Chief of Staff Effects. Interactive calls
    use the separate four-slot chat bucket from finding 40. The existing
    provider worker count, account ordering, fair admission, and shared
    provider cooldown remain in effect. Status: deployed through `e06dd8ae` in
    revision `maraithon-00220-k78`; compile and shell syntax checks passed.
    No tests run. Cloud Monitoring's pre-rollout steady interval, 00:26–00:38,
    averaged 36.80% CPU and 27.43% memory utilization. At 00:45:52 the durable
    tenant budget was six and six source model workers were active. The first
    post-rollout sample still saw three slots before the next recurring
    completion pass reconciled the configured budget. The final 00:53:58
    sample retained six workers, with Gmail at 26/300 and 26/175 children and
    Slack at 8/25; none of these graphs had failed children. Closure cursors
    still awaited settlement. CPU averaged 61.66% from 00:45–00:54, peaking at
    an 80.47% one-minute mean; memory averaged 35.35% in the available samples.

42. **A transient Mac page failure aborts the entire todo refresh.** The
    00:48 refresh loaded two pages, then received HTTP 429 on offset 400.
    Cloud Run reported no available instance; the app retained its older
    993-item snapshot and displayed the error.

    Read-only todo pagination now retries the current page up to three times
    for 429, 502, 503, and 504, with cancellation-aware backoff and short
    Retry-After support. Status: implemented in `19e358dc`, signed narrow Mac
    build passed, installed in place with the same signing requirement and
    pairing restored. The updated app loaded all 997 active todos at
    00:54:29. No transient failure occurred during that run, so the retry
    branch itself was not exercised live. Tests were not run. The server's
    instance-capacity rejection remains a separate investigation.

43. **Slack edits can create a second todo for the original message.**
    Read-only execution `4tqr2` confirmed three pairs for the same named work:
    each pair has one fractional Slack timestamp and another ending in
    `.000000`. The rows were inserted on September 5, about 45 minutes apart.
    Current source discovery preserves the raw timestamp. Execution `2m885`
    traced the rounded identities to three CRM mutation observations inserted
    at 14:19 on September 5. Their stored `metadata.ts` already ends in
    `.000000`, their thread timestamps are absent, and their provider event
    IDs are null. Execution `pbvft` proved all three are `message_changed`
    observations whose `target_ts` exactly matches the original todo's full
    timestamp. The acquisition and discovery fallbacks ignored that explicit
    target when `thread_ts` was absent, giving the edit a separate work identity.

    Status: `e5570dfe` uses the target message as the thread fallback for both
    grouping and deduplication, retaining the mutation identity for provenance.
    It passed `make build` and deployed in revision `maraithon-00222-njf`.
    Preview execution `4ltkx` failed read-only because its activity table name
    was incorrect. `bbsrb` returned no matches because the Slack account has
    a null `external_account_id`; its provider suffix identifies the workspace.
    Correcting that match in `gtx9t` found 96 distinct pairs. Its large log was
    truncated; `8lhtp` returned the complete result in compressed form.

    At review, all 96 pairs had distinct original and duplicate IDs, open status, the
    same owner/account, matching task identities, and no recorded user
    lifecycle activity. Two generated due dates differ only by seconds; the
    originals retain their more precise timestamps. Repair execution `9pfmd`
    completed successfully at 01:33:48.730. In batches of five, it locked and
    rechecked the reviewed snapshots and explicit observation targets, retained
    each original, and dismissed each duplicate through the Todo context with
    a reference to the original. Notes and source records remain intact, and outcome learning
    was explicitly disabled for this agent-authored maintenance. All 96
    duplicates were dismissed, all 96 originals remained open, and all 96
    duplicate notes were retained. Independent read-back `678bp` verified
    all 96 pairs with zero mismatches at 01:35:52.
    Tests were not run.

44. **Contact matching repeatedly reloads every active CRM person.** The
    ten-minute `h9k56` SQL window measured 3,640 calls to the full ranked
    contact-scan query, consuming 84.64 seconds (28.01% of SQL time).
    `Crm.people_for_contact_scan/1` is the matching query; single-contact
    callers reload the full collection for every lookup. The first correction
    batches message list/search/chat serialization, pending-reply observations,
    and the identifiers within a person upsert. All use the existing ranked
    matcher, retaining contact normalization and match ordering. Status:
    `9403199d` passed `make build` and deployed in revision `maraithon-00221-npj`
    through successful workflow `34071688696`. Execution `2m885` then identified
    the principal workload: 163 new Calendar observations contained 3,586
    participants, versus twelve Gmail participants and one Slack participant.
    `01d41dc5` resolves existing participants once per observation, while misses
    use the ordinary fresh lookup/upsert path and can see earlier creates.
    This follow-up passed compile and deployed in revision 222.
    Production savings are not yet measured. Tests were not run.

45. **Relationship attempts enqueue follow-up work without a learned result.**
    The handler unconditionally enqueued communication scoring, graph refresh,
    person deduplication, goal discovery, and enrichment after attempting a
    window. This includes failed attempts and already-completed replays.

    Only a successful result with a positive observation count now triggers
    those jobs. Failures keep their normal retry result, and completed-window
    replays remain no-ops. Status: `4cfc45fc` passed compile and was pushed in
    workflow `34071688696`, revision 221. No tests were run. Execution `2m885`
    found all thirteen inspected relationship jobs had positive observation
    counts, so this defect did not explain the measured refresh burst. It
    remains a correction to failure and replay handling.

46. **A rollout can restart an entire completion graph.** Revision 221's
    rollout interrupted six closure model calls, all retained as
    `provider_outcome_ambiguous` at 01:05:27. The existing graph-failure policy
    abandons the siblings and reacquires the source window. The preceding
    sample had Gmail at 38/300 and 36/175 and Slack at 22/25 completed children.
    No cursor advanced. Previously persisted completions remain evidence-backed.

    Status: `SourceClosureRecovery` prepares a new publication for the latest
    interrupted live window. It reuses completed job IDs and copies only
    abandoned children into fresh jobs. Eligibility requires an unchanged
    lower cursor, compatible evaluation/partitioning versions, intact bound
    payloads, matching account and batch identities, terminal predecessor
    children, and exact completed task evidence. Fresh acquisitions capture
    their lower cursor. The initial version-1 implementation also accepted
    older graphs when the cursor predated their acquisition. Version 2 now
    requires an explicit matching lower cursor and excludes all version-1
    evaluations because of finding 49. The existing fenced finalizer still proves
    complete coverage and commits the cursor. No original job, ambiguous
    outcome, source-cycle proof, or published child list is rewritten.

    Read-only projection `wnfkh` inspected both stored predecessor graphs:
    account 1 would reuse 69 of 300 children and rerun 231; account 2 would
    reuse 73 of 200 and rerun 127. The projected new parent identities and
    unique reused IDs matched. Loading and verifying the plans took 9.35 and
    2.77 seconds. A diagnostic-only structural DateTime comparison emitted a
    warning; both printed acquisition timestamps independently establish that
    the selected replacements were after the intended cutoff. The application
    uses `DateTime.compare/2`. The implementation additionally checks the
    acquisition's exact completion evidence. `make build` passed; no tests
    were run. Commit `0137657e` deployed in revision `maraithon-00223-9vh`
    through successful workflow `34074912781`. At 02:08:57, observer `ztf7l`
    verified account 2's new 184-child publication reused all seven completed
    predecessor jobs and had completed three fresh children. At 02:10:57,
    account 1 also published its replacement, reusing all 41 completed jobs.
    Both graphs together preserved 48 completed batches and had finished nine
    additional batches. Full settlement remains open.

47. **Waiting finalizers repeatedly load encrypted child payloads.**
    `completed_child_results/1` loaded full background-job rows and verified
    every payload binding before checking whether the graph was still running.
    Each pending poll therefore read source bundles and results for up to 300
    current children without using them. Completed results were also reordered
    with a repeated linear search.

    Status: `fc7f3837` first selects only child IDs and statuses. Once all are
    complete, it loads and verifies their payloads, checks the returned count,
    and restores publication order through a map. Missing, failed, cancelled,
    and pending children retain their existing outcomes. `make build` passed;
    tests were not run. The commit deployed in revision 222.

48. **Blank Gmail messages prevent an exact completion batch from settling.**
    Read-only diagnostic `mxxnh` found one acquired message with no usable
    subject or body in each Gmail account. `evidence_item/2` dropped those
    records, leaving 29/30 and 7/8 expected source references. The exact
    coverage check consequently rejected both batches before any model call.

    `32d70d26` retains blank records in exact mode so their source identities
    remain covered. They cannot match a completion quote, and a bundle with
    no actionable text or subject does not justify a model call on its own.
    The ordinary non-exact filtering remains unchanged. `make build` passed;
    tests were not run. Read-only projection `r4kqc` ran the changed extractor
    over the same stored failing bundles and produced 30/30 and 8/8 references,
    with no missing or extra identities and no provider call or mutation.
    Deployment workflow `34073869387` succeeded at 01:46:21 for code through `32d70d26`,
    including the previously queued Slack identity, participant batching, and
    finalizer payload-read fixes.

49. **Exact closure prompts include evidence outside their sealed bundle.**
    Account workers deliberately check todos from every source, so they no
    longer pass `source_account_id`. The collector used that option to omit
    global CRM and local-message evidence. The exact coverage check ignored
    records without a source reference, allowing unbound evidence into these
    decisions. Read-only execution `7f66n` found 120 Calendar observations
    and 80 iMessages, totaling 39,160 encoded bytes, added to every Gmail batch.

    The collector now excludes persisted global evidence in exact mode, and
    the validator rejects non-health records without a source reference.
    The general cross-source backstop retains its broader evidence sources.
    Evaluation version 2 retires incompatible reason jobs and finalizers
    through ordinary fenced cleanup; recovery cannot reuse version-1 results.
    This intentionally requires one fresh scan under the corrected contract.
    Previously recorded todo completions and original job outcomes are not
    rewritten. Read-only execution `zlf4l` completed successfully at 02:24:35
    and verified the fixed collector matches source-only evidence in all
    twenty inspected Gmail partitions, with strict reference validation.

50. **Older source partitions spend model calls on impossible closures.**
    Quote authorization already requires evidence strictly after the todo's
    request or latest reopening. Exact evaluation now applies the same gate
    before calling the model. It retains all source context for the remaining
    candidates and records negative decisions as policy evaluations with
    reason `no_later_source_evidence`. Finalization retains complete todo and
    source coverage; a model evaluation in another partition takes precedence
    when choosing the aggregate receipt. The policy never claims a closure.

    Read-only projection `zlf4l` used the original 899-todo batch membership
    across 460 Gmail children. It ruled out 10,472 of 17,980 todo-partition
    comparisons and left 68 complete batches needing no model call. For the
    first todo batch in each of twenty source partitions, scope filtering
    reduced prepared requests from 86 to 68, and temporal filtering reduced
    that further to 46. These are prompt-preparation projections, not observed
    provider calls or latency savings. `make build` passed with warnings as
    errors; no automated tests were run. Commit `053bdde4` deployed in revision
    `maraithon-00224-l5j` through workflow `34076511804`, which succeeded at
    02:34:04. At 02:39:33, observer `2xl2b` verified two completed Gmail batches
    with forty policy decisions, zero model calls, and all 8/8 and 33/33 source
    references retained. Other sampled batches mixed policy and model decisions
    with full manifests. Account 2 reached 47/184 completed children at 02:41:34
    without an error before the next rollout.

51. **Dependency waits trigger provider throttling and failure backoff.**
    Discovery and closure finalizers returned `retry_after` while their own
    children were still running. The generic runner blocks the shared
    `runtime_model_user` / `model` rate-limit key for this result, then starts
    incrementing failure attempts after twenty such polls. An ordinary graph
    wait could therefore delay unrelated model workers, grow into minutes of
    backoff, and eventually fail an otherwise valid scan. At 02:35:32,
    observer `2xl2b` found the abandoned Gmail graphs' finalizers still pending
    for 02:37:02 and 02:41:02 with `source_closure_children_pending`.

    Both finalizers now use the existing fenced self-reschedule outcome at a
    ten-second interval, recording the pending-child count and retaining replay
    metadata. This path clears the ordinary failure counters and does not set
    a provider cooldown. Missing or failed children still fail finalization,
    and actual provider/capacity errors retain their retry behavior. The shared
    ten-second model-capacity constant was renamed to describe its remaining
    use. `make build` passed; no automated tests were run. Commit `9e289360`
    deployed as `maraithon-00225-twr` through workflow `34076982880`, successful
    at 02:42:46. Read-only observer `xvsn2` confirmed both old finalizers had
    reached twenty dependency retries and six attempts by final failure. At
    02:45:32, a discovery finalizer used the new waiting outcome, retained zero
    attempts and no error, and scheduled its next poll exactly ten seconds
    after the prior one. The shared model cooldown remained unchanged since
    02:41:40. By 02:53:36, both Gmail closure finalizers also used ten-second
    waiting outcomes with zero attempts, no error, and no provider retry count.
    The shared cooldown was still unchanged. Complete catch-up remains open.

52. **Changing prompt prefixes prevent reuse of repeated closure evidence.**
    Exact closure batches placed changing todo JSON and the current timestamp
    before their repeated source material. The evidence itself began with a
    timestamped source-health record. Prompt preparation was already quick
    (17 ms median across 100 live batches), but 150 completed model calls used
    3,850,942 input tokens between 02:48:17 and 02:53:38. The logged cost is a
    list-price estimate, not cache-adjusted provider billing.

    Prompts now place source activity first, followed by health context, todo
    candidates, and the current time. Exact batches share an opaque session
    key derived from the user and sorted source references. Request budgeting
    validates the key and the OpenRouter adapter forwards it. This follows
    OpenRouter's documented automatic Moonshot caching and
    [session routing](https://openrouter.ai/docs/guides/best-practices/prompt-caching).
    Source content, evaluation rules, and recovery version remain unchanged.
    Provider-reported cache read/write token counts are emitted through the
    numeric log allowlist; unreported values stay null rather than implying
    zero usage.

    Read-only projection `chxjt` completed successfully at 03:02:52. For two
    consecutive todo batches against the same source partition, the common
    prompt prefix increased from 3,909 to 50,149 bytes for Gmail account 1,
    and from 3,909 to 50,475 bytes for account 2. Both retained forty candidates
    per batch and their respective two/four prompt chunks. Each pair shared
    its expected session key. The projection made no model calls and changed
    no records. Commit `1e783f0d` deployed successfully as revision 226 in
    workflow `34078364173`. Production reported positive cache reads on all
    four sampled initial calls. Three revision-227 calls at 03:15:37–03:15:43
    each reused 20,864 tokens out of about 30,000 input tokens (about 69%);
    other calls reused less. This proves reuse, not a uniform cache rate or
    a measured billing reduction. `make build` passed; no tests were run.

53. **Closure settlement omitted the policy decision field mappings.**
    At 03:05:55, Gmail account 2 reached finalization, but receipt selection
    crashed in `SourceCycleSettlement.known_atom("evaluator")`. The shared
    map reader eagerly resolves its atom-key fallback even for persisted
    string-key maps. Finding 50 added reads of `evaluator` and `reason_code`
    without adding their fixed mappings. Both are now included in the closed
    key set. No dynamic atoms, settlement rules, or existing outcomes change.
    The fenced finalizer can retry against the already-completed children.
    Commit `c0be077c` deployed as revision 227 in successful workflow
    `34078620021`. Account 2 saved its 184-child, 172-source, 899-todo source
    cycle at 03:14:22 and advanced its closure cursor at 03:14:25 from
    `1788356523` to `1788748667`. A subsequent two-source delta was already
    processing. Account 1 still awaits catch-up. `make build` passed; no tests
    were run.

54. **Interactive chat rejects its own context before replying.**
    A signed-in Chrome question asking for three priority todos created run
    `57532ecb-6814-49f7-ba0b-e4652a880a59`, then degraded at 03:05:13 without
    recording a context step or displaying a reply. Read-only review `wq6lf`
    confirmed the `context_fetch` request failed bounded JSON validation.
    Field review `mcctk` found 382,365 bytes even without calendar/deep memory:
    open loops used 225,470 bytes and twenty todos used 95,302. Insight detail
    also contained atom values such as `deadline` and `source_evidence`, which
    the durable JSON contract rejects. The complete 93-tool chat request with
    empty context already used 89,841 encoded bytes in a local measurement.

    Context snapshots now use the shared JSON compactor within a 96 KB budget
    and explicitly mark compaction. Context steps use that same bounded
    snapshot. Enum values normalize to JSON strings. Interactive loop payloads
    now compact source context and tool evidence before both step recording
    and provider dispatch, measuring the complete encoded request against a
    120 KB target. Todo/open-loop projection preserves actionable fields;
    the current user request and complete tool definitions remain intact.
    Raw source records remain available through the existing tools. The
    provider's final request validation remains authoritative.
    Read-only projection `phf6n` completed successfully at 03:25:09. Its
    382,581-byte context became a 95,926-byte snapshot and a 116,388-byte
    complete request; context-step and provider validation passed, with the
    current request and all 93 tools preserved. The diagnostic's 96 KB
    preflight check returned false because preflight uses conservative scalar
    costs; the actual snapshot storage limit is 640 KB and the stricter
    256 KB context-step check passed. Revision 228's browser retry compacted
    the full live request from 559,908 to 116,440 bytes and reached streaming
    generation at 03:27:06, proving the original blocker resolved. A separate
    stream protocol mismatch then prevented delivery (finding 56).
    `make build` passed; no automated tests were run.

55. **Failed web chat replies leave a silent conversation.**
    The manual check showed only the saved user question after its run
    degraded; the working indicator disappeared and no error replaced it.
    Chat now reads the latest durable run status for both polling and page
    loads and shows a shared Catalyst alert for failed/degraded replies.
    Starting a new conversation clears the previous reply state. No internal
    errors or context payloads appear in the alert. `make build` passed; no
    automated tests were run. Revision 228's signed-in Chrome reload displayed
    the alert for the earlier failed run. The retry cleared it while working
    and displayed it again when the separate stream failure occurred.

56. **OpenRouter's final usage frame is mistaken for a duplicate completion.**
    Revision 228's read-only priority question reached three streaming model
    attempts at 03:27:06–03:27:24. Each returned output and usage, then failed
    with `stream_repeated_finish_reason`. OpenRouter's
    [streaming contract](https://openrouter.ai/docs/api_reference/streaming)
    explicitly repeats the terminal finish reason on a final content-free
    usage frame before `[DONE]`. The parser previously rejected every repeat.

    It now accepts the same finish reason only when the event has usage and
    exactly one content-free delta containing only content/role fields.
    Conflicting reasons, repeated content, provider errors, incomplete streams,
    and stream size limits retain their rejection paths. Delivery still waits
    for `[DONE]`. Commit `cd9ab604` compiled and deployed as revision 229
    through successful workflow `34079790305`. Chrome then displayed the
    requested three-item priority answer after one streamed generation. Run
    `9149bffb-7270-4e63-9734-49fffe35a411` recorded completed context,
    request, and response steps, with the response at 03:34:01. It then hit
    a separate completion-metadata failure (finding 57). No tests were run.

57. **Successful chat delivery is marked failed by raw route enums.**
    Revision 229 delivered the priority answer, but its run failed at 03:34:02
    while updating `result_summary`. The completion path separately copied
    raw `model_tier`, `task_class`, and `route_reason` atom values into the
    summary; start-run already uses `route_summary/1` to serialize them as
    strings. This violates the bounded JSON contract and produces a failure
    alert even though the answer was saved.

    Completion now merges the same existing `route_summary/1` projection used
    at startup, eliminating the duplicate field-copy path. The reply, tool
    results, and model routing stay intact. Commit `b9a61e2f` passed
    `make build` and deployed as revision 230 in successful workflow
    `34080167164`; no tests were run. A fresh signed-in Chrome conversation
    `2f8b091a-a119-4790-8084-0b8285ad8876` displayed the three requested
    priorities, returned its Send button, and showed no failed-reply alert.
    Reload retained the answer and successful display. The complete live
    request compacted from 561,427 to 116,419 bytes at 03:40:09. The read-only
    observer confirmed run `62321861-fd94-4b35-b781-b89aade00599`
    completed at 03:40:16.630 with no error, sixteen seconds after startup.

58. **Cached todo briefs retain expired time-relative advice.**
    Manual Chrome review of Michael Lippi's top-ranked todo showed a brief
    generated August 29 still instructing Kent on September 6 to confirm
    evenings by Monday August 31. The Uride brief also retained a passed
    "about 3 hours from now" deadline. `Brief.current/1` checks the version
    and todo-content fingerprint, with no time freshness check. These are
    existing saved briefs, not new output from the priority-chat check.
    Active briefs now expire after six hours or once a due time that was
    still ahead at generation passes. Closed work retains its historical
    brief. Web detail refreshes on open; the existing mobile detail-open event
    schedules an individual refresh. Background ingestion skips briefs whose
    content still matches and only expired with time. Refresh jobs deduplicate
    against the prior generation timestamp. No inventory-wide timer was added.

    Shared projections hide an expired draft only when it exactly matches
    the stored generated reply. Saved edits remain available, and generation
    preserves them under the row lock. A changed todo fingerprint rejects a
    delayed result; first-generation draft updates also compare the draft
    present when generation began. When an edited reply is retained, the new
    generated brief cannot claim that sending the edited text completes the
    todo. New prompts require explicit calendar dates and treat past deadlines
    as overdue. Web loading/failure states no longer reveal the expired brief.
    `make build` passed; no tests were run. Shipped in `35d1c852`, revision
    `maraithon-00231-s8p`, successful workflow `34081063445`. Read-only
    projection `6c2ks` completed successfully at 03:50:50 UTC: Michael,
    DuraServ, and Uride's expired, unchanged generated drafts projected to
    empty maps without altering stored data. Signed-in Chrome refreshed
    Michael at 03:55, DuraServ at 03:57, and Uride at 04:02. The old August 31
    advice and three-hour countdown are gone; the briefs describe passed
    deadlines as overdue and propose explicit September dates. Michael's
    suggested availability still requires Kent and Christina's confirmation.

59. **A named reply can silently target a digest sender and its thread.**
    DuraServ's fresh brief says `to: Tal`, while its source is Runner's
    September 5 daily digest. Read-only metadata review `pdm4w` completed at
    04:03:38 UTC and exercised the existing pure recipient/thread helpers:
    it resolved to `runner@hey.runner.now` in digest thread
    `1a07029429174d3e`. Michael's explicit email correctly resolved to
    `m.lippi@ipcsecurities.com` in his original thread. No draft was saved and
    no email was sent. Earlier review `v67rh` failed on a nil account label;
    `vk7f6` returned HTTP errors because the bounded HTTP task supervisor was
    absent. `pdm4w` started that leaf supervisor alongside Req, Vault, and Repo.

    Explicit draft recipients now take precedence without fallback to an
    unrelated sender or a fuzzy contact match. A name-only generated email
    remains copyable, but direct send requires one concrete external address.
    The web page explains the missing address and removes its ready/send
    controls. The prompt asks for a source-backed address or a step to find it.
    Shared preparation also checks the source's actual participant and subject
    before inheriting thread/reply headers, and uses the account that supplied
    the source. Gmail draft creation and its saved send payload share this
    routing map. New routing metadata prevents the primer from reusing an old
    prepared Gmail action based on body text alone. `make build` passed; tests
    were not run under the manual-first policy. `00fe2479` deployed through
    successful workflow `34081849265`. Read-only projection `99k5p` completed
    successfully at 04:07:30: Michael retains his explicit address, personal
    mailbox, and original thread; DuraServ has no resolved address and direct
    send is false. Signed-in Chrome on revision `maraithon-00232-z6x`
    shows “Recipient email needed” for DuraServ, retains Copy/Open, and omits
    Ready to send and Send email. Michael retains Ready to send and Send email
    with his original conversation visible. No email was sent.

    The account follow-up requires a concrete source/saved mailbox before
    creating a draft. Both Gmail API helpers and direct message sends now
    preserve an explicit account choice: a missing token returns its error,
    instead of retrying with the default Google account. Implicit default
    selection remains available to callers that do not specify an account.
    This follow-up compiled successfully and shipped as `51167f39` in
    revision `maraithon-00233-r7s`, workflow `34082107360`; no test suite was run.

60. **Exhausted model retries discard completed closure batches.**
    Gmail account 1 retained 296/299 results after revision 231's rollout.
    One additional child completed, but two exhausted their three attempts
    with `timeout`. The finalizer was abandoned. Recovery's error allowlist
    recognized rollout interruptions but excluded model timeouts and the
    observed `cross_source_completion_incomplete_decisions` failure. It
    therefore rejected the reusable graph and acquired a fresh 305-source,
    905-todo window with 276 children and zero reused results at 04:06 UTC.

    Those two bounded evaluation failures now qualify for the existing
    immutable recovery path. Only failed children get fresh jobs. Completed
    siblings still require matching exact task outcome evidence; the sealed
    source identities, unchanged lower cursor, and full finalizer coverage
    remain mandatory. Nothing resets a failed task or advances a cursor by
    assertion. `make build` passed; tests were not run. Read-only projection
    `btwjn` completed successfully at 04:11:08 UTC. Against the actual failed
    299-child graph it retained 297 completed jobs and produced only two new
    handoffs. No jobs or cursors were changed by this projection. `31f21cde`
    shipped with `51167f39` in revision `maraithon-00233-r7s`, successful
    workflow `34082107360`. Full live catch-up remains in progress; the fresh
    276-child scan started before this fix and cannot reuse a different sealed
    source window.

61. **Reminder messages cannot find older versions of the same open work.**
    Exact source discovery disables embedding lookup and presents only the 80
    most recently updated todos. A daily Slack escalation gets a new message ID
    and thread, so the model cannot see the original task outside that window.
    Read-only execution `c9tml` completed September 7 at 04:34:12 UTC and found
    four open versions of Uride Task #126 and three of Task #140. Chrome search for “Josue Alexander” independently
    displayed all four active versions. The original contains the actual
    Sudbury-to-Edmonton transfer request; reminders lose that specific context.
    Their source
    account and channel match, while their reminder timestamps differ. The
    independent completion backstop also completed at 04:32:26 with no error;
    that loop does not repair duplicate intake.

    Add a bounded local text search over the user's open work before prompt
    construction. Batch candidate searches, hydrate only five matches each,
    and present relevant older work ahead of recency. Text similarity retrieves
    context; the model still compares task reference, person, account, owner,
    and requested outcome before choosing update. Preserve that relevance order
    when compacting oversized prompts. The change adds no embedding/model call
    and does not alter source cursors, exact decision coverage, or ownership.
    Status: implemented locally; `make build` passed. Actual source retrieval
    and the new SQL path are being checked through read-only Cloud Run jobs
    `vgsgx` and `swcp8` initially failed because the diagnostic used a nil
    external account ID. Corrected execution `7kb92` resolves the workspace
    from the connected provider. It completed at 04:43:21, but Slack returned
    no message at either exact timestamp, so it did not exercise retrieval.
    The large work preview also exceeded the logging line limit. The follow-up
    reads sealed source handoffs and emits bounded work batches. Its first
    attempt `sl25t` failed diagnostic compilation because datetime query values
    were not interpolated; the corrected script was compiled locally without
    execution before resubmission. Corrected execution `jk22b` succeeded at
    04:49:37 and returned 1,169 active Uride escalation rows in bounded batches.
    There are 385 unambiguous task-number groups with 703 extra entries and
    81 rows with missing/multiple task references; these counts are candidates
    for consolidation, not authority to dismiss every row.

    The first text-search check took 209–337 ms per example and recovered older
    reminders outside the recent 80, but common template words still excluded
    the richer original. Ranking now weights each overlapping term by inverse
    frequency in the user’s open work, so distinctive people/task references
    outrank generic escalation wording. Read-only execution `mdtfn` returned both exact sealed reminder bodies and
    recovered all four versions for each sampled task, including the original
    detailed records outside the recent 80. These weighted lookups took
    244–424 ms per example. `744ba7e1` passed `make build` and was pushed;
    workflow `34084822177` succeeded and revision `maraithon-00234-g2q`
    serves 100% of traffic. The original 703-extra count excludes
    task references present only in notes: Task #140 also has an older fourth
    version, whose notes explicitly identify the task.

    Two groups (Tasks #126 and #140) were manually reviewed against task ID,
    person, requested outcome, account/channel, source snapshots, notes, and
    user activity. Execution `hrznn` consolidated their six later reminders
    into their two oldest detailed todos. It verifies the sealed source payload,
    locks and compares every reviewed todo, rejects user activity or a shared
    insight, records duplicate links, and uses the Todo dismissal context with
    outcome learning disabled. It completed at 04:59:14: all six duplicates are dismissed, both originals
    remain open, and all eight notes are retained. Chrome independently shows
    one Josue task and one Task #140 document-review row; distinct Tasks #325,
    #410, and #411 remain in the Kamaldeep search. No real-world completion
    was asserted.

    Read-only `wb45x` retrieved all 290 targeted September 7 reminder bodies
    from 70 sealed jobs across 15 cycles and a fresh snapshot of 1,168 active
    escalation todos. Review compared external task reference, person, city,
    work type, original request, repeated-reminder wording, account/channel,
    and user activity. It selected 287 groups containing 687 later reminders.
    Three groups were excluded: #160's original describes a move to Vancouver
    Island while its reminders name North Bay; #149 has no city; and #158's
    oldest todo describes Hardik in Edmonton while its reminders name Aakash
    in Belleville. Task number alone cannot justify those merges.

    `h987c` completed at 05:16:20 and consolidated 657 duplicates into 271
    originals. All original and duplicate notes remain intact. It verifies the
    sealed message again, locks each group with the user, compares SHA-256
    fingerprints of all reviewed fields plus updated_at, checks current user
    activity, preserves source links, and dismisses duplicates without outcome
    learning. Sixteen groups (#204–219, thirty proposed duplicates) rolled back
    because rows changed after the review; they require a fresh comparison.
    Chrome's refreshed main list shows 561 active items, down from 1,218.
    Its Kamaldeep search shows four distinct tasks, with one #325 and one #140.
    Read-only `nv5nw` compared all 46 rows in the sixteen skipped groups:
    task wording, notes, source IDs, owners, statuses, and user activity are
    unchanged; only updated_at differs. A fresh fingerprint review therefore
    permits retrying those thirty reminders without weakening the write fence.

    `wffsm` corrected the CRM observation join to metadata channel/timestamp
    plus workspace and recovered fourteen original source messages. The source
    itself uses Task #158 for both Aakash's driving-schedule question and
    Hardik's deadline extension, proving the ID is not globally unique even in
    one channel. Aakash's three reminders can be consolidated into Aakash's
    original while Hardik remains separate. The original #160 names Fabian in
    North Bay and explicitly says he moved to Vancouver Island; #149 identifies
    Gurdeep with city unknown, matching its reminders' null city. Their original
    requests and repeated reminders are consistent. Follow-up `hww5v` is
    consolidating these nine reminders plus the thirty freshly compared rows.
    `hww5v` consolidated all thirty changed-row reminders. The three special
    groups still had older fingerprints and rolled back again; `h5t5x` confirmed
    their only changed fields are update timestamps, with no user activity.
    Final special-case repair `94n2f` used those freshly reviewed snapshots
    and consolidated all nine remaining reminders, with all notes retained.

    `z88br` recovered all nineteen older reminder bodies from 149 sealed jobs
    across six discovery cycles. Their task, person, city, work type, and
    original requests match. `kqws8` consolidated their 23 duplicates at
    05:29:31, preserving every note. Independent read-back `h5t5x` verified the
    earlier 693 dismissals plus 289 retained originals (982 rows) with zero
    status, parent-link, or note mismatches. Final read-back `jsqvf` completed
    at 05:36:45 and independently verified all 725 dismissed reminders and
    311 retained originals (1,036 rows), with zero status, parent-link, or note
    mismatches. The only remaining repeated task reference is #158, where
    source evidence proves two different people and requests. Those two
    originals correctly remain separate. Chrome's original tab was refreshed
    and visibly shows 499 active items (plus 27 done and 863 dismissed in the
    database). This completes the reviewed reminder consolidation; no task was
    falsely marked completed and no source cursor or runtime proof was altered.

    Revision 234 recovered its Chief at 04:59:04. The 04:59:59 observer sample
    had 60 ready and four preparing partitions, all with live leases, six running
    assignments, and no termination-requested task. Current matching Effect
    evidence is complete (1,202 outcomes, zero missing). The interrupted Gmail
    graph retained 210 completed children; five ambiguous provider outcomes
    and the remaining abandoned work require recovery. That recovery and a
    full scheduled cycle on revision 234 were not yet verified at that sample.

    Gmail's next acquisition reused all 210 completed children. At 05:01:53,
    a revision-234 instance received SIGTERM and four tasks stopped with
    `:shutdown`; the reason for that instance shutdown is unproven. The Chief
    recovered on the remaining instance at 05:02:31. The 05:02 sample briefly
    showed 27 draining partitions and eight unassigned; all 64 were ready/live
    again by 05:04, with no pending termination. Acquisition
    `637d5d85-04e4-439f-bf29-5f1a9514b505` reused all 214 completed children
    from the interrupted recovery graph. By 05:08, 237/276 were complete, two
    running and 37 pending, without child errors. The Chief's next Effects
    completed at 05:05:15; all 1,205 known Effect outcomes have matching
    evidence. Its new checkpoint and account 1's final cursor advance remain
    unverified. Cloud SQL showed two startup lock timeouts at 04:59:07, with
    no matching database errors at the later SIGTERM.

62. **Team escalation ownership is being inferred as personal obligation.**
    The exact sealed bodies for Tasks #126 and #140 name
    `recruitment_supervisor` as owner. Their generated todos nevertheless claim
    Kent is the exclusive decision/review bottleneck. The current prompt requires
    operator ownership, but does not have evidence here binding that role to
    Kent. A focused clarification was requested about whether routine Uride
    onboarding escalations belong on his personal list.

    The prompt also contained a conflicting shortcut: default ownership to the
    main user unless the generated candidate clearly names someone else.
    `afeeb604` removes that shortcut, requires source-backed personal ownership
    before the source-intake positive admission rules, and distinguishes a
    separate intervention request from the team member's underlying task.
    Channel membership, connected-account access, and overdue/escalation wording
    do not transfer ownership. An explicit user request to track team work is
    still supported. Reasoning must identify who owes the action and the source
    evidence connecting them to the operator. `make build` passed; workflow
    `34085600531` succeeded and `maraithon-00235-pk2` serves 100% of traffic.
    No tests were run.

    Read-only `h5t5x` inspected two naturally completed intake jobs on revision
    235 (`1f94051c` and `85f165fd`). All seven decisions updated existing work;
    none created another duplicate. The sealed messages describe five team-owned
    tasks (#408–412), and their template wording says "Do this" and "when you
    have done it". This confirms update routing, not personal ownership. The
    model continued to refresh the existing team work after the first prompt
    change. `248bd58e` additionally requires the ownership check for updates,
    excludes previous generated todos/decisions and inferred relationship
    memories as role-assignment proof, and explains that template "you" refers
    to the named task owner. `make build` passed; workflow `34087225973` is
    deploying this follow-up. It subsequently succeeded; revision
    `maraithon-00236-cm5` serves 100% of traffic and recovered its Chief at
    05:36:54. Read-only `6c29s` completed at 05:43:00 and inspected five
    naturally completed intake jobs on revision 236. All skipped the same
    routine Amazon shipment notification; no fresh Slack intake was available,
    so the team-ownership behavior remains unverified. All six source cursors
    were advancing and the list remained at 499 open, 27 done, 863 dismissed.
    The repeated identical Gmail input exposed finding 63 below.

    Existing team-work cleanup remains pending Kent's intended scope;
    source-verified duplicate repair is independent. Read-only execution
    `wb45x` completed its read-only source review at 05:10:12. The subsequent
    verified duplicate repair is recorded in finding 61. A direct CRM identity
    join in read-only `bztqn` returned no observations for 55 remaining rows;
    CRM mutation identity is separate from its metadata channel/timestamp, so
    the follow-up uses those provider fields plus the exact workspace.


63. **Source revision hashes change across the durable JSON boundary.**
    Read-only `6c29s` found five consecutive revision-236 intake jobs between
    05:37:49 and 05:41:57 evaluating the same unchanged Amazon shipment email.
    Their restored source records are identical, yet the one-hour safety overlap
    sends the message through the model again on each poll. The Gmail connector
    emits `internal_date` as a `DateTime`, and `SourceBundle` retains that struct.
    Acquisition hashes the raw Erlang term; settlement hashes the JSON-restored
    handoff, where the date is a string. The settled-revision lookup therefore
    cannot match the provider form to its own prior receipt.

    Normalize the full source item through its durable JSON representation
    before computing the deterministic revision digest. This preserves existing
    JSON-backed proof hashes and all body, label, and thread-context changes;
    it does not remove the safety overlap or rewrite historical receipts.
    Both discovery and closure use the shared helper. `make build` passed;
    no tests were run under the manual-first policy. Read-only `8rxjc` completed
    successfully at 05:46:33. The actual saved email had 20 discovery and 10
    closure receipts, all for one revision. Reconstructing the connector's
    `DateTime` form matched none under the old hash. The fixed hash matched
    every receipt and preserved the existing JSON-form hash exactly; both role
    filters reduced that settled source from one item to zero. This read-back
    made no provider/model calls and changed no ledger rows or cursors.

## Delivery state

Current server: `maraithon-00236-cm5`, code through `248bd58e`, deployed by
successful workflow `34087225973`. Current iPhone release: TestFlight `1.0.1`
build `20260906233635`, code through `1ba7bb51`, available to Founders via
workflow `34067357201`. The signed local Mac development app includes findings 32 and 42 and is installed
at `~/Applications/Maraithon.app`. Live checks verified
New Todo, saved wording and multiline notes after a fresh load, user completion,
the completed-row display, and Command-N/Escape. The two manual check items
are completed; these user actions are not automatic-closure evidence. The app
was returned to the unfiltered active list, which loaded 899 items after
the duplicate cleanup.
No public Sparkle release was made.


The first batch through `f3dfb2d8` deployed successfully using GitHub's existing
keyless `make deploy` workflow, run `34053264882`. Revision
`maraithon-00195-x7j` initially served 100% of traffic. The previously unpushed history was
already deployed through `d2608e73`; this delivery adds the backstop and fast
deployment changes. The same push triggered the configured mobile release
workflow for the already-present native updates (`34053264885`). It completed
successfully: TestFlight version `1.0.1`, build `20260906185611`, Founders group.

The second server batch through `4a2ded25` deployed successfully in workflow
`34053477349`. Revision `maraithon-00196-k5d` initially served 100% of traffic and
`/health` reported `ok` with the combined process role.

Local deployment was unavailable: the shell's active service account belongs
to another project, Kent's cached organizational logins require reauthentication,
and the other checked credentials lack deployment access. No credentials or
IAM grants were changed. Server fixes were committed and
delivered through the keyless workflows recorded beside each finding. `591e1ba7` separately records physical
Cloud Run revision/service identity on new runtime nodes and logs their node
IDs. This and the reopening fix (`3ffe1482`) deployed successfully in workflow
`34054377367`, revision `maraithon-00197-thz`, serving 100% of traffic.

## Stranded partition recovery

The 19:03 UTC snapshot isolated partition 31, epoch 160. No Agent leases or
unreconciled Agent incidents remain. The blocker is reserved background-task
assignment `efde0e1f-c57f-499d-9be8-26f8cfcade5a`, for closure acquisition job
`b7b6e422-b6d4-40ab-b42c-702db7a86748`, node
`0f3f3c54-7106-45dd-b55d-500de76ef9e2`. Its provider boundary is `not_entered`.
It blocks 148 connector, 99 model, and 13 provider jobs at that observation.

A reconciled Agent incident on that exact node carries owner generation
`3bbe378e-e0a9-4266-b8e7-f2e83f5760c9`. Cloud Run's 21:11:37 September 5 crash
log names that exact owner under revision `maraithon-00194-xqs`, establishing
the hosting revision independently of the reused protocol/deployment revision.

After verifying no traffic targeted it and the replacement served normally,
the retired revision was deleted. Its absence and successful deletion audit
were verified. Destruction evidence is retained outside the repo at
`~/.config/maraithon/agent-termination-evidence/task-efde0e1f-c57f-499d-9be8-26f8cfcade5a-destruction.json`,
SHA-256 `408e3071957eda76ed7fdc36f0cc0c0a05e7f26ccb6c264954f587a55d071d9c`.

Execution `maraithon-runtime-recovery-b778p` recorded the identity-bound
proof at 19:10:48 UTC through `TaskTerminationAttestations.record/4` and the
existing incident-role secret inside Cloud Run with two database connections.
Ordinary runtime reconciliation settled the task as `cancelled_before_provider`
at 19:10:49. The Chief of Staff recovered at 19:10:54. The temporary incident-role
job was deleted after saving its successful execution receipt outside the repo.
The first recovery execution was cancelled before use to add the API-token
secret reference required by release startup configuration.

At 19:12:54 UTC, all 64 partitions were ready with live leases, with no pending
termination requests. Eight discovery reasoning jobs had completed since
recovery, with more source work running. The Chief of Staff completed two
effects; all 1,104 outcome-known effect assignments matched complete outcome
evidence. Source watermarks and the latest checkpoint had not yet advanced;
the backlog and the active agent cycle still needed to finish. These observations
prove recovery, not yet complete source catch-up or full runtime health.

At 19:16:20 UTC, 21 discovery reasoning jobs had completed since recovery,
with ten left pending/running in that graph. All 64 partitions remained live.
Across the 205-second interval since the prior sample, storage verification
used 245 ms of 106,778 ms total database execution time (0.23%). Node renewal
used 17,194 ms (16.1%), and partition renewal 523 ms (0.49%). Verification is
no longer the dominant load. The Agent restart described in finding 8 still
prevented a fresh checkpoint, and account cursors awaited finalization.

## Verification policy

Use `make build` and direct production observations. No automated tests are
authorized for this routine iteration. Run database diagnostics only inside
Cloud Run job executions with an `eval` override and `POOL_SIZE=2`. This report
is a working list, not a claim that the objective is complete.

At 19:22:43 UTC, all 64 partitions remained ready/live and a new idle snapshot
was saved at 19:22:39. Since recovery, 28 discovery reasoning jobs and 44 closure
reasoning jobs had completed, with 1,108 outcome-known Effects and no missing
evidence. The cursors still awaited graph finalization. This sample predates
the deferred-ingestion deployment and does not validate that fix.

At 19:26:52 UTC, Slack discovery had advanced at 19:23:45 and the independent
completion backstop had completed at 19:23:48. Since recovery, 31 discovery
reasoning jobs and 54 closure reasoning jobs had completed. The leader-expiry
recovery was still converging: 13 partitions were ready, four draining, three
preparing, and 44 unassigned, with no active or termination-requested tasks.
This is a recovery observation, not a steady-state health result. Gmail catch-up,
freshly failed source graphs, deferred ingestion, and a complete periodic Agent
cycle/checkpoint remain to verify after the next deployment.

At 19:33:33 UTC, all 64 partitions had returned to ready/live, with two running
tasks and no termination requests. Discovery reasoning completions reached 74
since recovery; 90 were pending and two running. All 18 recurring schedules
were advancing without recorded errors, and all 1,108 outcome-known Effects
still had matching evidence. The next Agent checkpoint and wakeup were due at
19:35:07 and 19:35:25, respectively.

Querying failures by `failed_at` rather than historical aggregate strings found
eight interrupted model jobs recorded as `provider_outcome_ambiguous` since
recovery, plus three dependent graph/acquisition failures. No new invalid-JSON
or incomplete-decision failures appeared in this interval. Preserve those
ambiguous outcomes and let subsequent source cycles reevaluate unfinished
coverage. The deployment/recovery interruptions explain the current failures;
fresh Gmail cursor advancement still depends on completing its source graphs.


## Second recovery and stable processing

The reserved assignment in finding 12 belonged to retired revision
`maraithon-00200-zm4`, established by its node's physical Cloud Run metadata.
After verifying that no traffic targeted that revision, its deletion, absence,
and successful Cloud Audit deletion were recorded. Destruction evidence is
retained outside the repository in
`~/.config/maraithon/agent-termination-evidence/task-e398451c-7524-4eb8-9903-63663b0f57c8-destruction.json`,
SHA-256 `22ecb50d2e45bb85c21ed11f9f9aa935a4bb119c9e3c949678b5aeba73290ab5`.

Execution `maraithon-runtime-recovery-t9hgq` recorded the identity-bound task
termination proof and completed successfully at 19:55:57 UTC. The normal Chief
start action cleared its guard and persisted the desired running state; the
immediate response was `partition_not_owned` while reassignment converged.
The Watcher recovered the Agent eight seconds later at 19:55:59. Its successful
execution receipt is retained outside the repository, and the temporary
incident-role job was deleted. No cursor or ambiguous provider outcome was
rewritten.

At 20:14:28 UTC (`maraithon-todo-validation-f792r`), all 64 partitions were
ready with live leases, with three running tasks and no pending termination.
The serving node had remained the same since 19:52:02. The Agent guard had
zero crashes and no recovery requirement; its idle snapshot advanced at
20:14:20. All 1,108 outcome-known Effects retained matching evidence. Discovery
reasoning completions reached 158 since first recovery, with two pending and
three running; closure completions reached 61. All 18 recurring schedules
were scheduled ahead without persisted errors. Source cursors still awaited
complete graph coverage. No application errors were recorded on the current
revision between the Agent recovery and the 20:16 check. The moving periodic
wakeup described in finding 14 prevents calling the full loop verified yet.


At 20:19:21 UTC (`maraithon-todo-validation-98fj6`), Gmail account 2 discovery
had advanced at 20:14:44 and Slack discovery at 20:14:58. Open todos increased
to 942, with fresh source-backed discovery through 20:14:51. The second incident
assignment settled normally at 19:55:52 as `cancelled_before_provider`.

This sample also disproved sustained health: Cloud SQL reported another expired
node revival at 20:18:39 after a background task held a connection for 30 seconds.
This happened before the wakeup-fix deployment began. The runtime failed closed,
recorded one Agent crash, and settled four interrupted jobs as ambiguous instead
of inventing outcomes. No reserved task remained stranded; all 64 partitions
were ready/live again at 20:22:21. Execution
`maraithon-todo-validation-xcxn7` watches live database blockers to isolate the
remaining long transaction. Gmail account 1 and all closure cursors remain to
catch up, and full periodic work remains unverified.


At 20:42:30 UTC, all 64 partitions were ready/live on `maraithon-00204-r9k`.
The retired `maraithon-00202-fg4` node was draining and owned zero partitions.
The deployment's earlier best-effort HTTP drain had received 429. A temporary
zero-traffic revision tag reached a dormant instance, so no drain was requested
there; the tag was removed. A subsequent identity-checked invocation of
`Authority.begin_node_drain/1` committed the topology fence but returned
`partition_authority_lost` during workload cleanup. Ordinary reconciliation
completed the handoff; no incident attestation or outcome relabeling was used.
Two in-flight closure jobs were recorded as `provider_outcome_ambiguous` at
20:38:33 and require ordinary coverage recovery, not invented outcomes.

The latest sample had three running tasks, no termination requests, and no
queued/processing Agent directives. The Chief started at 20:39:10; its periodic
wakeup was due at 20:42:37. Fresh effects and checkpoints on this incarnation
still need observation. Closure reasoning had completed 75 jobs since initial
recovery, with 28 pending and two running. Discovery reasoning had completed
163, with 68 pending. Gmail account 1 and all closure cursors still lagged.
All 1,108 outcome-known Effects had matching exact evidence. The eight-minute
lock watch ending at 20:30:18 saw no transaction longer than 0.95 seconds; it
does not explain the earlier 30-second timeout.


At 20:46:00 UTC, the Chief's lease belonged to `maraithon-00204-r9k` and
remained live. Its scheduled wakeup fired at 20:42:37.783749, followed by two
settled, outcome-known completed Effects and a third running Effect. All 64
partitions remained ready/live. The retired 202 revision had no live Agent
lease, no owned partitions, and no active task assignments; its six historical
ambiguous outcomes remain intact. The 429 drain response was Cloud Run's
"no available instance" response, not an application authorization rejection.

The drained, zero-traffic revision `maraithon-00202-fg4` was deleted at
20:47 UTC after those ownership checks. No task outcome or proof was changed.


The Chief completed seven Effects in the scheduled cycle on revision 204 and
created a checkpoint at 20:49:36 UTC. The 20:51:22 observation landed during
revision 205's deployment drain (15 draining partitions, 49 unassigned, no
active tasks), so it is not evidence of post-handoff health. Kent's two intended
Google accounts and Slack workspace have tokens and are connected; the old
`kent@voteagora.com` Google connection has no tokens and reports `error`.
Its failed watch renewal does not explain the connected accounts' catch-up
backlog and must not be represented as a working source.


At 20:53:23 UTC, all 64 partitions were ready/live and the Chief was on revision
205. The database role can read/write the existing scheduling-watermark table.
The refreshed Mac displayed all 942 active items. Its five page requests ran
from 20:52:01.686762 through 20:52:38.658156, about 37 seconds in total; the
last three pages took 3.3–4.2 seconds each.

Deleting revision 202 did not immediately end its existing process: revision
logs and a newly registered node proved it remained alive. The companion has
a persistent WebSocket. Closing and relaunching the installed Mac app released
that connection, immediately followed by the old instance's SIGTERM at
20:58:16 UTC. This establishes that revision absence alone was not physical
termination evidence. No new incident attestation was recorded. Post-shutdown
ownership and proof cleanup remain to verify.


At 21:01:45 UTC (`maraithon-todo-validation-lprfk`), all 64 partitions were
ready/live on revision 206. No retired 202 node retained a live lease or owned
partitions; only its six previously recorded ambiguous outcomes remained.
The Chief held a live lease on 206, completed two new Effects, and persisted
an idle snapshot at 21:00:42. All 1,118 outcome-known Effects had matching
evidence. Three tasks were running and no task awaited termination. The
independent completion backstop and Agent ingestion both completed around
20:59. Closure/discovery cursors still awaited full coverage. Revision 207's
post-deployment observation (`maraithon-todo-validation-k6gj7`, successful)
followed at 21:08:06 UTC: all 64 partitions were ready/live on node `c7f08a86`,
the Chief held a live lease, three tasks were running, and none awaited
termination. The restart guard had no new crash since 20:18 and no recovery
requirement. All 18 recurring schedules had no persisted error. Slack discovery
advanced again at 21:03:15; Gmail and closure cursors still lagged. Since 21:02,
six discovery reasoning jobs, five closure reasoning jobs, and seven briefs
completed. Pending work included 58 discovery jobs and 81 briefs. The next Chief
wakeup was due at 21:10:42 and checkpoint at 21:13:15, so fresh periodic-cycle
proof on 207 remains outstanding. Between the 21:01 and 21:08 observations,
expensive verification accounted for about 2.53% of query execution time and
node renewal 7.71%. Cloud SQL recorded no error after the deployment through
the 21:08 log check.


At 21:13:46 UTC (`maraithon-todo-validation-z26vr`, successful), revision 207
still held all 64 ready/live partitions. Its scheduled wakeup fired at
21:10:43.484417, completed two Effects by 21:11:27, and created a checkpoint
at 21:13:15.590830. No new restart-guard crash was recorded. Discovery backlog
fell from 58 pending jobs at 21:08 to 24; briefs fell from 81 to 55. At 21:16:29
(`maraithon-todo-validation-xxsdc`), only one discovery reasoning job remained
pending, along with 38 briefs. However, Gmail account 1 closure repeatedly
references discovery acquisition `e5a82073`, whose finalizer failed. Discovery
and all closure cursors for that account still lag. This is a failed dependency
that needs inspection, not proof that catch-up has completed.


Execution `maraithon-todo-validation-wwdhh` explained the Gmail dependency:
63 of acquisition `e5a82073`'s 64 reasoning jobs completed, while job
`089197e1` became `provider_outcome_ambiguous` during the 21:02 deployment.
The finalizer correctly failed as `source_discovery_child_failed`. After the
remaining jobs finished, normal recurring discovery created acquisition
`2029a98b-1b2a-457c-ba3d-fecbd76b6b9d` at 21:17:22 with 66 fresh reasoning
partitions. This is ordinary recovery from an interrupted cycle; no receipt,
cursor, or ambiguous outcome was changed manually. The replacement cycle and
its dependent closure remain to finish before calling Gmail current.


The later observations supersede the earlier stable-looking revision-207
samples: further graph-preparation stalls interrupted work and tripped the
Chief's guard, as recorded in finding 22. Following that fix, execution
`maraithon-todo-validation-794nq` observed all 64 partitions ready/live on
revision 208 at 21:40:31 UTC, owned by node `8f5813b3`. The Chief had a ready,
live lease and zero new guard crashes; all 1,122 outcome-known Effects had
matching evidence. Its next wakeup and checkpoint were due at 21:47:01.
The large Gmail closure acquisition was still running, and no newly staged
graph was visible yet, so this sample does not prove graph publication.

That stable sample was superseded at 21:42:29 by another expired-node rejection.
Execution `maraithon-todo-validation-42sfn` observed three expired draining
partitions, 57 expired ready partitions, four unassigned partitions, and no
Agent lease at 21:43:33. The Chief's guard recorded one new crash, and Gmail
closure acquisition `1f5d8240` became `provider_outcome_ambiguous`. Source
catch-up, graph publication, and fresh automatic-completion provenance remain
outstanding. The ten-minute lock watch completed successfully at 21:48:35.

At 21:52:39 UTC, execution `maraithon-todo-validation-zxlc5` confirmed the
failed node's stored deadline was 21:42:28.854226, calculated at
21:41:58.854227 before its renewal lock wait completed. Normal recovery had
since restored all 64 ready/live partitions on revision 208; the Chief recovered
at 21:47:29, completed two Effects, and had matching evidence for all 1,124
outcome-known Effects. No task awaited termination. The workload still included
41 pending discovery reasoning jobs and 26 pending closure reasoning jobs.
No new staged graph or fresh automatic-completion provenance was visible.

Revision 209 recovered the Chief at 21:54:32 UTC. The observation execution
`maraithon-todo-validation-4w6j6` saw all 64 partitions ready/live on the same
node (`d07d5487`) at 21:55, 21:57, 21:59, and 22:01, with no new restart-guard
crash. Gmail closure acquisition `20ced29a` published 336 reasoning jobs and
completed at 21:56:26, demonstrating that large graphs now finish preparation
without the old long transaction. The scheduled Chief wakeup fired at 21:57:28
and completed two Effects by 21:58:16. Its next checkpoint remains to observe.

Execution `maraithon-todo-validation-64w64` inspected 12 completed closure
jobs. Each covered all 20 requested todos with no fetch/evaluation error and
found no supported closure. The sampled Slack batches each used nine model
calls for 411–415 source items, explaining part of catch-up latency. This proves
successful negative decisions, not a fresh automatic completion. Over the
21:59:07–22:01:07 query window, PostgreSQL spent 5.08 seconds executing queries
in total. The largest query accounted for 12.03%; the node write-lock query
accounted for 9.4%, and partition renewal for 4.92%. Expensive verification was
not among the top 12 queries. The execution completed successfully at 22:01:13.

The installed Mac app refreshed from 953 to 958 active items at 21:55 UTC.
Opening a todo loaded its source excerpt, Gmail link, suggested reply, and
actions successfully. No todo was completed, dismissed, or replied to during
this inspection; the app was left on its refreshed list.

The watch completed successfully at 22:05:42 UTC. Its final observation at
22:05:38 retained all 64 ready/live partitions on the same revision-209 node,
with a live Chief lease, no new guard crash, four running tasks, and nothing
awaiting termination. The scheduled checkpoint persisted at 22:04:32.512192;
all 1,126 outcome-known Effects had matching exact evidence. Four sampled
new Gmail children carried `parent_completion_v1` and belonged to their
completed parent's published 336-child list. They were still pending, so
execution of those new children remains to observe. At this point 25 discovery
reasoning jobs and 348 closure reasoning jobs were pending. Gmail account 2
discovery advanced at 22:04:40; Gmail account 1 discovery and all closure
cursors still lagged. Automatic completion with fresh provenance is still
unproven. These are remaining product outcomes, despite the improved runtime.

At 22:27:01 UTC, Gmail account 1's discovery cursor advanced for the first time
since September 2. Acquisition `13123827` completed all 69 reasoning jobs and
its finalizer, covering 278 source items. Slack discovery advanced at 22:27:10.
The observation execution `maraithon-todo-validation-2xv88` completed
successfully at 22:29:33; its last sample caught revision 211's handoff and must
not be treated as steady-state health.

Execution `maraithon-todo-validation-62hsg` observed all 64 partitions ready/live
on revision 212 at 22:40:34, with no new restart-guard crash. The Chief's
scheduled wakeup fired at 22:39:59 and completed two Effects by 22:40:29. All
1,134 outcome-known Effects had matching exact evidence; one task was running
and none awaited termination. A fresh revision-212 checkpoint remains due.
Cloud SQL showed no error after 22:37 through the 22:41 log check.

By this sample the old Gmail account 2 graph had settled all 336 children:
334 abandoned before model work, with its two ambiguous outcomes retained.
The old Slack graph also cleared its last pending child as abandoned; its 30
completed results and 17 ambiguous outcomes remain intact. The old Gmail
account 1 discovery graph retained 49 completed results, four ambiguous
outcomes, and 13 abandoned children. Eight staged closure children from an
interrupted Gmail account 1 acquisition were still pending. No source cursor
or outcome was manually relabeled.

Discovery watermarks for both Gmail accounts and Slack were now within roughly
a minute of the observation. Closure watermarks still lagged on September 2
(Gmail) and September 5 (Slack). Fresh closure cycles, automatic-completion
provenance, and sustained post-deploy processing remain outstanding. The
`62hsg` observation execution was still running at the 22:41 status check.

Execution `maraithon-todo-validation-62hsg` completed successfully at 22:44:39.
The subsequent watch, `maraithon-todo-validation-wf5kw`, completed successfully
at 23:00:36. Revision 212 persisted its scheduled checkpoint at 22:47:49 and
ran its next wakeup at 22:50:31, completing two Effects by 22:50:58. No Cloud SQL
error was recorded from 22:37 through the deployment handoff.

The packing change deployed successfully in workflow `34065190230`, revision
`maraithon-00213-vbb`. The Chief recovered at 22:55:11. All 64 partitions were
ready/live on the same node (`2ff4f1ac`) at 22:56, 22:58, and 23:00, with no new
restart-guard crash. At 23:00 there were three running tasks and none awaiting
termination; all 1,136 outcome-known Effects had matching exact evidence.

Eight Gmail account 2 batches had completed on 213. Sampled results covered
all 20 requested todos, used four to eight model calls for 12–41 source items,
and had no fetch/evaluation error. Those already-published handoffs retain
their original batch size. Their evidence differs from the prior Slack
samples, so this is successful processing evidence, not a measured speedup.
Gmail account 1 still had 550 pending children. Slack's two deployment-
interrupted children retained ambiguous outcomes, 32 further children had
settled as abandoned, and one remained pending; its finalizer was failed.
This remaining account-level starvation motivated finding 30.

Discovery cursors continued advancing, while closure cursors still lagged.
No fresh automatic completion was recorded. A new observation execution,
`maraithon-todo-validation-xr547`, was submitted to observe account rotation
and subsequent closure processing; it was starting at 23:03 UTC.


The first newly verified automatic completion closed todo
`087525a5-1d38-4e71-85cb-0ee79858d68c` at 23:00:47 UTC. Its exact closure job,
`fd546c1d-d720-4201-bd53-bc8d05e1585f`, completed with matching task outcome
evidence, checking 20 todos against 12 source items in eight model calls.
Execution `maraithon-todo-validation-khn99` completed successfully at 23:20:32
and verified that the recorded scheduling-confirmation quote occurs in the
stored Gmail source bundle, after the original request. This is real
source-backed automatic closure, distinct from the two manual check items.
The cross-source completion count lives under `result.cross_source.completed`;
the top-level sweep completion count covers only deterministic checks.

Execution `maraithon-todo-validation-xr547` completed successfully at 23:17:23.
By 23:15 and 23:17, all 64 partitions were ready/live on one revision-214 node.
No task awaited termination; all 1,140 outcome-known Effects had matching
evidence. A same-revision instance handoff earlier interrupted one Gmail
child, retaining its ambiguous outcome. Gmail's failed graphs still had 325
and 542 pending children at 23:17; Slack's fresh graph had three completed,
three running, and 19 pending children. These explicit counts show catch-up
was incomplete. Missing or delayed log lines are not evidence of graph cleanup.

Execution `maraithon-todo-validation-t4g6s` completed successfully at 23:20:18.
The scheduled checkpoint persisted at 23:18:13.884670, after the Chief's
23:12:05 wakeup and two Effects completed by 23:13:44. All 64 partitions stayed
ready/live, with no tripped restart guard or task awaiting termination. Over
23:18:13–23:20:13, PostgreSQL spent 8.95 seconds executing queries. Candidate
fair scheduling accounted for 23.28% (2.08 seconds across 207 calls), node
read/locking 13.61%, and partition renewal 2.78%. Expensive storage verification
was not in the top twelve. Discovery continued advancing; closure watermarks
still lagged. The larger Slack batches averaged 309 seconds, motivating
finding 31 rather than a claim of improved latency.


Execution `maraithon-todo-validation-nvp6z` completed successfully at 23:32:28.
Its 23:28 and 23:30 samples retained all 64 ready/live partitions on revision
215, with no new restart-guard crash or task awaiting termination. Discovery
cursors continued advancing. At 23:30, Slack replacement acquisition
`ab0bea85-bbd1-4bc8-b39a-f4ec258a9e67` had two completed, three running, and
20 pending children. Both completed batches checked all 40 todos against 476
source items in nine calls, with complete coverage and no fetch/evaluation
error. Closure catch-up remained incomplete.

The preparation log appeared on revision 215, but its numeric fields were
silently excluded by the closed safe-metadata schema. Use the existing
approved numeric keys instead: `candidate_count` (todos), `item_count`
(evidence), `count` (chunks), and `duration_ms` (packing time). This exposes
only counts and duration, with no source content or schema expansion.


The revision-215 latency probe `maraithon-todo-validation-p2s8g` observed eight
completed 40-todo Slack batches averaging 118.1 seconds against 476 source
items. The preceding revision-214 graph's six completed 40-todo batches
averaged 311.6 seconds against 472 items. This is a measured reduction in
completed-batch time with very similar input sizes, though it does not isolate
model latency from local packing. Every sampled successful new batch retained
complete coverage and nine model calls. The two-minute query window started
at 23:35:18; its final runtime measurements remain pending.


The revision-215 query window completed in execution
`maraithon-todo-validation-p2s8g` at 23:37:21. Its 23:35:18–23:37:18 window
included revision 216's activation, so the one-off storage verification calls
are startup work, not steady-state load. SQL execution totaled 15.44 seconds;
fair scheduling contributed 18.37%, and the node write-lock query 9.48%.
The final snapshot caught the deployment handoff (60 draining, four unassigned)
and is not a healthy steady-state observation. Before that handoff, revision
215 created a checkpoint at 23:35:58 and completed two Effects by 23:36:27;
all 1,142 outcome-known Effects had matching evidence.

Revision 216 recovered the Chief at 23:38:18.582 UTC. Execution
`maraithon-todo-validation-z2clz` observed all 64 partitions ready/live on node
`e4ba2b7b` at 23:39:07, with no new restart-guard crash and no task awaiting
termination. Gmail account 2's old graph was already fully terminal: 275
cancelled, sixteen completed, and 59 failed (including its retained ambiguous
outcome). Gmail account 1 cleanup was still in progress in that sample.
The old Slack graph retained eleven completed and three ambiguous outcomes,
with ten unclaimed children cancelled and its failed finalizer recorded.
No source cursor or ambiguous outcome was manually relabeled.

The production-safe timing keys deployed in `37494cc3` now report actual
packing measurements: the first two fresh revision-216 batches each prepared
40 todos against 690 evidence items into ten chunks, in 136 and 146 ms.
Completion latency and source-cursor advancement are separate outcomes still
being observed by the running `z2clz` watch.


At 23:41 and 23:43, the `z2clz` watch confirmed both old Gmail graphs fully
terminal, with their previous completion and ambiguous-outcome counts intact.
Fresh Gmail account 2 acquisition `4a528a15-cd06-4f3f-b8e4-e27fe682e26a` published
175 children; its first two completed by 23:43:10 with complete coverage and
no evaluation/fetch error. Slack replacement `cb721b54` also completed its first
two batches. Account 1 acquisition `993c7be3-f1e3-4e6a-a90e-fdb600925196` remained
in graph preparation, with 1,716 staged children at 23:45:11. These children
cannot do model work before the parent publishes its complete list. All 64
partitions stayed ready/live at each observation, and the restart guard had
no new crash. Closure cursors had not advanced. The next wakeup is due at
23:46:28 and checkpoint at 23:48:17. A two-minute performance/final-runtime
probe was submitted as `maraithon-todo-validation-pnbvp`.

Execution `maraithon-todo-validation-pnbvp` completed successfully at 23:51:21.
At 23:51:15, all 64 partitions were ready/live, with no task awaiting
termination or new restart-guard crash. The Chief's scheduled checkpoint
persisted at 23:48:18, following its 23:46:29 wakeup; all 1,144 outcome-known
Effects had matching evidence. Discovery cursors advanced, while Gmail and
Slack closure cursors still lagged. The 23:49:14–23:51:15 SQL window totaled
15.85 seconds: fair scheduling contributed 30.1% (4.77 seconds across 246
calls), node read/locking 8.03%, and partition renewal 1.93%. Expensive storage
verification did not dominate this window. Completed revision-216 batches
averaged 75.7 seconds for Gmail account 2 (six samples) and 109.0 seconds for
Slack (seven samples). These measurements precede evidence coalescing.

Findings 35 and 36 were pushed through `d5cc439c` in two semantic commits;
deployment workflow `34068079615` is running. A new read-only graph watch will
measure replacement graph sizes, completed coverage, and runtime progress:
`maraithon-todo-validation-ddc6q`, submitted at 23:52:59. It is still waiting
to start; the successful `pnbvp` execution is terminal and has not been rerun.

Workflow `34068079615` completed successfully, and revision
`maraithon-00217-wx6` serves all traffic. The Chief recovered at 23:56:49.646;
`ddc6q` observed all 64 partitions ready/live at 23:58:17 and September 7
00:00:19, with no new restart-guard crash or task awaiting termination. A
wakeup at 23:57:04 completed two Effects by 23:58:00. All 1,146 outcome-known
Effects had matching evidence. The next checkpoint is due at 00:06:49.

Both Gmail graphs survived the rollout: account 2 had eleven completed of
175 children, and account 1 had nine completed of 1,800 at 00:00:19. A Slack
call interrupted during rollout retained its ambiguous outcome. Its graph
finished cleanup with twelve completed, ten cancelled, and three failed
children; replacement acquisition `a531f423-4ecf-484c-99c0-a19246d19414`
published 25 children for 487 source items and 996 todos. Its first child
completed with full coverage and ten model calls. Discovery kept advancing;
closure cursors still lagged. `ddc6q` completed successfully at 00:00:28.

The existing 1,800-child graph does not automatically receive the new packing
layout. A read-only replay of its stored source partitions and todo snapshots
is measuring whether repacking would materially reduce it. Initial probe
`dgld6` failed before application startup at 00:00:52; the eval argument was
185,464 bytes. The replacement compresses that argument to 44,110 bytes and
was submitted as `maraithon-todo-validation-flbtj`. It restores stored source
bundles, verifies the original source-reference count, uses the live 40-todo
batch size, and only builds handoffs in memory: no provider/model calls, job
inserts, or cursor writes. A follow-up runtime watch, `2hpp7`, will inspect the
next checkpoint and identify the account behind a `watch_renewal/no_token`
failure observed at 23:58:19, without reading token values into logs.

`flbtj` completed successfully at 00:03:24 with the 300-handoff result recorded
in finding 37. `2hpp7` completed successfully at 00:09:00. Its 00:04:52 and
00:06:53 samples retained all 64 partitions ready/live and 1,146 proven
outcome-known Effects, with no new guard crash. Revision 217 persisted its
scheduled checkpoint at 00:06:58.257 and received its next wakeup at
00:08:02.327. The final sample caught revision 218's deployment drain and is
not a steady-state health observation. Two Slack model calls and one Gmail
discovery call interrupted during this rollout retained ambiguous outcomes;
both Gmail closure graphs survived, so the large account-1 graph still needs
the versioned upgrade rule.

The `watch_renewal/no_token` job references account 3's Calendar cursor for
`google:kent@voteagora.com`; that account was already in `error` status. It is
separate from the two connected Gmail accounts making discovery progress.

Workflow `34068694257` succeeded and revision `maraithon-00218-p5q` serves all
traffic. The new read-only watch `maraithon-todo-validation-wbvrp`, submitted
at approximately 00:09:50, will inspect cleanup of the 1,800-child graph,
replacement partition/version counts, completed coverage, and runtime leases.
Full source catch-up remains outstanding.

Findings 38 and 39 shipped in separate semantic commits, `9bb5d11e` and
`5ac6467a`, through successful workflow `34069227776`. Revision 219 recovered
the Chief at 00:19:59.359. Its 00:20:01 wakeup completed two Effects by
00:20:48; all 1,148 outcome-known Effects had matching evidence. Read-only
watch `maraithon-todo-validation-psjlh` observed all 64 partitions ready/live
at 00:21:14, 00:23:15, and 00:25:16, with no new restart-guard crash or task
awaiting termination. No Cloud SQL error was returned by the check covering
the rollout from 00:19 onward. The next checkpoint is due at 00:29:58;
the watch's SQL interval and final sample are still running.

The prior watch `wbvrp` completed successfully at 00:19:52; its final sample
caught rollout recovery and was not a steady-state health snapshot. The
following `psjlh` samples confirmed the old 1,800-child Gmail graph fully
terminal: 1,766 cancelled, fourteen completed, and twenty failed (nineteen
abandoned plus the one explicit repacking decision). The old account-2 graph
retained its 22 completed and one ambiguous outcome; its other children also
retired, and its finalizer failed normally before replacement acquisition.
No source cursor or ambiguous outcome was manually advanced or relabeled.

Account-1 replacement acquisition `b871ad9e-563e-493e-8b2e-6d3d6083ace8`
published 300 children for 294 source items and 997 todos, with version 1
partitioning and finalizer `4e6e7660-60d0-4e4f-9b6d-3a36336572d2`. At 00:25:16,
two children had completed. Each checked all forty assigned todos with no
fetch/evaluation error and three model calls, against forty and seventeen
source items respectively. This verifies the smaller graph in live use,
beyond the read-only packing profile. Account-2 replacement `bcaaaf01` was
still acquiring, while Slack replacement `b60adb64` had three completed of
25 children. All closure cursors still awaited full graph settlement.

`psjlh` completed successfully at 00:29:24. Its final sample retained 64
ready/live partitions, no task awaiting termination, and no new guard crash.
The account-2 replacement published 175 children for 168 source items and
997 todos, with seven source partitions and partitioning version 1. At
00:29:19 the two Gmail replacements had five and three completed children;
Slack had seven of 25. None of these replacement graphs had failed children.
The eight-minute SQL window totaled 68.32 seconds of execution time.
Background-job reads contributed 30.96%, graph inserts 11.95%, fair scheduling
3.67%, and partition renewal 1.84%. Expensive storage verification did not
dominate. This is a workload observation, not a CPU-capacity measurement.

Follow-up read-only observer `maraithon-todo-validation-ddks9` confirmed the
scheduled checkpoint persisted at 00:29:59.995 and the next wakeup arrived at
00:30:50.654. Its two Effects completed by 00:32:00.804; all 1,150
outcome-known Effects had matching evidence. At 00:34:52, all 64 partitions
were ready/live with no new guard crash or task awaiting termination.
Discovery cursors continued advancing, while closure cursors still awaited
settlement. The Gmail replacements each had seven completed children;
Slack had eleven of 25, with no failed children in any replacement graph.

Remaining work is to complete source closure catch-up, verify full graph
settlement, and assess model throughput under that workload. The model runner
and source-tenant budget currently allow three concurrent jobs. Production
uses the same model for primary, chat, and routing, which sends these calls
through the same reasoning bucket under the current model-based selection.
Capacity changes must account for interactive and Chief of Staff work as well
as source workers. No concurrency setting has been changed in this check.

Revision 220's observer `h9k56` completed successfully at 00:54:04. It retained
64 live/ready partitions throughout and recorded the 00:53:02 checkpoint,
with 1,154 outcome-known Effects and no missing evidence. The subsequent
`rnsgx` watch confirmed another checkpoint at 01:03:03 and 1,156 proven Effects.
Its final sample caught revision 221's rollout, with 52 draining and twelve
unassigned partitions, and is not a steady-state health observation. Revision
221 recovered the Chief at 01:06:46.657; recovery observer `z9zdf` is running.

Read-only source proof `2m885` completed successfully at 01:06:11. Two more
automatic completions have matching source identities, full stored quotes,
and exact task outcome evidence. Slack todo `c98ae5dd-2450-45ff-ad85-95e02de06977`
("Review the driver documents blocking Stalonne Kaze Fotsing (Sudbury)") closed
at 01:00:47 with source Task #357's explicit closed message. Gmail todo
`3b802a53-3e68-442f-9dfe-14e6ecb97481` (Loewith Greenberg onboarding) closed at
01:00:16 with Charlie's meeting-invitation reply. Their completing jobs were
`7dcb3c45-fd28-4b1f-a418-e18492d7675c` and
`d63c23be-bfbf-4c5c-8b05-4d193507476e`. A different Gmail partition covering the
same todo did not contain that quote; it was not the completing job.

Cloud Run rejected eleven requests between 00:47 and 00:51, including the Mac
page and health requests. The container maximum-request-concurrency metric
reported only one or two concurrent requests in that interval, below the
configured forty. One instance remained allocated to revision 220; the older
219 instance also remained allocated. No further 429 appeared in the check
from 00:54 onward. The rejection cause is still unresolved; increasing the
concurrency setting is not supported by these observations.

At 01:10:41, `z9zdf` observed revision 221 with all 64 partitions ready/live,
no task awaiting termination, the restart guard recovered and untripped,
and 1,158 outcome-known Effects with zero missing evidence. New Slack
acquisition `21e7fb31-79c4-4926-ab32-7c0ddddbcf8c` published 25 children; six
were running. A Gmail acquisition was active. The old account-1 children were
fully terminal (252 cancelled, forty completed, eight failed), with its
finalizer still pending. Closure cursors remained unchanged. The observer's
second sample began at 01:12:43; final output is still being collected.

A narrow read-only follow-up, `maraithon-todo-validation-pbvft`, was submitted
at approximately 01:12 to inspect the rounded Slack observations' event type,
target identity, and task reference. It does not modify source data or todos.
The worktree has the attendee batching commit and these audit updates ahead
of the deployed revision; no additional server push has been made.

Recovery observer `z9zdf` completed successfully at 01:12:52. Its second
sample retained 64 ready/live partitions and 1,158 outcome-known Effects with
matching evidence. All three abandoned predecessor graphs, including their
finalizers, were terminal. The replacement Slack graph had five completed
children and Gmail account 2 had one; neither had failed children.

Follow-up observer `bkxth` confirmed the 01:19:10.934 checkpoint and 1,160
outcome-known Effects with zero missing evidence. At 01:22:22 it retained all
64 live/ready partitions and an untripped, recovered guard. The current Slack
graph had 21/25 children complete, Gmail account 1 had 10/300, and account 2
had 14/200. All had zero failed children. Discovery cursors continued to
advance; closure cursors still awaited full settlement.

The Mac app refreshed successfully during this check and showed 995 active
items and 22 completed items. The completed list contains the Slack Task #357
and Loewith Greenberg completions described above.

Read-only review `v2t6t` inspected thirteen stored messages in the Loewith
Greenberg thread. Charlie's September 4 05:57 UTC reply apologized, accepted
responsibility, set out onboarding milestones, and offered an immediate
workshop. Jennifer's 13:42 reply accepted that plan and chose 2:30 that day;
Charlie's 16:35 reply confirmed the invitation was sent. This supports closing
the escalation/handoff todo. It does not prove the later implementation work
finished. The todo was left unchanged after this semantic review.

Observer `bkxth` completed successfully at 01:26:30. Its final sample retained
64 live/ready partitions, a recovered/untripped guard, and 1,160 outcome-known
Effects with no missing evidence. Gmail account 1 had 17/300 children complete
and account 2 had 24/200, with no failed children. The SQL window includes the
one-off duplicate preview's 15.28 seconds (12.93% of measured execution time),
so it must not be treated as an application-only performance comparison.

Read-only execution `8lhtp` confirmed all 25 Slack closure children completed.
Finalizer `8af9bbd6-f118-4857-9384-db7e26955b2a` completed at 01:27:13.211 with no
error, and `slack_closure_watermark` advanced to `1788743405` at 01:27:13.204.
This is the first observed full settlement of the replacement Slack scan;
the Gmail scans and the next Slack delta remain to be checked.

The Mac completion inspector was also opened manually. It shows the Loewith
Greenberg evidence quote, local completion time, original request, retained
notes, original Gmail link, and Reopen action. No status action was invoked.

At 01:35:52, independent read-back `678bp` verified all 96 repaired pairs with
zero mismatches: duplicate status, original status/title, both notes, source
identities, and both directions of the provenance link matched. The Mac app
then showed 899 active items, down from 995 before cleanup.

The same sample retained 64 live/ready partitions, the 01:29:11.692 checkpoint,
and 1,162 outcome-known Effects with no missing evidence. Gmail account 1
had 44/300 children complete and account 2 had 46/200. Both still had pending
children whose last error was `cross_source_completion_source_coverage_incomplete`.
This check compares the stored source-item references with extracted evidence
before making a model call. Read-only diagnostic `mxxnh` compares one affected
stored bundle per account to locate the omitted or extra references. It makes
no provider call and does not alter a job, todo, cursor, or outcome.

Revision 222 recovered the Chief at 01:47:01.647. Observer `9lg66` at
01:52:32 retained all 64 partitions ready/live, no task awaiting termination,
an untripped guard, and 1,166 outcome-known Effects with no missing evidence.
The new Chief wakeup completed two Effects by 01:50:28; a checkpoint on this
revision and the observer's SQL interval remain to be collected.

The new Slack graph completed all 23 children and finalized at 01:51:15.137.
Its closure watermark subsequently advanced to `1788745918` at 01:51:59.978,
while discovery also continued advancing. The new account-1 Gmail graph
`cf6113aa-3ff6-46c3-9979-f3d473bbc51b` had six of 276 children complete and
six running, with no recorded error. No new exact source-coverage error
appeared in the sample. Both Gmail closure watermarks still date from
September 2, so Gmail completion catch-up is not yet established. The todo
counts remained 899 open, 22 done, and 137 dismissed.

Observer `9lg66` completed successfully at 01:58:38.148. Its final sample
retained all 64 ready/live partitions, no termination request, and 1,166
outcome-known Effects with no missing evidence. The scheduled checkpoint
persisted at 01:57:01.894 with no snapshot failure. Fourteen of eighteen
recurring schedules advanced in the ten-minute interval; the longer-period
schedules were not due, and none had a recorded error. Slack closure advanced
to `1788746289` at 01:58:10.586. Account-1 Gmail had 22/276 children complete,
six running, and one pending timeout retry; no new source-coverage error was
recorded. Both Gmail closure cursors still awaited settlement.

The same SQL interval totaled 169.05 seconds of execution time. The largest
entry was the node-authority row lock (12.88%), followed by task activation
(10.82%) and the User fence (9.98%). Expensive catalog verification and lease
renewal did not dominate the top ten. This window is not a controlled
participant-ingestion comparison, so it does not quantify the CRM batching
fix's savings. At approximately 02:00, `wnfkh` also observed account 2's new
acquisition `13b2aca7-5842-4b9b-86c5-e56663edd263` running; the earlier new-graph
samples had not yet included it.

Workflow `34074912781` completed successfully at 02:05:06; revision
`maraithon-00223-9vh` serves 100% of traffic. The Chief recovered at
02:05:56.503. Observer `ztf7l` saw all 64 partitions ready/live at 02:06:56
and 02:08:57, without a task awaiting termination or a new coverage error.
The first sample at 02:04:55 caught the rollout and is not a steady-state
health observation. The observer remains running for the next checkpoint,
Effects, schedules, SQL interval, and both resumed Gmail graphs.

The account-2 replacement `5b28ef9c-f667-41ed-acc4-c7c2aaac2a2f` names
predecessor `13b2aca7-5842-4b9b-86c5-e56663edd263` and reuses its seven completed
children in the new publication. At 02:08:57 it had ten completed children,
five running, and 169 pending, with no error. The predecessor remains
unchanged with seven completed, 171 cancelled, and six failed children,
including two ambiguous provider outcomes. Account 1's predecessor retained
41 completed children and was fully terminal; its replacement acquisition
`1e5c5f04-bded-4823-b346-dff2e2eafc63` was running. Slack's existing 23-child
scan completed and its closure cursor advanced at 02:06:43.911.

The installed Mac app remained paired and showed 899 active work items.
Opening `/chat` in Chrome redirected to the signed-out landing page, so the
interactive chat check remains pending; no login email or chat was sent.
No request with HTTP status 429 or higher appeared in the request-log query
from 01:46 through approximately 02:05. The earlier intermittent rejection
cause remains unresolved.

At 02:10:57, `ztf7l` verified both resumed Gmail publications. Account 1
retained all 41 completed predecessor jobs and had 42/276 children complete,
two running, and 232 pending. Account 2 retained all seven predecessor jobs
and had 15/184 complete, three running, and 166 pending. Neither new graph
had an error. The original jobs, including the four ambiguous outcomes,
remained terminal and unchanged. All 64 partitions were ready/live, no task
awaited termination, and 1,168 outcome-known Effects had matching evidence.
The Gmail cursors still awaited full settlement. The observer remains live;
its next samples include the new revision's scheduled checkpoint and SQL
interval. No automated tests were run; `make build` passed for `0137657e`.

Observer `ztf7l` completed successfully at 02:17:04. Its final sample at
02:16:59 retained all 64 partitions ready/live, no task awaiting termination,
the 02:15:56.934 checkpoint, and 1,170 outcome-known Effects with zero missing
evidence. The Chief's 02:11:19 wakeup completed two Effects by 02:12:00.
Account 1 had 54/276 children complete, including all 41 reused jobs; account
2 had 29/184 complete, including all seven reused jobs. Neither had an error.
Both Gmail closure cursors still awaited settlement. The SQL interval totaled
203.30 seconds; the largest entry was the node-authority lock at 14.83%, then
full background-job reads at 10.14% and claimed-at renewal at 8.49%. It
includes rollout and cleanup, so it is not a steady-state comparison.

Revision 224 recovered the Chief at 02:34:36.164. Its 02:35:10 wakeup
completed two Effects by 02:35:56, bringing the total to 1,174 outcome-known
Effects with no missing evidence. Observer `2xl2b` completed successfully at
02:43:40. Its first and last samples caught the rollouts into revisions 224
and 225; the middle samples retained 64 live/ready partitions. Its SQL window
therefore is not a steady-state comparison. Account 2's version-2 Gmail graph
completed fifty children before revision 225 interrupted four provider calls.

Revision 225 recovered the Chief at 02:43:20.203. At 02:45:32, `xvsn2` showed
all 64 partitions ready/live, no task awaiting termination, and 1,176
outcome-known Effects with matching evidence. Gmail account 2's replacement
`fb086130-a551-4d44-8ff7-a3e0ccbe731f` preserved all fifty completed version-2
jobs and had completed ten more, with no error. Account 1's new acquisition
was running. The observer remains active for checkpoint, finalizer behavior,
source-cycle settlement, and a SQL interval starting after its second sample.

The Mac app refreshed to 899 active and 24 completed items. Manual review of
the latest Abe Choi completion showed the reply quote, local completion time,
original request, retained notes, and original Gmail link. A read-only source
review is checking all three completed Abe Choi entries. The earlier browser
tab is no longer open, and no authenticated Maraithon browser session was
available. Kent was asked asynchronously to sign in for the remaining chat
check; runtime work continues independently.

The eleven earlier 429 request logs all reported that Cloud Run had no
available instance, with zero request latency and no container instance ID.
Current configuration is manual scaling at one instance, two CPUs, 2 GiB RAM,
and request concurrency forty. Cloud Run's
[manual scaling documentation](https://docs.cloud.google.com/run/docs/configuring/services/manual-scaling)
states that revision-level min/max settings are ignored in this mode. Its
[troubleshooting guide](https://docs.cloud.google.com/run/docs/troubleshooting#abort-request)
classifies this response as an instance-availability/scaling problem. The
specific transient trigger remains unproven; these findings do not establish
that request concurrency forty was exhausted. No scaling setting was changed.

Read-only source review `f7ztc` completed successfully at 02:48:20. All three
Abe Choi completion entries cite Charlie's September 4 22:21:58 reply in
thread `1a06875f0fd03a35`, after Abe's 09:15:26 request. The stored message
`1a06e83e377e93f5` contains the recorded quote offering Monday or Tuesday
meeting times. The oldest todo (`46775375-1ed7-4663-af57-af80d7ea25bc`) closed
in job `ca51dfb1-00ee-4f8b-90b6-a97017067712` at 01:04:14. The other two
(`5fe5193a-d2fc-4260-9d2b-54064a52e3ff` and
`61cad9dd-762f-45a4-bfbc-83d729cab400`) closed in job
`915211fc-d890-404b-9f7e-adb9f30f4dc2` at 02:29:24. Both completing jobs contain
the quote in their stored source bundles and have matching exact completed
task evidence. Other contemporaneous partitions lacked the quote and recorded
zero completions. Charlie's response satisfies the reply/handoff request;
it does not establish that the later meeting or pilot happened. No todo was
changed by this review, and the Mac app was returned to its active view.

At 02:47:33, `xvsn2` retained 64 live/ready partitions and 1,176 outcome-known
Effects with no missing evidence. Gmail account 1 published its corrected
version-2 graph with 299 children for 302 source items and 899 todos; three
children were complete. Account 2 reached 83/184, including all fifty reused
jobs. Neither graph had an error. Two discovery finalizers were waiting with
zero attempts, no error, and ten-second deadlines; the model cooldown still
had not changed since 02:41:40. Full Gmail settlement remains open.


Observer `xvsn2` completed successfully at 02:53:41. Its final sample retained
64 ready/live partitions, no task awaiting termination, a 02:53:20 Chief
checkpoint, and 1,176 outcome-known Effects with no missing evidence. Across
02:43:32–02:53:38, SQL totaled 156.10 seconds: full job reads accounted for
14.49%, task activation 12.08%, and claimed-at renewals 9.28%; catalog
verification did not dominate.

Observer `xdsjw` completed successfully at 03:19:19. Its final sample retained
64 ready/live partitions, five running tasks, no task awaiting termination,
and 1,182 outcome-known Effects with no missing evidence. Revision 227's
03:15:17 Chief wake completed its Effects by 03:15:55. Recurring schedules
advanced, Slack cursors advanced, and Gmail account 2 settled its prior scan.
Account 1 had 136/299 closure children complete, retaining all 121 reused
results; three were running and 160 pending, including one timeout retry.
The 03:09–03:19 SQL window crossed rollouts: node-authority locking was 12.97%
of 249.20 seconds, user locking 10.73%, and full job reads 8.87%. It is not a
steady-state performance comparison.

Kent's signed-in Chrome session resolved the login blocker. A request at
03:07:04 reproduced the platform's no-available-instance 429 on revision 225,
twenty seconds before the next ReplaceService request. The prior six-minute
window showed one active instance, request concurrency 2–3, CPU mean 35.74%
(max one-minute 46.81%), and memory near 24%. These samples do not establish
CPU, memory, or configured concurrency exhaustion. The specific transient
trigger remains unproven; no scaling changes were made.


At 03:38:12, observer `mgfpq` showed Gmail account 1 at 196/299 completed
closure children, including all 186 reused results, with two running and 101
pending. Gmail account 2 had settled another delta and started its successor;
Slack had 21/23 children complete for its seven-source delta. Revisions 229
and 230 interrupted this observer's SQL interval, so it cannot establish a
steady-state comparison. Revision 230's Chief recovered at 03:39:53.
Read-only observer `vvs7d` is running a separate twelve-minute measurement
on the current revision, including the fresh chat's durable status and the
three visible todos' source-address metadata. It starts Vault and Repo only,
uses pool size two, and performs no provider calls or data mutations.


Observer `mgfpq` completed successfully at 03:42:19. Its final sample retained
64 ready/live partitions, six running tasks, no pending termination, and 1,186
outcome-known Effects with matching evidence. Gmail account 1 reached 201/299
completed children, retaining all 199 reused results. Its SQL interval crossed
rollouts, with node-authority locking at 21.40% of 347.50 seconds, so it does
not establish steady-state contention.

Observer `vvs7d` confirmed at 03:49:30 that account 1 had reached 261/299
completed children, with five running and 33 pending (five timeout retries).
Gmail account 2 and Slack had settled and were advancing through empty deltas.
All 64 partitions remained ready/live and 1,188 outcome-known Effects had
matching evidence. The Chief's 03:48:20 wake completed its Effects by 03:48:54.
The current-revision observation continues through its checkpoint and SQL
window.


Observer `vvs7d` completed at 03:55:36 UTC. Gmail account 1 reached 296/299
before revision 231 interrupted two running children. Its 03:45–03:55 SQL
window totaled 96.78 seconds: claim renewal 13.70%, task activation 13.57%,
node-authority locking 11.31%, and catalog readiness 2.04%. The final minute
crossed the rollout, so this is not a steady-revision comparison.

Revision 231 observer `4q4jm` sampled 03:59:08–04:07:12 UTC. All five samples
had 64 ready partitions with live leases and no termination-requested tasks.
The Chief completed Effects at 03:59:34 and checkpointed at 04:05:53 without
a snapshot-persist failure; 1,190 outcome-known Effects had matching evidence.
Recurring schedules advanced on their intervals. Slack processed a new
23-child, two-source delta completely and returned to empty deltas, as did
Gmail account 2. Account 1's timeout/reacquisition is finding 60; its closure
cursor remains September 2, so whole-product catch-up is not complete.

The 04:01:10–04:07:13 SQL interval stayed on revision 231 and totaled 111.21
seconds. The leading categories were encrypted job reads (13.81%), task
activation (12.34%), node-authority locking (10.11%), and user locks (9.74%).
Claim renewal was 4.00%; catalog verification was outside the top ten.
This includes the avoidable full reacquisition and read-only diagnostic job
reads, so it is not an idle-load benchmark or an application-only profile. The routing projection `99k5p` separately confirmed Michael's
address, personal Gmail account, and original thread, while DuraServ resolved
to no address with direct send disabled. It used only metadata GETs and pure
routing helpers; no draft or message was created.

Current read-only observer `74rhc` follows revision 233 for ten minutes using
pool size two, Vault, and Repo only. It reads the latest acquisition's published
child IDs and aggregates status rows; it does not decrypt every child payload
or call providers. It completed successfully at 04:27:01 UTC. All six samples had 64 ready/live
partitions and no termination-requested tasks. The 04:21:30 wake completed
Effects by 04:22:03; the checkpoint persisted at 04:25:00 with no snapshot
failure. All 1,194 outcome-known Effects had matching evidence, and all 18
recurring schedules had no error or overdue execution in the final sample.
Gmail account 1 reached 46/276 completed children; its full cursor catch-up
remains unproven.


Revision 233's 04:18:55–04:26:57 SQL window totaled 84.20 seconds. Fair
admission accounted for 13.73%, background claim renewal 11.27%, task
activation 10.39%, and node-authority locking 10.13%; catalog verification was
outside the top eight. No verification or renewal query dominated the sample.
This interval ran entirely on revision 233 without a rollout. It includes
lightweight observer reads, not a synthetic benchmark.

The list grew from 905 to 953 open todos while new Slack deltas arrived.
Read-only execution `4qw77` samples the latest twelve additions and their
stored source quotes to review quality and repeated work. It is still starting;
follow this handle rather than restarting it.


Observer `7bfjj` completed at 05:12:07. Its final sample crossed revision 235's
rollout: 25 ready partitions, three preparing, and 36 unassigned. All known
Effect outcomes still had matching evidence. Gmail account 1 retained 251/276
completed children. Its 04:33:54–05:12:02 SQL window spanned revisions 233–235
and the same-revision shutdown, so it is not a steady-state comparison. Of
557.56 seconds total SQL execution time, node-authority locking was 14.61%,
activation 8.78%, and background claim renewal 8.24%; catalog verification was
outside the top eight.

Revision 235 recovered its Chief at 05:12:07. Read-only observer `ltv7q`
started at 05:15:31 and runs eight samples over fourteen minutes, with a
per-execution timeout of 1,200 seconds and pool size two. Its first two samples
had all 64 partitions ready/live with no pending termination. The scheduled
Chief Effects completed at 05:16:06; all 1,207 outcomes have matching evidence.
Gmail acquisition `425c2e63-ae42-4d4c-beed-63382b7b398b` reused all 251 completed
children. At 05:17:33 all 276 children were complete without errors; finalizer
`3c23dfd0-f514-40f5-9ff3-f768d755d952` was pending for 05:18:27. Its cursor
settlement and the new Chief checkpoint remain to verify. Slack recovered its
27 completed children, settled, and started a new 15-child delta for the
reduced 561-todo list.


At 05:18:49 the Gmail account-1 finalizer advanced its closure cursor from
September 2 (`1788380231`) to September 7 04:05:17 UTC (`1788753917`). This
is an actual persisted cursor advance, not a projected recovery. Its next
acquisition `7867226b-d06a-4e41-9e0a-603af1d68063` has four new source messages
and fifteen child partitions against the current 561-todo snapshot. At
05:19:33 three children were complete, two running, and ten pending, without
errors. All 64 runtime partitions remained ready/live and no task awaited
termination.


At 05:21:19 Gmail account 1's following delta settled and its closure cursor
reached `1788758479` (05:21:19 UTC). All three source accounts then returned
completed empty deltas. At 05:23:34 all 64 partitions remained ready/live,
with no task awaiting termination; discovery and closure cursors continued to
advance. The Chief persisted `checkpoint_created` at 05:22:07 with no
`snapshot_persist_failed`. Its 1,207 outcome-known Effects all have matching
storage evidence. The observer's SQL interval still runs through 05:29.


Observer `ltv7q` completed successfully at 05:29:39. All eight samples retained
64 ready/live partitions and no task awaiting termination. Both observed
scheduled Chief cycles completed their Effects, its checkpoint persisted,
all 18 recurring schedules had no error and their due source schedules advanced,
and all 1,209 outcome-known Effects had matching storage evidence. Gmail's
later one-message delta also settled by the final observation.

The 05:17:33–05:29:36 SQL window remained entirely on revision 235 and totaled
132.07 seconds. Node-authority locking accounted for 17.79%, assignment proof
reads 11.64%, user locks 11.60%, task activation 7.68%, claim renewal 4.56%, and
catalog readiness 2.82%. No verification or renewal query dominated. This
includes the bounded source reviews and duplicate maintenance; it is not an
idle-load or application-only benchmark.


Final reminder read-back `jsqvf` completed at 05:36:45: all 1,036 reviewed
rows matched their intended status, duplicate parent, and original note hash.
The only repeated single task number in the active escalation list is #158,
which the source reused for Hardik's extension and Aakash's schedule question.
The original Chrome Todos tab visibly shows 499 active items after refresh.
The latest prompt-only change `248bd58e` deployed successfully in workflow
`34087225973`, serving revision `maraithon-00236-cm5` at 100% traffic. Its Chief
recovered at 05:36:54. The full scheduled-cycle and SQL observations above
belong to revision 235; they were not repeated after this prompt-only rollout.
No tests were run or modified. Existing team-work scope and natural behavior
of the final ownership instruction remain open; all submitted observer,
source-review, and duplicate-repair executions have finished.
