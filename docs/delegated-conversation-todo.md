# Maraithon development checklist

Updated September 16, 2026. This is the short working list. The
[status report](delegated-conversation-status.md) holds the detailed evidence
and limits; the [execution plan](delegated-conversation-execution-plan.md)
defines the intended behaviour.

## Doing now

- [ ] Make delegation suggestions appear reliably and verify accepting one
  through the actual task UI. The first controlled run expired without a
  suggestion. A local fix lets scheduled planning reconsider an expired
  suggestion after the task's next review without reranking unchanged rejected
  candidates on every completion poll. The fix is deployed; live proposal
  generation and acceptance remain open.
- [ ] Resolve Runner Gmail's repeated processing and finalisation failures.
  Sequential thread reads have restored successful acquisition on two other
  accounts, but the Runner pipeline is still unfinished. Live Activity at
  9:49 p.m. Toronto still showed repeated 20-batch Runner cycles with failed
  AI reviews. The diagnostic now includes processing and finalisation failures
  so dependent completion errors cannot hide the earlier cause. The fresh report
  returned interrupted model outcomes around deployment. The revised report
  isolates competing batches invalidating the todo intake snapshot, plus a
  separate incomplete-decision failure. The fix to serialise new discovery
  batches per user is deployed on `maraithon-00451-v76`; its build and deployment
  health check passed. A complete new discovery cycle and the incomplete-decision
  failure still need verification.
- [ ] Verify scheduling uses the three approved Mac calendars when fresh and
  falls back to Google when unavailable or stale. The selections are now saved;
  the consumer and fallback still need a live check.

## Next

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
