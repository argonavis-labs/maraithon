# Delegated conversation implementation status

For the current short checklist, see [what is done and what remains](delegated-conversation-todo.md).

Updated September 16, 2026. Controlled Gmail information and scheduling evals now pass as both Kent and October. The Kent-pair busy-slot recovery eval also passes. Mailbox signatures, assistant isolation, brief reporting, work/personal categories, and the cost warning are deployed. The full [execution plan](delegated-conversation-execution-plan.md) is not complete.

## Assistant selection belongs to each user

Kent clarified that October is his assistant only. The existing `assistant_identities` record stores the selected connected account and sending address per user. Settings reads and writes use the authenticated user's ID, and the backend checks account ownership before saving. Dedicated assistant accounts are marked in account metadata and excluded from personal-source discovery, identity, briefs, voice samples and People history. The fixed October address appears only in the controlled eval fixture and its restricted send gate.

The live web Assistant settings page and installed Mac app both showed October with `october@ewakened.com` selected as the assistant's own account. iPhone's Settings → Assistant & scheduling uses the same shared native form and server API. Physical iPhone interaction was not repeated. No product code or saved configuration needed changing for this clarification. The project rules and execution plan now state the user-specific selection explicitly; no build or automated tests were needed for these documentation changes.

## Conversation across releases

The eval preflight now uses the same operator command as start, status and memory checks. The workflow forwards the chosen actor, and report collection still runs when a Cloud Run execution fails. A read-only diagnostic accepts one controlled execution ID and reports exception classes, fixed failure reasons and application source locations without exposing inspected arguments or provider bodies.

Commit `2ea1f5f4` passed shell syntax checks and deployed through workflow `35103948234` to revision `maraithon-00417-f72`. Diagnostic workflow `35104296534` confirmed the earlier launcher stopped with `eval_preflight_required`. Corrected assistant preflight `35104584209` then passed for both Kent accounts and October, with Muse, active development spending, sending access and assistant isolation intact. It made zero model calls, sent no messages and created no events. The earlier failed preflight did not retain its detailed report, so its particular failed check is unknown.

Verification now restores the final reply ID from its delivered message after a lost eval checkpoint. The canary also requires settled receipts showing the actual configured model for every counted call. A refused launch emits its preflight report before exiting unsuccessfully. These changes passed `make build` with warnings treated as errors. Automated tests were not run under the manual-first policy.

Commit `e83a04a0` deployed through successful workflow `35105032370` to revision `maraithon-00418-q8b`. Launcher `35105695496` created job `338b5a91-b56e-4536-b24c-9575848f3d8f`. Read-only status `35106472132` found it had ended with `rate_limited` before recording a delegation. This does not establish whether its initial email was sent. No replacement conversation was launched. [Canary observations](evidence/delegated-conversations/2026-09-16-durable-canary.json).

The fixture now uses the existing provider retry-delay classifier to reschedule throttled reads, preserving its saved state and deadline. A restricted recovery operation can requeue this same controlled canary after an initial throttle failure. It requires a completed job with no claim, settled runtime assignments, no created delegation and a remaining deadline. The operation retains the original payload, subject, account binding and deterministic prepared-action IDs; an already delivered email is observed through the existing receipt path. Recovery does not alter grants or reopen stopped conversations. The build and shell syntax checks passed.

Commit `8e72ece8`, including the shared model report from `c91e10b1`, deployed through successful workflow `35108239455` to revision `maraithon-00419-l2c`. Recovery workflow `35108765820` requeued the same job for `2026-09-16T14:32:14.235445Z` with phase `waiting_for_provider`. It passed the settled-worker and no-delegation checks.

Read-only status workflow `35109485511` confirmed that the same job exchanged three counterparty replies and reached `waiting_across_releases`. Its saved baseline has four assistant messages, eight model calls, US$0.003337 in recorded cost and no unresolved reservation. The quiet interval began at `2026-09-16T14:36:36Z`; the final reply is due no earlier than `20:36:36Z` (4:36 PM Toronto). The sending identity passed verification. The six-hour interval and later memory turn are still pending.

The original canary later passed. Read-only status `35148073704` reported its
completion at `20:39:37Z`, after a quiet interval from `14:36:36Z` to `20:37:59Z`.
The grant, scope, owner, ledger, source revision and spend remained unchanged
during that interval, across revisions `00419-l2c` and `00444-btg`. The final
turn used an older fact, obtained all four answers, passed independent review,
and completed the todo. Every settled model receipt used Muse Spark Contributor.
Four ordinary turns used two calls each; the final research turn used three.
Total recorded cost was US$0.005449 with no unresolved reservation. All eight
canary checks passed. This establishes six-hour continuity across releases,
not months-long operation or the remaining recovery matrix. The report is in
the existing [canary evidence](evidence/delegated-conversations/2026-09-16-durable-canary.json).

The `durable_memory` controlled Gmail scenario collects four facts, one reply at a time. Before the final reply, it saves a baseline and schedules the existing eval job for at least six hours later, inside the user's working hours. It does not poll during that interval. The final reply also waits for a different serving revision. Each inspection reports elapsed time and current counters without reading provider messages or calling a model.

The baseline covers the grant, scope, task owner, saved ledger, source revision, model calls, unresolved reservations, recorded cost and sent-message count. The unchanged interval is committed before the final reply can send. Active launches deduplicate per actor, and prepared replies keep their deterministic action IDs. The scenario has a three-day deadline and uses the existing controlled-recipient gate, signatures, request admission, send limits and independent review.

The final decision must use the first saved answer after its message has left the six-message prompt window. The check requires that fact in the frozen ledger, its source in recalled evidence, its citation in the decision, all four answers saved with their respective sources, and independently reviewed completion. It reports model calls, stages, actual models and cost per turn. This is a live check of a real interval across releases; it is not evidence of months of operation until those months have elapsed.

The original canary implementation, `11921c8a`, passed `make build` and deployed through workflow `35099445591` to revision `maraithon-00416-mhz`. Its initial launcher and preflight issues were diagnosed and corrected as recorded above. No automated tests ran under the manual-first policy, and no completed conversation was restarted.

## Live saved-fact recall

October's completed information conversation saved one fact with one citation. Read-only workflow `35095785564` passed after loading the encrypted conversation from PostgreSQL and removing its prompt cache in memory. The production toolbox fetched the cited Gmail message and verified its account, thread and content digest. The saved fact contains the expected project colour and cites the eval's counterparty reply. The final completion decision had independent review, used the configured Muse model, and kept the ledger within its size bound.

This check made zero model calls, sent no messages, created no calendar events and changed no conversation records. OAuth refresh and shared request admission retain their usual operational writes. It does not prove months of retention, a later model turn using the fact, or Slack recall. [Live recall evidence](evidence/delegated-conversations/2026-09-16-october-memory-recall.json).

The bounded command accepts only a completed, successful controlled information eval belonging to the fixture's user. It reads at most six citations and logs counts and check results, never fact text or email bodies. Commit `31092865` passed `make build`; successful workflow `35095261732` deployed revision `maraithon-00414-fj4` to all traffic. No automated tests ran under the manual-first policy.

## Compact People context

New decision turns now freeze a short People summary for exact granted email addresses or Slack member IDs. One bounded query selects active records from the same user. Missing or ambiguous matches supply no context; name similarity and partial contact matches are not used. Each summary is capped at 320 bytes and includes the name, relationship and preferred communication method. Notes and other contacts are excluded. The existing encrypted run snapshot keeps the same context across retries, while a later turn can read updated People records.

Composition and independent review receive the same instruction: this is private context for names and tone, not evidence of an outcome, a commitment, ownership or sending authority. It cannot enter the fact ledger without the conversation evidence already required by that ledger. Existing snapshots default to no People context. The prompt version advances to 2. There are no additional model calls, provider requests, tables or processes.

`make build` passed with warnings treated as errors. Automated tests were not run under the manual-first policy. This addition still needs live verification of the selected context and its use in a decision.

Commit `e7ed426f` deployed through successful workflow `35097197940`. Revision `maraithon-00415-mdn` serves all traffic. No migration or native release was needed.

## Model calls by turn and stage

Controlled evals now share the cost report in `Delegations.Reports`. It groups ordinary, research, repair and zero-call turns separately. Each turn reports its requested model, stage receipts, actual models, prompt versions, token counts, billed micro-USD and unresolved reservations. Zero-call work has no calls-per-turn average and cannot lower the model-turn averages. New model entries also record the chat tier; older receipts keep their original fields.

The saved-memory probe includes the same report for the inspected completion turn. Reading it adds no provider request or model call beyond that probe's existing evidence fetches. The canary uses the shared projection, removing its duplicate reporting code. `make build` passed with warnings treated as errors. Automated tests were not run under the manual-first policy. This deployed with `8e72ece8`.

Read-only workflow `35110150724` inspected October's existing completion turn. Its two settled receipts name Muse Spark Contributor: composition cost US$0.000281 and independent review cost US$0.000332, for US$0.000613 total. There were no unresolved charges. The inspection made zero model calls and sent no messages. This verifies an ordinary turn; research and repair remain unverified. [Receipt evidence](evidence/delegated-conversations/2026-09-16-model-receipts.json).

The receipt check is now shared across information, scheduling, memory and longevity evals. Every counted call must have a settled receipt naming the expected model. Zero-call turns need no model receipt. A configured model name alone no longer passes the memory probe's model check. `make build` passed with warnings treated as errors. Automated tests were not run under the manual-first policy. Commit `4334bd7d` deployed through successful workflow `35111300631`; revision `maraithon-00420-sqt` serves all traffic. This release landed after the canary's saved baseline. Its final verification has not run yet.

## Thanks-only replies without model calls

Gmail and Slack now share a whole-message classifier for short thanks-only replies. An acknowledgement stays in the event ledger and history, but does not advance the source revision, start a decision turn, complete the todo or reset its follow-up schedule. Sender, participant, takeover, stop and delivery-error checks run first. Agreement such as "yes", completion claims and requests such as "Thanks, book the first time" remain substantive.

The classifier requires verified text-only content and an entire body from a short phrase list, capped at 128 bytes. Gmail also requires the original subject, allowing `Re:` prefixes. The full-message reader preserves a plain-body marker; HTML alternatives, attachments, unsupported MIME parts and older records without that marker keep the normal path. Slack accepts plain messages and matching text-only rich-text blocks. Files, attachments and unsupported blocks keep the normal path. Editing an earlier Slack message into an acknowledgement still invalidates the source.

An acknowledgement arriving before a send also needs special handling. Gmail can exclude up to 64 newly arrived acknowledgements already classified in the account-bound ledger, but the entire remaining header index must match the saved fingerprint. Slack's fresh paginated verification computes a second fingerprint that excludes only new, unedited thanks-only messages. The original fingerprint remains intact. Participant and revision checks still apply, so other changes cannot pass through this exception. Gmail verification resumes its bounded source read when additional batches remain. Older snapshots without usable dates cannot take the acknowledgement exception.

`make build` passed with warnings treated as errors. Tests were not run under the manual-first policy. No live acknowledgement exchange has verified this path yet, and no cost reduction is claimed from the compile. Composition and independent model review remain unchanged. Kent's September 16 decision keeps independent review and replaces the target below 1.3 model calls per turn with two calls for an ordinary substantive turn and a three-call ceiling for research or repair, including review of the final decision. Waiting and ignored acknowledgements use zero calls and are reported separately. Muse Spark Contributor remains configured.

Commit `32f256fb` deployed through successful workflow `35091064234`. Revision `maraithon-00411-5mm` served all traffic. The older-snapshot compatibility fix in `978d3c38` then deployed through successful workflow `35091691984`; revision `maraithon-00412-v6f` served all traffic. No native release or migration was needed.

Commit `8a87ff70` also keeps invalid UTF-8 on the normal reply path before the phrase check. Its build passed, and successful workflow `35092861779` deployed revision `maraithon-00413-q2h` to all traffic. The revised independent-review target is recorded in `a22a82b1`.

## Slack source progress across replacement turns

A Slack history page can discover a missed reply and advance the conversation's source revision. That makes its current turn obsolete. Previously, the replacement turn started the thread scan again, including when the preceding scan had just finished.

Source sync now saves a resume binding with the page in the existing encrypted run snapshot, in the same fenced transaction that routes the messages. The binding covers the grant, scope, account, channel, thread, DM coverage and resulting source revision. The reader checks at most three preceding turns belonging to the same user, delegation and grant. A changed source or grant cannot reuse that progress.

An unfinished scan may continue from a checkpoint made within 30 minutes. A finished scan may be adopted only by its immediate replacement, within 30 seconds, when that preceding turn discovered the newer source revision. The original read timestamp stays intact. Older records without the binding start a fresh scan. Preflight and verification before sending keep their existing read paths; a cache is never a delivery receipt or send authority.

`make build` passed with warnings treated as errors. Tests were not run under the manual-first policy. Live Slack evaluation remains deferred and autonomous Slack sends remain disabled. This change has not had a live cross-turn or worker-loss check. General incremental reuse after new webhook arrivals remains unfinished; this addresses work discarded when a scan supersedes its own turn. Slack's [thread reader](https://docs.slack.dev/reference/methods/conversations.replies/) supports the existing cursor and timestamp continuation used here.

Commit `5a928945` deployed through successful workflow `35088309189`. Revision `maraithon-00410-n6j` serves all traffic. No native changes, migration, new model calls or new coordinator process were needed.

## Redacted delegation trace

The existing encrypted event ledger now records model entry, billed cost, turn admission, coordinator acceptance or rejection, and executor entry. Grant controls, decisions, policy holds, delivery receipts, uncertain delivery, reconciliation and applied state changes use their existing events. Observation records are consumed on insertion, so they do not wake another job or appear in the user's conversation history. No new worker, table, provider request or model call is needed.

Each background job, user control and coordinator reduction collects at most 256 event IDs in its process. After its transactions end, it reads the committed rows and emits selected IDs, revisions, versions, timing and cost fields. Rolled-back rows produce no log receipt. Bodies, prompts, recipients and execution tokens are excluded. Executor entry remains an attempt, not proof of delivery. Its deduplication key uses a digest of the execution claim because local rate-limit deferral can reset the numeric attempt count.

Logs are best effort. Process death, a full buffer or a failed log read can leave a committed event without a log line. `Maraithon.Delegations.Audit.page(user_id, delegation_id, before)` reads up to 100 redacted records directly from the durable ledger for operator inspection. It does not dispatch work or authorise another send. Job records include the job and assignment IDs when available. Coordinator records retain the agent ID; they do not invent a job or assignment ID.

`make build` passed with warnings treated as errors. Tests were not run under the manual-first policy. This change has not yet been exercised through a fresh live conversation or a worker-loss scenario. Earlier event rows are readable but are not backfilled with metadata that was never recorded. Local Google Cloud reauthentication is expired; the existing keyless deployment workflow remains available.

Commit `84d89b83` deployed through successful workflow `35086410229`. Revision `maraithon-00409-pnb` serves all traffic. No new message, calendar event or eval was started for this release. The scheduled September 16 memory eval was left in place.

## Conversation history on web, Mac and iPhone

Tasks now expose a read-only conversation history from the existing encrypted events and fact ledger. It shows user controls, received messages, planned actions, confirmed receipts, uncertain delivery, holds, and saved facts with their source links. Pages contain at most 30 events and use a sequence cursor scoped to the authenticated user and delegation. Opening history makes no provider or model calls. The same server copy and response drive both native apps and the web view.

The coordinator records applied state changes in its existing fenced transaction. Those history events are consumed immediately and never wake more work. A planned completion is labelled Outcome identified; Delegation completed requires the applied state transition. Older decisions are not rewritten as successful transitions. Late inbound records remain visible even when the delegation is terminal.

