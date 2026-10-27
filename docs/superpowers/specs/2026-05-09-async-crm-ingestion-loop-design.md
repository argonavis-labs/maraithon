# Async CRM / Relationship Ingestion Loop

Status: Design approved 2026-05-09. Ready for implementation plan.

## 1. Problem

Maraithon already has the durable primitives — `Crm.Person`, `Crm.PersonLink`, `RelationshipIntelligence`, `Memory`, the `background_jobs` queue — but no source path actually feeds them on its own. Today, relationship learning only fires when:

1. The `InboxCalendarAdvisor` agent's periodic scan calls `RelationshipIntelligence` directly, or
2. The user explicitly invokes the `learn_relationship_context` tool from Telegram.

That means "Who is Charlie?" still depends on a one-off lookup or on the Chief of Staff having run a scan recently. Inbound webhooks for Gmail, Calendar, and Slack arrive, get processed for their immediate purpose, and leave no durable trace in the CRM.

We want the opposite: every inbound human contact (email, calendar event, Slack message) updates People, relationship strength, and open loops in the background. By the time the user asks who someone is, the answer is already accumulated.

## 2. Goals

- Every Gmail / Google Calendar / Slack event involving a real human becomes durable CRM state — without blocking webhooks, Telegram replies, or agent runtime.
- `Person.interaction_count` and `last_interaction_at` reflect activity in real time on the synchronous webhook path.
- Richer learning (relationships, memories, links, todo creation/dedup) happens once per rolling window via the existing `RelationshipIntelligence` prompt — premium-tier model, ~10–15 min windows.
- Backfill of bounded historical data (per source, per user) uses the same code path.
- Drift signals ("usually weekly, hasn't been 18 days") emerge as candidate proactive nudges; existing `proactive_check_in` decides whether to send.
- Source transparency for free: every learning event is anchored to a durable observation row.

## 3. Non-goals

- No Telegram or WhatsApp ingestion in v1 (Telegram stays delivery-only; WhatsApp deferred).
- No new proactive delivery surface — nudge candidates ride the existing `OperatorEvents` → `proactive_check_in` pipeline.
- No new admin UI in v1 — the existing background-jobs page and operator events log are sufficient.
- No per-event LLM call. The model only fires once per flushed window.
- No in-memory window state (no GenServer-per-user). All window state is durable in Postgres.
- No new connectors. Only `Gmail`, `GoogleCalendar`, `Slack` are wired.

## 4. Architecture

```
[ webhooks + periodic pull + backfill driver ]
                  |
                  v
       Source adapters (gmail/cal/slack)
       normalize → %Crm.Ingest.Observation{}
                  |
                  v
   Crm.Ingest.observe/2  (synchronous, no LLM)
   • contact resolution → Person upsert (cheap fields only)
   • interaction_count++, last_interaction_at = max
   • write crm_observations row (dedup-keyed)
   • find/open user+source window, increment count
                  |
                  v
   Crm.Ingest.WindowPolicy.ready?/1
   • size threshold (~50 obs)
   • time threshold (~15 min since opened_at)
   • driver-forced flush (pull / backfill page complete)
                  |
                  v
   enqueue("relationship_ingestion", %{window_id: ...})
                  |
                  v
   BackgroundJobHandler "relationship_ingestion"
   1. RelationshipIntelligence.learn_from_observations
      (Person upserts, memories, PersonLinks)
   2. OpenLoops.reconcile_from_observations
      (model-decided todo creates/updates, link to people)
   3. OperatorEvents.record(event_type: "crm_ingest.completed")
      (proactive_check_in picks up drift_signals)
```

### 4.1 Layer responsibilities

