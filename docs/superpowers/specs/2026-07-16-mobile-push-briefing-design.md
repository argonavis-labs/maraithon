# Mobile push migration: phone-first delivery, in-app briefing

**Date:** 2026-07-16 · **Status:** approved (Kent: "go for it") · **Sequencing:** push first (Kent), hard cutover (Kent)

## Goal

Move all proactive assistant delivery from Telegram to iOS push notifications, and make the
morning briefing an in-app experience. Todo digests and nudges ride the same pipe. Reliability
practices (receipts, dead-token pruning, safe rollout) are built in, not bolted on.

## What exists (survey, 2026-07-16)

- Zero push infrastructure — no APNs client, no device-token registry, no entitlements.
- `TelegramAssistant.PushBroker` already unifies all 7 proactive origin types (brief, insight,
  assistant_digest/check-ins + todo digests, nudge, agent_push, connector_health, dogfood_digest)
  with dedupe, hourly caps, quiet hours, and PushReceipts. Telegram is only the last hop.
- Mobile app (SwiftUI, 5 tabs) already renders briefings (Today tab), todos, chat, CRM; talks to
  `/api/mobile/*` with magic-code auth + Bearer session.
- Assistant chat on mobile is persist-only (`AssistantChat.MobileDelivery`); the phone polls.

## Architecture

### 1. APNs client — `Maraithon.Push.APNS`

Direct APNs over HTTP/2 (no Firebase, no new deps):

- Finch pool (`Maraithon.Push.Finch`, `protocols: [:http2]`) for
  `api.push.apple.com` / `api.sandbox.push.apple.com`.
- Provider-token auth: ES256 JWT signed with the `.p8` key via `:public_key`/`:crypto`
  (DER→raw signature conversion inline; no jose/joken dependency). Token cached ~50 min
  in `:persistent_term`.
- Config from env: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY` (PEM contents),
  `APNS_TOPIC` (default `com.bliss.maraithonmobile`), `APNS_ENVIRONMENT`
  (`production` | `sandbox`). `configured?/0` false → entire channel inert.
- Response handling: 200 ok; **410/`BadDeviceToken`/`Unregistered` → prune the device**;
  429/5xx → `{:error, :retryable}` (broker's natural hourly retry covers it); other 4xx logged.

### 2. Device registry — `Maraithon.Push.Devices`

- Table `mobile_push_devices`: `user_id`, `device_token` (unique), `platform` (`ios`),
  `app_version`, `environment`, `status` (`active`/`disabled`), `last_seen_at`, timestamps.
- `POST /api/mobile/push/devices` (upsert by token; re-registering moves a token between
  users — a phone has one owner) and `DELETE /api/mobile/push/devices/:token` (sign-out).
  Both behind `require_mobile_session`.
- `Devices.active_for_user/1`, `Devices.disable/1` (used by the 410 prune).

### 3. Delivery routing — hard cutover, safely gated

`Maraithon.Push.Notifier` is the single "notify this user on their phone" entry point:
`notify(user_id, %{title, body, deeplink, thread_id, origin_type, dedupe_key})` → APNs alert
to every active device (payload carries `deeplink` for routing; `thread-id` groups by origin).

Cutover rule inside `PushBroker`'s send path (one choke point, `send_candidate/1`):
**if the user has ≥1 active push device and APNs is configured, the candidate is delivered
via APNs and Telegram is not called; otherwise Telegram delivery proceeds unchanged.** All
broker machinery upstream (dedupe, caps, quiet hours, receipts) applies identically to both
channels — receipts record `channel: "apns"`.

That is the hard cutover Kent chose, gated per-user on device registration so nobody is ever
stranded channel-less (the failure class from the 2026-07-16 briefing outage). Kill switch:
`MOBILE_PUSH_ENABLED=false` env reverts everything to Telegram instantly.

Additional push producers:
- **Morning briefing:** when `BriefNotifier` dispatches a `morning` brief for a push-user, the
  Telegram body is replaced by a compact push ("Your morning briefing is ready" + brief title)
  deep-linking `maraithon://today`. The brief is marked sent on APNs accept. Email continues
  unconditionally (baseline channel).
- **Assistant chat replies:** `AssistantChat.MobileDelivery` pushes the reply snippet
  (deep-link `maraithon://chat/<thread_id>`) when a run completes, so the phone no longer
  depends on foreground polling.

### 4. iOS app

- `aps-environment` entitlement (+ project.yml wiring); no background modes needed for alerts.
- `PushRegistrationService` (Core/Push): requests authorization after sign-in, registers for
  remote notifications, uploads the hex token via `MobileAPIClient.registerPushDevice`;
  re-uploads on every launch (`last_seen_at` heartbeat). Sign-out deletes the registration.
- `UIApplicationDelegateAdaptor` captures the APNs token; `UNUserNotificationCenterDelegate`
  shows foreground banners and routes notification taps: parse `deeplink` from userInfo →
  `AppNavigation` (today / todos / chat thread / person).
- Deep-link scheme `maraithon://` registered in Info.plist (also used by email links later).

### 5. Todos, chief-of-staff grade

Todo digests and reconnect/waiting-on nudges already flow through the broker and therefore
arrive on the phone with this change, deep-linking into the Todos tab. The deeper semantic
ranking work (beyond `AttentionRanker`'s deterministic first pass) is its own follow-up spec —
shipping it inside this one would make both worse.

## Error handling & reliability

- APNs unconfigured → channel inert, Telegram unaffected (deploy-safe before the key exists).
- Dead tokens pruned on 410; a user whose every device is pruned falls back to Telegram
  automatically on the next candidate.
- Every APNs send is wrapped in the existing PushReceipt audit trail; failures log with
  `apns_status`/`apns_reason` fields.
- No new GenServers on the hot path — `Notifier` is synchronous inside the broker's existing
  flow (which already runs off-request).

## Testing

- ExUnit: JWT shape (header/claims/ES256), payload construction, cutover routing (device →
  APNs, no device → Telegram, kill switch → Telegram), 410 prune, registration API
  (auth required, upsert semantics, token ownership move).
- APNs HTTP layer stubbed via config-injected module (repo's established pattern).
- iOS: build sanity via xcodebuild; simulator can't receive real APNs — end-to-end verified on
  device after Kent adds the `.p8` key.

## Manual step (only one)

Fly secrets: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY` (contents of the `.p8` from
App Store Connect → Keys), `APNS_ENVIRONMENT=production`. Until then, everything ships inert
and Telegram keeps working.

## Out of scope (follow-up specs)

- Notification action buttons (Done/Snooze from the lock screen).
- Android.
- Semantic todo ranking overhaul.
- Retiring the Telegram code paths entirely (happens after push is proven in prod).
