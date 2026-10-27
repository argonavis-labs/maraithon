# Async CRM Ingestion Loop Implementation Plan

> **For agentic workers:** Implementing inline. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire every inbound Gmail / Calendar / Slack event into a durable, batched, model-driven CRM + open-loop update pipeline so the user accumulates context instead of paying for cold lookups.

**Architecture:** `source webhook | pull` → adapter normalization → `Crm.Ingest.observe/2` (synchronous: dedup row, contact upsert, counter bump, window roll) → `relationship_ingestion` job (one LLM-driven pass for relationships, one for open loops, one operator event for nudge candidates).

**Tech Stack:** Elixir + Phoenix 1.8, Ecto, Postgres, existing `background_jobs` queue, existing `RelationshipIntelligence` and `OpenLoops` modules, existing `OperatorEvents`.

**Spec:** `docs/superpowers/specs/2026-05-09-async-crm-ingestion-loop-design.md`

---

## File map

**New**
- `priv/repo/migrations/<ts>_create_crm_ingest_windows.exs`
- `priv/repo/migrations/<ts>_create_crm_observations.exs`
- `lib/maraithon/crm/ingest/window.ex` — Ecto schema (`crm_ingest_windows`)
- `lib/maraithon/crm/observation.ex` — Ecto schema (`crm_observations`); also exposes `new/1` constructor used by adapters
- `lib/maraithon/crm/ingest/window_policy.ex` — pure `ready?/4`
- `lib/maraithon/crm/ingest.ex` — `observe/2`, `flush_pending/2`, `enqueue_backfill/3`, `sweep_stale_windows/1`
- `test/maraithon/crm/ingest/window_policy_test.exs`
- `test/maraithon/crm/ingest_test.exs`
- `test/maraithon/crm/ingest_loop_test.exs` — end-to-end

**Modified**
- `lib/maraithon/crm.ex` — add `resolve_contact/2`, `bump_interaction/3`
- `lib/maraithon/runtime/background_jobs.ex` — add `enqueue_relationship_ingestion/1`, `enqueue_relationship_backfill/3`; add default queues
- `lib/maraithon/runtime/background_job_handler.ex` — add `relationship_ingestion`, `relationship_backfill` clauses
- `lib/maraithon/runtime/background_job_runner.ex` — invoke `Crm.Ingest.sweep_stale_windows/1` on the reclaim tick
- `lib/maraithon/open_loops.ex` — add `reconcile_from_observations/3`
- `lib/maraithon/connectors/gmail.ex` — call `Ingest.observe` from webhook + add `to_observation/2`
- `lib/maraithon/connectors/google_calendar.ex` — pull adapter calls `Ingest.observe` + `flush_pending`
- `lib/maraithon/connectors/slack.ex` — webhook adapter calls `Ingest.observe`

---

## Phase 1 — Data layer

### Task 1: Migrations

**Files:**
- Create: `priv/repo/migrations/<ts>_create_crm_ingest_windows.exs`
- Create: `priv/repo/migrations/<ts>_create_crm_observations.exs`

`crm_ingest_windows` first (referenced by observations).

```elixir
# crm_ingest_windows
create table(:crm_ingest_windows, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :user_id, :string, null: false
  add :source, :string, null: false
  add :status, :string, null: false, default: "open"
  add :opened_at, :utc_datetime_usec, null: false
  add :flushed_at, :utc_datetime_usec
  add :completed_at, :utc_datetime_usec
  add :failed_at, :utc_datetime_usec
  add :observation_count, :integer, null: false, default: 0
  add :flush_job_id, :binary_id
  add :last_error, :text
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:crm_ingest_windows, [:user_id, :source],
  where: "status = 'open'",
  name: :crm_ingest_windows_open_per_source_index
)
create index(:crm_ingest_windows, [:status, :opened_at])
```