- **Source adapters** — stateless mappers from webhook payload or pull-page row to `%Observation{}`. Never write CRM directly. Live inside the existing connector modules (`Maraithon.Connectors.Gmail`, `…GoogleCalendar`, `…Slack`).
- **`Maraithon.Crm.Ingest`** — public API. Owns counters, dedup, and window state. No LLM here.
- **`Maraithon.Crm.Ingest.WindowPolicy`** — pure functions answering "is this window ready?" Stateless.
- **`Maraithon.Crm.Observation` / `Crm.Ingest.Window`** — Ecto schemas. Durable. Single source of truth for observation history and window state.
- **`Maraithon.Runtime.BackgroundJobHandler`** — owns all model calls behind the queue. Two new clauses: `relationship_ingestion`, `relationship_backfill`.
- **`Maraithon.Runtime.BackgroundJobs`** — adds `enqueue_relationship_ingestion/1` and `enqueue_relationship_backfill/3` helpers, mirroring the existing pattern.

## 5. Components and contracts

### 5.1 New modules

#### `Maraithon.Crm.Ingest` (context, public API)

```elixir
@spec observe(user_id :: String.t(), Observation.t()) ::
        {:ok, :buffered, observation_id :: String.t()}
        | {:ok, :flushed, job_id :: String.t()}
        | {:ok, :duplicate}
        | {:error, term()}

@spec flush_pending(user_id :: String.t(), source :: String.t()) ::
        {:ok, :flushed, job_id :: String.t()} | {:ok, :nothing_to_flush}

@spec enqueue_backfill(user_id :: String.t(), source :: String.t(), opts :: keyword()) ::
        {:ok, BackgroundJob.t()} | {:error, term()}

@spec sweep_stale_windows(now :: DateTime.t()) :: {:ok, count :: non_neg_integer()}
```

`observe/2` is the only call adapters need. `flush_pending/2` is for pull drivers and backfill paging. `sweep_stale_windows/1` is a janitor used by the existing `BackgroundJobRunner` reclaim cadence.

#### `Maraithon.Crm.Ingest.Observation` (struct)

```elixir
defstruct [
  :source,             # "gmail" | "google_calendar" | "slack"
  :source_account,     # connected_account id
  :source_item_id,     # gmail message id, calendar event id, slack ts
  :occurred_at,        # DateTime
  :direction,          # :inbound | :outbound
  :participants,       # [%{role: atom, identifier: map, display_name: nil | binary}]
  :subject,            # nil | binary
  :excerpt,            # nil | binary, short — full body fetched in job pass if needed
  :metadata            # map: thread_id, channel, attendee_count, etc.
]
```

`participant.identifier` is one of `%{email: ...}`, `%{slack_id: ...}`, `%{phone: ...}`, etc. The struct mirrors what `RelationshipIntelligence` already accepts as observations, so the job-handler conversion is trivial.

#### `Maraithon.Crm.Ingest.WindowPolicy`

```elixir
@max_observations 50          # premium tier — fewer, richer windows
@max_age_minutes 15
@max_flushes_per_hour 6       # per (user_id, source) rate cap

@spec ready?(window :: Window.t(), now :: DateTime.t(),
             flush_count_last_hour :: non_neg_integer(),
             driver_force? :: boolean()) :: boolean()
```

Pure. No DB. Caller (Ingest) supplies the inputs.

#### `Maraithon.Crm.Observation` (Ecto schema, table `crm_observations`)

```
id                   uuid pk
user_id              text not null
source               text not null     -- "gmail" | "google_calendar" | "slack"
source_account       text
source_item_id       text not null
occurred_at          timestamptz not null
direction            text not null     -- "inbound" | "outbound"
participants         jsonb not null default '[]'
subject              text
excerpt              text
metadata             jsonb not null default '{}'
resolved_person_ids  uuid[] not null default '{}'
window_id            uuid references crm_ingest_windows(id) on delete set null
flushed_at           timestamptz
learned_at           timestamptz
last_error           text
inserted_at          timestamptz not null
updated_at           timestamptz not null

unique (user_id, source, source_item_id)
index  (user_id, source, window_id)
index  (user_id, occurred_at desc)
```

#### `Maraithon.Crm.Ingest.Window` (Ecto schema, table `crm_ingest_windows`)