The live web check loaded an earlier spending hold, a successful October information exchange, and a successful October booking. The signed Mac app showed the same completed information exchange, including the sent receipt, received reply, timestamps and learned indigo outcome. Clicking the email evidence opened the exact cited reply in October's Gmail account. This caught and fixed a Gmail URL path that had selected the default mailbox. Source links now name the mailbox explicitly.

Server commit `78d0f158` and Gmail-link correction `a66fbfec` deployed successfully. Native commit `1a1e0583` passed both native builds, including project generation and Mac signature verification, and is installed on Mac. Mobile workflow `35079623000` shipped TestFlight 1.0.1 (`20260916092859`) to Founders, including Kent. Phoenix builds passed. Tests were not run under the manual-first policy, and no new messages or calendar events were created for these UI checks.

Older calendar receipts discarded Google's event URL. Commit `d6084e4c` preserves it on future direct and reconciled receipts; history only links to a retained Google Calendar URL. It does not invent links or fetch old events during display. This follow-up passed the Phoenix build and deployed through workflow `35082619194`; revision `maraithon-00408-5b5` serves all traffic. The Mac history refreshed against this revision. A fresh live booking still needs to verify URL retention.

Physical iPhone interaction, pagination beyond the first page, the saved-fact disclosure, and newly recorded applied transitions remain unverified in production. The operational trace is described above; its live recovery checks remain outstanding. The latest UI checks cover existing saved records, not the whole recovery matrix.

## Durable conversation checks before delegation

Opening Delegate now starts a read in the existing encrypted background-job lane. Slack checks save one page at a time, including the cursor, timestamp boundary, evidence digest, authors and six recent messages. Rate limits use the runtime's bounded backoff. A deploy or closed sheet does not discard saved progress. The job has a one-day lifetime and retains the reader's message, page and payload bounds.

Web, Mac and iPhone poll for the result. The user can close the sheet or switch actors while it runs. Reopening the same task reuses an active check or a completed result from the last 30 minutes. Changes to the task, source account, preferences or assistant configuration invalidate that review. Submitting Delegate applies the explicit form edits to the server-owned result and checks the scope hash and task revision, without repeating the source scan. The existing grant transaction and live checks before sending remain in place.

The native preview endpoint accepts `async: true`, `actor` and `kind`. A pending response contains `preflight.id`, `status: "pending"` and `retry_after_ms`; subsequent preview requests include `preflight_id`. A ready response adds `scope`. Submission includes that same `preflight_id` with the scope hash and expected revision. IDs are scoped to the authenticated user and task. Older clients retain the synchronous contract. A preview never creates a grant or sends a message.

Server commit `e7b10a32` passed `make build` and deployed through workflow `35073798732`. Revision `maraithon-00405-gpw` serves all traffic. Both native builds passed, including Xcode project generation and the Mac signature check. Native commit `f81c9d87` is installed on Mac. Workflow `35074724476` shipped TestFlight 1.0.1 (`20260916083700`) to Founders, including Kent.

The live Mac sheet showed the correct Gmail sender and recipient. The web sheet then opened the same completed review immediately. Switching to October showed the pending state with Cancel enabled; after closing and reopening, October's completed review appeared with the correct sending address. These checks stopped before Delegate, so they created no grant and sent no message. Automated tests were not run under the current manual-first policy. Long Slack pagination, worker loss during preflight and physical iPhone interaction remain unverified.

## Ranked scheduling choices

Scheduling now ranks the complete bounded set of computed openings before returning up to eight choices, with at most three per local day. Previously, taking the first three openings each day could discard afternoons before the model saw them. Candidates start on quarter hours and retain the requested duration, working hours, notice, buffers, calendar conflicts, and daily meeting cap.

The user can prefer mornings or afternoons and earlier or later weekdays. Ranking applies time of day first, weekday next, then the soonest date. Morning meetings end by noon; afternoon meetings start at noon or later. These are soft preferences: other available times remain fallbacks. The final review still rejects an offer that violates an explicit constraint such as "afternoons only".

The existing bounded `find_times` read can override these rankings for a preference stated in the grant or conversation. Its request and applied settings are saved with the computed slots, and a sent offer preserves the request for later turns. No new model call, worker, or migration is required. Web and the shared iPhone/Mac settings form use the server's choice definitions; older clients leave the new saved fields intact.

Server commit `cb984a05` passed `make build`. Both native builds passed, including iPhone project generation and the Mac signature check. Manual pure calculations returned eight 45-minute choices, selected noon for an afternoon preference, preferred Monday for early-week mornings, and kept a 15-minute busy-event buffer. Invalid ranking values were rejected. These checks made no provider or model calls. Automated tests were not run under the current manual-first policy; live scheduling verification remains pending.

Server workflow `35069699454` succeeded; revision `maraithon-00404-76j` serves all traffic. Native commit `1271076b` is installed on Mac. The live native and web forms showed both choice fields with the existing defaults, and saving the unchanged native preferences succeeded. The iPhone controls use the same form and API. No physical iPhone interaction was performed.

Mobile workflow `35070118640` succeeded. TestFlight 1.0.1 (`20260916074515`) is available to Founders, including Kent.

## Saved meeting links

Delegated scheduling now reads the user's saved video and booking links. The video link is frozen when an offer is sent and included in the eventual invitation description. An accepted older offer keeps its original link, including no link for offers made before this change. The existing calendar action and reconciliation cover that description.

The composer may include an active, user-owned booking link alongside computed slots. Automatic selection matches the meeting length and the task's personal or work context through the existing selector. A preferred link overrides automatic selection but still must be active and match the meeting length. An unavailable or mismatched preferred link is omitted, without substituting another one. A booking link cannot replace the slot offer.

Assistant settings expose the preferred link on web and through the shared native iPhone/Mac form, with a link to the existing booking-link editor. Unavailable saved choices stay visible. Saving the link list now retains each existing URL's record ID, so editing a label or another setting does not break a preferred-link selection.

Server commit `7f04547c` passed `make build`. Shared native commit `91a70c84` passed the Mac and iPhone simulator builds. The mobile project was regenerated; the existing Mac project remained current, and its installed app signature passed verification. Automated tests were not run under the current manual-first policy. The new invitation path has not had a live calendar eval.

The live Mac form rendered the new picker and saved the unchanged preferences successfully. Kent had no active booking links, so selection persistence could not be exercised with an existing link. Opening the editor exposed an old admin-only route. Commit `260bfc79` adds a signed-in owner route, shares the existing form and save logic, and keeps the admin page protected. The native link now opens that owner route. The server and both native builds passed again; the earlier mobile release was cancelled before shipping the broken editor link.

Workflow `35068514603` deployed the owner editor successfully to revision `maraithon-00403-7h5`, serving all traffic. The signed-in web editor loaded and saved the unchanged empty link list. Native commit `e8d6b962` is installed in the signed Mac app; its Manage booking links action opened that owner page successfully. No meeting links, calendar events, or messages were created during these checks.

Mobile workflow `35068839405` succeeded. TestFlight 1.0.1 (`20260916073030`) is available to Founders, including Kent. This build also includes the People loading and readable-error fixes. No physical iPhone interaction was performed.

## Requested meeting length and dates

The controlled `requested_scheduling` case asks for a 45-minute call next week, afternoons only. It uses the existing Kent-pair email, calendar, signature and cleanup paths. Before accepting a slot, the fixture checks the received email and every offered time against those constraints. Completion also requires a three-call scheduling research turn with independent review, a proven booking, and matching times and title on the recipient's calendar copy. All scheduling evals now verify the invitation description against the frozen prepared action. Relative dates are anchored to the actual delegation start, so queuing a fixture overnight does not change the expected week. `make build` and shell syntax checks passed; automated tests were not run under the manual-first policy.

Commit `afc154ba` deployed through successful workflow `35112697450` to revision `maraithon-00421-6kn`, serving all traffic. Assistant launcher `35113421896` created job `77fa8492-89b1-44e9-8e79-822a2dd7e1ce` at `2026-09-16T15:13:26.992171Z`. Status workflow `35114034091` found it failed with `eval_completion_without_reply`, after the delegation reached completed. Cleanup reported complete. The saved decisions and actions still need inspection; this result alone does not establish the cause. The failed conversation has not been restarted. [Requested scheduling evidence](evidence/delegated-conversations/2026-09-16-requested-scheduling.json).

Inspection found that both validation and the state machine allowed a scheduling model to return `complete` without a calendar receipt. They now reject that transition. Only the confirmed booking path can finish scheduling; an attempted early completion explains that the calendar confirmation is missing. Composition and review instructions now state that rule, with prompt version 3. A selected eval job can also return bounded, redacted diagnostics: the latest ten turns, twelve action states and one existing audit page, without provider calls or message bodies. `make build` passed after correcting a local variable-scope compile error. Automated tests were not run under the manual-first policy. Commit `a7968bd6` deployed through successful workflow `35115711342` to revision `maraithon-00422-r65`, serving all traffic. Detailed status workflow `35116238092` inspected the failed job.

The final reply verifier also hid provider read errors behind `eval_completion_without_reply`. It now returns those errors to the existing bounded-delay handler, so a Gmail throttle can wait without discarding the reply's deterministic identity. Missing or unexecuted reply actions still fail. The build passed. Commit `300e7ea3`, pushed with evidence commit `43d95286`, deployed through successful workflow `35116988107` to revision `maraithon-00423-4bs`, serving all traffic. The original failure did not retain its provider error, so this code finding alone cannot prove that throttling caused it.

Detailed status `35116238092` confirmed a reviewed `propose_times` decision followed by a reviewed `book` decision, an executed fixture reply, an executed calendar booking and the fixture's later cancellation. This attempt did not use the unguarded `complete` decision path. Its research turn had three settled Muse calls costing US$0.001498; booking had two costing US$0.001095. Total cost was US$0.002593 with no unresolved reservation. The durable audit page contains model entry and settlement, decision, send entry, receipt and completion events. The final verifier failed before checking the recipient's calendar copy, so the overall eval remains failed even though the booking and call-budget evidence is valid.

After the verifier fix deployed, launcher `35117654513` created a fresh controlled attempt, job `73ffb81a-149d-4d7d-9b45-f6374bcaa876`, at `2026-09-16T15:51:07.570631Z`. The earlier attempt remains terminal, with its test event cancelled and its failed verdict preserved. [Second attempt](evidence/delegated-conversations/2026-09-16-requested-scheduling-second-attempt.json).

Read-only diagnostic `35118992517` confirmed that October sent the offer and the fixture sent its acceptance. Independent review then rejected the next decision with `policy_review_required`; no calendar action was created. The two turns used five settled Muse calls costing US$0.002405, with no unresolved reservation. The research turn used three calls; the acceptance turn used two. The fixture stopped this failed conversation. This does not pass the scheduling eval, and the redacted trace does not identify the reviewer's specific reason.

Private conversation history now reads the bounded explanation from a rejected review, including saved older holds. Future holds save that explanation with the failure event. Reads are scoped to the authenticated user, delegation and displayed history page; the reason stays out of operational logs. This adds no model or provider call. Separately, initial calendar-read throttling now uses the existing durable provider wait, just like later reads, instead of becoming a permanent review hold. The second attempt failed independent review, so that throttling fix is not presented as its cause. `make build` passed with warnings treated as errors. No automated tests ran under the manual-first policy.

Commit `3130bb4a` deployed through successful workflow `35121045787` to revision `maraithon-00424-s65`. The authenticated web history loaded the saved rejection. It disputed noon as an afternoon slot, a dated fact citing only a relative acceptance, and the lack of a calendar receipt before booking. Prompt version 4 now shares the calculator's noon boundary between composition and review, requires offer-plus-acceptance decision citations, and keeps derived booking facts out of the counterparty fact ledger. It explicitly distinguishes approval to book from proof of a later successful calendar write. Independent review, grant checks and the fresh availability check remain required. The build passed; this prompt change still needs a fresh controlled scheduling run.

Commit `ef2ebb35` deployed through successful workflow `35122185354` to revision `maraithon-00425-j96`, serving all traffic. Launcher `35122703977` refused the next attempt because the Runner mailbox was rate-limited during preflight. It created no eval job, made zero model calls, sent no emails and created no events. The personal mailbox and October were ready; October passed account isolation, and Muse plus development spending remained configured. This is a provider preflight failure, not a result for the corrected scheduling decisions. The existing six-hour canary was left in place. Retry launcher `35123454773` was also refused before any effects: Runner was ready, but the personal Gmail mailbox was rate-limited. No further attempt was launched while inspecting the throttle. [Preflight evidence](evidence/delegated-conversations/2026-09-16-scheduling-review-preflight.json).

The shared Gmail admission layer uses `rate_limited` for both provider throttles and local mailbox contention. The earlier reports retained neither the subtype nor the wait duration, so they do not prove which occurred. Preflight now reports the existing classifier's retry delay and the closed local-deferral subtype without exposing provider bodies. Gmail identity reads retry at most twice for local waits of one to five seconds. Longer cooldowns and provider failures return normally without retrying. Assistant-account errors retain the same diagnostics instead of becoming a generic setup failure. `make build` passed; no automated tests ran. Commit `3a9d9342`, shipped with `36afe592`, deployed through successful workflow `35124600280` to revision `maraithon-00427-bdf`. Launcher `35125144462` then passed preflight and created job `42b77f9f-f81b-46f3-be90-9e38ffa78424`, scheduled at `2026-09-16T16:59:54.001944Z`. Read-only status `35125515701` found a terminal `eval_send_failed` before a delegation was recorded. This did not exercise the corrected scheduling decision, and the generic error does not establish delivery. [Current scheduling run](evidence/delegated-conversations/2026-09-16-requested-scheduling-reviewed.json).

The delegated model can request calendar slots for a specific meeting length and date window through the existing bounded read step. This connects instructions such as "45 minutes, next two weeks" to the shared slot calculator. The server accepts durations from 5 to 240 minutes and windows up to 31 days. The request cannot choose calendars or override working hours, notice, buffers, or meeting caps. It can read cited older evidence in the same step.

The request and computed slots are saved in the encrypted run snapshot. A retry reuses that result, and the final offer still needs independent review against the grant and source evidence. The calendar query itself is not authority. A turn that needs the extra read uses the existing three-call ceiling. Sending an offer also saves its requested length and window for later turns, including a busy-slot reoffer. Booking continues to use the accepted slot's exact interval and frozen calendars.

The prompt now includes when the delegation began, and new user answers carry their answer time. This lets relative dates stay anchored to the instruction or reply that supplied them across pauses and restarts. Older answers without dates remain ambiguous when the context cannot resolve them. Calendar searches read whole local days plus buffer time, so a narrow afternoon request still counts earlier meetings and sees conflicts at its edges.

Commit `3358ac4b` passed `make build`. A manual calculation using a 45-minute request over two weeks returned only 45-minute slots with Toronto labels and the existing working rules. This was a pure calculation without provider or model calls. Automated tests were not run under the current manual-first policy. The new request path has not had a live email or calendar eval.

Workflow `35067072428` deployed the change successfully. Revision `maraithon-00401-xwm` serves all traffic. No native app changes or database migration were needed.

## Read older evidence before deciding

The delegated model can now request one bounded evidence read before composing its decision. It can read sources already cited in the fact ledger and, for Gmail, the original task message identified by the frozen grant. This gives an older conversation with no saved facts access to its originating email even after that email leaves the six-message window. The request cannot select another account, destination, or arbitrary message.

