# Companion desktop app: local context sync (iMessages first)

**Date:** 2026-05-10
**Status:** spec
**Goal:** ship a macOS companion app that reads local context the cloud can't reach (iMessages first, files later) and pushes it to Maraithon, so the assistant's CRM, memory, and briefings include what's actually happening on the user's machine.

## Why this exists

Today Maraithon sees Gmail, Calendar, Slack, and Telegram. It misses the single highest-signal source for most knowledge workers: SMS/iMessage threads with co-founders, partners, family, and operators. Kent's CRM has Charlie listed via email; the texts where Charlie actually proposes meetings live only on the laptop. Same for files — design docs, voice memo transcripts, screenshots — they sit in `~/Documents` and never reach the brief.

A companion daemon closes that gap by treating the user's machine as another connector.

## v1 scope

**In:**
- macOS-only, signed + notarized desktop app with a real window (not menubar-only).
- Device-pair login flow with Maraithon (one-time consent).
- iMessage sync: append-only, polled, plain text + handle metadata.
- CRM person resolution by phone/email handle.
- Window UI: per-source sync status, controls, debug log.
- Menubar status item as a secondary affordance (last-sync glance + show-window).

**Out (designed-for, deferred):**
- File sync (separate spec, same daemon).
- Attachment body upload (only metadata in v1).
- Edits, reactions, deletes.
- Windows / Linux.
- Real-time push (polling is fine for daily-context use cases).

## Architecture

```
                                  ┌────────────────────────────────────────┐
                                  │  macOS desktop app (Swift / SwiftUI)   │
                                  │                                        │
                                  │  ┌────────────┬───────────────────────┐ │
                                  │  │ Sidebar    │  Detail pane          │ │
                                  │  │            │                       │ │
   user logs in once  ─────────►  │  │ • Account  │  Selected source:     │ │
                                  │  │ • iMessage │   • Status card       │ │
   System Settings →              │  │ • Files…   │   • Controls          │ │
   Full Disk Access  ─────────►   │  │ • Logs     │   • Recent activity   │ │
                                  │  └────────────┴───────────────────────┘ │
                                  │                                        │
                                  │  Core (headless):                      │
                                  │    • Auth: device token (Keychain)     │
                                  │    • Sources: IMessageSource…          │
                                  │    • Sync engine (batched push)        │
                                  │    • EventLog (ring buffer + file)     │
                                  │                                        │
                                  │  Optional menubar status item          │
                                  │    (glance: last sync, click → window) │
                                  └─────────────────┬──────────────────────┘
                                                    │ HTTPS
                                                    ▼
                  ┌──────────────────────────────────────────────────────┐
                  │ POST /api/v1/companion/messages                       │
                  │   (bearer: device token)                              │
                  │                                                       │
                  │ Maraithon (Phoenix)                                   │
                  │   • CompanionController                               │
                  │   • LocalMessages context                             │
                  │   • CRM handle resolver                               │
                  │   • Memory/insight pipeline ingest                    │
                  └──────────────────────────────────────────────────────┘
```

The companion app is a **simple sync daemon, not a smart agent.** It does not interpret messages, run LLMs, or make decisions — that all happens server-side in Maraithon's existing pipelines. The app is responsible for: read locally, push reliably, expose a few controls.

## Platform choice: native Swift + SwiftUI

- The app's value is reading macOS-specific data (`~/Library/Messages/chat.db`, FSEvents, Keychain, login items, Full Disk Access entitlement). Native Swift makes all of that idiomatic.
- SwiftUI for window UI is fast to build and grows well as we add sources — `NavigationSplitView` for the sidebar pattern, `Form` for status cards, `Table` for logs.
- A web-tech wrapper (Electron, Tauri) buys cross-platform but iMessages are Apple-only, so we'd still need Mac-specific code paths. Net: zero portability win, larger binary, more friction with notarization.
- Single Xcode project, ~1,000–1,500 LOC for v1 (more than a menubar-only app because of the proper window UI). Distribute as signed `.app` in a DMG; auto-update with Sparkle.

## UI surface

The window is a `NavigationSplitView` with three regions:

### Sidebar — "Sources"
- **Account** (top): user email, device name, "Sign out" link, last cloud handshake.
- **iMessage** — primary row in v1. Status icon (●/◐/⏸/⚠), label, "12m ago" subtitle.
- **Files**, **Voice memos**, **Notes** — disabled rows in v1 with "Coming soon" tag, so the shape is visible.
- **Logs** (bottom) — opens the debug log pane.