```
id                   uuid pk
user_id              text not null
source               text not null
status               text not null default 'open'   -- open | flushed | completed | failed
opened_at            timestamptz not null
flushed_at           timestamptz
completed_at         timestamptz
failed_at            timestamptz
observation_count    integer not null default 0
flush_job_id         uuid references background_jobs(id) on delete set null
last_error           text
inserted_at          timestamptz not null
updated_at           timestamptz not null

unique  (user_id, source) where status = 'open'   -- partial unique: only one open window per user+source
index   (status, opened_at)                        -- janitor scan
```

The partial unique index is the linchpin that keeps the open-window invariant under concurrent webhooks.

### 5.2 Existing modules touched

- **`Maraithon.Crm`** — add `resolve_contact(user_id, identifier)` (returns existing Person or upserts a stub with display_name only) and `bump_interaction(person_id, occurred_at, source)` (atomic counter + last_interaction_at update).
- **`Maraithon.RelationshipIntelligence`** — no signature change. Job handler converts our `%Observation{}` rows into the loose-map shape this module already accepts.
- **`Maraithon.OpenLoops`** — add `reconcile_from_observations(user_id, observations, opts)`. Reuses the existing semantic-dedup pathway; just a new entry point that takes observation rows.
- **`Maraithon.Runtime.BackgroundJobHandler`** — two new clauses: `relationship_ingestion`, `relationship_backfill`.
- **`Maraithon.Runtime.BackgroundJobs`** — `enqueue_relationship_ingestion(window_id)` and `enqueue_relationship_backfill(user_id, source, opts)`, both with deterministic `dedupe_key`.
- **`Maraithon.Connectors.Gmail`**, **`…GoogleCalendar`**, **`…Slack`** — webhook handlers (and existing pull paths) call `Ingest.observe/2` after their normalization step. Each connector exposes a small `to_observation/1` (or similar) that builds the struct from its native event shape.

### 5.3 Deliberately not new

- No new GenServer / DynamicSupervisor for window state.
- No new proactive delivery surface.
- No per-event LLM call.

## 6. Data flow

### 6.1 Path 1 — Webhook (push)

```
POST /webhooks/google/gmail
  → Connectors.Gmail.handle_webhook
  → resolve user + account, fetch new message header (id, thread, from/to/cc, date, subject, snippet)
  → build %Observation{source: "gmail", ...}
  → Crm.Ingest.observe(user_id, obs)
       a. INSERT crm_observations
            ON CONFLICT (user_id, source, source_item_id) DO NOTHING
            -- if conflict → return {:ok, :duplicate}, stop
       b. for each participant identifier:
            Crm.resolve_contact(user_id, identifier)
              → upsert Person with display_name only (no LLM)
              → bump_interaction(person_id, occurred_at, source)
       c. update crm_observations.resolved_person_ids
       d. INSERT crm_ingest_windows (..., status='open')
            ON CONFLICT (partial unique on open) DO NOTHING
          then SELECT the open window for (user_id, source)
       e. UPDATE crm_observations SET window_id = ?, then
          UPDATE crm_ingest_windows SET observation_count = observation_count + 1
       f. if WindowPolicy.ready?(window, now, flush_count_last_hour, false):
            -- guarded transition from open → flushed
            UPDATE crm_ingest_windows SET status='flushed', flushed_at=now()
              WHERE id = ? AND status = 'open' RETURNING *
            if rows = 1:
              INSERT background_jobs (job_type='relationship_ingestion',
                payload={window_id}, dedupe_key='crm_ingest:flush:<window_id>')
              return {:ok, :flushed, job_id}
          else:
            return {:ok, :buffered, observation_id}
  → 200 OK to Google
```

The synchronous path stays under ~150 ms in the happy case. Full message body is **not** fetched here — only the header / snippet needed for `Observation`. The job handler can fetch full body if a model pass needs it.

### 6.2 Path 2 — Periodic pull

A small `Crm.Ingest.PullScheduler` cron (or extending the existing Chief of Staff wakeup — TBD in plan) loops connected accounts. For each `(user_id, source, account)`:

1. Read `since_cursor` for that account from `connected_accounts.metadata`.
2. Page the connector's "list since" API.
3. For each row: `Ingest.observe/2` (which may flush mid-page if size threshold hits).
4. Persist new cursor.
5. After last page: `Ingest.flush_pending(user_id, source)` — closes any open window regardless of size.

A pull sweep produces at most one `relationship_ingestion` job per source unless size-threshold flushes happened mid-page.

### 6.3 Path 3 — Flush job (`relationship_ingestion`)

```
BackgroundJobHandler.execute(%BackgroundJob{job_type: "relationship_ingestion"} = job)
  window_id = job.payload["window_id"]
  observations = Repo.all(from o in Observation, where: o.window_id == ^window_id)
  user_id = window.user_id

  -- pass 1: relationship learning
  {:ok, _} = RelationshipIntelligence.learn_from_observations(
    user_id,
    Enum.map(observations, &Observation.to_intelligence_input/1),
    source: "crm_ingest", now: now
  )
  -- → upserts/enriches Person, writes memories, attaches PersonLinks

  -- pass 2: open-loop reconciliation
  {:ok, %{todo_changes: changes}} = OpenLoops.reconcile_from_observations(user_id, observations,
    source: "crm_ingest", now: now)

  -- pass 3: nudge candidates (fire-and-forget)
  OperatorEvents.record(%{
    user_id: user_id,
    source: "crm_ingest",
    event_type: "crm_ingest.completed",
    source_item_id: window_id,
    dedupe_key: "crm_ingest:completed:<window_id>",
    payload: %{
      window_id: window_id,
      people_touched: people_count,
      todos_touched: length(changes),
      drift_signals: drift_signals_from(passes)
    }
  })

  Repo.update_all(from o in Observation, where: o.window_id == ^window_id,
    set: [learned_at: now])
  Window |> Repo.get!(window_id) |> change(status: "completed", completed_at: now) |> Repo.update!()

  {:ok, %{source: "crm_ingest", window_id: window_id, ...}}
```

Two LLM passes per window. Both are idempotent on the input keys, so retries are safe.

### 6.4 Path 4 — Backfill (one-shot per user/source)

A `relationship_backfill` job carries `{user_id, source, days_back, page_token, observations_so_far}`. Each execution:

1. Pages the connector's history list starting at `page_token`.
2. For each row: `Ingest.observe/2`.
3. After the page: `Ingest.flush_pending/2`.
4. If a next page exists and we're under `max_observations` and `days_back` cutoff: re-enqueue a follow-up `relationship_backfill` with the new cursor and `scheduled_at = now + backoff`.
5. Otherwise: complete.

`dedupe_key="crm_backfill:<user_id>:<source>"` ensures only one chain runs per user/source. Backfill produces a stream of normal `relationship_ingestion` jobs.

### 6.5 Three durable consequences

1. **`crm_observations` is the source-transparency trail.** "Why did I learn this about Charlie?" is a query.
2. **Counters update on the synchronous path.** "Charlie just emailed me" is reflected in CRM the moment the webhook arrives, even before the model runs.
3. **A window flushes once.** The partial unique index + the guarded `open → flushed` transition guarantee no double-flush, no lost observations.

## 7. Error handling and edge cases

### 7.1 Synchronous path

- Wrapped in `DbResilience.with_database/2`. On DB failure, return `{:error, :transient}`. Webhook still 200s; source retry + `(user_id, source, source_item_id)` dedup makes that safe.
- Contact resolution is best-effort. No-match identifiers leave `resolved_person_ids` empty; the model handles them at flush time.
- Window-row contention: the partial unique index `(user_id, source) where status = 'open'` prevents two open windows. `INSERT ... ON CONFLICT DO NOTHING` then `SELECT` is the canonical idiom.

### 7.2 Window flush race

```sql
UPDATE crm_ingest_windows SET status='flushed', flushed_at=now()
  WHERE id=$1 AND status='open' RETURNING *;
```

If 0 rows, another caller already flushed — skip the enqueue. The job's `dedupe_key='crm_ingest:flush:<window_id>'` is a backstop.