The existing read-only toolbox retrieves the source, checks its account and thread, and saves the message and digest in the encrypted run snapshot. The next composition sees that evidence. New facts still require the independent policy review before entering the ledger, and a send rechecks the source digest. A repeated read request holds with an explanation. Ordinary turns retain their current path; a turn that needs the read uses at most three model calls, including review, under the existing budget.

The new composition stage uses the existing continuation and model-entry reservation. Proven worker-termination recovery recognizes the stage and preserves unknown spend. Retrying a saved read can reuse its authenticated source snapshot. Cross-account message-ID collisions and conflicting references remain errors. Origin citations use the ledger's canonical reference shape.

Commits `da804e25` and `3099666b` passed the server compile. Automated tests were not run under the current manual-first policy. This path has not had a live provider or model eval. Selecting uncaptured historical messages beyond the pinned origin and existing fact citations remains unfinished.

Workflow `35066122312` deployed the final change successfully. Revision `maraithon-00400-nm7` serves all traffic. The scheduled September 16 memory eval remains pending; this deployment did not start another eval or send a message.

## Calendar choices for delegated scheduling

Assistant settings now let the user choose which Google account books meetings and which other accounts to check for conflicts. Web, iPhone, and Mac share the same saved preferences and account eligibility rules. Scheduling checks each selected account's primary calendar, including the booking account, and freezes that ordered set with the offer. Existing offers retain their saved calendars. Older settings preserve the first selected account as the organizer; new settings default to the task's Google account, with the existing personal-account fallback for non-Google sources.

Assistant mailboxes are excluded. Unavailable saved accounts remain visible so the user can remove or replace them; they cannot silently become another booking identity. The optional preference lives in the existing encrypted payload and requires no database migration. Slot ranking and scheduling-link refinements remain unfinished.

The Phoenix compile and both native builds passed, including Xcode project generation and the Mac signature check. Automated tests were not run under the current manual-first policy. Commit `e13771bd` deployed through successful workflow `35063819854`; revision `maraithon-00397-zds` serves all traffic. The live web form showed Kent's three eligible Google accounts and excluded October. Saving the unchanged preferences succeeded.

The shared native controls are in `b30026df` and `dc8b68ed`. Manual Mac inspection caught a SwiftUI row-identity collision between calendar IDs and weekday indices. Distinct row identities and separate form sections fixed it. The corrected signed app is installed; all seven weekdays and the three calendar choices appear separately. Toggling a calendar left the working days unchanged, and saving the original settings through the native API succeeded. No physical iPhone interaction was performed.

Mobile workflow `35064395623` succeeded. TestFlight 1.0.1 (`20260916063532`) is available to Founders, including Kent. The earlier native release was cancelled after the visual check found the row collision.

The final scheduling review also found that one invitation copied across checked calendars counted more than once toward the daily meeting cap. Commit `c7ede090` counts matching iCalendar UIDs and intervals once, while retaining every busy interval for conflict checks. Events without a usable UID remain separate. The server compile passed; no live invitation was sent for this check.

Workflow `35064779189` deployed that follow-up successfully. Revision `maraithon-00398-d27` serves all traffic.

## People loading on mobile

The September 15 mobile request failed with HTTP 500 because the default People query compared its float ranking field to integer `0`. Ecto rejected that query before it reached PostgreSQL. Commit `b857905c` uses `0.0`, preserving the ranking and visibility rules. The iPhone People list and person detail now use the existing public error-copy helper instead of displaying raw error codes.

The Phoenix compile and iPhone simulator build passed, including project generation. Tests were not run under the current manual-first policy. No schema, permissions, or stored People data changed.

Server workflow `35062580948` succeeded; revision `maraithon-00396-n6q` serves all traffic. Web and the existing native Mac client both loaded 60 ranked people out of 2,276 known people. Web also opened Charlie's detail. The native client uses the same People response decoder as iPhone. Mobile workflow `35062580967` succeeded; TestFlight 1.0.1 (`20260916061123`) is available to Founders, including Kent. No physical iPhone interaction was performed.

The native detail check found a separate Mac URL bug: pre-encoded UUID hyphens were encoded again by the request builder, producing `%252D` and a missing-person response. Commit `10edf3f1` appends the opaque ID as a single URL component. The signed companion build passed and was installed in place. Charlie's meetings, relationship, and recent history then loaded successfully in the native app. This Mac-only follow-up required no server redeployment.

The corrected Mac build was checked again after revision `maraithon-00403-7h5` deployed. People still loaded 60 ranked contacts from 2,276 known people. The iPhone request builder preserves percent-encoded path components and does not have the Mac detail URL bug. Physical iPhone verification remains unperformed.

After the September 16 trace deployment, refreshing People in the signed Mac app loaded 60 ranked contacts from 2,281 known people, including Charlie. This confirms the shared native API still loads; it is not a physical iPhone check. The fix is also included in TestFlight 1.0.1 (`20260916092859`).

## Calendar emphasis through the day

Finished calendar rows now use muted text and regular time labels in the iPhone Today view, briefing history, and web briefing. Current and upcoming events retain their emphasis. A shared server projection resolves explicit time ranges using the brief's date and timezone; unclear rows remain unchanged. Each visible surface advances its clock every minute without fetching calendar data or making a model call. New briefs retain their timezone in the existing metadata. No database or SwiftData migration is required.

Commit `0b823a05` passed the Phoenix compile and iPhone simulator build, including project generation. Tests were not run under the current manual-first policy. The Mac has no Today briefing view, so no companion binary changed.

Server workflow `35062001913` succeeded; revision `maraithon-00395-s2f` serves all traffic. The authenticated web briefing was inspected visually: all seven September 15 calendar rows were muted after their end times, while surrounding notes retained their styling. Mobile workflow `35062001946` succeeded; TestFlight 1.0.1 (`20260916060331`) is available to Founders, including Kent. No physical iPhone interaction was performed.

## Standalone Chat sessions

Opening a task creates a durable conversation for its history. That conversation previously appeared in the general Chat list, even when the user had not started a chat session. Task conversations now stay with Todos. Web and iPhone list standalone sessions in Chat, and task reply notifications open the associated todo. Old web and iPhone chat links resolve the stored task identity and open its workspace.

The server filters before pagination and uses the same scope for collection versions. The updated iPhone requests `scope=chat`. Older clients retain their previous collection response so their sync code cannot interpret excluded task conversations as deleted history. Nullable SwiftData fields classify cached threads without resetting the store. Unclassified legacy threads stay hidden until refreshed, and task history and unsent messages are preserved.

Commit `3154a184` passed the Phoenix compile and iPhone simulator build. Tests were not run under the current manual-first policy. No Mac binary changed, and no physical iPhone interaction was performed.

Server workflow `35061212075` succeeded. Revision `maraithon-00394-grd` serves all traffic. The authenticated web Chat page shows the three standalone conversations and no task conversations. Mobile workflow `35061212069` also succeeded; TestFlight 1.0.1 (`20260916055153`) is available to Founders, including Kent. Updating the iPhone is required for the cached-list and notification changes.

Read-only production execution `maraithon-todo-validation-v28n9` confirmed three standalone sessions out of 28 stored conversations, with zero task conversations in the Chat collection. The hockey task's history remained accessible through its direct thread lookup, with the correct task identity in the API response. This check made no writes, provider calls, or model calls.

## Direct task chat

Task chat is now the direct way to give Maraithon an instruction. Web, Mac, and iPhone no longer show the generic “Prepare this for me” action. The iPhone keeps the summary compact and puts secondary information under Task details. Web puts suggested actions and source details after the conversation. The Mac's specific action shortcuts say “Ask Maraithon” and send their instruction into the same chat.

The iPhone preserves keyboard focus after sending, keeps the composer editable during execution, and no longer waits for a second conversation fetch after the server accepts a message. Existing saved message IDs, retry controls, durable jobs, and live updates remain in place. Calendar instructions use the selected task, timezone, preferences, and availability. An explicit request books the user's calendar through the existing conflict and ownership checks. Booking time does not complete the task. Manual task summaries preserve the user's stated goal instead of treating missing details as a reason to ask whether to dismiss it.

The server, signed Mac, and iPhone simulator builds passed, as did eight existing calendar checks. Commit `4d83aac4` deployed through successful workflow `35059490171`; revision `maraithon-00392-mns` serves all traffic. The installed Mac build includes the final shortcut wording in `b9c522ac`. The web task workspace and installed Mac chat were inspected directly. TestFlight release `35059489962` succeeded; version 1.0.1 (`20260916052626`) is available to the Founders group, which includes Kent. No physical iPhone interaction was performed during this check.

The controlled live request “Add this to my calendar tomorrow” was accepted in 483 ms and completed in 19.299 seconds. It checked availability, booked a private 30-minute block, and kept the test task open. Resubmitting the same message ID returned the same run. This is one measured request, not a latency guarantee. Muse Spark Contributor and active development spending remain configured. No message was sent to another person.

The removal request completed in 28.208 seconds, but used five model calls because the saved event ID was missing from task chat's context. The task metadata projection had omitted `calendar_block`. Commit `4cb2eac3` carries its event ID, calendar ID, and timestamps into chat while excluding unrelated provider payloads. Cancellation instructions use that reference directly; the executor still verifies live ownership. The server build and a focused check for preserving and clearing the saved reference passed.

Production execution `maraithon-todo-validation-2s4l7` confirmed one executed create, one executed cancellation, Google's cancelled status, and the test task's cleanup. The initial report script had failed during cleanup on `not(nil)` after both chat turns finished. The follow-up read the saved outcomes and cleaned up without resending either action. It also regenerated the hockey brief: the goal remains registration, and the missing question is which league and season. [Task chat evidence](evidence/delegated-conversations/2026-09-16-direct-task-chat.json).

The calendar-reference fix deployed successfully through workflow `35060348062` to revision `maraithon-00393-l8q`. The repeat eval, `maraithon-todo-validation-v4t42`, passed on that image. Booking took 20.992 seconds with three model calls and two tools. Removal took 10.381 seconds with two model calls and one tool, down from five model calls and five tools. Server acceptance took 397 ms and 329 ms respectively. Both duplicate submissions reused their original run. The task stayed open after each action, Google confirmed cancellation, and the disposable task was dismissed. These are server timings from two controlled conversations, not device or network latency measurements.

## Slack display names

Slack discovery now keeps its workspace credential attached through conversation, history, search, thread, and directory requests. Dropping that context had caused requests to fail before reaching Slack. Task preparation also resolves IDs copied into titles, summaries, notes, and participant labels. It saves verified names per task and workspace, uses a credential with directory permission, and checks the task version before saving. Task lists perform no provider lookup. Links, message destinations, prepared drafts, ownership, and status retain their original values.

Slack confirmed that `U0A7JQ8V5NH` is Paolo. The saved task now reads “Reply to Paolo on Brett note workaround.” Production execution `maraithon-todo-validation-hdvqv` repaired nine of 21 Slack tasks and verified the shared task projection. Existing open task briefs were queued for regeneration from the corrected copy. The repair made no direct model calls and sent no Slack messages. Message action labels also use the saved names while retaining the underlying Slack recipient ID.

The server build and 19 focused checks passed. They cover directory permissions, workspace isolation, stale edits, replay without another lookup, preserved links and recipients, source acquisition, and brief generation. Commits `80fe77f0` and `112f0764` deployed successfully; revision `maraithon-00391-fjn` serves all traffic. Web, Mac, and iPhone consume the shared task data; no native binary changed. Muse Spark Contributor, active development spending, and disabled Slack sends remain configured. [Slack name evidence](evidence/delegated-conversations/2026-09-16-slack-display-names.json).

## Todo chat reliability

The failed “Mohit is getting this for me” turn never changed the task. Muse rejected its first request because the chat harness required a function call; this provider accepts only automatic tool selection. The harness now uses that supported setting and accepts either a function call or a plain final reply. Failed requests are recorded as failed, and chat plus API error copy explain what did not complete without claiming that evidence was saved.

Selected-task chat now loads the task, recent conversation, preferences and account settings. It fetches other sources only when needed. An explicit ownership update uses the user's statement as evidence, resolves the named person, saves the workflow transition, then confirms the saved result. It does not search connected mail to corroborate the user's own correction.

The live replay resolved Mohit (Uride), saved `they_own`, and moved the CSV task into Tracking. Its reply was “Updated. Mohit has the next move on the CSV; this is now in Tracking.” It used three model calls and two tools: People lookup and workflow transition. No Slack message was sent. Duplicate acceptance returned the same run. The ownership change remains saved at revision 1.

That replay took 85.171 seconds, including 72.471 seconds before execution during a deployment. A later follow-up completed in 7.083 seconds without changing ownership. The rollout overlap prevents attributing the whole delay to background contention. Interactive chat now has a separate, bounded worker queue using the existing OTP runner and PostgreSQL lease checks. Local checks prove that chat runs while a background model worker is occupied. Conversation ordering and duplicate detection remain in the existing durable execution path; previously queued requests retain their original queue.

The server build and 92 focused checks passed. These cover native tool responses, failure receipts, context selection, restart recovery, API and export redaction, duplicate acceptance, worker isolation, and exact lease admission. Commits `7fa7b554` and `cf68f713` deployed successfully. Queue isolation in `71ca0a3e` deployed through workflow `35057468192` to revision `maraithon-00389-dcq`, serving all traffic. Its live follow-up completed in 7.166 seconds, including 1.577 seconds waiting to start, with one model call and no tool or external send. The new queue and duplicate reuse were verified. This does not prove that deployment handoff delays are eliminated. [Chat evidence](evidence/delegated-conversations/2026-09-16-todo-chat-reliability.json). These are shared server changes for web, Mac and iPhone; no native binary changed.

## Delegation suggestions

The Chief of Staff now ranks source-backed delegation candidates inside its existing cycle memo. It scans at most 40 open Gmail or Slack tasks and passes at most 12 eligible candidates to that call. Eligibility requires work owned by the user, an outbound next action, a resolved person, and evidence bound to the connected account and conversation. Work owned by Charlie or another person does not qualify. The memo may suggest up to three tasks, each with a one-line reason.

A suggestion records an insight through AttentionArbiter and updates the existing task. It creates no duplicate task, grant, or conversation. Replays cannot duplicate the suggestion. A changed task, source, or account prevents publication of a stale memo. The next task review expires the suggestion; dismissing it leaves the task open. The brief lists current suggestions in one row.

Web, Mac, and iPhone share the suggested actor and task type. Opening “Delegate to October?” uses the existing fresh grant preview before accepting the work. This adds no model call, though eligible candidates add bounded input to the memo already being generated. Quiet cycles do not create a memo just to produce suggestions.

The server, signed Mac, and iPhone simulator builds passed. All 18 focused proposal and reporting checks passed, including the memo callback, ownership exclusions, stale-source rejection, replay, dismissal, expiry, Slack binding, public JSON, and web component rendering. Commit `b38175da` deployed through workflow `35037908722` to revision `maraithon-00379-skh`, serving all traffic. The Mac update is installed and opens connected. The iPhone release passed in workflow `35037908692`; TestFlight 1.0.1 (`20260915235739`) is available to Founders. The authenticated web task list also loads after deployment. [Proposal evidence](evidence/delegated-conversations/2026-09-15-proposals.json).

Read-only production execution `maraithon-todo-validation-vtbrg` loaded the new module and confirmed Muse Spark Contributor, development spending, the labelled Gmail eval restriction, and disabled Slack sends. It found no eligible live proposals, made no provider or model calls, and sent no messages. Live proposal acceptance is still unverified. The existing October memory eval remains pending for September 16 at 08:00 Eastern; its durable job survived this release.

## Slack delivery adapter