### Detail pane — selected source
For iMessage:
- **Status card** at the top: "● Syncing" / "⏸ Paused" / "⚠ Needs Full Disk Access" / "⚠ Connection issue", with a one-line subtitle (e.g. "Last sync 14:23 — 47 new, 0 errors").
- **Stats grid**: Messages synced today / This week / Total. Cursor position (rowid). Backfill progress bar when initial sync is running.
- **Controls**:
  - Pause / Resume toggle.
  - "Sync now" button (manual nudge).
  - "Backfill more…" → sheet to extend the historical window.
  - "Clear cloud data for this device" (destructive, confirm).
- **Recent activity** — last 20 batches: timestamp, count, accepted/duplicate split, latency.

### Logs pane
- Live tail of the `EventLog` ring buffer, with level filter (Debug / Info / Warn / Error), source filter (Auth / iMessage / Sync / Cloud), and a search field.
- Each entry: timestamp, level, source, message, optional structured context (expandable).
- "Copy all" and "Reveal log file in Finder" buttons. Persistent log at `~/Library/Logs/Maraithon/companion.log` rotated at 10 MB × 5 files.

### Menubar status item (secondary)
- Always-visible glance: ●/⏸/⚠ icon + click-to-open-window.
- Quick actions: Pause/Resume, Sync now, Show window, Quit.
- The menubar is the affordance for "I forgot if it's running"; the window is where actual work happens.

### Window lifecycle
- Default: open on first launch and after auth. After that, `closing` the window only hides it (app keeps running headless, menubar item stays). Quitting from `⌘Q` or the menubar's "Quit" actually exits the process.
- "Open at login" toggle in the Account section, backed by `SMAppService` so the launch agent registers cleanly.

## Auth: device-pair flow

1. App opens for the first time → "Connect to Maraithon" CTA.
2. App generates a `device_id` (UUID, persisted to Keychain) and opens `https://maraithon.com/companion/auth?device_id=<uuid>&device_name=<MacBook%20-%20Kent>` in the default browser.
3. User logs in to Maraithon (existing session usually already present), then sees a one-screen consent: "Maraithon Companion on Kent's MacBook wants to sync iMessages to your account. Approve / Deny."
4. On approve, server issues a long-lived `device_token` and redirects to `maraithon://device-token/<token>`.
5. The custom URL scheme is registered by the app's `Info.plist`. App receives the token, stores it in macOS Keychain (`maraithon.device_token`), and shows "Connected as kent@runner.now".
6. Token revocation lives at `https://maraithon.com/admin/companion-devices` — list, name, last-seen, revoke.

Token is per-device. No refresh dance — long-lived bearer is fine for a single-user trusted-device model. Revocation is the kill switch.

## iMessage source

### Read path

- File: `~/Library/Messages/chat.db` (SQLite, Apple-managed).
- Macros: requires **Full Disk Access** in System Settings → Privacy & Security. App detects missing access on launch, shows a one-screen onboarding with a deep link (`x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`).
- Read-only. Open with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`. Apple's WAL means we never lock the file.
- Schema we touch:
  - `message` (`ROWID`, `guid`, `text`, `attributedBody`, `date`, `is_from_me`, `service`, `handle_id`, `cache_has_attachments`)
  - `handle` (`ROWID`, `id` — phone or email, `service`)
  - `chat` (`ROWID`, `guid`, `display_name`, `chat_identifier`, `style`)
  - `chat_message_join`, `chat_handle_join`
- Body decoding: modern macOS stores message body in `attributedBody` (an NSAttributedString archived as a binary plist). Decode via `NSKeyedUnarchiver` with `NSAttributedString` as expected class. Fall back to legacy `text` column on older rows.
- Apple's `date` is "nanoseconds since 2001-01-01 UTC" on modern macOS; convert to ISO-8601 UTC.

### Sync cursor

- Persist `last_synced_rowid` in app sandbox (`UserDefaults` or a tiny SQLite). Query `SELECT * FROM message WHERE ROWID > ? ORDER BY ROWID ASC LIMIT 200`.
- Polling cadence: 30 seconds when active, 5 minutes when laptop is on battery and idle.
- No file-watch / FSEvents on chat.db — Apple's WAL writes don't reliably surface as filesystem events; polling is simpler and good enough.

### Push payload

```json
POST /api/v1/companion/messages
Authorization: Bearer <device_token>
Content-Type: application/json

