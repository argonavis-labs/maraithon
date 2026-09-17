# Maraithon development checklist

Updated September 17, 2026. This is the short working list. The
[status report](delegated-conversation-status.md) holds the detailed evidence
and limits; the [execution plan](delegated-conversation-execution-plan.md)
defines the intended behaviour.

The September 17 Runner recovery, generated-suggestion acceptance and calendar
fallback checks are complete. The next work is listed below.

## Next

- [ ] Identify and bound the separate oversized Chief of Staff skill request.
  Recent production steps reject roughly 296 KB of message content against the
  128 KB request budget. Proposal reviews continue afterward; the affected skill
  and its product outcome still need diagnosis.
- [ ] Measure current daily OpenRouter spend and call volume after the remaining
  retry fixes. Separate normal operation from development evals, and compare
  with the original audit. Do not treat the small per-conversation cost as proof
  of the whole application's daily cost.
- [ ] Finish live checks of the revised call budget: two calls for an ordinary
  delegated turn and at most three for research or repair, preserving independent
  review. Ordinary and research turns have passed; repair remains open.
- [ ] Verify the latest iPhone build on a physical device: task chat, ownership
  changes, standalone Chat, People, past-event styling, account filters and
  Assistant settings. Shared API, web and Mac checks have passed in the cases
  recorded in the status report; these do not replace an iPhone check.
- [ ] Check task-chat responsiveness during deployment and reconnects. Controlled
  requests now reuse duplicate message IDs and have a separate worker queue, but
  deployment handoff latency is not fully resolved.
- [ ] Complete the assistant-account audit for older memories and merged People
  fields. New source selection and learning exclude the user's assistant;
  older records do not all have enough provenance to establish that separation.
- [ ] Finish remaining Gmail conversation coverage: verified provider thread
  splits, a model choosing older date-window evidence, and invitations using a
  nonempty saved meeting link.
- [ ] Finish general incremental Slack history reuse. Keep live Slack evaluation
  and autonomous sending deferred as requested.
- [ ] Finish longer conversation and recovery coverage, including restart races,
  schema changes and restore. The six-hour check across deployments passed;
  months-long operation and the full crash matrix remain unverified. Broad
  automated hardening follows the current development-mode policy.
- [ ] Complete the controlled Gmail pilot before expanding the live send gate
  beyond the labelled Kent-pair eval.
- [ ] Commit and deploy finished changes as they land. Restore the normal US$7
  spending pause when active development ends.

## Completed, with recorded evidence

- [x] Accept a generated “Delegate to October?” suggestion through the actual
  task UI and complete the resulting controlled conversation. The explicit
  handoff case passed: one assistant message, one reply, a Done todo and a
  saved fact citing that reply. Four settled Muse calls cost US$0.001355, with
  two calls per ordinary turn and independent review. Earlier ambiguous cases
  were declined; this does not establish suggestion quality for every task.
- [x] Recover Runner Gmail discovery after contention and incomplete-evidence
  failures. At `14:49:23Z`, the fixed serving revision completed all 23 batches,
  recorded 144 decisions for 144 source items and advanced its watermark.
  A subsequent incremental scan started with three new items. The exact coverage
  requirement and current-message size guard remain enforced.
- [x] Verify scheduling uses all three approved Mac calendars when fresh and
  falls back to all three Google accounts when stale. The missing conflict-account
  selections were saved in Settings. The actual consumer returned complete
  three-account coverage from the companion at `14:23Z` and Google at `14:33Z`
  after the snapshot expired. No messages or calendar events were created.

- [x] Add a per-user Assistant section and connected-email selector. October is
  assigned to Kent's user only and excluded from personal-source scheduling.
- [x] Save the three approved Mac calendar matches: Kent Fenwick under
  kent.fenwick@gmail.com, kent@runner.now under Runner, and kent@voteagora.com
  under Agora. The live Settings page confirmed all three saved selections.
- [x] Pass controlled Gmail information and scheduling exchanges as both Kent
  and October, plus busy-slot recovery as Kent.
- [x] Preserve mailbox signatures and formatting in the controlled exchanges.
- [x] Pass the original six-hour conversation check across releases, with older
  fact recall and independent review. Its 11 settled Muse calls cost US$0.005449.
- [x] Deploy durable conversation state, send records, restart recovery and
  bounded OTP workers. Broader recovery verification remains listed above.
- [x] Deploy direct task chat and remove “Prepare this for me.” Verify controlled
  calendar creation/removal and Mohit's ownership correction.
- [x] Keep task conversations out of standalone Chat, resolve verified Slack
  names, deploy the People query fix and mute completed calendar events.
- [x] Deploy Tracking ownership and Personal / Work / All account filtering.
- [x] Use Muse Spark Contributor and retain independent decision review with the
  revised call targets.
- [x] Deploy the US$3/day projection, US$6 email warning to
  kent.fenwick@gmail.com and six-hour checks. Verify delivery of a warning.
  The normal US$7 pause has an explicit active-development override.

Live Slack sends remain off. Incremental voice learning and profile promotion
remain a separate spec. The checklist does not mark either as complete.