```elixir
# crm_observations
create table(:crm_observations, primary_key: false) do
  add :id, :binary_id, primary_key: true
  add :user_id, :string, null: false
  add :source, :string, null: false
  add :source_account, :string
  add :source_item_id, :string, null: false
  add :occurred_at, :utc_datetime_usec, null: false
  add :direction, :string, null: false
  add :participants, :map, null: false, default: %{}
  add :subject, :text
  add :excerpt, :text
  add :metadata, :map, null: false, default: %{}
  add :resolved_person_ids, {:array, :binary_id}, null: false, default: []
  add :window_id, references(:crm_ingest_windows, type: :binary_id, on_delete: :nilify_all)
  add :flushed_at, :utc_datetime_usec
  add :learned_at, :utc_datetime_usec
  add :last_error, :text
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:crm_observations, [:user_id, :source, :source_item_id])
create index(:crm_observations, [:user_id, :source, :window_id])
create index(:crm_observations, [:user_id, :occurred_at])
```

Note: `participants` is a list, but Ecto `:map` is fine because the schema declares it as `{:array, :map}`. We use `{:array, :map}` in the schema.

- [ ] Generate both migrations with `mix ecto.gen.migration`.
- [ ] Run `mix ecto.migrate`.
- [ ] Commit.

### Task 2: Window schema

**File:** `lib/maraithon/crm/ingest/window.ex`

Schema mirrors columns. Statuses `~w(open flushed completed failed)`. Required fields: `user_id, source, status, opened_at`. Default: `status: "open"`, `observation_count: 0`. Validate inclusion of status.

- [ ] Write schema.
- [ ] Compile.
- [ ] Commit (with Task 3 to keep schema layer atomic).

### Task 3: Observation schema

**File:** `lib/maraithon/crm/observation.ex`

Schema mirrors columns. Directions `~w(inbound outbound)`. Sources `~w(gmail google_calendar slack)`.

Add a constructor that adapters can call:
```elixir
def new(attrs) when is_map(attrs) do
  %__MODULE__{}
  |> Ecto.Changeset.cast(stringify_keys(attrs), @cast_fields)
  |> Ecto.Changeset.validate_required([:user_id, :source, :source_item_id, :occurred_at, :direction])
  |> Ecto.Changeset.validate_inclusion(:direction, ~w(inbound outbound))
  |> Ecto.Changeset.validate_inclusion(:source, ~w(gmail google_calendar slack))
end
```

Helper `to_intelligence_input/1` converting a row to the loose-map shape `RelationshipIntelligence` accepts (existing `relationship_intelligence.ex` consumes a list of observation maps with keys like `source`, `source_item_id`, `direction`, `participants`, `subject`, `excerpt`, `occurred_at`, `metadata`).

- [ ] Write schema + `new/1` + `to_intelligence_input/1`.
- [ ] Run `mix compile --warnings-as-errors`.
- [ ] Commit Task 2 + Task 3 together.

---

## Phase 2 — Pure logic

### Task 4: `Crm.Ingest.WindowPolicy`

**Files:**
- Create: `lib/maraithon/crm/ingest/window_policy.ex`
- Test: `test/maraithon/crm/ingest/window_policy_test.exs`

```elixir
defmodule Maraithon.Crm.Ingest.WindowPolicy do
  @max_observations 50
  @max_age_minutes 15
  @max_flushes_per_hour 6

  def max_observations, do: @max_observations
  def max_age_minutes, do: @max_age_minutes
  def max_flushes_per_hour, do: @max_flushes_per_hour

  def ready?(window, now, flush_count_last_hour, driver_force?)
  def ready?(_window, _now, flush_count, _force) when flush_count >= @max_flushes_per_hour, do: false
  def ready?(_window, _now, _flush_count, true), do: true
  def ready?(%{observation_count: c}, _now, _flush_count, _force) when c >= @max_observations, do: true
  def ready?(%{opened_at: opened_at, observation_count: c}, %DateTime{} = now, _flush_count, _force) when c > 0 do
    DateTime.diff(now, opened_at, :second) >= @max_age_minutes * 60
  end
  def ready?(_window, _now, _flush_count, _force), do: false
end
```