{
  "device_id": "9b1a…",
  "source": "imessage",
  "messages": [
    {
      "local_id": "p:42",                  // ROWID, namespaced
      "guid": "ABCD-1234-…",               // chat.db guid (idempotency key)
      "service": "iMessage",
      "is_from_me": false,
      "sender_handle": "+14165550199",
      "chat_handles": ["+14165550199"],    // 1:1 → 1 entry; group → many
      "chat_display_name": null,           // group name if any
      "chat_style": "im",                  // "im" | "group"
      "text": "Want to grab coffee tomorrow?",
      "sent_at": "2026-05-10T13:14:22Z",
      "has_attachments": false,
      "attachments": []                    // {filename, mime_type, byte_size} once we add it
    }
  ]
}
```

Idempotency key on the server: `(user_id, device_id, guid)`. Re-sending the same payload is a no-op.

Batches of 200 messages, gzip-encoded. On 5xx, exponential backoff (max 5 minutes). On 401, prompt re-auth.

### Backfill

- First sync after pairing: pull the trailing 30 days, in batches of 200, paced (one batch / 5s) so we don't burst the cloud.
- User-controlled in onboarding: "Backfill last 30 days / Backfill last 90 days / Start fresh".

## Cloud side

### New schema (Postgres)

```
local_messages
  id                uuid pk
  user_id           text       (kent@runner.now)
  device_id         uuid
  source            text       ("imessage", later "files", …)
  guid              text       (source-native id; null for sources without one)
  local_id          text       (cursor-stable id)
  is_from_me        boolean
  sender_handle     text
  chat_key          text       (canonical chat id for grouping)
  chat_display_name text
  chat_style        text
  text              text       (encrypted-at-rest via existing Cloak setup)
  sent_at           timestamptz
  has_attachments   boolean
  attachments       jsonb
  inserted_at       timestamptz
  updated_at        timestamptz

unique (user_id, device_id, source, guid)
index (user_id, sent_at desc)
index (user_id, chat_key, sent_at desc)
```

Reuse existing `Maraithon.Encrypted` Cloak vault for `text` and `sender_handle` — same pattern as Gmail bodies.

### Phoenix endpoint

`Maraithon.Companion.Controller`:
- `POST /api/v1/companion/messages` — bearer auth via new `Maraithon.Companion.Devices` table (`device_id`, `device_name`, `user_id`, `token_hash`, `last_seen_at`, `revoked_at`).
- Validates batch shape, dedupes via the unique constraint, returns `{accepted, duplicate}` counts so the client can advance its cursor.
- Emits `:companion_messages_ingested` event for downstream consumers.

### Routing into existing pipelines

On insert, `LocalMessages.after_insert/1` does three things:

1. **CRM resolve** — for each unique `sender_handle` not already linked to a person, run `Maraithon.Crm.resolve_handle/2`. If a person exists by phone/email, link this message via `link_person_data` so future relationship questions surface it. If no match, leave for later — `learn_relationship_context` can pick it up when the message gets surfaced.
2. **Open-loop hint** — for `is_from_me: false` messages younger than 24h that look like a question or ask, emit a `pending_inbound` insight. Existing insight pipeline handles dedupe and prioritization; we don't reinvent that.
3. **Memory feed** — append to `Maraithon.Memory` deep memory with `kind: "imessage_observation"` and rich source metadata so morning briefs and CRM relationship learning see it.

### Source health

Hook into the existing `SourceBundle.put_imessage/2` (new) so morning briefings include "iMessage: 47 messages from 12 contacts in last 18h" alongside Gmail/Slack stats. When the device hasn't checked in for >2h, mark `imessage_status: "stale"` so the model knows not to trust the snapshot.

## Privacy & user controls

- Per-source toggle in the menubar UI.
- **Per-contact blocklist** stored locally (synced to cloud as a metadata-only list). If a handle is on the blocklist, the app filters before push — the cloud never sees blocked threads.
- "Pause sync for 1 hour" / "Pause indefinitely" menubar option.
- "Clear cloud data for this device" — calls `DELETE /api/v1/companion/devices/<id>/messages`, server purges all rows for that device.
- Onboarding screen explicitly states: "Maraithon stores your message text encrypted at rest. We never share it with third parties. You can revoke this device or wipe its data anytime."

## Failure modes

| Failure | Behaviour |
|---|---|
| Full Disk Access not granted | App stays in "Setup needed" state, no polling, clear instructions on the menubar dropdown |
| `chat.db` schema unexpected | Telemetry ping (`companion.imessage.parse_failure`) with macOS version, fall back to skipping unparseable rows, never crash |
| Cloud 4xx | Stop sync, surface "Connection issue, click to fix" in menubar; on 401 trigger re-auth flow |
| Cloud 5xx / network | Exponential backoff up to 5 min, retry indefinitely with jitter |
| Mac asleep | Polling pauses naturally; on wake, send the now-larger batch in chunks |
| Disk full / sandbox eviction | Cursor in Keychain so a fresh app reinstall resumes from the last synced rowid |

## File structure (companion app)

```
maraithon-companion/
  Maraithon.xcodeproj
  Maraithon/
    App/
      MaraithonApp.swift            // @main, scene + menubar wiring
      AppEnvironment.swift          // shared services (DI container)
    UI/
      RootWindow.swift              // NavigationSplitView host
      Sidebar/
        SidebarView.swift
        AccountRow.swift
        SourceRow.swift
      Sources/
        IMessageDetailView.swift    // status card + controls + recent activity
        ComingSoonDetailView.swift
      Logs/
        LogsView.swift              // table + filters + search
        LogEntryRow.swift
      Onboarding/
        ConnectView.swift
        FullDiskAccessView.swift
        BackfillSetupView.swift
      Menubar/
        MenubarController.swift     // status item, quick menu
    Auth/
      DeviceAuth.swift              // URL scheme handler, Keychain wrapper
      DeviceToken.swift
    Sources/
      SourceProtocol.swift          // pollable + cursor-aware + status publisher
      SourceStatus.swift            // shared status enum/model
      iMessage/
        IMessageDatabase.swift      // SQLite + AttributedBody decoder
        IMessageSource.swift        // poller, cursor, payload builder
    Sync/
      SyncEngine.swift              // batching, retry, backoff
      MaraithonClient.swift         // HTTP client
    Logging/
      EventLog.swift                // ring buffer + file rotation, Combine publisher
      LogLevel.swift
    Info.plist                      // url scheme, FDA usage, login-item entitlements
  MaraithonTests/
    IMessageDatabaseTests.swift     // golden chat.db fixtures
    SyncEngineTests.swift
    EventLogTests.swift
