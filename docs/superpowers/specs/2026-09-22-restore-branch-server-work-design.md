# Restore the Sep 11 server work from `codex/runner-desktop` onto `main`

Status: draft for Kent's review, 2026-09-22.

## Why this exists

From Sep 9 to Sep 11 the server was deployed from the `codex/runner-desktop`
worktree. On Sep 13 the "deploy only from `main` via CI" rule took effect and
`main`'s Sep 13 squash (`a1eaf28a`) replaced production. That squash carried
the Mac companion, the assistant model setting, and direct calendar booking,
but not the rest of the branch's server work. Production has been running
without it since Sep 14.

Evidence that this is real loss, not a rename:

- `git cat-file -e main:<path>` fails for `lib/maraithon/fiber.ex`,
  `lib/maraithon/crm/fiber_enrichment.ex`, `lib/maraithon_web/live/person_live.ex`,
  `lib/maraithon/google_contacts.ex`, `lib/maraithon/google_access.ex`,
  `lib/maraithon/todos/calendar_blocks.ex`.
- `main`'s People page is the older graph-first page: no `sort:` option on
  `Crm.list_people/2`, no `/operator/people/:id` route.
- The calendar check-in failure ("Calendar check-in model synthesis failed")
  ran at 36 to 47 per day, dropped to zero on Sep 12 and 13 while the branch
  was deployed, and returned on Sep 14. It is at 34 today.
- Production `schema_migrations` equals `main`'s migration files, and the
  branch adds no migrations, so nothing here needs a migration.

Kent's decisions so far: restore Fiber enrichment and the person page; stage
the work in three slices, each compiled, deployed through CI, and verified in
production before the next starts. The Electron app itself is retired and
stays out (see `CLAUDE.md`).

## Scope

In scope (three slices, in order):

1. Calendar check-in budget fix.
2. People list-first page and the full person page.
3. Fiber.ai people enrichment and per-account Google Calendar polling into
   People.

Out of scope, also lost, needs a separate decision (see "Open decisions"):

- Per-account Google permissions page and Google contacts sync into People
  (`a718e663`, `cb7cba8b`, `582e6d34`, `82947372`, `4ce66f98`; about 1,300
  lines).
- Web one-click calendar block on every todo (`24cfc174`, `56ac7be8`,
  `d171731e`; about 600 lines).
- Web todo workspace redesign and the Runner chat components for the web
  (`dcad6d65`, `79e41144`, `5f2357a0`, `7bd71808`, `0d456db7`, `7eb47a6c`,
  `bf8007b0`; about 900 lines plus 42 vendored asset files).

## How each slice is done

Common mechanics:

- One git worktree per slice, branched from current `main`.
- `git cherry-pick -x <commits>` in the order listed. Conflicts are resolved
  by hand using the rules in each slice. A dry run on 2026-09-22 showed which
  commits collide; those collisions are listed below so nothing is a surprise.
- `make build` is the only automated check (project policy: no test runs).
  Dormant tests that the commits carry are kept in the tree.
- Commit to `main`, push, let `deploy-gcp.yml` deploy, then verify in
  production as described. The next slice does not start until the previous
  one is verified. Rollback for any slice is `git revert` of its commits.

### Slice 1: calendar check-in budget fix

Commit: `1e8b81eb` (75 lines in
`lib/maraithon/chief_of_staff/skills/calendar_check_in.ex`). Applies cleanly.

What it changes: the check-in prompt packed full todo serializations for
dozens of todos and exceeded the 128 KB model request cap, so every check-in
failed silently. The fix sends a compact todo shape (nine keys, 240-char
strings), lowers the list caps, and drops the retired Telegram wording and
provider requirement.

Verify: the daily count of "Calendar check-in model synthesis failed" goes to
zero within a day of deploy, and check-ins appear in the brief channels when
the calendar has openings.

### Slice 2: People list-first page and person page

Commits, in order: `e046fefb`, `a27e0735`, `00eacb94`, `a2506646`, and the
`lib/maraithon/people_network.ex` hunk of `6ac888f4` (serve the last
completed network generation while a rebuild runs).

What lands: `Crm.list_people/2` gains `sort:` (affinity default, rank,
recent, name) and `Crm.count_people/2`; `PeopleLive` becomes list-first with a
sort control and 150 ms search, with the network graph on a tab; new
`PersonLive` at `/operator/people/:id` built on `Crm.get_person_for_user/3`,
`PeopleNetwork.Detail.fetch/3` (its `todos/2` becomes public) and
`Crm.UpcomingMeetings`; `PeopleComponents` exports `person_avatar/1`,
`people_table/1`, `initials/1`, `channel_label/1`, `source_name/1`; the
branch's `people_live_test.exs` comes along dormant.

Known conflicts and how they resolve:

- `lib/maraithon_web/live/people_live.ex`: `main` touched it once since the
  split (`a1eaf28a`). Take the branch version, then re-apply `main`'s hunk.
- `lib/maraithon/people_network.ex`: `main` has four later commits (ranking
  query fix, assistant-mail exclusion, cadence). Keep `main`'s code and add
  only the branch's two changes (float rank comparison; serve the last
  completed generation).
- `lib/maraithon_web/live/person_live.ex` conflicts in the dry run only
  because the file was missing; it applies once `e046fefb` is in.