The delegated Slack sender now freezes the exact member or bot, workspace, channel, thread, and message hash. It verifies the live credential before posting, preserves October's configured name and icon, and sends mentions as literal text. The source member takes precedence over the person who installed the Slack app. Both the OAuth request and committed app manifest include `chat:write.customize`; existing installations still need to grant that scope before October can send.

Delivery recovery uses the existing prepared-action record. A partial response retains only Slack's channel and server timestamp, then a bounded thread read must match the author, thread, and content. A lost response stays uncertain and cannot trigger another send. This follows Slack's warning that `internal_error` and `fatal_error` can follow a partially successful operation. [Slack posting reference](https://docs.slack.dev/reference/methods/chat.postMessage/).

The server build passed. Local transport, policy, manifest, and prepared-action recovery checks passed, including persistence of an uncertain timestamp and rejection of a second execution. Commit `13d7a791` deployed successfully through workflow `35023672528`; revision `maraithon-00368-sgf` is ready. No live Slack messages or model calls were made. Production retains the Gmail eval restriction, disabled Slack autonomous sends, and active development spending. Source refresh, durable reply ingress, and the controlled live conversation evals are still outstanding; this adapter alone does not complete the Slack slice.

## Slack reply routing

Slack messages now enter the delegation event log in the same transaction as source ingestion, before webhook acknowledgement. The existing outbox wakes the coordinator after commit. Provider event IDs and message revisions deduplicate webhook retries and repair reads. An edit invalidates an unsent decision; the coordinator rejects the stale action and returns the task to ready. Deletes and new participants require review. A manual message from the operator pauses the task, while an exact Maraithon echo does not become a reply.

Grant preview reads the thread and freezes its known counterparties. Source refresh verifies the bound reader and preserves authors, message IDs, and content revisions. A DM includes unthreaded replies only when it has one live delegation; unrelated threads stay out of the snapshot. The coordinator's command dispatch now admits Slack through the same source, decision, and send path as Gmail.

The server build and focused checks passed. Coverage includes real leased source and sender jobs for the member and assistant bot, a lost response with no repeated write, an edit before send, webhook persistence before acknowledgement, duplicate events, ambiguous DMs, and Gmail sender regression checks. The test runtime helpers are shared with the Gmail evals. These checks use local provider fixtures and make no paid model calls or live Slack sends. Commit `b14ecb92` deployed through workflow `35025526204`; revision `maraithon-00369-5ft` is ready.

Slack autonomous sends remain disabled. Kent deferred the controlled live Slack eval. Slack-to-calendar scheduling and source pagination beyond the bounded snapshot remain unfinished.

## Assistant Slack DMs

An assistant delegation now resolves a separate bot DM with the exact counterparty before activation. Kent's member token reads the original DM; October's bot posts the first message in its own channel. Repeated previews resolve the same destination and send no message. The confirmed provider timestamp becomes the durable thread root. Later replies and source reads use that bot conversation. [Slack DM reference](https://docs.slack.dev/reference/methods/conversations.open/).

A changed original thread invalidates the first unsent decision. Messages in the bot DM before that first send cannot count as answers. Once a send is entered, a lost response stays uncertain without another write. Reconciliation requires the exact returned timestamp, actor, channel, thread, and content. Bot-only DM ingress saves delegated events without adding CRM observations or waking personal discovery. The committed Slack manifest now includes bot `message.im` events.

The server build and focused transport, leased-worker, isolation, manifest, and connector checks passed. Local fixtures cover opening the DM, rejecting the wrong recipient or original channel, binding the first receipt, an unthreaded reply, switching reads to the bot, edits before sending, and lost responses. No live Slack message or model call was made. Commit `e4b20456` deployed through workflow `35026566631`; revision `maraithon-00370-mvq` is ready. This does not complete the controlled Slack conversation eval, which Kent has deferred.

A read-only production inventory on September 15 found one connected Runner member and its bot. The bot lacks `chat:write.customize`; the external Slack installation must also adopt the updated message subscription. A second controlled test member would be needed to resume that eval. Kent asked to defer it for now; no additional Slack setup is requested. Autonomous Slack sends remain disabled.

## Personal provider reads

The direct-read audit found that the legacy Gmail connector and Calendar's default account lookup could bypass the assistant exclusion already present in tool and discovery helpers. They now share a personal-account resolver. A named assistant provider is rejected for personal reads, and the generic Google fallback cannot select an assistant when no personal account remains. Explicit account reads used by delegation workers, signature setup, and delivery reconciliation remain available.

The server build and all 14 assistant-isolation checks passed. The new cases cover direct Gmail lists, messages, threads and history, Calendar sync and upcoming events, an assistant-only connection, choosing the personal account when both exist, and retaining explicit assistant evidence reads. Four existing leased Gmail send-and-recovery regression cases also passed. These were local provider fixtures with no live messages or model calls. Commit `b30e9ee7` deployed through workflow `35027028412`; revision `maraithon-00371-lxr` is ready. Production still uses Muse Spark Contributor, the Gmail eval restriction, disabled Slack autonomous sends, and active development spending.

Calendar watch renewal also keeps the bound account's token when retiring the old channel. Previously, an assistant or secondary-calendar renewal could create the replacement correctly, then try to stop the old watch with the default personal account. That could leave both channels delivering notifications. The existing renewal checks now include an assistant account alongside a different default account; all three checks and the server build passed.

Commit `f63e0af7` deployed through workflow `35029135398`; revision `maraithon-00373-4c8` is ready. Muse Spark Contributor, the Gmail eval restriction, disabled Slack sends, and active development spending remain configured. Default Google watch helpers also use the shared OAuth fallback, which already excludes assistant accounts; explicit per-account renewal remains available.

## Authored voice samples

Gmail and Slack now share a voice-sample cleaner. Gmail requires Sent mail from the bound mailbox's primary or verified send-as addresses; assistant accounts and the configured assistant alias are excluded. Slack verifies the token's live member and workspace, then checks those fields on every search result. Search terms and caller-supplied sample text cannot substitute for sender evidence.

The cleaner removes recognised reply quotes, wrapped reply headers, configured signatures, mobile footers and confidentiality notices. It excludes forwarded and automated messages, missing authors or dates, and known Maraithon sends. HTML-only mail is rendered without link-attribute annotations. Profiles record removal and exclusion counts. Generated-send history is a bounded, authenticated read of prepared actions. More than 128 candidate actions or a purged action holds the refresh instead of silently dropping provenance.

Older profiles without the cleaning version, failed refreshes, and successful JSON responses without actual guidance use explicit style instructions. Assistant turns retain their house style. This adds no provider or model calls to a delegated turn; collection runs only on voice refresh. Recognition of signature and quote formats is deterministic, not a claim that every possible mail-client format is covered.

The server build and 23 focused local checks passed. They cover both providers' authorship, quoted and generated evidence, signatures, account isolation, draft and turn selection, history overflow, and a real prepared-action retention purge under the exact runtime. No live messages or paid model calls were made for these checks.

Commit `49bcd252` deployed through workflow `35028690308`; revision `maraithon-00372-thq` is ready. A read-only production job then sampled eight messages from Kent's Runner mailbox. All four controlled eval emails were excluded as generated writing. Two ordinary messages were excluded as forwards; two were retained after footer removal. The check used 39 authenticated prepared-action records and wrote no profile, made no model call, and sent no message. This verifies the deployed sampling path on a small real mailbox sample, not learned-profile quality. [Live sampling evidence](evidence/delegated-conversations/2026-09-15-voice-sampling.json).

## Long Gmail conversations

The Gmail reader no longer rejects a source merely for containing more than 100 messages, or because old bodies exceed the snapshot limit. It reads the complete header index, records progress in the existing event ledger eight messages at a time, and keeps six recent bodies in the turn snapshot. An unfinished batch reschedules the same job. A new worker resumes from committed events without admitting a model decision early. Unchanged bodies can be reused from three prior authenticated turn snapshots.

Before sending, the worker compares the full thread fingerprint. A late reply invalidates the pending send, including before October opens a separate thread. That first sync uses Kent's source account and provider queue. Missing or foreign account bindings cannot fall back to another mailbox. The index remains bounded at 10,000 messages and the recent snapshot at 240 KB; unreadable or oversized recent evidence still holds the conversation.

The server build and 35 focused checks passed. The long-thread fixture covers 180 messages across 180 days and 23 separately leased workers. It fetched six bodies; the next unchanged turn fetched none. It also covered a late reply, old-message removal, a mismatched body, source-account isolation, and durable deduplication. The existing Gmail delivery and local Slack sender checks passed. The accelerated fixture raises only its local admission rate so one-second retries can run immediately. It does not prove whole-app crash recovery or a six-month production run.

This removes the reader's history-size failure. Google also documents that Gmail conversations split after more than 100 emails or a subject change. The 180-message fixture is synthetic; it does not prove continuity when Gmail assigns a different thread ID. The continuation work below handles that separate boundary. [Gmail conversation grouping](https://support.google.com/mail/answer/5900?hl=en), [Gmail API threading rules](https://developers.google.com/workspace/gmail/api/guides/threads).

Commit `de752a8d` deployed through workflow `35031069439` to revision `maraithon-00374-r5k`. Read-only production job `maraithon-todo-validation-4lk4w` then verified an existing conversation for Kent and one for October on that image. All seven messages had usable dates, metadata without bodies, and matching full-read fingerprints. Both snapshots were complete, with no pending ingress messages. The check made no model calls, sent no emails, and wrote no conversation state. It verifies the real API shape on small threads, not a live 180-message conversation.

Commit `7a820edf` reuses the connector's existing metadata reader instead of adding another entry point. Its build and five source checks passed; workflow `35031427439` deployed revision `maraithon-00375-2s5`, which is ready. Muse, controlled Gmail evals, disabled Slack sends, and active development spending remain configured. [Long Gmail source evidence](evidence/delegated-conversations/2026-09-15-gmail-source-history.json).

### Following verified Gmail thread changes

Gmail ingress now records RFC Message-IDs in authenticated, consumed event rows. A reply in a new thread can continue the same delegation only through a recorded parent in the same mailbox, with the granted participants and subject unchanged. Matching subjects alone do not connect conversations. The original grant remains in force. The transaction records the new thread segment and advances the source revision before an older decision can send.

Ambiguous ancestry, changed participants, or a changed subject holds for review. Replies after stop remain recorded without restarting the conversation. Older releases' authenticated inbound events can supply parent evidence through a bounded compatibility read. Indexed and legacy matches are checked together, so an upgrade cannot hide conflicting ownership. This uses the existing event ledger and indexes, with no new process, table, model call, or provider scan.

Turn context carries at most six recent messages across verified segments and always includes the current reply parent. Prepared messages target that segment even when a later-dated message from an earlier segment is cached. Before October's first send, source classification uses Kent's source mailbox identity while preserving October's sending identity and grant.

The server build passed, and 60 focused ingress and source checks pass. The fixtures cover two thread changes months apart, duplicates, foreign users and accounts, contradictory headers, changed participants and subjects, mixed legacy/indexed ambiguity, stopped conversations, and current-thread reply preparation. One fixture called the wrong helper; that call was corrected and the failing case passed on rerun. No live email or paid model call was used for these checks. Gmail's automatic split after 100 messages has not been reproduced with a live provider conversation.

Commit `c18cd3d1` deployed successfully through workflow `35033415934`. Revision `maraithon-00376-m9w` is ready and serving. Production job `maraithon-todo-validation-c5prq` then verified 32 authenticated legacy references across Kent's and October's mailboxes. Both accounts are well below the 2,048-row compatibility bound; the sampled query execution took 1.1 and 1.9 ms. The transaction was read-only, with no provider calls, model calls, messages, or conversation writes. This verifies stored upgrade evidence and lookup cost, not a live automatic thread split. Muse Spark Contributor, the Gmail eval restriction, disabled Slack sends, and active development spending remain configured. [Thread continuity evidence](evidence/delegated-conversations/2026-09-15-gmail-thread-continuity.json).

Slack pagination was unfinished at this checkpoint; the later resumable-history section records its implementation. The later six-hour Gmail canary passed as recorded above. Longer longevity coverage and automatic Gmail rollover still need live provider evidence. The fact-ledger work below adds recall for facts learned by reviewed turns.

## Durable facts and cited recall

Reviewed turns now save compact facts and their exact source references in the delegation's existing encrypted payload. No new table or process is needed. The model proposes facts during its normal composition call, and the existing independent review checks each fact against its cited message before anything is stored. A rejected or superseded decision cannot change memory. Retries reuse the committed turn and its frozen context.

Each fact has a stable key, a short statement, and citations bound to the provider, account, channel or thread, message ID, and content digest. A correction replaces the same key. Other facts remain unless the reviewed decision explicitly removes them. Drafts, self-authored claims, unknown citations, and changed participants cannot supply a new fact. The grant and task owner remain separate from memory.

When a decision cites evidence outside the last six messages, the read-only toolbox resolves only citations already present in the frozen ledger. Gmail reads the exact message from the bound mailbox. Slack reads the exact timestamp from the bound channel or DM, after verifying the token's author and workspace. The original message enters the review context and is saved with the turn. Before sending, the worker checks recalled evidence again; changed, missing, or inaccessible evidence prevents entry. The Slack read uses the provider's documented timestamp bounds. [Slack thread reads](https://docs.slack.dev/reference/methods/conversations.replies/), [Slack history reads](https://docs.slack.dev/reference/methods/conversations.history/).

The ledger is capped at 32 KiB, with 28 KB available to facts and room reserved for existing outcome and booking notes. A turn may update eight facts and recall six older messages totalling at most 128 KB. PromptBudget enforces a 64 KB prompt ceiling. Limits hold visibly; they do not silently truncate facts. Decision wake events now carry only the kind and user question because the reviewed decision is already stored on the turn.

The server build and 106 distinct focused checks passed. The initial run passed 105 checks; after preserving the original account in outcome citations, the 62-check follow-up included one new case. A simulated turn 180 days later used its stored fact, fetched one cited message, and passed independent review with the usual two model calls. Replaying the leased worker made no additional provider or model calls. Other checks cover rejected facts, corrections, explicit removal, size limits, foreign mailboxes, missing messages, changed evidence before sending, preserved Gmail signatures, and local Slack channel and DM reads. These fixtures do not prove whole-app recovery or a real six-month conversation.

Commits `5adf1c58` and `3e9ad3f5` deployed through workflow `35035265999` to revision `maraithon-00377-xkw`. The first live memory attempt, `maraithon-todo-validation-kts9t`, stopped at preflight with zero messages. Its validation job still had an old model and lacked the serving app's delegation flags. The serving app retained Muse and the controlled Gmail gate. Live verification of learned memory remains pending.

## Controlled eval configuration and sending hours

The eval commands now share a configuration reader that pins the serving image and copies only the relevant non-secret model, spending, and delegation settings. They also pass the selected actor, clear stale model fallbacks, and disable automatic container retries. Starting an eval no longer changes the serving app's rollout gates. A local configuration fixture verified model selection, comma-separated allowlists, disabled gates, omitted secrets, and the default US$3 projection.

The saved sending hours are 08:00 to 18:00 Eastern on weekdays. A live eval started in the evening now queues for the next working window, and its one-hour deadline starts there. A late-day start without a full hour also waits. This uses the existing durable background job schedule and leaves user preferences and send checks intact. The server build and two focused evaluation checks passed, including the weekend daylight-saving transition and short working windows. The memory eval still needs to finish with real provider evidence.

The corrected read-only production preflight, `maraithon-todo-validation-4wvrt`, passed for both Kent accounts and October. It confirmed Muse Spark Contributor, development spending, execution readiness, and October's separation from personal sources. It sent no messages, created no events, and made no model calls. [Durable memory evidence and current limits](evidence/delegated-conversations/2026-09-15-durable-facts.json).

Commit `358d5360` deployed successfully through workflow `35036148839`. Revision `maraithon-00378-lqv` is ready and serves all traffic. The controlled Gmail gate, disabled Slack sends, Muse model, and development spending remain configured.

Launcher `maraithon-todo-validation-dk94d` completed and committed one October information eval: job `04a64f25-c24a-42ee-a819-a94cbe07e917`, scheduled for September 16 at 08:00 America/Toronto (`12:00 UTC`). Use this job when checking the live learned facts and recalled source; do not launch a duplicate.

Read-only status workflow `35088725203` succeeded on September 16 before the scheduled start. It confirmed that same job is still `pending` at `12:00 UTC`, with no result yet. It did not start another conversation.

After the scheduled start, successful status workflow `35093470917` confirmed that the same job completed with phase `passed`. The October information conversation used four model calls across two turns, cost US$0.001201, sent one assistant message and marked the task done with the counterparty reply cited as completion evidence. This supports the revised ordinary-turn target. The separate fact-ledger and cited-source probe subsequently passed through workflow `35095785564`, as recorded above. [Saved eval result](evidence/delegated-conversations/2026-09-16-october-information.json).

## Previously verified

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

This completes the central isolation, signature, and first-message copy paths, not the full assistant slice. The remaining work includes the direct provider read audit and live actor verification. October connected on September 15; live actor verification still needs Google's sending permission.

## Conflict recovery and retention

A malformed message body gets one durable repair attempt, followed by the same independent policy review. A second malformed response holds. Early conflict detection now counts a changed offer toward the single-reoffer limit. The focused admission, policy, and calendar run passed 50 checks.

The next conflict run stopped on an OpenRouter rate limit during its second turn. Four provider entries reported US$0.002103, plus a retained reservation for the rejected request. Calendar cleanup completed. Commit `2c40b9ae` records a capacity outcome and retries from fresh sources after the provider cooldown. Replaying the worker cannot enter another call, and unresolved spend stays reserved. Its 33 focused ingress checks and server build passed. [Rate-limit evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-rate-limit.json).

The following run, job `88ad8513-f3de-422c-a6ca-f8fbb5e12a59`, used revision `maraithon-00348-8dc`. Its first turn reached `policy_review_required` after two Muse calls costing US$0.001305. It sent no agent email, and the fixture stopped the conversation and completed calendar cleanup. The verdict incorrectly rejected the authorized mailbox signature because it applied the composition instruction to the final signed body. Commit `01172cde` clarifies that review receives the final body, and that the frozen signature is expected. It also removes fixture sign-offs and uses the actual sending mailbox signature for eval and assistant emails, unless the assistant has an explicit override. [Evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-signature.json).

Retention also keeps stopped conversations with unresolved model reservations. Its focused check verifies that cleanup preserves the turn and its reservation, and that settled spend restores eligibility. This is separate from user-requested privacy erasure.

Commit `3aff247f` also carries the frozen mailbox display name into the From header alongside the verified address. Nine Gmail transport checks passed, including rejection of header injection through the name. The server build passed.

## Booking approval and mailbox formatting

The conflict rerun on revision `maraithon-00351-j2n` sent two offers and received acceptance of the replacement time. The independent reviewer returned `allowed=true`, with a reason confirming explicit counterparty acceptance and current availability. It correctly returned `outcome_proven=false` because no calendar event existed yet. `Policy.approved?/2` incorrectly required that flag for booking as well as completion. No invite was sent. The fixture stopped and cleaned up its temporary calendar entries. Six calls cost US$0.004518. [Evidence](evidence/delegated-conversations/2026-09-15-calendar-conflict-booking-approval.json).

Commit `0bbf7c4a` requires semantic approval before booking and reserves outcome proof for a complete decision. Counterparty evidence, the offered slot, fresh availability, and the provider receipt remain required by their existing checks. The two leased-booking cases passed with outcome proof false before creation, including refusal when the slot becomes busy. The 32 policy, calendar transport, and scheduling checks passed, and the server build passed.

The new conflict run passed on revision `maraithon-00353-79v`. It offered three times, detected the first accepted slot becoming busy, offered replacements, and booked exactly one meeting in the accepted replacement slot. The recipient calendar copy was verified before cleanup completed. Three turns used six model calls and cost US$0.004483. All five sent emails matched their frozen plain-text and HTML bodies, included the original mailbox signature, had no plain-text link annotations, and preserved the sender display name. The initial delivered email was also visually verified in Mimestream. [Live conflict evidence](evidence/delegated-conversations/2026-09-15-live-calendar-conflict.json).

The provider reader verified all five emails against the frozen mailbox signatures. Kent's screenshots revealed that the evidence renderer had exposed link annotations in outgoing signatures. Commit `c98b50ee` preserves the mailbox HTML signature in a multipart email and supplies a clean plain-text alternative. Model evidence still retains its link annotations. It also falls back to the account's saved display name when send-as omits one. The email formatter escapes the composed body and appends the frozen footer once. The 36 focused identity, policy, transport, settings, and category checks passed; the follow-up identity and native contract run passed 11 checks.

## Native assistant settings

Commits `6e23e6aa` and `9eb9c2ac` give Mac and iPhone a shared assistant form using the same account choices, timezones, numeric limits, identity, and preferences as web. The server returns account labels without loading credentials. Both device authentication paths passed the settings contract check. Native account and delegation requests also remove a duplicate `/api/mobile` prefix that would have prevented the iPhone from reaching those endpoints.

Signed Mac and iPhone simulator builds passed, with XcodeGen regeneration. The focused iPhone request test could not run because the dormant test target references the removed `TodayViewCopy` type. An earlier compile failure in the todo-count fixture was updated to include the current action, watching, and snoozed counts. The native test target remains unverified; no test was deleted, skipped in the project, or replaced with a passing stub.

Server workflow `35007994634` passed, serving revision `maraithon-00353-79v`. iPhone workflow `35007994545` built and uploaded to TestFlight successfully. The signed Mac app is installed. Its preferences saved through the shared API, and web showed the same values. After October was configured on web, Mac loaded its name, verified address, and disclosure setting. Simulator inspection was unavailable through the app-control connection, so the iPhone screen has not been visually verified.

## October eval preparation

Kent connected `october@ewakened.com`, account 9. Web verified its sending address and saved the assistant name October with the mailbox signature, AI disclosure enabled, and first-message Cc left off. Mac loaded the same identity.

The eval extension supports the frozen actor and permits October only as the assistant sender on labelled Kent-pair conversations. Preflight checks its verified identity, sending scope, and exclusion from personal source accounts. The reply fixture resolves the latest executed send into the recipient's actual mailbox by RFC Message-ID, then replies in that mailbox's thread. It checks the sender address, display name, and frozen signature before replying. The server build and 12 focused gate, offer, and isolation tests passed. The leased fixture retry check also passed, confirming that replay does not send the initial email twice. This extension deployed in revision `maraithon-00355-ftz`, workflow `35010181018`.

The read-path audit found that `OAuth.get_token(user, "google")` could fall back to an assistant mailbox. The default lookup now excludes assistant providers while exact bound access remains available. Eleven isolation checks and 39 OAuth checks passed, along with the server build. Older OAuth fixtures now create real test users so the existing privacy fence can run; their assertions were preserved.

The first assistant attempt stopped before enqueueing the conversation. The production reader verified October's account, sending address, display name, disclosure, and assistant classification, but its five Google scopes include only read access to Gmail, Calendar, and Contacts plus account identification. No accepted Gmail sending scope is present. Both Kent accounts and the Muse model passed preflight. This attempt sent no messages, created no events, made no model calls, and incurred no LLM cost. [Permission evidence](evidence/delegated-conversations/2026-09-15-october-permissions.json).

Commit `4728607c` moves the same send-permission check into normal delegation identity preparation, before source reading or model work. Web, Mac, and iPhone receive a shared warning when the selected mailbox cannot send. Settings may still save the identity, and the warning clears when Google grants sending permission. The server build and 13 focused checks passed, including both native authentication paths and the web warning. Workflow `35011567883` deployed revision `maraithon-00356-6l2` successfully. October's Google sign-in is open for Kent to finish and grant Gmail compose access.

Kent's connector screenshot showed why this was confusing: the row said Healthy and listed five permissions without saying that Gmail was read-only. Commit `0056f910` names read and send access on each Google account, adds an Enable Gmail sending action for missing access, and flags October's missing permission. Its consent URL includes the exact account and assistant purpose. Assistant reconnects also preserve that purpose and request compose access. The server build and four connector controller checks passed, including disappearance of the action after sending is granted. Workflow `35012173010` deployed revision `maraithon-00357-fmg` successfully. Production web verification showed the missing-permission message and the account-specific consent link on October's row; all three Kent accounts showed Gmail sending and calendar booking access. The assistant eval remains pending Google's consent.

## Personal and work accounts

Commit `ced148f9` adds account categories and an All / Personal / Work filter. The filter uses the task's source account, so changing an account updates existing tasks without model calls or rewriting todos. Unassigned accounts and tasks without a source account appear under All. Provider token refreshes cannot overwrite the category. Account and assistant settings are available to signed-in users without admin access.

Web, Mac, and iPhone use the same saved categories. The native apps share the account settings form and category enum; the iPhone stores the optional category through an additive SwiftData field and refreshes it on sync. The server migration registers the reviewed column and constraint in the durable and privacy catalogs and checks that all other proofs remain valid. The focused domain, signature, policy, eval, settings and API checks passed 29 tests. Server, signed Mac, and iPhone simulator builds passed. Server workflow `35003898249` passed, serving revision `maraithon-00350-qk8`; production migration `maraithon-migrate-tt86z` passed. The signed Mac app is installed. A temporary category change saved from Mac produced seven existing tasks in the web Personal filter, then was restored to Unassigned. Commit `07b95afa` replaces provider IDs with readable account labels and avoids loading OAuth credentials for category reads. Its three regression checks and server build passed. Follow-up deployment `35004585260` passed, serving revision `maraithon-00351-j2n`. Google email addresses and Agora / Runner account names are verified in production. iPhone release `35004585337` passed. [Category evidence](evidence/delegated-conversations/2026-09-15-account-categories.json).

The post-rollout sample at 18:13 to 18:14 UTC found all 64 partitions ready with live leases, no termination requests, and advancing recurring work. Renewal and storage verification did not dominate query time. Recovery logs are present, but the sample contained no recent effect or checkpoint events, so it does not prove every runtime health criterion. [Recovery evidence](evidence/delegated-conversations/2026-09-15-category-runtime-recovery.json).

The 18:47 to 18:48 UTC sample again found all 64 partitions ready with live leases, no termination requests, and advancing recurring work. Both active agents had created checkpoints with no snapshot persistence failures. Renewal took about 25 ms of query time, and no storage verification query ran during the sample. The cost monitor ran at 18:45 UTC and scheduled its next check six hours later. Recent effect-completion evidence was absent, so this sample still does not establish full runtime health. [Evidence](evidence/delegated-conversations/2026-09-15-signature-runtime.json).

## Account-specific voice

Voice refreshes now retain the selected account. Profiles are keyed by account and channel; an explicit account cannot fall back to another mailbox or the legacy channel profile. Assistant, foreign, disconnected, and ambiguous accounts cannot supply a user profile. Gmail training excludes drafts, incoming mail, and Maraithon's own sends, including messages whose original Message-ID Google has preserved after rewriting it. General draft memory excludes voice profiles so it cannot reintroduce another mailbox's style.

Each delegated turn freezes a bounded voice snapshot in its existing authenticated Run payload before model entry. Retries reuse it; the prepared action includes its version in the frozen payload. As-user turns use the bound account's profile or explicit style guidance. Assistant turns use the house style. Composition and review receive voice as style data, with no authority to add facts, recipients, or commitments. This adds no provider reads, training, or model calls to a turn. Existing queued turns without a snapshot retain their original continuation.

The server build and 26 focused checks passed: 20 profile, draft, and policy checks, plus six leased-turn and prepared-action checks. The draft checks also caught and corrected a missing optional account being parsed as the string `nil`. Commit `3033a205` deployed successfully in workflow `35013622962`; revision `maraithon-00358-zmw` became ready at 19:29 UTC and serves all traffic. This is local verification of account isolation and durable voice selection; no live October exchange or Slack voice proof is claimed. The refreshed production account page still shows October's missing Gmail sending permission.

## Idle coordinator retirement

The recurring delegation sweep now includes coordinators with no live or recently changed conversations for seven days. It uses the existing lifecycle operation to stop and soft-remove the unused installation after quiescence is proven. Conversation, grant, and action history remain stored. The next delegation creates one new coordinator with a fresh identity key; the retired binding stays revoked. A new conversation between candidate selection and the locked retirement check cancels retirement. Stopped agents, tripped crash guards, unfinished turns, and unproven sends are not retired automatically. Restarts do not reset the cutoff. Late replies to terminal conversations remain stored as consumed events without changing the conversation's activity timestamp.

The server build and eight focused checks passed. The checks cover the seven-day boundary across restarts, months-long waiting conversations, recent completions, archived late replies, crash guards, unfinished turns and sends, stale job authority, recreation without identity-key collisions, and retention of the installation until the monitored owner is proven down. The sweep and recreation checks run under exact background-job authority. The owner-down check exercises the existing monitored lifecycle path. This does not establish whole-BEAM recovery or a seven-day production canary.

Commits `0f40b402` and `929ff6fc` deployed successfully through workflow `35015027021`. Revision `maraithon-00360-w2m` became ready at 19:44 UTC and serves all traffic. [Retirement evidence](evidence/delegated-conversations/2026-09-15-idle-coordinator.json).

## Delegation reporting in the morning brief

The morning brief now includes a bounded report of conversations that changed recently or still need a decision. It preserves the task owner and renders progress and costs directly from saved state. Model output cannot replace this section, and the source fallback includes it too. Quiet work being handled by the agent is excluded from ordinary open commitments. Paused work returns to the user's action list.

The report shows recorded lifetime cost and average cost per turn for each listed conversation, plus the user's recorded 30-day delegation spend. Unresolved reservations stay separate and remain visible beyond the window. The window follows the existing conservative budget rule: a turn's recorded spend is counted from its latest update, rather than claiming provider billing timestamps that are not stored. All totals are scoped to the user and include conversations beyond the eight displayed rows. The report adds three bounded-result database queries and no provider or model calls. It uses the existing shared brief body for web, Mac, iPhone, and delivery.

The server build and seven focused checks passed, covering ownership, old decisions, quiet waiting, the 30-day boundary, unresolved charges, user isolation, bounded rows with complete totals, source-label escaping, model-claim replacement, fallback rendering, and paused work. Commit `218bc736` deployed successfully through workflow `35016276268`, revision `maraithon-00361-jwc`. A read-only production check generated the section with eight rows, US$0.019560 in recorded delegation charges and US$0.210536 in unresolved reservations. It made no model or provider calls. No extra morning brief was sent. [Report evidence](evidence/delegated-conversations/2026-09-15-brief-reporting.json). Proposals remain separate unfinished work.

## October sending enabled and budget hold

October's Gmail sending permission is now enabled. The refreshed account page and production reader both confirm it. The assistant remains excluded from personal accounts, default Google access, and the user's own identity handles.

The information eval on revision `maraithon-00361-jwc` stopped on `account_cost_hold`. Its durable event proves the cause. The first turn made zero model calls, incurred zero model charges, and sent no October message. One initial Kent fixture email was sent, with its plain and HTML signatures verified. The fixture then stopped the conversation and completed cleanup. The assistant exchange has not passed.

The 18:45 UTC cost monitor recorded US$4.423600 billed that UTC day and a US$6.024171 rolling upper estimate, above the US$6 threshold. Its warning email was verified in `kent.fenwick@gmail.com` at 2:45 PM ET. The next scheduled check is September 15 at 8:45 PM ET. This account-wide amount is separate from the much smaller delegation-only charges in the brief report. The six-hour sample boundary makes the rolling estimate conservative. [Permission, hold, and alert evidence](evidence/delegated-conversations/2026-09-15-october-budget-hold.json).

Commit `2aef1f3c` checks the same account budget before a live eval reads providers or creates a fixture. Preflight reports budget readiness, and all clients receive a clear LLM spending hold label. Future warning emails explain that delegated conversations pause new model work while the cost hold is active. The threshold and six-hour schedule are unchanged. The server build and three focused budget checks passed. Workflow `35017699826` deployed revision `maraithon-00362-4hv` successfully; it serves all traffic.

## Development spending

Kent clarified that normal spending should pause above US$7, while active development can spend what is needed to make the product work. The explicit `LLM_DEVELOPMENT_SPENDING` setting implements that choice. Development mode skips dollar admission limits but still records charges and reservations and preserves call limits and send authority. Normal mode accepts a valid US$6 alert without pausing until usage exceeds US$7. The original US$3 projection, US$6 email warning, and six-hour schedule remain separate.

The server build and five focused budget checks passed. Development spending is enabled for the serving service and eval jobs. Commit `bb6cf2b9` deployed successfully in workflow `35018446689`, revision `maraithon-00364-4r2`. It will be turned off when active development ends.

## October reply routing and calendar selection

With development spending enabled, October sent its first email from the bound assistant mailbox. The recipient identity check passed, and the fixture sent the answer back. All three sent emails matched their frozen plain-text and HTML bodies, signatures, and display names. Two Muse calls cost US$0.000650.

The eval then stopped because it tried to find the reply using the ordinary user mailbox helper, which excludes assistant accounts. Commit `10b813e8` uses the existing bound-account read for that fixture lookup. The same commit corrects assistant scheduling to use the source calendar frozen in the grant instead of defaulting to the first connected account. The six focused model-admission cases passed, including the new source-calendar case. The server build passed. [Failed-run evidence](evidence/delegated-conversations/2026-09-15-october-reply-lookup.json).

Commit `dd0c50e8` also keeps a failed voice-profile refresh from being treated as learned style. New turns use explicit style instructions in that case. Five focused voice checks and the server build passed. Both corrections deployed successfully in workflow `35019664976`, revision `maraithon-00365-hq8`. The fixture lookup check passed. The next live run exposed the question-routing issue below.

## Asking the right person

The next assistant run made two calls, cost US$0.000512, and sent no assistant email. The model chose `needs_user` to ask Kent the operator for the project colour, even though the counterparty had offered to supply it. Review approved that unnecessary escalation. The prompt's blanket instruction to ask the user for missing facts conflicted with the delegated outcome.

Composition and review now share explicit routing instructions: use `send` to obtain the requested information from the granted counterparty; use `needs_user` for a decision, permission, preference, or authority gap that requires the operator. The review also checks the chosen recipient. Signature-composition instructions now appear only in the composition prompt. The server build and 13 focused policy checks passed. [Failed-run evidence](evidence/delegated-conversations/2026-09-15-october-question-routing.json).

## October information and scheduling passed

Commit `d7c71162` deployed successfully in workflow `35021093988`, revision `maraithon-00366-r29`. The controlled assistant run then passed both scenarios. October asked for the project colour, received indigo, cited the reply, and marked the task Done. Scheduling offered three times, received acceptance of the second, and created exactly one meeting on Kent's source calendar for September 21, 8:30 to 9:00 AM Toronto time. The recipient calendar copy was verified before the temporary event was cancelled.

Both flows used four Muse calls each. Information cost US$0.001125; scheduling cost US$0.002615; together they cost US$0.003740. Including the two failed attempts during this iteration, recorded model cost was US$0.004902. These are delegation eval charges, not total OpenRouter account spending. All six sent emails matched the frozen plain-text and HTML bodies, mailbox signatures, and display names. Assistant account isolation passed in both runs. [Live October evidence](evidence/delegated-conversations/2026-09-15-live-october.json).

The completed information task is visible on the authenticated web app as Completed, October, as your assistant. That check also found that the panel still said Sent a message instead of showing the learned answer. Commit `b89a789e` projects the verified completed outcome through the existing shared `last_action` field consumed by web, Mac, and iPhone. The server build passed; this presentation change adds no model or provider calls. Workflow `35022106548` deployed revision `maraithon-00367-9p7` successfully. The production web panel now displays the learned indigo answer beneath Completed and October, as your assistant.

## Shared Gmail admission and cooldowns

Gmail reads and writes now share one request slot per mailbox across sync, voice sampling, tools, reconciliation, and delegation. Each credential carries a stable mailbox key derived from the connected account, so rotating a token or using another connection to the same address does not open a second slot. Bare Gmail tokens are rejected at the connector and Google request boundary. Watch renewal and sync resolve the exact connected account.

The existing bounded HTTP worker owns a PostgreSQL transaction lock while the request runs. Another request for the same mailbox returns a retry delay; another mailbox can proceed. Google throttles are saved in the existing cooldown table before releasing the lock. The cooldown survives worker exit and honours numeric or HTTP-date `Retry-After`. Recognised Google `usageLimits` errors no longer ask the user to reconnect. This applies to Maraithon's requests; other mail clients still contribute to Google's shared limits.

Both full and incremental sync now hydrate messages sequentially through the same reader. A throttle preserves its retry deadline and prevents a successful sync result or cursor advance. This also removes the tools' duplicate body-fetch loop. The implementation adds no table or coordination process. Its tradeoff is one database connection held for each bounded in-flight Gmail request. It does not prove that Google cancels a remote operation after a connection or process is lost; the existing delivery reconciliation still owns uncertain writes.

The server build and 114 focused checks passed. They cover separate database sessions, mailbox isolation, caller death, durable cooldown, token rotation, all five HTTP verbs, cursor preservation, assistant account exclusion, long-thread source reads, and send reconciliation. The mock-server isolation check now observes the database from the request worker before HTTP because that worker owns the test's sandbox connection. No paid model calls or live emails were used in these local checks.

Google error normalisation shipped in commit `0f3f01f7`, workflow `35038983064`, revision `maraithon-00380-49b`. Shared admission commit `4a8a17f1` deployed through workflow `35040624836` to revision `maraithon-00381-gxc`, serving all traffic. Cloud Run execution `maraithon-todo-validation-6wkhz` verified Kent’s Runner mailbox and October. The personal Gmail probe returned a retry signal with no active persisted cooldown at the end of the check; its exact subtype was not recorded. Follow-up execution `maraithon-todo-validation-xgrl8` verified that mailbox on its first attempt. All three returned the expected address and stable admission key. Both jobs used the deployed image, made no model calls, sent no messages, and created no calendar events. The October memory eval remains pending for September 16 at 08:00 Eastern. [Gmail admission evidence](evidence/delegated-conversations/2026-09-15-gmail-admission.json).

## Shared Slack admission and safe local deferral

Slack API calls now share admission by workspace and method. User and bot tokens for the same workspace use the same limit. Message posts also share a one-second channel deadline. A throttle blocks that method across the workspace while unrelated methods and workspaces can continue, matching [Slack's documented rate-limit scope](https://docs.slack.dev/apis/web-api/rate-limits/).

This extends the existing Gmail admission helper and cooldown table. The bounded HTTP worker owns the transaction locks. A failed attempt to acquire both Slack lanes releases either lock already acquired. HTTP 429 and Slack's JSON `ratelimited` response preserve `Retry-After`; missing deadlines use 30 seconds. Bare Slack tokens cannot bypass the workspace binding. Sync, voice sampling, identity checks, tools, source reads and reconciliation all pass their resolved account identity. OAuth token exchange and revocation remain separate control-plane operations.

A send rejected locally before its provider request now waits safely. Under the current worker lease and action claim, the executor records `send_deferred` evidence and restores the action's unentered status in one transaction. The evidence keeps the action, turn, grant, payload hash and retry deadline. A later attempt rechecks the conversation; a changed reply supersedes the old send. A lost response, Slack partial failure or malformed receipt still requires reconciliation. This does not infer delivery from similar text or automatically replay an uncertain write.

Provider delays during source refresh, cited recall and sending also update the shared task summary. Web, Mac and iPhone receive the waiting explanation through the existing `last_action` field. No new native code, database table or coordination process is needed.

The server build and 157 focused checks passed. Coverage includes cross-token cooldowns, separate workspace and method lanes, channel pacing, lock release, Gmail and Slack deferral under real local leases, changed evidence before retry, uncertain sends, and existing Slack readers. Commit `2fdccf75` deployed successfully through workflow `35042395245`. Revision `maraithon-00382-v5b` is ready and serves all traffic. Muse Spark Contributor, the US$3 projection, development spending, and the controlled Gmail gate remain configured. No live Slack exchange is part of this change; Kent deferred that eval and autonomous Slack sends remain disabled. [Slack admission evidence](evidence/delegated-conversations/2026-09-15-slack-admission.json).

## Resumable Slack history

Active Slack conversations now checkpoint one page at a time in the existing encrypted Run. The page's ingress records and continuation commit under the same job lease. Another worker resumes the cursor after a restart or throttle. An expired cursor resumes from the last fetched timestamp, using Slack's timestamp bounds. The reader follows short and empty cursor pages, rejects repeated cursors and inconsistent thread evidence, and never marks an unfinished page sequence complete. [Slack pagination](https://docs.slack.dev/apis/web-api/pagination/), [thread reads](https://docs.slack.dev/reference/methods/conversations.replies/), [history reads](https://docs.slack.dev/reference/methods/conversations.history/).

The snapshot keeps six recent bodies, a fingerprint of the complete read, the message count, and the verified participant set. Older participants remain in scope even when their bodies leave recent context. Both threaded replies and unthreaded replies in a single live DM use this reader. Bounds are explicit: 100 messages per page, 10,000 included messages, 1,000 pages, and 240 KB for progress or a snapshot. Preview reads share the parser and have a 15-second admission deadline between bounded HTTP calls. They do not yet checkpoint before a grant exists.

Before sending, a separate durable page checkpoint repeats source verification. No action enters while pages remain. Edits outside the six recent bodies still invalidate the old turn. The complete snapshot fingerprint is independent of page boundaries; malformed or inconsistent reads remain gaps. Initial assistant DM reads now also record their original source evidence, so new replies found there advance the revision before a decision.

The server build and 110 focused checks passed. Local leased-worker fixtures cover a 180-message channel and a 300-message DM, an expired cursor, a provider throttle, resumption without duplicate ingress, compact snapshots, and an older edit before sending. Additional checks cover empty and short pages, retained participants, repeated cursors, foreign threads, duplicate pages, existing Slack sends, and shared Gmail source and send behaviour. A separate check confirms that a reply arriving after the grant interrupts the assistant’s initial source read before any action is prepared. No paid model calls or live messages were used. Commit `fb621856` deployed through successful workflow `35043381626`; revision `maraithon-00383-qs5` is ready and serves all traffic. Muse Spark Contributor, active development spending, the controlled Gmail gate, and disabled Slack sends remain configured. [Slack history evidence](evidence/delegated-conversations/2026-09-15-slack-history.json).

This is durable pagination, not the full read-economy requirement. A new turn still scans the bound history. Reusing verified history so subsequent turns fetch only missing messages, and durable progress for a long preflight before a grant exists, remain unfinished. Live Slack evaluation remains deferred.

## Process loss during a send

A local eval now kills a complete application BEAM after the mail provider accepts a message and before Maraithon records the response. A second BEAM starts against the same committed database with a new node incarnation. It uses the real coordination Session, PostgreSQL leases, task supervision, action executor, and delivery observer. The old task blocks its partition until an incident-role attestation records the observed OS exit. Expired leases alone do not release it.

The replacement rejects writes using the old job claim. It leaves the ambiguous send job failed and runs the observer already saved before the crash. That observer records `execution_unknown`, finds the exact accepted message through the local provider's history, and records one proven receipt. The grant survives unchanged. There is one provider send, one lifetime send, and no model call. Both stale-write attempts are rejected.

Run this explicit eval with `MIX_ENV=test mix run --no-start test/evals/delegation_beam_recovery.exs`. It creates and removes a fresh local database, migrates it through the existing role gates, and uses a loopback HTTP fixture with synthetic addresses and credentials. The eval and `make build` passed. Commits `15eec32f` and `b6e480fb` add only test files. This work requires no server or native deployment. [Recovery evidence](evidence/delegated-conversations/2026-09-15-beam-send-recovery.json).

This first check covered the sender and receipt path across an OS process death. The extension below adds coordinator checkpoint recovery. Killing a model decision before commit, schema upgrades across a long-lived conversation, disaster restore, and a real longevity canary remain unverified. Live Slack evaluation remains deferred.

## Coordinator checkpoint recovery

The coordinator's snapshot migration callback receives the stored version. It was copying that older version back into the restored state, leaving the version-1 wake handler unable to reduce work. It now stamps the current schema version. A focused check restores version 0 through `Runtime.Agent.restore_from_snapshot/4`, preserves the cursor, wake time and budget, removes transient data, and confirms the next wake reaches the reducer.

The BEAM recovery eval now starts the real coordinator Agent and saves its 49-byte checkpoint before the send. After the crash, an ephemeral test signer attests the observed OS exit for the exact old Agent lease. The existing incident-role API records that proof; runtime reconciliation consumes it. The job and Agent claims both remain fenced until their own proof requirements are met.

The new incarnation reconciles the accepted message before restoring the Agent. At that point, the only coordinator checkpoint still predates the receipt events. The restored Agent consumes those durable events, returns the conversation to `waiting_reply`, and preserves one lifetime send and one receipt. A fresh owner token replaces the old token. Both attempts to reuse the old Agent fence and both stale job writes are rejected.

The focused migration check, extended isolated eval, and `make build` passed. Commit `35963cfc` contains the one-line production fix and the eval extension. [Deployment 35052541910](https://github.com/argonavis-labs/maraithon/actions/runs/35052541910) succeeded; revision `maraithon-00384-688` is Ready and serves 100% of traffic. Muse remains selected, active-development spending is enabled, Gmail remains restricted to controlled evals, and autonomous Slack sends remain disabled. [Coordinator recovery evidence](evidence/delegated-conversations/2026-09-15-coordinator-recovery.json).

Cloud Run execution `maraithon-todo-validation-wvc2t` passed the same schema-0 restore check against the deployed image. It preserved the cursor, wake and budget, removed transient state, and reached the reducer with version 1. This pure module check made no database queries, model calls or provider calls. It does not establish overall runtime health.

Periodic product producers and automatic watcher recovery remain disabled in this fixture. The test advances proof reconciliation and Agent restart explicitly through production APIs. The legacy schema case exercises the runtime restore function directly; the BEAM crash case restores a current-version checkpoint older than the receipt. This does not yet prove automatic recovery with every producer running, a model decision killed before commit, two schema upgrades across 180 days, or disaster restore.

## Interrupted decision recovery

An interrupted decision could leave a conversation stuck on `deciding`. The runtime correctly retained the failed job and its ambiguous provider outcome after termination was proven, but the delegation sweep had no replacement path. Commit `05e76232` adds that path to the existing five-minute sweep.

Recovery admits a new decision job for the same turn only after the old task has an identity-matched termination proof and its outcome has been reconciled. The old job and task evidence stay intact. Current grant, source revision, workflow ownership and rollout gates are checked again. The existing active-job key prevents concurrent replacements, and a sweep handles at most 25 candidates per user.

A saved model response resumes from its checkpoint. An interrupted read-only model call can run again, with its earlier unknown charge retained under a separate entry. Model-call counters and cost reservations never reset. Each replacement receives a bounded execution deadline so a long outage doesn't consume all its time in the queue. Two automatic recoveries are allowed per turn; another failure creates a durable request for review. Send jobs are excluded and continue to use receipt reconciliation.

Five new local checks terminate the real supervised worker before the model call, during composition, after the composition response was saved, during policy review, and after the recovery limit has been reached. They use the runtime guardian's process-termination proof and normal task reconciliation. The checks verify stale-claim rejection, duplicate-sweep suppression, unchanged cost records, disabled-delegation gating, expired-deadline recovery and the final review hold. The focused suite passed 65 checks, and `make build` passed. No real messages or paid model calls were made.

[Deployment 35053762059](https://github.com/argonavis-labs/maraithon/actions/runs/35053762059) succeeded. Revision `maraithon-00385-zx2` is Ready and serves all traffic. Muse, active-development spending and the controlled Gmail gate are unchanged; autonomous Slack sends remain disabled. [Decision recovery evidence](evidence/delegated-conversations/2026-09-15-decision-recovery.json).

Read-only Cloud Run execution `maraithon-todo-validation-n4qwh` confirmed the recovery module in the deployed image. The regular sweep completed at `2026-09-16T04:02:56Z`, after the revision became Ready, and scheduled its next run five minutes later. It reported zero users and no holds or errors. This proves the scheduled sweep is running; it does not prove a recovery in production because there was no conversation to repair. The probe made no database writes, model calls or provider calls.

These first checks kill one worker under the live supervisor. The extension below covers a decision interrupted by loss of the entire BEAM. Automatic boot with every producer enabled, schema upgrades across 180 days, and database disaster restore remain unverified. Live Slack evaluation remains deferred.

## Decision recovery after BEAM loss

The isolated eval now destroys the application BEAM while the model's first response is in flight. The model-entry checkpoint, one call, and its unknown cost reservation are committed before `SIGKILL`. The next node leaves the old partition draining and rejects the old model response. It cannot replace the decision until an incident-role attestation records the observed OS exit for that exact task and runtime reconciliation consumes the proof.

The replacement then runs the production `RecurringJobs.execute/1` entry point with a global `delegation_due_sweep` job. The sweep admits one replacement for the same turn, creates and binds the coordinator, and schedules its next run five minutes later. Composition and policy review finish, and the real coordinator consumes the decision event and returns the conversation to `waiting_reply`. The original grant survives unchanged.

The fixture records three model calls: the lost response and two successful calls. It settles 200 micro-USD from the mock receipts and retains the original 105,268 micro-USD reservation for the lost response. Normal budget admission remains enabled. Both old-response writes are rejected, one decision event exists, and no send action is created.

Both isolated cases passed in 35.3 seconds. The existing send case still records one provider send and one receipt after restoring the older coordinator checkpoint. Each case creates and removes its own local database; the cleanup check found none left behind. Commit `3bd01e0f` changes only eval files, so it requires no server or native deployment. [Whole-BEAM decision recovery evidence](evidence/delegated-conversations/2026-09-16-whole-beam-decision-recovery.json).

These are loopback model and mail fixtures with no paid calls or real messages. Periodic producers and automatic watcher recovery remain disabled. The driver supplies destruction evidence and invokes the leased recurring job explicitly. Fully automatic boot, disaster restore, two schema upgrades across 180 days, and a real longevity canary still need coverage.

## Saved assistant mailbox history

Personal context now excludes saved observations belonging to a dedicated assistant mailbox, including observations ingested before the account was designated. One query filter covers People source pages and detail, legacy communication and affinity scores, CRM suggestions, queued relationship learning, task-completion evidence, and delegation proposals. It matches account IDs, providers, and normalized mailbox addresses within the same user. Alias mode keeps the user's mailbox available. Source records remain available to account-bound delegation evidence reads.

Designating an assistant account invalidates published and unfinished People generations in the same transaction and clears their legacy CRM scores. Reconnection and signature edits preserve a clean generation. People detail also removes the whole excluded history entry, including its cached title. Upcoming People calendar reads no longer enumerate the assistant account. Old records with no attributable mailbox identity cannot be classified by this filter.

The server build passed. The focused local checks covered 19 assistant-isolation cases and 24 CRM ingestion, insight, and task-completion regressions. An older ingestion fixture expected a queued job while coordination was disabled; it now explicitly enables coordination before exercising that path. Its two checks passed on rerun. The default test database had a pre-existing migration catalog mismatch, so these checks ran against fresh disposable local databases. No live message or paid model call was made by these checks. Native code was unchanged.

Commit `c5fa81d3` deployed through workflow `35055281619`. Revision `maraithon-00386-znv` is ready and serves all traffic. The production query found one dedicated assistant account and 18,776 observations, with none attributable to that mailbox, so it made no cache change and enqueued no rebuild. Muse Spark Contributor, the Gmail eval restriction, disabled Slack sends, and active development spending remain configured. The existing live memory eval is still pending for September 16 at 8:00 a.m. Toronto. [Isolation evidence](evidence/delegated-conversations/2026-09-16-assistant-history-isolation.json).

The selected-job status report now includes the fixture's prepared actions even when no delegation was created. It returns only action IDs, states, timestamps and the saved failure class, code and HTTP status, never payload bodies. A still-confirmed action's retryable error also reaches the existing eval wait handler; failed actions remain terminal. The build passed.

## Relationship learning source provenance

The shared relationship-learning boundary now captures input references before the model call and rechecks them before saving. Persisted CRM observations carry their record IDs; the server resolves them within the same user and reads account identity from the stored observation. Scanner inputs without a stored observation are labelled as inputs, with an account ID only when exactly one owned Google account matches. Dedicated assistant sources and missing or foreign observation IDs reject the batch.

The save and assistant-account recheck share the user write lock used when designating an assistant. A designation committed during a model call therefore prevents its pending learning from being saved. The existing advisor effect passes its pending source batch into the same boundary. Memory metadata and the latest People learning metadata retain the server-generated references. No email bodies or addresses are copied into this provenance map, and model-provided provenance cannot replace it.

Inspection also found that CRM observations lacked the three keys used for deduplication, so distinct records collapsed into one input. Normalization now removes exact duplicates and preserves up to the existing 16-observation limit. `make build` passed with warnings treated as errors. No automated tests or new live model calls ran for this change.

Commit `e2ca0be2` deployed through successful workflow `35124043521` to revision `maraithon-00426-vcx`, serving all traffic.

The central memory recall path and delegated People context now omit records whose saved provenance names a currently dedicated assistant account. The filter uses the authenticated user's account IDs and runs before records enter a model prompt. It keeps the existing candidate bounds and People ambiguity check. Stored records remain available for review; none are deleted. The server build passed. The regular memory-list path now applies the same exclusion, covering model tools, todo and briefing context, and voice context. The authenticated Memories management page explicitly includes these records for inspection. The shared People prompt summary also applies the filter, including relationship-learning context, morning briefs, goals and commitment tracking. These follow-ups passed the server build.

This is input provenance, not proof of each generated claim. It does not reconstruct older learning, preserve a complete history for every merged People field, or exclude every previously learned field after a later assistant designation. Those remain part of the isolation audit. Unknown input account identity stays unknown; no old records were deleted or rewritten.

These memory and People filters, plus the fixture action diagnostic, deployed through successful workflow `35126348398` to revision `maraithon-00428-m7b`, serving all traffic.

## Initial fixture send recovery

Read-only workflow `35126829237` inspected job `42b77f9f-f81b-46f3-be90-9e38ffa78424`. Its initial Gmail action is terminally failed with class `transient` and code `unknown_error`. No HTTP status or local-admission subtype was retained. This does not establish delivery or prove local contention caused the failure. The job and action remain unchanged; no replacement conversation was launched. [Saved action evidence](evidence/delegated-conversations/2026-09-16-requested-scheduling-reviewed.json).

Code inspection found that a closed local admission rejection preserved delegated sends for retry but failed human-confirmed fixture sends. Both now keep the same confirmed action, frozen payload and message identity when Gmail or Slack admission proves that the request did not enter the provider. The caller retains its existing retry schedule and deadline. Provider errors and ambiguous delivery still follow their existing failure or reconciliation paths. Saved provider error codes now unwrap the structured provider envelope, so future failures retain the inner code without logging response bodies.

`make build` passed with warnings treated as errors. Automated tests were not run under the current development policy. This change does not recover the missing cause of the old failure or prove that the live scheduling scenario passes.

Commit `c9e70be7` deployed through successful workflow `35127688133` to revision `maraithon-00429-p7q`, serving all traffic. A separate labelled `requested_scheduling` attempt passed preflight through launcher `35128182399`, creating job `af4c9031-8d0d-4847-908d-b66347fb5ee9` at `2026-09-16T17:29:58.141605Z`. The old terminal attempt was not reopened or resent.

Read-only workflow `35128792245` confirmed this new attempt passed. October offered three afternoon slots in the requested next-week window and booked the accepted 45-minute slot on September 21, noon to 12:45 p.m. Toronto. The verifier confirmed the recipient's calendar copy and invitation description before cancelling the test event. The todo moved to Waiting. Both decisions passed independent review: three settled Muse Spark Contributor calls for research and two for booking, US$0.002583 total, with no unresolved reservations. This proves the controlled requested-scheduling path, not the cause or delivery outcome of earlier terminal attempts. [Passing scheduling evidence](evidence/delegated-conversations/2026-09-16-requested-scheduling-passed.json).

## Local calendar source state

The companion now captures EventKit calendar and source identifiers, a source label, the opaque external event identifier, cancellation status, availability and the current user's response. The server accepts a bounded, versioned `source_state` object on the existing HTTP and realtime ingestion paths and retains it on each upsert. Legacy or unavailable state stays unknown. The migration refreshes only the reviewed calendar-table fingerprints and checks all protocol proofs before and after the change.

`make build` and the companion's `swift build` passed. No automated tests ran. This is the source-state prerequisite for local availability, not a completed mirror. Unchanged events are not forced through a full resync. Account binding, complete-window receipts and deletion reconciliation still need implementation before scheduling can prefer the mirror. The SDK documents the external event identifier as opaque, so it is not labelled or used as an iCal UID. [Calendar payload contract](companion/CALENDAR_API.md).

The signed Xcode companion build also passed and has the same designated signing requirement as the installed app. Deployment `35129411239` failed in migration execution `maraithon-migrate-tfjpw` before rolling out the server; the Mac bundle was not installed. Read-only diagnostic `35130586122` reported `Calendar source state privacy catalog entry is missing`. The migration had incorrectly copied a two-manifest refresh from the account-category change. Calendar events belong to the durable-payload catalog only. The corrected migration updates that table's durable fingerprint and verifies that privacy and coordination proofs remain valid, without changing their manifests. Its build passed. Local gcloud auth was unavailable; the diagnostic used the existing main-branch-only keyless connection. Commit `f77b2c36` added that read-only operator path with automatic deployment skipped until this migration fix was ready.

Commit `99433d52` deployed successfully through workflow `35130917709` to revision `maraithon-00430-9mm`, serving all traffic. The signed companion bundle was installed in place after the server rollout and opened in the background. Its designated signing requirement is unchanged.

## Complete local availability and account matching

The server now stores one bounded replacement availability window per paired
Mac, separate from calendar history. Ingestion validates the complete calendar
inventory and every event, rechecks the device token and revocation under its
row lock, and applies the user erasure fence. Identical retries do not refresh
capture time; older captures reject. Re-pairing, revocation and calendar purges
clear the cache. Normal device queries do not load it. The privacy-only
manifest migration checks all protocol proofs before and after its change.
Commit `34c2cb7e` deployed through successful workflow `35132238452`.

The companion sends a full upcoming window on its existing sync cycle, including
unchanged events and empty calendars. Replacement handles local deletions.
Settings on Web, Mac and iPhone let the user explicitly match owned Google
accounts to primary calendars on the same paired Mac. Dedicated assistant
accounts are excluded. No names are used to infer ownership, and no selections
are applied automatically.

Scheduling prefers the mirror only for a complete requested window captured
within five minutes. Missing bindings, stale data, revocation and known calendar
writes fall back to Google. Coverage records the source and capture receipt.
Booking still checks Google immediately before the write. EventKit occurrence
identifiers are namespaced separately from Google iCal UIDs for meeting counts.
Local capture freshness does not establish the remote CalDAV sync time.

The server, companion Swift build, signed Mac build and iPhone simulator build
passed. XcodeGen regenerated the native projects; generated project files stay
untracked. Tests were not run under the current policy. Commit `3f32f749` deployed through successful workflow `35133254724` to revision
`maraithon-00432-d7v`. The signed Mac bundle was installed in place. Mobile
workflow `35133254684` published TestFlight 1.0.1 (`20260916181547`), with Kent
verified in the Founders group. Web and Mac Settings both show October bound
to Kent's user. The new web calendar selectors remain on Google directly.

The first Mac availability upload was rejected with HTTP 422. Its diagnostic
counts showed 17 calendars, 302 events, no empty calendar identity fields, no
zero or negative durations, and a three-second capture age. Commit `69fa6765`
deployed through successful workflow `35133975561` to revision
`maraithon-00433-wf4`. Its bounded error codes identified invalid all-day dates:
48 occurrences had non-increasing date strings. No event content was logged.

The companion now interprets EventKit's floating dates in the Mac's default
timezone and normalizes an end time within a day to the next day's exclusive
boundary. Midnight stays exclusive. The Swift and signed Mac builds passed,
and the bundle was installed in place with its signing requirement preserved.
At 18:35 UTC, reloading live Web Settings showed all 17 Mac calendars in the
selectors, confirming that the replacement snapshot was accepted. The account
selectors remain on Google directly. No binding or new live conversation was
created, so this proves ingestion and inventory presentation, not live use of
the mirror for a scheduling proposal. No automated tests ran.

## People source-account retention

The isolation audit found that later People learning could replace input
provenance while retaining older fields. People updates and merges now retain
the union of known source account IDs. Personal prompt filtering checks that
history against the user's current and previous assistant accounts. Updates
reload the person under the existing user write fence, and merges take that
same fence before reading either person. This prevents concurrent updates from
silently dropping the account history.

The history holds up to 64 account IDs. Overflow is persistent and excludes the
record from personal prompts while the user has an assistant account, rather
than treating a truncated history as complete. This stores account attribution,
not message contents or proof of individual claims. Older unattributed learning
stays unknown; no historical person or memory was removed or rewritten.

`make build` passed with warnings treated as errors. Automated tests were not
run under the current development policy. Commit `d71b65df` deployed through
successful workflow `35135789338` to revision `maraithon-00434-4z7`.

The same review found four background writers that replaced the entire People
metadata map after enrichment or scoring. They now use one small atomic helper
to patch only their own key and metric. New learning and its source history
therefore survive a slow enrichment, graph update, communication-score update
or merge suggestion. The helper is scoped to the person's user and preserves
the existing database write fences. It adds no model call or process. Its
`make build` check passed; no automated tests ran.

Commit `fe23a0f9` deployed through successful workflow `35136330889` to revision
`maraithon-00435-mwd`, serving all traffic. A fresh live Settings read confirmed
October's selected account, name and assistant-account mode. This verifies the
deployed settings read path, not the full concurrency or historical-attribution
matrix. The six-hour conversation canary remains in its scheduled quiet period.

## Live proposal entry fixture

The controlled Gmail fixture now has a `proposed_information_reply` scenario.
It sends the labelled test email through the existing Kent pair, ingests the
actual recipient copy through Gmail's normal observation path, and binds the
todo to its resolved counterparty. It then waits for the real Chief of Staff
proposal. The fixture does not rank a candidate, create a suggestion or call
`delegate` itself.

Once the proposal is observed, acceptance must create a delegation with the
same actor and kind before the existing reply and completion checks continue.
The job records candidate readiness, the proposal and its observation and
acceptance times. Provider sends still use the controlled-pair gate and existing
action identities. The scenario requires assistant mode. `make build` and shell
syntax validation passed; no automated tests ran. Live verification is pending.

Commit `4d46b58d` deployed through workflow `35137464447` to revision
`maraithon-00436-lrn`. Launcher `35137918032` created job
`fade27a9-e362-484b-b160-f26bf8507dab`. Read-only status `35138589359`
reported a terminal `background_job_error` after the initial email action had
executed. No delegation was recorded.

Code inspection found that fixture preparation persisted `Workflow.current/1`,
a display projection lacking the required reason and change time. A manual,
provider-free calculation reproduced that invalid changeset. Preparation now
uses the existing workflow transition function; the same calculation produces
a valid changeset. The original failure retained no exception detail, so this
does not establish that it was the only failure.

Restricted recovery now also admits this proposal fixture's initial failure
only while its workflow is empty, its runtime assignments are settled, its
claim is clear, no delegation exists and its original deadline remains open.
It preserves the original job, subject, account binding and prepared-action
identities. It does not restart a live job or extend the deadline. `make build`
passed with warnings treated as errors. Automated tests were not run.

The Mac check also exposed a fallback card that called a next-step instruction
a Gmail draft and always said to reconnect. Commit `155abddf` excludes known
placeholder drafts from all provider fallback cards and labels a genuine Gmail
fallback as a suggested reply for review. It adds no model or provider call.
The server build passed; deployed UI verification is pending.

Commit `9c17e172` deployed through successful workflow `35139481014` to
revision `maraithon-00437-rdw`, serving all traffic. The installed Mac app then
showed the controlled todo with its chat composer and no placeholder draft card
or false reconnect warning. Native binaries did not change. Recovery workflow
`35139998036` successfully recovered the original eval job, scheduled at
`2026-09-16T19:23:51.433062Z`. The refreshed Mac task now shows its saved outcome
and a plain Delegate button. A Chief of Staff proposal has not appeared yet.
[Proposal entry observations](evidence/delegated-conversations/2026-09-16-proposal-entry.json).

Read-only status `35140500627` then confirmed `waiting_for_proposal` with
`proposal_candidate_ready: true`, no current error and a future scheduled wake.
The only recorded action is the same executed initial email. Proposal generation
and acceptance remain unverified.

Status workflow `35143224581` again found the original job waiting for a
proposal at `19:58:21Z`, with its single initial action unchanged. The first
checkpoint diagnostic returned no agents because it only selected direct
Chief of Staff installations. The lookup now includes packaged installations
and unwraps their source state. That empty result does not prove absence.
The live Activity page showed running Chief of Staff work, failed scheduled
model steps and repeated failed Gmail discovery and completion jobs. The saved
generic errors do not establish their cause.

Background and source workers now preserve a bounded exception type and first
application code location. Exception messages, arguments and provider bodies
are excluded. The controlled proposal status includes at most eight recent
source-worker failures for its user. A provider-free calculation retained the
exception type and location without its private marker. `make build` passed;
no automated tests ran. Deployment and diagnosis of a fresh failure are pending.

Diagnostic deployment `35144444078` succeeded on revision `maraithon-00441-zt8`.
Status `35144918697` confirmed the original fixture had completed cleanup with
phase `failed` and reason `eval_stopped`, without a proposal or acceptance. Its
deadline was not extended and the job was not restarted. Recent source errors
were `source_discovery_acquisition_incomplete`, followed by dependent completion
failures. Those are incomplete acquisitions, not exception reports. Acquisition
errors now retain bounded status and count summaries, excluding mailbox names
and message content. The checkpoint diagnostic also separates missing or
undecodable snapshots from readable state and includes recent closed effect
failure codes. Deployment of this additional diagnosis is pending.

Inspection also found that candidates were fetched only when the cycle already
needed a memo. A new eligible todo on an otherwise quiet day could wait until
the daily memo refresh. Scheduled wakes now check candidates and allow their
existing memo call to rank a changed set. A saved digest excludes bookkeeping
fingerprints, so completion polling alone cannot create more model work. A
valid result records that set only after all selected proposals persist; an
empty selection is also a completed review. Failed or malformed attempts wait
at least the configured wake interval before triggering another quiet-cycle
call. The review digest and attempt time survive checkpoints. `make build`
passed; live proposal verification remains open.

The cadence change deployed through `35146212539` to revision
`maraithon-00443-22z`. A manual digest calculation confirmed that a polling-only
fingerprint change is ignored and a changed next action is detected.

Live Activity also exposed a remaining assistant-account queueing gap. The
completion scheduler enumerated all connected accounts and its common source
wakeup could enqueue discovery for October, despite the discovery acquisition
guard. Both scheduling paths now exclude each user's designated assistant.
Completion acquisition also checks the designation before consuming live or
saved source bundles, covering already queued work. No address is hard-coded.
`make build` passed before deployment.

The queueing fix deployed through `35147106544` to revision
`maraithon-00444-btg`, serving all traffic. At `20:39Z`, live Activity showed new
personal Gmail discovery and completion jobs; the most recent October entries
were from `20:31Z` and `20:32Z`, before deployment. This is a short observation
window, not a claim about historical learning cleanup.

Status `35146657621` identified a Gmail `rate_limited` acquisition and another
batch where 19 of 20 thread reads failed after all 21 message reads succeeded.
The batch was not truncated. Inspection found concurrent thread hydration
competing with the mailbox's single-request admission lane. Thread hydration
now runs sequentially within each mailbox, matching message hydration. The
outer stream still reads different accounts concurrently, and the existing
timeouts and complete-acquisition requirement remain in force. `make build`
passed; a successful production acquisition still needs verification.

Thread-read serialization deployed through `35147678598` to revision
`maraithon-00445-w88`, serving all traffic. No automated tests ran under the
manual-first policy.

Live Activity at `20:43Z` showed successful Gmail acquisition jobs
`3a5e4eff-4cdf-456e-8fc2-332581eadee6` for personal Gmail and
`99f75462-ae79-489a-9dc6-cd9810dca12c` for Agora, followed by their model fan-outs.
The acquisitions took 43 and 26 seconds. This verifies fresh provider
acquisition for those accounts, not full runtime health or completed downstream
todo decisions.

The same status found an idle Chief of Staff checkpoint at sequence 26018, but
the separate diagnostic process could not decode an unknown snapshot symbol.
This does not establish that the serving Agent cannot restore it. Recent
scheduled model steps reported `invalid_request`; the saved closed error does
not identify the request validation cause.

## Read earlier conversation windows

The date-window history reader is now implemented. A model may use its existing
single research step to request up to 31 days of earlier conversation evidence.
The reader examines at most 49 event rows, selects at most six distinct messages,
and verifies their provider content under the original or current granted
account and thread. Slack selections retain their recorded revision digest.
The response reports truncation; empty results cannot establish silence or
completion. It accepts no model-supplied account or destination.

The result and coverage are saved in the existing encrypted run snapshot. A
retry reuses the saved read. Composition and independent review keep the
three-call ceiling; no new process, model stage or queue was added. The
read-only memory probe now also clears the fact ledger in memory and checks
that the delivered answer can be recovered through this history path.
`make build` passed, and a provider-free request check accepted a bounded window
while rejecting an oversized window, an account override and a fact write.
Automated tests were not run under the manual-first policy.

Commit `1d9bd2ab` deployed through successful workflow `35141593439` to revision
`maraithon-00438-rfs`, serving all traffic. Read-only workflow `35142254118`
passed against October's completed information conversation. With the prompt
cache and fact ledger cleared in memory, the reader recovered the delivered
counterparty answer through the synchronized event history and verified Gmail
content. It made zero model calls, sent no messages, created no calendar events
and changed no conversation records. This does not prove a later model choosing
the read, Slack retrieval or months of retention.
[Live history-read evidence](evidence/delegated-conversations/2026-09-16-uncited-history-recall.json).

The compatibility follow-up in `16fd7d9c` excludes only the six messages visible
to the model from history selection, so older snapshots with larger caches
remain readable. The build passed. Proposal diagnostics now report a bounded
Chief of Staff checkpoint summary without memo text or source content, to help
explain why an eligible task has not received a proposal. That build also passed;
both follow-ups deployed through successful workflow `35142795714` to revision
`maraithon-00439-7vv`, serving all traffic.

## Bound Gmail sources in task briefs

The Mac proposal fixture showed a source-verification warning even though its
candidate had a saved Gmail account and observation. Inspection found that the
brief reader ignored `source_account_id`, relying on labels and draft metadata
or searching all personal inboxes. It now resolves the owned connected account
and uses the same account-bound access for the message and thread. A missing,
disconnected or assistant account cannot fall back to another mailbox. Legacy
tasks without a binding keep their existing lookup path.

`make build` passed with warnings treated as errors. This removes unnecessary
cross-mailbox reads; the fixture's original provider error was not retained, so
it does not establish the sole cause of that warning. Commit `1e68ecdf`
deployed through successful workflow `35143818000` to revision
`maraithon-00440-ml5`, serving all traffic. The Web task's Refresh context action
then completed with the actual email request, its sender and a useful next
action. The source-verification warning disappeared. This verifies the bound
read on that controlled task; it does not establish background discovery health.
No automated tests ran under the current policy.

## Scheduled planning rejection

The 20:52 UTC scheduled Chief of Staff run failed after the Gmail acquisition
fix had deployed. A read-only diagnostic now reports saved request size and
counts without prompt or email content. `make build` passed; commit `cbe16591`
deployed through successful workflow `35149443027`. No automated tests ran.

Read-only workflow `35149897205` found three recent `invalid_request` steps,
including one at 21:01 UTC. Each retained an empty request placeholder. The
runtime clears rejected parameters before recording a local validation failure,
so validating that placeholder cannot identify the rejected constraint. This
narrows the failure to local request admission before OpenRouter, but does not
prove a size-limit cause. The original proposal eval remains failed at its
original deadline. This inspection made no provider or model calls, sent no
messages and changed no conversation records.

## Proposal review and source-failure follow-up

At 9:49 p.m. Toronto on September 16, live Activity still showed repeated
20-batch Runner Gmail discovery cycles with failed AI reviews. Several later
scheduled Chief of Staff runs had completed. This does not establish source
pipeline recovery or a working suggestion.

The pending suggestion fix now tracks the previous saved proposal in the
review digest. When the task's next completion review expires that proposal,
the scheduled planner can rank it again. An unchanged candidate that the model
declined stays quiet through completion polling. The existing wake interval
still bounds retries, and neither fingerprint is included in the model prompt.

Read-only status workflow `35155546296` exposed two diagnostic gaps: it returned
only acquisition failures, and checkpoint decoding failed with
`unknown_snapshot_symbol`. The diagnostic now loads the known Chief of Staff
and skill modules before resolving existing snapshot symbols. It includes up
to two failures from each source-worker stage, at most 16 total, so failed
processing and finalisation are visible alongside their dependent errors.
No source content or request body is added to the report. Request-budget error
reporting also tolerates malformed message lists without raising a second error.

`make build` passed with warnings treated as errors. Automated tests were not
run under the manual-first policy. Commit `cfdaf991` deployed through successful
workflow `35172180735` to revision `maraithon-00448-kvq`, serving all traffic.
The normal deployment health check passed. Read-only workflow `35172503572`
failed while encoding its report. Diagnostic workflow `35172764644` identified
`Jason.EncodeError` at the report boundary. A provider-free query-plan inspection
found that selecting a map from the ranked subquery lost Ecto's UUID loading:
job IDs reached the report as raw bytes. Explicit UUID and timestamp types now
preserve JSON-compatible values. This failure affected the inspection job, not
the serving application. Live proposal generation and acceptance remain open.

## Remaining work

1. Extend live coverage beyond the controlled Gmail pair and finish the assistant-account audit for previously learned memories and person facts. October's information and regular scheduling evals pass; the busy-slot recovery eval has passed as Kent. New relationship learning now captures input provenance, rechecks assistant designation before saving, and filters known assistant-derived records from personal prompts. That does not establish source attribution for older learning or every merged People field. No historical records were removed or rewritten during this inspection.
2. Finish the remaining Slack product paths. Local ingress, sending, authorship, DM and reconciliation checks pass. Kent deferred the controlled live Slack eval; autonomous Slack sends remain disabled.
3. Verify proposal acceptance on a real controlled task and inspect its native presentation. Proposal generation, projection and brief integration are deployed with local coverage. The recovered controlled task passed the production candidate gate but reached its original deadline without a proposal. Diagnosis of incomplete Gmail acquisition and failed scheduled Chief of Staff work is in progress.
4. Finish the rest of whole-app recovery and race checks, schema evolution, and longer longevity coverage. The original six-hour Gmail canary passed across releases with stable quiet state, older-fact recall and independent review. Send recovery, older coordinator checkpoints, and interrupted model decisions have local whole-BEAM evidence. Automatic recovery with every producer running, disaster restore and the remaining crash matrix still need coverage. Shared Gmail and Slack request admission are deployed with focused coverage. Gmail also has read-only production checks; live Slack evaluation remains deferred.
5. Verify the revised call budget across the remaining paths and reduce redundant calls and daily workload volume. The information eval's two calls per turn meet the revised ordinary-turn target; live research turns have three settled calls with independent review; repair still needs verification against that ceiling. The measured day had 1,542 attempts, above the earlier 300 to 500 target.
6. Manually verify the account-matching consumer with explicit user-selected calendars. Deployment, complete availability ingestion and live inventory presentation are verified. The replacement window includes unchanged events and reconciles local deletions; explicit bindings and a five-minute limit control use in slot proposals. Final booking always checks Google. Live coverage must establish the selected window and fallback behavior; a local capture timestamp does not prove remote CalDAV freshness.

The pilot voice sampler has local and small live Gmail evidence. Incremental learning and profile promotion remain a separate spec. Slack can now retain a scan superseded by its own newly discovered messages; general incremental history reuse remains unfinished. The redacted operational trace is deployed, with live recovery checks outstanding. The user-facing conversation history is deployed; its live verification limits are recorded above. Durable preflight is deployed with live Gmail preview evidence; long Slack reads and worker-loss recovery still need verification. The requested next-week window, 45-minute duration and afternoon ranking now have passing live scheduling evidence. Saved meeting links reach offers and invitations, but a nonempty configured link still needs live verification. The scheduled October information conversation and its fresh provider recall probe passed. The six-hour canary subsequently verified a later reviewed model turn using an older fact; its report also confirms one People context entry, without proving broader relationship inference. The original task email can now supply evidence for reviewed facts; bounded date-window selection of synchronized historical messages now has live Gmail read evidence; a model using that path and Slack recall remain unverified. Gmail evidence fingerprints already ignore read, inbox, star, and custom labels, retaining only sent and draft classification. Gmail thread continuity has local coverage and a deployed compatibility check; an actual provider split still needs live evidence.

The live gate remains restricted to the labelled Kent-pair eval. The code and evidence do not justify enabling general autonomous outreach yet.