```

## Server-side files (Maraithon)

```
lib/maraithon/companion/
  devices.ex                       // schema + Maraithon.Companion.Devices
  device.ex                        // Ecto schema
  local_messages.ex                // Maraithon.LocalMessages context
  local_message.ex                 // Ecto schema
  crm_routing.ex                   // resolve_handle, attach to person
  insight_routing.ex               // pending_inbound / brief_observation
lib/maraithon_web/
  controllers/companion_controller.ex
  controllers/companion_auth_controller.ex     // /companion/auth + callback
  plugs/device_token.ex
priv/repo/migrations/
  20260510_create_companion_devices.exs
  20260510_create_local_messages.exs
test/maraithon/companion/
  local_messages_test.exs
  crm_routing_test.exs
  controller_test.exs
```

## Milestones

**M1 — server scaffold (1–2 days)**
- Migrations, schemas, controller, device-pair auth flow with a stub HTML "approve / deny" page. End-to-end pair flow verifiable by hand-curling the endpoint with a fake batch.

**M2 — companion app skeleton (3–4 days)**
- Xcode project, SwiftUI `NavigationSplitView` shell with Sidebar / Detail / Logs, EventLog ring buffer wired to the Logs view, menubar status item. Deep-link auth + Keychain token storage. "Connected" / "Disconnected" states with no data sync yet.

**M3 — iMessage source (3–5 days)**
- Full Disk Access onboarding, chat.db reader with attributedBody decoder, cursor, polling, push to server. Ship to Kent for daily use.

**M4 — pipeline integration (2–3 days)**
- CRM resolve, deep-memory ingest, source-health surface in morning brief. First brief that cites an iMessage thread.

**M5 — controls + polish (2–3 days)**
- Pause, blocklist, clear-data, "Sync now", "Backfill more…" sheet, open-at-login (`SMAppService`), Sparkle auto-update, signed DMG.

Total: ~11–17 working days for a private-use v1.

## Open questions explicitly deferred

- File sync — separate spec, same daemon shell.
- Attachment uploads — start with metadata, add bodies once we have a hash-dedupe scheme.
- Multi-user — out of scope (Maraithon is single-tenant today).
- Cross-device merge (laptop + iMac syncing the same iCloud account) — server's `(user_id, source, guid)` unique constraint handles it; first writer wins.
- Voice memos / Notes / Reminders — same source pattern; pick up after iMessage is stable.

## Why this scope, not bigger

The temptation is to make a general "Mac data exfiltrator" — files, browser history, Notes, Reminders, voice memos, screenshots. Resist. iMessage alone is the single highest-signal Mac-only source for relationship and commitment context. Ship that, prove the daemon shell works, then add the next source as a 200-line `Source` implementation against the same interface.