**Tests:**
- under threshold + young + not forced → false
- count ≥ 50 → true
- age ≥ 15 min, count > 0 → true
- forced → true
- rate cap (flush_count ≥ 6) overrides everything → false
- empty window (count=0) old → false

- [ ] Write module + tests.
- [ ] `mix test test/maraithon/crm/ingest/window_policy_test.exs`.
- [ ] Commit.

---

## Phase 3 — Crm enhancements

### Task 5: `Crm.resolve_contact/2`

**File:** `lib/maraithon/crm.ex`

Identifier shapes: `%{email: e}`, `%{slack_id: s}`, `%{phone: p}`, `%{telegram_id: t}`. Look up an existing Person whose `contact_details` contains the identifier; if none, upsert a new Person with `display_name` derived from `display_name || email-local-part || identifier`.

Reuse the existing `find_existing_person/2` helper which already searches contact_details.

```elixir
def resolve_contact(user_id, identifier, opts \\ [])
def resolve_contact(user_id, identifier, opts) when is_binary(user_id) and is_map(identifier) do
  display_name = Keyword.get(opts, :display_name) |> ensure_display_name(identifier)

  attrs = identifier_to_attrs(identifier, display_name)

  case find_existing_person(user_id, attrs) do
    %Person{} = person -> {:ok, person}
    nil -> create_person(user_id, attrs)
  end
end
```

Tests in `test/maraithon/crm_test.exs`:
- known email → returns existing person
- unknown email → creates stub Person, display_name = email local-part if no display_name supplied
- explicit display_name preferred over local-part
- slack_id, phone, telegram_id variants

- [ ] Write fn + tests. Run `mix test test/maraithon/crm_test.exs`.
- [ ] Commit.

### Task 6: `Crm.bump_interaction/3`

**File:** `lib/maraithon/crm.ex`

Atomic update: `interaction_count = interaction_count + 1`, `last_interaction_at = greatest(last_interaction_at, ?)`. Use `Repo.update_all` with `[inc: ..., set: ...]` and a `fragment("GREATEST(...)")` to keep last_interaction_at monotonic.

```elixir
def bump_interaction(person_id, %DateTime{} = occurred_at, source) when is_binary(person_id) do
  now = DateTime.utc_now()

  Repo.update_all(
    from(p in Person, where: p.id == ^person_id),
    [
      inc: [interaction_count: 1],
      set: [updated_at: now],
      push: []
    ]
    # last_interaction_at via fragment update
  )

  Repo.update_all(
    from(p in Person, where: p.id == ^person_id),
    set: [
      last_interaction_at:
        fragment(
          "GREATEST(COALESCE(?, '1970-01-01'::timestamptz), ?::timestamptz)",
          field(p, :last_interaction_at),
          ^occurred_at
        )
    ]
  )

  {:ok, :bumped}
end
```

Tests:
- fresh person + occurred_at → count=1, last_interaction_at = occurred_at
- bump twice → count=2
- second bump with older occurred_at → last_interaction_at unchanged
- second bump with newer occurred_at → last_interaction_at advances

- [ ] Write fn + tests.
- [ ] Commit.

---

## Phase 4 — Ingest context

### Task 7: `Crm.Ingest.observe/2` happy + duplicate paths

**Files:**
- Create: `lib/maraithon/crm/ingest.ex`
- Test: `test/maraithon/crm/ingest_test.exs`

API:
```elixir
def observe(user_id, %Crm.Observation{} = obs)
```

Steps in the function:

