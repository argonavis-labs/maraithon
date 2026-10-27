# People network

Implemented 2026-09-07 for web, iOS, and the macOS companion. The main surface
is a two-dimensional explorer based on actual connected communication. A list
alternative, upcoming meetings, person evidence, and linked open todos support
meeting preparation and deciding what to do next.

## Subsystem boundaries

`Maraithon.PeopleNetwork` owns the projection. Recurring discovery checks every
ten minutes, starting thirty seconds after runtime startup. It selects at most
25 users per pass. `people_network_refresh` jobs use the dedicated
`people_network` queue, one runner slot, and a database-coordinated global
rate-limit key. The general, provider, and model runners do not consume this
queue. No LLM is involved in graph construction.

`ReadRepo` reserves one extra database connection for scanning and staging.
Queries have a four-second statement timeout and a 500ms lock timeout. Workers
run at low BEAM scheduling priority. Source pages contain at most 1,000 rows,
with a 90-second read budget, 100,000-event cap, and 15,000-observed-person cap.
Exceeding a cap fails the refresh rather than publishing an incomplete graph.
Upcoming Google Calendar reads share a separate 20-second total budget, over
at most ten connected Google accounts and 100 primary-calendar events each.

The worker builds immutable generations and indexed per-person profiles for
30, 90, and 180 days. A short transaction proves the job's current task lease,
checks privacy-erasure state and generation validity, then publishes a snapshot
pointer and the existing CRM communication/rank summaries together. Failed
refreshes retain the last valid snapshot. Superseded and abandoned generations
older than one hour are removed when the next refresh starts.

Source ingestion does not trigger full graph scans. The old downstream score
and graph handlers delegate to this queue for compatibility; regular ingestion
no longer enqueues those two scans. Existing Chief of Staff consumers read the
stored CRM summary fields and never wait for People to refresh.

This is workload isolation within the existing deployment, not a separate
Cloud Run service. It still shares PostgreSQL and BEAM resources. Production
latency and resource usage have not been measured; the design bounds work but
does not establish a zero-overhead guarantee.

## Evidence and identity

- Local message mirrors supply iMessage/SMS and other mirrored message sources.
  Gmail and Slack use durable CRM observations, including observations not yet
  processed by relationship learning. Historical calendar records supply shared
  context; local calendar mirrors and fresh Google reads supply upcoming events.
- User identities and archived people are excluded. Merged identities resolve
  to their survivor. Ambiguous shared handles are not guessed. New participants
  receive stable `observed_…` IDs and can appear without creating CRM records.
- Stable source IDs deduplicate messages mirrored across devices. Calendar
  occurrence IDs deduplicate matching local copies. Upcoming duplicates for a
  person also collapse on start time and title.
- Direct communication receives decayed, daily-capped weight. Two-way contact
  gets more weight; inbound-only communication gets less. Slack DM attribution
  uses observed peers from that DM channel over the available history.
- Shared conversations and calendar co-presence produce weaker person-to-person
  edges only for small groups. These edges describe observed shared context,
  not a verified personal relationship or proof of meeting attendance.
- Future meetings never enter historical communication counts or ranking.
  Calendar records and todos never count as messages. Declined/cancelled Google
  meetings and all-day events are omitted from upcoming meetings.
- Profiles retain eight recent source references, five upcoming meetings, and
  24 strongest neighboring people. Selected-person reads fetch source excerpts
  capped at 700 characters and at most twelve open linked todos. Device-encrypted
  message bodies and calendar titles are not exposed as plaintext.

Statement-level deletion triggers on messages, calendar mirrors, contact mirrors,
and observations remove the user's cached generations and evidence. A generation
exists before source reads start, so a concurrent purge revokes an in-flight
build too. Person identity edits/merges/deletion invalidate existing generations.
Full user erasure includes all three projection tables. Privacy invalidation can
temporarily show the preparing state until the next refresh.

## Read contract

Authenticated endpoints, scoped by the existing session/device token:

| Client | Network | Person |
| --- | --- | --- |
| iOS | `GET /api/mobile/people/network` | `GET /api/mobile/people/network/:node_id` |
| macOS | `GET /api/v1/companion/people/network` | `GET /api/v1/companion/people/network/:node_id` |

Network query parameters are `days` (30/90/180, default 30), `q` (up to 160
characters), and `focus` (opaque node ID). The payload contains `status`,
`nodes`, `edges`, `meetings`, `people_count`, and, when ready, generation and
freshness timestamps, source counts, and warnings. `calendar_unavailable`
means an upcoming calendar fetch failed; available synced meetings still appear.

The default response contains the top sixty ranked people. Search queries the
entire projected directory but returns at most sixty matches. Focusing a person
adds that person and up to 24 neighbors, for at most 85 visible people. This is
a bounded explorer, not a paginated full-directory export. Each edge has an
opaque ID, endpoint IDs (`you` identifies the user), weight, kind, and evidence.
Person responses are wrapped in `{"person": …}`; missing nodes return 404.
Dates are ISO-8601 strings. Native decoders treat IDs as strings, not UUIDs.

Web LiveView reads the same projection directly at `/operator/people`; the
existing management interface is preserved at `/operator/people/manage`.
The new local `apps/people-network` Swift package shares native rendering,
decoding, cancellation, and selection state. Clients supply their established
authenticated HTTP clients and todo navigation. iOS restores a People tab;
macOS adds People to the sidebar. Native desktop contact management opens the
web management screen. iOS retains native contact management.

Graphs draw only on changes and interaction. Static collision relaxation is
bounded to visible nodes, with no continuous simulation. Active native views
and connected LiveViews refresh snapshots every minute. Search/window changes
and person selection perform bounded reads, never source scans or PageRank.
Dates render in the device/browser timezone. Person rows and evidence controls
provide keyboard/VoiceOver alternatives to clicking canvas connections.

## Verification and limits

- `make build` and `mix assets.build` passed.
- XcodeGen generation passed for both native projects.
- Companion `swift build` and iOS simulator `xcodebuild … build` passed.
- The new migration applied to local `maraithon_dev`; three tables and five
  invalidation/deletion triggers were confirmed in the local catalog.
- No automated tests were run or changed, per `docs/development-mode.md`.
- The local database has no users or connected-source data, so actual graph
  quality, production freshness, and performance under real traffic remain
  manual validation work after deployment. Nothing has been deployed or pushed.

Coverage is limited to what the existing connectors and mirrors have retained.
Historical Google observations may describe an earlier event state; a local
calendar mirror does not carry RSVP or cancellation state. Cross-provider
historical calendar duplicates without a common occurrence ID can remain.
Deleted Slack originals can remain in historical counts until the underlying
original observation is purged; mutation observations themselves are excluded.
Global Slack IDs and existing phone normalization retain the repository's
identity assumptions. These limitations should guide the first real-data review.
