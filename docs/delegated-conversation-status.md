# Delegated conversation implementation status

Updated September 15, 2026. Controlled Gmail information and scheduling evals now pass as both Kent and October. The Kent-pair busy-slot recovery eval also passes. Mailbox signatures, assistant isolation, brief reporting, work/personal categories, and the cost warning are deployed. The full [execution plan](delegated-conversation-execution-plan.md) is not complete.

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

## Authored voice samples

Gmail and Slack now share a voice-sample cleaner. Gmail requires Sent mail from the bound mailbox's primary or verified send-as addresses; assistant accounts and the configured assistant alias are excluded. Slack verifies the token's live member and workspace, then checks those fields on every search result. Search terms and caller-supplied sample text cannot substitute for sender evidence.

The cleaner removes recognised reply quotes, wrapped reply headers, configured signatures, mobile footers and confidentiality notices. It excludes forwarded and automated messages, missing authors or dates, and known Maraithon sends. HTML-only mail is rendered without link-attribute annotations. Profiles record removal and exclusion counts. Generated-send history is a bounded, authenticated read of prepared actions. More than 128 candidate actions or a purged action holds the refresh instead of silently dropping provenance.

Older profiles without the cleaning version, failed refreshes, and successful JSON responses without actual guidance use explicit style instructions. Assistant turns retain their house style. This adds no provider or model calls to a delegated turn; collection runs only on voice refresh. Recognition of signature and quote formats is deterministic, not a claim that every possible mail-client format is covered.

The server build and 23 focused local checks passed. They cover both providers' authorship, quoted and generated evidence, signatures, account isolation, draft and turn selection, history overflow, and a real prepared-action retention purge under the exact runtime. No live messages or paid model calls were made for these checks.

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

## Remaining work

1. Extend live coverage beyond the controlled Gmail pair and finish the remaining assistant-account read audit. October's information and regular scheduling evals pass; the busy-slot recovery eval has passed as Kent.
2. Verify the cleaned voice sampler against live mailbox evidence. The pilot's authored-sample checks pass locally; incremental learning and profile promotion remain a separate spec.
3. Finish the remaining Slack product paths. Local ingress, sending, authorship, DM and reconciliation checks pass. Kent deferred the controlled live Slack eval; autonomous Slack sends remain disabled.
4. Add delegation proposals. Brief reporting is deployed and verified against production records.
5. Finish mailbox-wide quota coordination, the whole-app recovery and race checks, schema evolution, and a real longevity canary.
6. Reduce model calls per turn and daily workload volume. The information eval used two calls per turn, above the plan's target below 1.3. The measured day had 1,542 attempts, above the earlier 300 to 500 target.

The live gate remains restricted to the labelled Kent-pair eval. The code and evidence do not justify enabling general autonomous outreach yet.