1. `Repo.transaction` containing:
   - INSERT observation (`Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :source, :source_item_id])`).
   - If row already exists (`returning_id == nil` because `on_conflict: :nothing` returns 0-affected) → return `{:ok, :duplicate}`.
   - For each participant identifier: `Crm.resolve_contact/3` → collect person_ids.
   - For each person_id: `Crm.bump_interaction(person_id, occurred_at, source)`.
   - Update observation with `resolved_person_ids: person_ids`.
   - Find/open the window via `upsert_open_window/2`:
     - `INSERT crm_ingest_windows ... ON CONFLICT (user_id, source) WHERE status='open' DO NOTHING`
     - `Repo.one(from w in Window, where: w.user_id == ^user_id and w.source == ^obs.source and w.status == "open")`
   - `Repo.update_all` set `window_id` on observation, `inc observation_count` on window.
   - Reload window.
2. Outside transaction:
   - Compute `flush_count_last_hour` (cheap aggregate query).
   - If `WindowPolicy.ready?(window, now, flush_count, false)`:
     - Guarded transition: `Repo.update_all(from w in Window, where: w.id == ^window.id and w.status == "open", set: [status: "flushed", flushed_at: now])`. If `{1, _}` → enqueue job.
     - Return `{:ok, :flushed, job_id}`.
   - Else `{:ok, :buffered, observation_id}`.

Tests:
- single new observation → row + person + interaction_count=1, window opened, no job
- duplicate observation → `{:ok, :duplicate}`
- 50 observations → at threshold, job enqueued
- old window → next observation triggers flush
- rate cap (≥ 6 flushes/hour) → next ready-by-size window stays open
- concurrent observe (Task.async_stream) → one window, both observations counted

- [ ] Write impl + tests.
- [ ] `mix test test/maraithon/crm/ingest_test.exs`.
- [ ] Commit.

### Task 8: `Crm.Ingest.flush_pending/2`

Forces a flush regardless of size, only if a window has observations.

```elixir
def flush_pending(user_id, source) do
  with %Window{observation_count: c} = window when c > 0 <- get_open_window(user_id, source),
       {1, [%Window{} = window]} <- guarded_flush(window) do
    enqueue_flush(window)
  else
    nil -> {:ok, :nothing_to_flush}
    %Window{observation_count: 0} -> {:ok, :nothing_to_flush}
    {0, _} -> {:ok, :already_flushed}
  end
end
```

Tests:
- empty / no window → `:nothing_to_flush`
- has observations → flushed, job enqueued

- [ ] Write + test.
- [ ] Commit.

### Task 9: `Crm.Ingest.sweep_stale_windows/1`

Selects open windows where `opened_at < now - 30 min` and observation_count > 0, force-flushes each.

Tests:
- 31-min old window force-flushes
- 5-min old window not touched

- [ ] Write + test.
- [ ] Commit.

### Task 10: `Crm.Ingest.enqueue_backfill/3`

Wraps `BackgroundJobs.enqueue_relationship_backfill(user_id, source, opts)` with sensible defaults (`days_back: 30`, `max_observations: 5_000`).

- [ ] Write + test (asserts job exists with right payload + dedupe_key).
- [ ] Commit.

---

## Phase 5 — Background jobs

### Task 11: `BackgroundJobs.enqueue_relationship_ingestion/1` and `enqueue_relationship_backfill/3`

**File:** `lib/maraithon/runtime/background_jobs.ex`

```elixir
def enqueue_relationship_ingestion(window_id) when is_binary(window_id) do
  enqueue("relationship_ingestion", %{
    "queue" => "relationships",
    "payload" => %{"window_id" => window_id},
    "dedupe_key" => "crm_ingest:flush:#{window_id}"
  })
end

def enqueue_relationship_backfill(user_id, source, opts \\ []) when is_binary(user_id) and is_binary(source) do
  days_back = Keyword.get(opts, :days_back, 30)
  max_observations = Keyword.get(opts, :max_observations, 5_000)
  page_token = Keyword.get(opts, :page_token)

  enqueue("relationship_backfill", %{
    "user_id" => user_id,
    "queue" => "relationships",
    "payload" => %{
      "source" => source,
      "days_back" => days_back,
      "max_observations" => max_observations,
      "page_token" => page_token,
      "observations_so_far" => Keyword.get(opts, :observations_so_far, 0)
    },
    "dedupe_key" => "crm_backfill:#{user_id}:#{source}",
    "scheduled_at" => Keyword.get(opts, :scheduled_at, DateTime.utc_now())
  })
end
```