### 7.3 Job-handler failures

- **Pass 1 fails** → mark window `failed`, set `last_error`, leave `learned_at` null. Existing retry/backoff in `BackgroundJobRunner`. Observations stay attached; retry input is identical.
- **Pass 2 fails after pass 1 succeeded** → don't roll back pass 1. Mark `last_error="open_loop_pass:<reason>"` and return `:error`. Pass 1 is naturally idempotent (same upsert keys); pass 2's todo dedup is already semantic.
- **Pass 3 fails** → log, don't fail the job.
- **Schema validation failures** inside `RelationshipIntelligence` are already returned as structured errors (not exceptions); surface to `last_error`.

### 7.4 Stuck windows

`Crm.Ingest.sweep_stale_windows/1` runs from the existing `BackgroundJobRunner.reclaim_stale_jobs` tick: any `status='open'` window with `opened_at < now - 30 min` is force-flushed.

### 7.5 Dedup across windows

`(user_id, source, source_item_id)` unique on `crm_observations`. A late-arriving duplicate (Pub/Sub replay, pull overlapping with webhook) is a no-op. Same item is never re-learned.

### 7.6 Backfill safety

- `dedupe_key="crm_backfill:<user_id>:<source>"` blocks parallel chains.
- Each page checks rate-limit headers; if hit, the next chained job uses `scheduled_at` with backoff.
- `max_observations` ceiling per backfill (default 5,000) bounds premium-tier spend.

### 7.7 Cost / runaway protection

- Per-user-per-source flush rate cap (`@max_flushes_per_hour = 6`). When exceeded, `WindowPolicy.ready?/4` returns false; observations accumulate. Hard ceiling on worst-case LLM spend during traffic spikes.
- Every `relationship_ingestion` job records `observations_count`, `model_tokens`, `duration_ms` into `result` for the existing background-jobs admin view.

### 7.8 Connector-down / account-disconnected

- Disabled-account webhooks are short-circuited by the connector (existing behavior). No observation row.
- Disconnected during a flush: the model works with what it has; the flush has no synchronous source dependency.

### 7.9 Privacy

- Deleting a `Person` does not delete observations (evidence stays). `resolved_person_ids` arrays are not FK-enforced by Ecto; we just leave the stale uuid (cheap).
- Operator can purge `crm_observations` older than N days per source at need; observations are evidence rows, not the canonical CRM.

## 8. Testing

### 8.1 Unit (pure / fast)

- `WindowPolicy.ready?/4` — table-driven: under-threshold + young → false; over-size → true; over-age → true; rate-cap exceeded → false even if size ready; driver-forced → true.
- `Observation` normalization — adapter inputs (committed Gmail / Calendar / Slack fixtures) → expected `%Observation{}`. One fixture per source × direction × shape (DM vs thread, 1 attendee vs many).
- `Crm.resolve_contact/2` — email / slack_id / phone variants, plus the "no match → stub Person" path.
- `Crm.bump_interaction/3` — atomic counter increment, `last_interaction_at` only moves forward.

### 8.2 Integration (Repo, no LLM — `Mox` for `RelationshipIntelligence` and `OpenLoops`)

- Single observation, fresh user → row in `crm_observations`, Person upserted, `interaction_count=1`, `last_interaction_at` set, window opened with count=1, no job enqueued.
- N observations within window → one window row, all observations attached, one job enqueued at threshold.
- Duplicate `source_item_id` → second `observe/2` returns `{:ok, :duplicate}`, no counter bump, no new row.
- Concurrent webhooks racing → one window row, both observations linked.
- `flush_pending/2` after a pull sweep → status `flushed`, single dedup-keyed job enqueued.
- Stale-window janitor → 31-min-old open window force-flushed.
- Per-user-per-source rate cap → 7th flush in an hour stays open.

### 8.3 Job-handler tests

