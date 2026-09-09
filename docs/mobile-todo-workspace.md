# Mobile todo workspace

The iOS todo detail now shares the Mac workspace structure: todo and completion
controls, suggested next actions, connected-app reviews, and the todo's persistent
conversation. A People/Details sheet fits the phone; wide layouts use a sidebar.
The summary expands in place, keeping the next actions and chat close to the top.

People and suggested actions come from the server-authored brief used on Mac.
Opening a todo marks it opened and refreshes only that todo while its brief is
prepared, with a bounded retry window. Existing call, source reply, edit, snooze,
importance, completion, and dismissal controls remain available.

Chat cards use the existing native provider assets and the Runner review pattern.
Email recipients, subject, Cc/Bcc, and body remain editable; local email drafts
show the Google permission action when the account is read-only. Calendar cards
show the account, exact start/end and time zone. Messages cards open Apple's
review composer with the server-verified handle. Opening a composer does not
record delivery or complete the todo. Remote execution requires a current,
server-issued prepared action and explicit confirmation.

Unsent composer text and card edits use SceneStorage keyed by thread/message.
Conversation messages retain their existing SwiftData persistence. The new brief
fields are optional values in the existing Codable blob: no schema migration.
Interrupted message requests retain their client message ID, reconcile server
state on reopening, and offer a retry for unconfirmed messages. The timeline
measures variable-height cards directly and initially displays at most 60
messages; earlier history is available in batches. This avoids an iOS 26 lazy
layout loop encountered while jumping across the real conversation.

## Verification, September 8, 2026

- XcodeGen generation passed.
- iOS Simulator build passed for iPhone 17 / iOS 26.4 with Swift 6 strict concurrency.
- Manually opened the real Michael/Christina todo using the existing signed-in
  simulator and production APIs. Todo controls, all three suggested actions,
  people context, shared conversation history, email review, and calendar
  account/time/zone were visible. The todo remained open.
- Native text edits survived navigating away and reopening the todo.
- The simulator reports Messages unavailable; native composer presentation on
  a physical phone still requires device verification.
- Gmail sending and calendar booking remain dependent on the user's Google
  write consent. No external messages or calendar events were sent/created.
- Tests intentionally not run under docs/development-mode.md. No test files
  or test targets were changed. iPad layout is compile-checked, not device-verified.

## Release

The main checkout also passed the simulator build after merging this change.
The Release archive and App Store export passed using the existing Apple
Distribution identity and the team's active Maraithon AppStore CI profile, which
was downloaded and installed locally without creating or replacing a certificate.
Apple accepted version 1.0.1, build 20260908125249 on September 8, 2026.
Delivery UUID: 55c50113-8d58-4244-8d4d-b25966ccf6f0.

The interrupted read-only question was retried with its persisted client ID,
progressed through relationship and Gmail checks, and completed with the server's
incomplete-evidence response. The composer became usable again. This verifies
client recovery, not the factual completeness of that assistant answer.

App Store Connect confirmed processingState VALID and internalBuildState
IN_BETA_TESTING. The Founders group already has access to all builds; its
existing membership includes kent.fenwick@gmail.com. No testers were added.
