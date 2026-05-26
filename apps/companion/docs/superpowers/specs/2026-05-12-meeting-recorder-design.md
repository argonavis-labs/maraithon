# Meeting Recorder — Design

Status: approved (2026-05-12)
Owners: maraithon-mac + maraithon (server)

## Summary

In-app meeting recorder. One press on a global top-of-window
recorder bar captures **mic + system audio** into a mixed `.m4a`,
ships it to Maraithon on **Stop**, and the server transcribes it
via Whisper. The resulting **Capture** becomes a new first-class
source (parallel to Notes / Reminders / Voice Memos), so the
existing agent surfaces — morning brief, CRM enrichment, todo
extraction — pick the transcript up the same way they consume the
other `local_*` text today.

Goal: a user mid-meeting hits Record, talks, hits Stop, and the
open loops surface in their morning brief without any further
clicks.

## Out of scope

* Live partial transcripts during recording. The hybrid local /
  server transcription path is rejected for v1 to avoid two
  recognition stacks.
* Stereo separation of mic vs. system audio. Stored as one mixed
  track; the upload preserves the split intent in metadata so a
  later pass can re-mix.
* Speaker diarization. Whisper hands us one transcript stream;
  who-said-what is a follow-up.
* Agent-side tuning to "extract open loops from captures
  specifically." The morning-brief / CRM / todos pipelines
  already read populated `local_*` text columns; once the
  transcript lands, they pick it up on their existing cadence.
  Targeted prompt tweaks to favor captures are a follow-up spec.

## Decisions

| Question | Decision |
|---|---|
| What audio? | Mic + system audio (via `ScreenCaptureKit.SCStream`) |
| Transcription? | Server-side Whisper |
| Where do controls live? | Persistent top strip on the main window; pushes detail content down when active |
| Title? | Auto from start datetime (`2026-05-12 13:47`) — agent can re-title from content later |
| Upload timing? | One-shot on Stop |
| Recording-state UI? | Red dot + monospaced elapsed timer + live mic-level meter + Stop button |
| Where in the app + cloud? | New "Captures" source, new `local_captures` table |

## User flow

```
1. User clicks ● Record in the window's top strip.
2. Permissions checked (Mic + Screen Recording). Missing perms ⇒ focused
   unblock view with deep links to System Settings. Stop here.
3. Recorder starts AVAudioEngine (mic) and an SCStream (system audio).
   Both feed a single mixer node, encoded to .m4a (AAC) on disk under
   ~/Library/Application Support/Maraithon/captures/<uuid>.m4a.
4. Top strip expands from 30pt → ~60pt and shows:
     ● recording • 00:14:32 • ▁▃▅▆▃▁ ▁▃▅▂▁  [■ Stop]
   Detail content pushes down to make room.
5. User clicks ■ Stop.
6. Recorder closes the .m4a, computes duration.
7. CaptureUploader POSTs the file via multipart to
   `POST /api/v1/companion/captures` with metadata. Realtime channel
   preferred (`ingest:captures`); HTTP fallback on any channel error.
8. Server stores the audio, inserts `local_captures` row with
   `transcript=nil`, enqueues a Whisper transcription job, returns
   `202 Accepted` with the guid.
9. Client immediately inserts a local Capture row titled with the
   start datetime; sidebar Captures source shows it as "transcribing…".
10. When the Whisper job completes, server updates the row's
    `transcript` and emits a Phoenix PubSub event on the device's
    channel; client refreshes the row inline.
11. Agent layer picks up the populated transcript on its existing
    cadence (morning brief next day, CRM enrichment, todos).
```

## Architecture

### Client (Swift on Mac)

* **`CaptureRecorder`** — `@MainActor`-isolated actor; one instance
  held by `AppEnvironment`. State machine:
  `idle → starting → recording → stopping → uploading → idle | error`.
  Owns the `AVAudioEngine` (mic), `SCStream` (system audio), a mixer
  node, and the AAC file writer. Exposes `@Observable` props for
  the bar to bind: `state`, `elapsed: Duration`, `meterLevel: Float`.