- Mocked `RelationshipIntelligence.learn_from_observations/3` and `OpenLoops.reconcile_from_observations/3` are called with the exact observations attached to the window.
- Pass 1 success, pass 2 failure → job returns `:error`, window `failed`, `last_error` set, retry sees same observations.
- Pass 1 failure → retry; second attempt with mocked success completes window.
- `OperatorEvents` recorded with `event_type="crm_ingest.completed"` and right counts.
- Idempotency: rerun the same job; second run is a no-op (window already `completed`).

### 8.4 Backfill tests

- 30-day backfill with mocked pager yielding 250 items in 3 pages → produces three `relationship_ingestion` jobs, self-completes.
- `max_observations` ceiling → terminates cleanly, records cutoff.
- Rate-limit response → next page scheduled with backoff.

### 8.5 End-to-end (one slow test)

`IngestionLoopTest`: drives a real Gmail-shaped webhook payload through `WebhookController → Connectors.Gmail.handle_webhook → Ingest.observe`, fast-forwards window age, runs `BackgroundJobRunner.drain_once/0`, and asserts:

- `crm_observations` row with `learned_at` set
- Person upserted with the participant's email
- One PersonLink to the Gmail thread
- One `crm_ingest.completed` operator event

`RelationshipIntelligence` and `OpenLoops` mocked at module boundaries — wiring is the test surface, not model output.

### 8.6 What we do not test

- Model output quality (covered by existing `RelationshipIntelligence` prompt tests).
- Real network calls to Google / Slack — fixtures only.
- Telegram delivery of nudges — `proactive_check_in`'s test surface, untouched here.

### 8.7 Coverage targets

- New modules (`Crm.Ingest`, `Crm.Ingest.WindowPolicy`, `Crm.Observation`, `Crm.Ingest.Window`) — line + branch covered.
- Modified modules — only the new clauses / call sites need new tests; existing tests stay green.

## 9. Migration plan

Two new tables, both additive:

1. `crm_ingest_windows` — created first (referenced by `crm_observations.window_id`).
2. `crm_observations` — references `crm_ingest_windows(id) ON DELETE SET NULL`.

Both backfill to empty. Indexes:

- `crm_observations` unique `(user_id, source, source_item_id)`
- `crm_observations` index `(user_id, source, window_id)`
- `crm_observations` index `(user_id, occurred_at desc)`
- `crm_ingest_windows` partial unique `(user_id, source) where status = 'open'`
- `crm_ingest_windows` index `(status, opened_at)`

No data migration needed. Backfill is opt-in via `enqueue_backfill/3` (no automatic mass-spawn on deploy).

## 10. Rollout

1. Land migrations + new modules + handler clauses + tests. No connector wiring yet — feature is dark.
2. Wire Gmail webhook path. Watch `crm_observations` and `relationship_ingestion` job behavior in admin.
3. Wire Calendar pull path.
4. Wire Slack webhook path.
5. Enable backfill (operator action, per user, ~30 days, one source at a time).
6. Watch the existing background-jobs page for queue depth, error rate, model token cost.

Each step is independent and reversible. If a connector misbehaves, that connector's `to_observation` call gets gated and the rest keeps running.

## 11. Open decisions deferred to the plan

- Whether `PullScheduler` is a new GenServer or an extension of an existing wakeup loop — the plan picks one based on what's already running per user.
- Exact LLM model id for the flush pass — the plan picks the current premium tier from `Maraithon.LLM`.
- Whether `OpenLoops.reconcile_from_observations/3` reuses one existing private function or gets its own pass — the plan looks at the existing `OpenLoops` shape and decides.

## 12. Definition of done

- All new modules implemented and tested per §8.
- Migrations applied; both new tables present in dev and staging.
- Gmail, Calendar, and Slack call `Ingest.observe/2` from their respective adapters.
- `BackgroundJobHandler` handles `relationship_ingestion` and `relationship_backfill`.
- `BackgroundJobRunner` invokes `Crm.Ingest.sweep_stale_windows/1` on its reclaim tick.
- `mix precommit` passes.
- A manual smoke test on staging produces a `crm_ingest.completed` operator event and a Person/PersonLink trail from a real Gmail thread.