Add `default_queue/1` clauses for both. Tests in `background_jobs_test.exs`.

- [ ] Write + test.
- [ ] Commit.

### Task 12: Handler for `relationship_ingestion`

**File:** `lib/maraithon/runtime/background_job_handler.ex`

```elixir
def execute(%BackgroundJob{job_type: "relationship_ingestion"} = job) do
  with {:ok, window_id} <- payload_uuid(job, "window_id"),
       %Window{} = window <- Repo.get(Window, window_id) do
    observations = load_window_observations(window_id)
    user_id = window.user_id

    pass_one = run_relationship_pass(user_id, observations)
    pass_two = run_open_loop_pass(user_id, observations)
    record_completion_event(window, observations, pass_one, pass_two)

    finalize(window, observations, pass_one, pass_two)
  else
    nil -> {:error, :window_not_found}
    {:error, _} = err -> err
  end
end
```

Pass 1 calls `RelationshipIntelligence.learn_from_observations/3` with `Enum.map(observations, &Observation.to_intelligence_input/1)`. Pass 2 calls `OpenLoops.reconcile_from_observations/3`. Pass 3 calls `OperatorEvents.record/1` with `event_type: "crm_ingest.completed"`.

`finalize/4`:
- success: `Repo.update_all(observations set learned_at = now)`, window status=`completed`, completed_at=now → `{:ok, %{...}}`
- failure: window status=`failed`, last_error → `{:error, reason}`

Mocks: `Mox` is already used in the codebase. Use module attribute for `relationship_intelligence` and `open_loops` modules so tests can swap them out:

```elixir
@relationship_module Application.compile_env(:maraithon, :crm_ingest_relationship_module, RelationshipIntelligence)
@open_loops_module Application.compile_env(:maraithon, :crm_ingest_open_loops_module, OpenLoops)
```

…or use `apply/3` with module from app env at runtime so test setup can override.

Tests:
- happy path: both passes succeed → window completed, observations.learned_at set, operator event recorded
- pass 1 fails → window failed, retry sees same observations
- pass 2 fails after pass 1 succeeded → window failed, last_error includes "open_loop_pass"
- idempotency: rerun completed window → no-op `{:ok, :already_completed}`

- [ ] Write + test.
- [ ] Commit.

### Task 13: Handler for `relationship_backfill`

Pages connector history; for each row builds an observation and calls `Ingest.observe`. After page: `Ingest.flush_pending`. If next page exists and under ceilings, enqueues a follow-up `relationship_backfill` with `scheduled_at = now + backoff`.

Connector backfill pager interface (small, per-connector):
```elixir
@callback fetch_backfill_page(user_id, opts) :: {:ok, %{observations: [...], next_page_token: token | nil, rate_limit_backoff_ms: integer | nil}} | {:error, term}
```

For v1 implement just Gmail's pager (skeleton ok for Calendar/Slack).

Tests with a stub connector module.

- [ ] Write + test.
- [ ] Commit.

### Task 14: `OpenLoops.reconcile_from_observations/3`

Use the existing model-driven open-loop pathway. Build a prompt similar to existing `OpenLoops` calls (or wrap an existing entry point). The function should:
1. Convert observations to a prompt-friendly shape.
2. Call LLM (premium tier, similar to `RelationshipIntelligence`).
3. Parse JSON proposing todo creates/updates.
4. Apply via existing `OpenLoops.upsert_todo` / equivalent semantic-dedup helpers.