Fiber decoupling: the branch's `PeopleLive` footer calls
`FiberEnrichment.enabled?/0` and `progress/1`, and `PersonLive` calls
`FiberEnrichment.summary/1`. Slice 2 lands without those three references
(footer omitted, `profile` assigned `%{}`); slice 3 restores them.

Verify in production: `/operator/people` shows the list with the sort control
and search, rows link to `/operator/people/:id`, the person page renders
header, interaction history, todos, and meetings; no `PeopleLive` or
`PersonLive` errors in Cloud Logging. Meeting data will be thin until slice 3
polls calendars.

### Slice 3: Fiber enrichment and calendar polling into People

Commits, in order: `472e0ffc`, `8652cbbc`, `6ca6e2a0`, `dff389e7`,
`2c8d4dce`, `bf07db9d`, `c8fcaf49`, and the remaining hunks of `6ac888f4`
(LinkedIn stays in `metadata.fiber`, never in `contact_details`).

What lands:

- `Maraithon.Fiber` (HTTP client: reverse email lookup, kitchen-sink person,
  org credits; 15 s lookup timeout; 404 is "no match"; transport errors
  retried) and `Maraithon.Crm.FiberEnrichment` (per-user backfill job
  `person_enrichment_backfill`: queue `enrichment`, partition `user:<id>`,
  rate-limit key `fiber`, batches of 25 with a 20 s gap, stops when idle;
  cadence 90 d / 60 d / 30 d / 24 h; writes `crm_people.metadata.fiber` and
  fills blank names and the "Title, Company" relationship line).
- `config/runtime.exs`: `config :maraithon, Maraithon.Fiber, api_key:
  System.get_env("FIBER_API_KEY")`; absent key means disabled.
- `scripts/monorepo/deploy-fast`: bind `FIBER_API_KEY=maraithon-fiber-api-key:latest`
  in `runtime_secrets` (the secret exists, created Sep 11).
- `GoogleCalendar.maybe_enqueue_poll/2` and `ingest_events/3`: every Google
  account is polled over a window (Google returns no sync token once
  `timeMin`/`timeMax` are set); the first visit backfills 90 days; the
  `calendar_incremental_sync` job gains a `window` payload ("poll" or
  "backfill"); meetings that did not happen are not counted
  (`Crm.InteractionEvents`).
- `docs/people-enrichment.md` and the branch's `docs/google-accounts.md`
  section on calendar polling.

Integration points on today's `main` (these differ from the branch, so the
hooks are placed by hand):

- The branch hooked `FiberEnrichment.ensure_scheduled/1` and
  `GoogleCalendar.maybe_enqueue_poll/2` into `GoogleContacts` sync and into
  `FreshnessSweep.maybe_refresh_google_contacts/1`. Neither exists on `main`.
  On `main` the hooks go into the Gmail sync completion path in
  `BackgroundJobHandler` (the `gmail_incremental_sync` clause rewritten on
  Sep 21) and a new Google-account hook in `FreshnessSweep`.
- `ConnectedAccounts.preserve_runtime_metadata/2` (keeps `calendar_sync`
  state across hourly token refresh) came from the contacts-sync commit and
  is absent on `main`; slice 3 adds it with `calendar_sync` only.
- `lib/maraithon/connectors/google_calendar.ex` has four Sep 15 commits on
  `main` (assistant-account isolation, exact-account transport binding, watch
  retirement). The polling code is added beside them, not over them; the
  assistant-account exclusion applies to polling too.
- The `lib/maraithon/http.ex` hunks in `6ca6e2a0` and `2c8d4dce` are
  obsolete: `main` already has `post_json/4` with options.
- `lib/maraithon/runtime/background_job_handler.ex` has ten later commits;
  the new `person_enrichment_backfill` clause and the `window` payload read
  are added by hand.

Guards carried over: the People-network invalidation trigger fires on any
update of `display_name`, `contact_details`, `status`, `merged_into_id`, so
enrichment writes only `metadata` and blank names, in batches; the network
serves its last completed generation during rebuilds (slice 2). Fiber cost is
1 credit per hit, 0 per miss, against about 279k credits a month; the backfill
is bounded by batch size, gap, and cadence.

Verify in production: `person_enrichment_backfill` jobs complete and stop
when idle; `crm_people.metadata->'fiber'->>'status'` counts grow across a few
batches; Fiber org credits move by roughly the number of hits; the People
network is not stuck on "being prepared"; `calendar_incremental_sync` jobs
run per Google account with a `window` payload; calendar interaction events
appear and the person page shows meetings; Google Calendar requests do not
trip the request-admission wait or Google quota.

## Risks

- No automated tests run (project policy). Each slice is verified by compile
  and by production behavior, so slices stay small and are deployed one at a
  time.
- Hand-merged conflicts in `background_job_handler.ex`, `google_calendar.ex`,
  and `people_network.ex` are where a mistake would hide. The diff of each
  slice is reviewed file by file before push.
- Slice 3 adds paid API calls and more Google Calendar traffic. Both are
  bounded as described, and the secret can be unbound to disable Fiber
  without a code change.

## Open decisions for Kent

1. Approve this spec as the plan for slices 1 to 3.
2. Whether to schedule the three out-of-scope items afterwards, and in which
   order. Recommendation: Google permissions page plus contacts sync first
   (it feeds People and the assistant), then the web calendar block, then the
   web workspace redesign.
