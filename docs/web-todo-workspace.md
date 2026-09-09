# Web todo workspace

The web todo detail now uses the same persistent todo conversation and public
review-card projection as Mac and iPhone. Suggested next actions appear below
the todo controls. Source context is available in a disclosure, action reviews
sit above chat, and the People sidebar shows grounded relationship context.
On narrow screens the content stacks and navigation uses a second row.

Implementation:

- `TodosLive` retains list navigation, filters, done/dismiss controls, editable
  next action, projects, and source reply handling in Details.
- `TodoWorkspace` owns one async conversation operation and one scheduled
  refresh at a time. Queued/running requests refresh every three seconds;
  idle conversations refresh every thirty seconds and on focus/reconnect.
  Awaiting approval is distinct from working and does not lock the composer.
  AssistantChat's existing durable workers still own execution.
- `MobileChatJSON` remains the source of public message, account, permission,
  action status, and expiration projections. Prepared-action decisions are
  scoped to the current conversation and authenticated user and execute through
  the existing durable decision API.
- `todo_workspace.js` keeps composer text, local review edits, disclosure state,
  and a pending client message UUID in tab-scoped session storage. Only a
  matching server message receipt clears the pending request. Retry reuses the
  UUID. Nothing is sent automatically on reconnect.
- Gmail, Messages, Slack, and calendar reviews follow Runner's provider header,
  editable content, connection state, and explicit action-footer pattern.
  Older cards remain reviewable inside conversation history. Messages opens a
  reviewed device draft; opening Messages never reports delivery or completes
  the todo. Google actions remain blocked until the right write consent exists.
- Saved `/todos/:id/chat` links lead to the integrated todo workspace.

## Verification and release — September 8, 2026

- `make build` passed in the isolated implementation checkout and the shared
  working checkout, preserving the separate People work. `mix assets.build`
  passed. Tests were not added or run under the manual-first policy.
- Reviewed the real Michael/Christina availability todo in the authenticated
  browser at 1440px and 390px widths. No horizontal page overflow; the people
  panel is alongside the work on desktop, with stacked content on narrow screens.
- Gmail recipient, account, subject/body, CC/BCC edits, read-only Google notice,
  and disabled preparation without write consent were visible. An expired
  calendar review stayed non-sendable and did not block chat.
- Draft edits and the composer survived switching to Details and a full reload.
  Temporary verification text was removed and its absence checked after reload.
- The Michael People link opened his saved relationship context, then returned
  to the todo. The suggested Message Christina action produced a fresh review
  card with her verified Messages handle and an editable body. The assistant's
  completion appeared in the shared conversation. Nothing was sent or booked.
- Google write consent remains outstanding. Device Messages handoff and actual
  email/calendar delivery were not exercised in this web change.
- The previous rollout's transient runtime-retirement warning recovered: the
  serving runtime subsequently reported all 64 partitions admitting work. The
  final rollout successfully requested retirement of the old instances.

Deployed code: `1e35f85385cc`, Cloud Run revision `maraithon-00266-tbn`,
100% traffic. Image:
`us-central1-docker.pkg.dev/maraithon/maraithon/maraithon:dev-1e35f85385cc-20260908132243-1`.
No migrations were needed. Release notes and a whitespace-only cleanup follow
that deployed code commit.