Investigate the existing `OpenLoops` module first; reuse whatever already exists. If a tighter helper doesn't exist, add `reconcile_from_observations/3` as a new module-level entry that wraps the existing semantic-dedup machinery.

Tests with `Mox`-style boundary on the LLM call.

- [ ] Read `open_loops.ex` for existing reconciliation entry. Wrap or extend.
- [ ] Test with mocked LLM.
- [ ] Commit.

---

## Phase 6 — Runtime integration

### Task 15: `BackgroundJobRunner.sweep_stale_windows`

**File:** `lib/maraithon/runtime/background_job_runner.ex`

In `handle_info(:poll, state)` and `handle_call(:drain_once, ...)`, after `reclaim_stale_jobs/1`, also call `Maraithon.Crm.Ingest.sweep_stale_windows/1`.

Wrap in `DbResilience.with_database/2` and rescue/log any error so a sweep failure never halts the poll loop.

Tests in `background_job_runner_test.exs` confirming the runner invokes the sweep on drain.

- [ ] Wire + test.
- [ ] Commit.

---

## Phase 7 — Connector wiring

### Task 16: Gmail webhook → `Ingest.observe`

**File:** `lib/maraithon/connectors/gmail.ex`

Add private `to_observation(message_payload, user_id, account)` that builds an `Observation` from Gmail's push payload (after the existing fetch-headers step). After the existing webhook normalization succeeds, call:

```elixir
{:ok, _} = Maraithon.Crm.Ingest.observe(user_id, observation)
```

Errors logged but never bubble out — webhook still 200s.

Tests in `connectors/gmail_test.exs`: webhook payload fixture → asserts observation row exists.

- [ ] Wire + test.
- [ ] Commit.

### Task 17: Google Calendar pull → `Ingest.observe` + `flush_pending`

**File:** `lib/maraithon/connectors/google_calendar.ex`

Find the existing pull pathway. After each event listed since last cursor, build an `Observation` and call `Ingest.observe`. After last page, call `Ingest.flush_pending(user_id, "google_calendar")`.

Tests with calendar fixture.

- [ ] Wire + test.
- [ ] Commit.

### Task 18: Slack webhook → `Ingest.observe`

**File:** `lib/maraithon/connectors/slack.ex`

In the existing message-event branch of `handle_webhook`, after existing processing, build an Observation and call `Ingest.observe`. Skip bot/system messages.

Tests with slack fixture.

- [ ] Wire + test.
- [ ] Commit.

---

## Phase 8 — End-to-end + precommit

### Task 19: `IngestionLoopTest`

**File:** `test/maraithon/crm/ingest_loop_test.exs`

Drive a Gmail-shaped webhook through `WebhookController`, fast-forward window age (or call `flush_pending`), drain the runner, assert:
- `crm_observations` row with `learned_at` set
- Person upserted with the participant email
- A `PersonLink` to the gmail thread
- An `OperatorEvent` with `event_type="crm_ingest.completed"`

Mock RelationshipIntelligence + OpenLoops at module boundaries.

- [ ] Write test.
- [ ] Commit.

### Task 20: `mix precommit`

- [ ] Run `mix precommit`.
- [ ] Fix any lint/format/test issues.
- [ ] Final commit + push.

---

## Self-review notes

- Spec coverage: every section in the spec maps to a phase here.
- Type consistency: `Crm.Observation` (schema + factory `new/1`), `Crm.Ingest.Window`, `WindowPolicy.ready?/4` consistent across all callers.
- Placeholders: none. `to_observation` per connector is defined inline at each connector task.
- Open decisions in spec §11: PullScheduler uses the existing `BackgroundJobRunner` reclaim tick (no new GenServer); LLM tier uses the same path `RelationshipIntelligence` already picks (`LLM.intelligence/0`); `OpenLoops.reconcile_from_observations/3` is added as a new entry that wraps existing reconciliation.