* **`CaptureRecorderBar`** — SwiftUI view, root of the window's
  top strip. Idle = 30pt with a `● Record` pill (capsule button).
  Active = ~60pt with: pulsing red dot, monospaced-digit elapsed
  timer, `Canvas`-drawn level meter (30 Hz refresh from the
  recorder's mic tap), and a destructive-tint `■ Stop` button. The
  bar lives in `RootWindow` outside the `NavigationSplitView` so it
  spans the full window width and never overlaps the sidebar.
* **`CaptureUploader`** — mirror of `NotesIngest`'s shape. Multipart
  POST helper with auth + transport; tries the realtime channel
  first, falls through to HTTP on any `RealtimeChannelError`. On
  202, returns the guid. On transport error, keeps the audio file
  under `captures/pending/` and retries with exponential backoff
  on app launch + every 5 minutes.
* **`CapturesSource`** (`SourceProtocol`) — list-only source, no
  polling. Its `state` is driven by the recorder + uploader:
  `.syncing` while uploading, `.connected` once at least one
  capture has shipped, `.needsAttention("capture_permission_denied")`
  when the recorder hit a permission denial during its last attempt.
  `SourceProtocol` shape is honored but most methods are no-ops:
  `start()` / `pause()` toggle whether the uploader retries pending
  captures; `syncNow()` triggers an immediate retry of anything in
  `captures/pending/`; `clearLocalState()` deletes the pending
  folder. Registered in `AppEnvironment` alongside the other
  sources so it inherits the sidebar row + detail pane scaffolding.
* **`CapturesDetailView`** — the sidebar pane: list of captures
  (newest first) with title, duration, a `pending_transcription /
  transcribed` chip, the transcript preview, and a play button that
  uses `AVPlayer` against the local file (or streams from the cloud
  if local was already deleted).
* **`SourcePermissionHint`** gains two new mappings:
  `"capture_mic_denied"` → deep link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`;
  `"capture_screen_recording_denied"` → deep link
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`.

### Server (Maraithon)

* **New endpoint** `POST /api/v1/companion/captures` — multipart:
  `audio` (m4a binary part), plus JSON metadata: `device_id`,
  `guid`, `started_at`, `ended_at`, `duration_seconds`,
  `source_apps` (JSON array of bundle ids that were foreground
  during the recording, for future "who was this meeting with"
  inference). Validates `(user_id, device_id)` from the bearer
  token. Returns `202 Accepted` with `{"guid": "..."}`.
* **New realtime channel event** `ingest:captures` (parallel to
  `ingest:notes`, `ingest:messages`, etc.) — same payload shape
  except the audio is base64-encoded inside the JSON since channels
  don't carry multipart. Client prefers the channel for the small
  metadata + base64 audio (capped at e.g. 30 MB); HTTP path used
  for anything larger.
* **New schema** `local_captures` —
  ```
  id uuid PRIMARY KEY
  user_id text NOT NULL
  device_id uuid NOT NULL
  source text NOT NULL DEFAULT 'captures'
  guid text NOT NULL
  title text NOT NULL
  started_at timestamptz NOT NULL
  ended_at timestamptz NOT NULL
  duration_seconds integer NOT NULL
  audio_bytes bytea       -- v1: in-row; v2: ref to object store
  audio_mime text NOT NULL DEFAULT 'audio/m4a'
  transcript text         -- nullable until Whisper job completes
  transcript_engine text  -- 'whisper-1', 'whisper-v3', etc.
  source_apps jsonb DEFAULT '[]'::jsonb
  inserted_at timestamptz NOT NULL
  updated_at timestamptz NOT NULL
  UNIQUE (user_id, device_id, source, guid)
  ```
  Mirrors the column conventions of `local_voice_memos`. All
  user-controlled string columns are `text` (we learned the lesson
  with `local_files.local_id` and varchar(255)).
* **Whisper job** — `Maraithon.Captures.TranscribeJob` enqueued on
  the existing background-job runner. Keyed by capture id. Calls
  OpenAI Whisper (or self-hosted `whisper.cpp` if the
  `WHISPER_PROVIDER` env says so) with the audio bytes. On success
  updates `transcript` + `transcript_engine` and emits a Phoenix
  `PubSub` broadcast on the device channel so the Mac app refreshes
  the row inline. On failure, leaves `transcript=nil` and records
  the error in a `transcribe_failures` audit table so the user
  can request re-run from the detail pane.
* **on_conflict policy** — `:replace` on `[:transcript,
  :transcript_engine, :updated_at]` so re-running Whisper updates
  the row without re-inserting. Identity + audio bytes are
  immutable post-insert.

## Data flow

```
[Mac]  CaptureRecorder.start
   │   ├─ AVAudioEngine.mic
   │   └─ SCStream.systemAudio
   │       └→ mixer → AVAudioFile.write(.m4a)
   │
   │   user hits Stop
   ▼
CaptureUploader.upload(audio, metadata)
   │
   │   realtime channel push: "ingest:captures"
   │   (HTTP fallback on RealtimeChannelError)
   ▼
[Server]  CompanionChannel.handle_in("ingest:captures", ...)
   │
   └→ Captures.ingest(audio, meta)
        │
        ├─ insert local_captures (transcript=nil)
        ├─ enqueue TranscribeJob
        └─ reply 202 with guid
                                  │
                                  ▼
                       BackgroundJobs worker
                       calls Whisper, updates
                       local_captures.transcript,
                       broadcasts companion:device:<id>
                       payload {kind: "capture_transcribed", guid}
                                  │
                                  ▼
[Mac]  RealtimeChannel.handle(message)
   │   captures source refreshes affected row
   │
[Agent layer]  morning brief / CRM / todos reads local_captures
               on existing cadence
```

## Error handling

| Failure | Behavior |
|---|---|
| Mic permission denied | Recorder state becomes `.error(.permission(.mic))`. Bar collapses; Capture source flips to `needsAttention("capture_mic_denied")`. Detail pane shows focused unblock with deep link. |
| Screen Recording permission denied | Same as above but `needsAttention("capture_screen_recording_denied")`. |
| Disk full / encoder failure | Recorder cancels; partial file deleted; bar shows brief inline error toast; state returns to idle. |
| Upload transport failure | Audio file moves to `captures/pending/`. Retried on next launch + every 5 min. Detail pane surfaces "1 capture pending upload" row. |
| Whisper job failure | Row stays with `transcript=nil`. Detail pane shows a re-transcribe button per capture. |
| App quit / crash during recording | On next launch, detect orphaned `.m4a` in captures dir, auto-upload as a pending capture (best-effort recovery). |

## Testing

* `CaptureRecorderTests` — state-machine transitions; the `.m4a`
  is valid AAC after Stop; the meter tap delivers non-zero levels
  for synthetic input.
* `CaptureUploaderTests` — 202 path inserts the pending row;
  transport error keeps the file + schedules a retry; 4xx surfaces
  error state without retrying.
* `CapturesSourceTests` — sidebar state reflects recorder +
  uploader correctly; `needsAttention` reasons map to the right
  permission hints.
* `CapturesIngestTest` (server) — multipart accept; happy-path
  Whisper mock fills transcript; `on_conflict :replace` updates
  transcript without re-inserting; PubSub broadcast fires on
  successful transcription.

## Open questions deferred to follow-ups

* Whisper provider configuration — start with OpenAI, gate on env;
  self-hosted `whisper.cpp` on Fly is a follow-up if cost / privacy
  push us there.
* Audio storage location — `audio_bytes` bytea in v1 is fine for
  short meetings (<50MB). Long meetings will need object-storage
  refs (Fly volumes or external). Migrate when the first user
  hits the row-size pain.
* Open-loop extractor prompt tuning — captures may benefit from a
  more-specific extractor than the generic notes / voice memo path.
