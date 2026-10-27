---
status: ready
---
# Proactive Delivery Planner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert a single per-user model-driven planning stage between proactive *candidate generation* and *Telegram delivery*, so that the assistant decides — once, with full context — what is worth interrupting the user for, what should be folded into one digest, and what should wait.

**Architecture:** Today three proactive paths (`Runtime.ProactiveCheckIn`, `InsightNotifications`, `BriefingCron`/`Briefs`) each call `PushBroker.deliver*` directly and independently. Only the proactive check-in path has a model interrupt decision; insights and briefs hardcode `interrupt_now: true`. The only cross-path guardrail is `PushBroker.suppress_for_rate_limit?`, which *drops* low-urgency sends after 3/hour rather than batching them — and the `PushReceipt` decisions `queued_digest` and `merged` are declared but never produced. This milestone adds a `proactive_candidates` queue that the three sources enqueue into (instead of delivering directly), and a `DeliveryPlanner` that gathers a user's pending candidates, makes one `AssistantHarness.plan_delivery/2` model call assigning each candidate a disposition (`interrupt_now` / `digest` / `hold`), then dispatches: interrupt-now items sent individually, digest items bundled into one message + cards, held items left in the queue. Everything is gated behind a new `:proactive_delivery_planner_enabled` flag (default `false`); the legacy direct-delivery paths stay intact and are exercised by existing tests until the flag is flipped.

**Tech Stack:** Elixir, Phoenix, Ecto/PostgreSQL, ExUnit (`Maraithon.DataCase`), OpenTelemetry via `Maraithon.Tracing`. The LLM is stubbed in tests by passing `llm_complete: fn params -> {:ok, %{content: json}} end` through `opts` (see `test/maraithon/telegram_assistant/proactive_test.exs`).

**Out of scope (explicitly):** No change to insight scoring thresholds, briefing cadence, the inbound chat `Runner`, or the proactive check-in *content* model call. `Proactive.plan_check_in` keeps generating message content; this milestone only changes *where that content goes* (queue vs. direct send) and adds the delivery-disposition decision on top.

---

## File Structure

**New files:**
- `priv/repo/migrations/20260514000000_create_proactive_candidates.exs` — `proactive_candidates` table.
- `lib/maraithon/telegram_assistant/proactive_candidate.ex` — `Maraithon.TelegramAssistant.ProactiveCandidate` Ecto schema.
- `lib/maraithon/telegram_assistant/proactive_queue.ex` — `Maraithon.TelegramAssistant.ProactiveQueue` context: enqueue, list, claim, status transitions, expiry.
- `lib/maraithon/telegram_assistant/delivery_planner.ex` — `Maraithon.TelegramAssistant.DeliveryPlanner`: gather → plan → dispatch.
- `test/maraithon/telegram_assistant/proactive_queue_test.exs`
- `test/maraithon/telegram_assistant/delivery_planner_test.exs`

**Modified files:**
- `lib/maraithon/telegram_assistant.ex` — add `proactive_delivery_planner_enabled?/0` and a thin `enqueue_proactive_candidate/1` delegate.
- `lib/maraithon/telegram_assistant/push_broker.ex` — `deliver_insight/1` and `deliver_brief/1` enqueue instead of delivering when the planner flag is on.
- `lib/maraithon/telegram_assistant/proactive.ex` — `deliver_plan/4` enqueues instead of calling `PushBroker.deliver` when the planner flag is on.
- `lib/maraithon/assistant_harness.ex` — add `plan_delivery/2`, `build_delivery_plan_request/2`, `build_delivery_plan_prompt/1`, `normalize_delivery_plan/1`, and the `@valid_dispositions` module attribute.
- `lib/maraithon/runtime/proactive_check_in.ex` — run `DeliveryPlanner.run_for_due_users/1` each tick when the flag is on.
- `config/config.exs` — default `proactive_delivery_planner_enabled: false` and `proactive_candidate_ttl_minutes`.
- `config/runtime.exs` — `PROACTIVE_DELIVERY_PLANNER_ENABLED` env wiring.
- `test/maraithon/telegram_assistant/proactive_test.exs` — no edits expected; it must keep passing with the flag off (regression guard).

---

# Phase 1 — Candidate queue (schema + context)

Adds the durable queue. No behavior change to any delivery path; nothing reads or writes the table yet outside its own tests.

### Task 1.1: `proactive_candidates` migration

**Files:**
- Create: `priv/repo/migrations/20260514000000_create_proactive_candidates.exs`

- [ ] **Step 1: Write the migration**

Follow the conventions in `priv/repo/migrations/` (binary_id PK, `references(:users, type: :string)`, `:utc_datetime_usec` timestamps — see the `telegram_push_receipts` table inside `..._add_telegram_assistant_runtime.exs`).

```elixir
defmodule Maraithon.Repo.Migrations.CreateProactiveCandidates do
  use Ecto.Migration

  def change do
    create table(:proactive_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      # source: "proactive_check_in" | "insight" | "brief"
      add :source, :string, null: false
      add :source_id, :string
      add :dedupe_key, :string, null: false

      add :title, :string
      add :body, :text, null: false
      add :urgency, :float, null: false, default: 0.0
      add :why_now, :text
      add :structured_data, :map, null: false, default: %{}
      add :telegram_opts, :map, null: false, default: %{}

      # status: "pending" | "planned" | "delivered" | "held" | "expired"
      add :status, :string, null: false, default: "pending"
      # disposition (set by the planner): "interrupt_now" | "digest" | "hold"
      add :disposition, :string
      add :plan_reason, :text

      add :planned_at, :utc_datetime_usec
      add :delivered_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:proactive_candidates, [:user_id, :status])
    create index(:proactive_candidates, [:status, :inserted_at])

    # One live (pending/planned) candidate per (user, dedupe_key); delivered/held/expired
    # rows do not block re-enqueue of the same key later.
    create unique_index(:proactive_candidates, [:user_id, :dedupe_key],
             where: "status IN ('pending', 'planned')",
             name: :proactive_candidates_live_dedupe_index
           )
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `mix ecto.migrate`
Expected: `create table proactive_candidates` and three `create index` lines, no errors. Then `mix ecto.rollback` then `mix ecto.migrate` again to confirm `change/0` is reversible.

- [ ] **Step 3: Commit**

```bash
git add priv/repo/migrations/20260514000000_create_proactive_candidates.exs
git commit -m "Add proactive_candidates table for the delivery planner queue"
```

### Task 1.2: `ProactiveCandidate` schema

**Files:**
- Create: `lib/maraithon/telegram_assistant/proactive_candidate.ex`
- Test: covered by Task 1.3's `proactive_queue_test.exs` (the schema has no behaviour worth a standalone test beyond its changeset, which Task 1.3 exercises through `ProactiveQueue.enqueue/1`).

- [ ] **Step 1: Write the schema**

Mirror `lib/maraithon/telegram_assistant/push_receipt.ex` for style (binary_id PK, `belongs_to :user, User, type: :string`, `~w(...)` constant lists).

```elixir
defmodule Maraithon.TelegramAssistant.ProactiveCandidate do
  @moduledoc """
  A proactive Telegram message candidate awaiting a delivery-planning decision.

  Sources (proactive check-ins, insights, briefs) enqueue candidates instead of
  delivering directly. `Maraithon.TelegramAssistant.DeliveryPlanner` gathers a
  user's pending candidates, asks the model for a disposition per candidate, and
  dispatches them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(proactive_check_in insight brief)
  @statuses ~w(pending planned delivered held expired)
  @dispositions ~w(interrupt_now digest hold)

  schema "proactive_candidates" do
    field :source, :string
    field :source_id, :string
    field :dedupe_key, :string
    field :title, :string
    field :body, :string
    field :urgency, :float, default: 0.0
    field :why_now, :string
    field :structured_data, :map, default: %{}
    field :telegram_opts, :map, default: %{}
    field :status, :string, default: "pending"
    field :disposition, :string
    field :plan_reason, :string
    field :planned_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  def sources, do: @sources
  def statuses, do: @statuses
  def dispositions, do: @dispositions

  @enqueue_required [:user_id, :source, :dedupe_key, :body]
  @enqueue_optional [
    :source_id,
    :title,
    :urgency,
    :why_now,
    :structured_data,
    :telegram_opts,
    :expires_at
  ]

  @doc "Changeset for inserting a new pending candidate."
  def enqueue_changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @enqueue_required ++ @enqueue_optional)
    |> validate_required(@enqueue_required)
    |> put_change(:status, "pending")
    |> validate_inclusion(:source, @sources)
    |> validate_length(:dedupe_key, min: 3, max: 255)
    |> validate_number(:urgency, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :dedupe_key],
      name: :proactive_candidates_live_dedupe_index
    )
  end

  @doc "Changeset for the planner assigning a disposition."
  def plan_changeset(candidate, disposition, reason) do
    candidate
    |> change(%{
      status: "planned",
      disposition: disposition,
      plan_reason: reason,
      planned_at: DateTime.utc_now()
    })
    |> validate_inclusion(:disposition, @dispositions)
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Changeset for a terminal status transition (delivered / held / expired)."
  def status_changeset(candidate, status) when status in @statuses do
    changes = %{status: status}

    changes =
      if status == "delivered", do: Map.put(changes, :delivered_at, DateTime.utc_now()), else: changes

    candidate
    |> change(changes)
    |> validate_inclusion(:status, @statuses)
  end
end
```

- [ ] **Step 2: Verify it compiles**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no errors.

- [ ] **Step 3: Commit**

```bash
git add lib/maraithon/telegram_assistant/proactive_candidate.ex
git commit -m "Add ProactiveCandidate schema"
```

### Task 1.3: `ProactiveQueue` context

**Files:**
- Create: `lib/maraithon/telegram_assistant/proactive_queue.ex`
- Test: `test/maraithon/telegram_assistant/proactive_queue_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Maraithon.TelegramAssistant.ProactiveQueueTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.TelegramAssistant.{ProactiveCandidate, ProactiveQueue}

  setup do
    user_id = "queue-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id}
  end

  defp attrs(user_id, overrides \\ %{}) do
    Map.merge(
      %{
        user_id: user_id,
        source: "insight",
        source_id: "insight-1",
        dedupe_key: "insight:1",
        body: "An insight worth surfacing.",
        urgency: 0.6
      },
      overrides
    )
  end

  test "enqueue/1 inserts a pending candidate", %{user_id: user_id} do
    assert {:ok, %ProactiveCandidate{} = candidate} = ProactiveQueue.enqueue(attrs(user_id))
    assert candidate.status == "pending"
    assert candidate.source == "insight"
    assert candidate.urgency == 0.6
  end

  test "enqueue/1 is idempotent on a live (user_id, dedupe_key)", %{user_id: user_id} do
    assert {:ok, first} = ProactiveQueue.enqueue(attrs(user_id))
    assert {:ok, second} = ProactiveQueue.enqueue(attrs(user_id, %{body: "changed body"}))
    assert first.id == second.id
    # the existing pending row wins; it is not overwritten
    assert second.body == "An insight worth surfacing."
    assert ProactiveQueue.list_pending_for_user(user_id) |> length() == 1
  end

  test "list_pending_for_user/1 returns only pending rows ordered by urgency desc", %{
    user_id: user_id
  } do
    {:ok, low} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "a", urgency: 0.2}))
    {:ok, high} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "b", urgency: 0.9}))
    {:ok, planned} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "c", urgency: 0.5}))
    {:ok, _} = ProactiveQueue.mark_planned(planned, "hold", "not now")

    assert [high.id, low.id] == Enum.map(ProactiveQueue.list_pending_for_user(user_id), & &1.id)
  end

  test "pending_user_ids/1 returns distinct users with pending candidates", %{user_id: user_id} do
    {:ok, _} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "a"}))
    {:ok, _} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "b"}))
    assert ProactiveQueue.pending_user_ids(10) == [user_id]
  end

  test "mark_planned/3 then mark_delivered/1 moves a candidate to delivered", %{user_id: user_id} do
    {:ok, candidate} = ProactiveQueue.enqueue(attrs(user_id))
    {:ok, planned} = ProactiveQueue.mark_planned(candidate, "interrupt_now", "timely")
    assert planned.status == "planned"
    assert planned.disposition == "interrupt_now"
    assert planned.planned_at

    {:ok, delivered} = ProactiveQueue.mark_delivered(planned)
    assert delivered.status == "delivered"
    assert delivered.delivered_at
    assert ProactiveQueue.list_pending_for_user(user_id) == []
  end

  test "expire_stale/1 marks pending candidates past their cutoff as expired", %{user_id: user_id} do
    stale_at = DateTime.add(DateTime.utc_now(), -7200, :second)
    {:ok, stale} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "stale"}))

    # backdate inserted_at so it falls before the cutoff
    Maraithon.Repo.update_all(
      from(c in ProactiveCandidate, where: c.id == ^stale.id),
      set: [inserted_at: stale_at]
    )

    {:ok, _fresh} = ProactiveQueue.enqueue(attrs(user_id, %{dedupe_key: "fresh"}))

    assert {1, _} = ProactiveQueue.expire_stale(DateTime.add(DateTime.utc_now(), -3600, :second))
    assert ProactiveQueue.list_pending_for_user(user_id) |> Enum.map(& &1.dedupe_key) == ["fresh"]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/proactive_queue_test.exs`
Expected: FAIL — `Maraithon.TelegramAssistant.ProactiveQueue` is undefined.

- [ ] **Step 3: Write the context**

```elixir
defmodule Maraithon.TelegramAssistant.ProactiveQueue do
  @moduledoc """
  Durable queue of proactive Telegram message candidates.

  Sources enqueue candidates here; `Maraithon.TelegramAssistant.DeliveryPlanner`
  drains the queue per user, assigns each candidate a delivery disposition, and
  dispatches them. The `(user_id, dedupe_key)` live-uniqueness index makes
  `enqueue/1` idempotent for as long as a candidate is still pending or planned.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  @doc """
  Inserts a new pending candidate.

  If a live (pending/planned) candidate already exists for the same
  `(user_id, dedupe_key)`, returns `{:ok, existing}` without modifying it.
  """
  def enqueue(attrs) when is_map(attrs) do
    %ProactiveCandidate{}
    |> ProactiveCandidate.enqueue_changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, candidate} ->
        {:ok, candidate}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :user_id) and dedupe_conflict?(errors) do
          {:ok, fetch_live(attrs[:user_id] || attrs["user_id"], attrs[:dedupe_key] || attrs["dedupe_key"])}
        else
          {:error, changeset}
        end
    end
  end

  defp dedupe_conflict?(errors) do
    Enum.any?(errors, fn
      {:user_id, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp fetch_live(user_id, dedupe_key) do
    ProactiveCandidate
    |> where([c], c.user_id == ^user_id and c.dedupe_key == ^dedupe_key)
    |> where([c], c.status in ["pending", "planned"])
    |> Repo.one()
  end

  @doc "Pending candidates for a user, highest urgency first."
  def list_pending_for_user(user_id) when is_binary(user_id) do
    ProactiveCandidate
    |> where([c], c.user_id == ^user_id and c.status == "pending")
    |> order_by([c], desc: c.urgency, asc: c.inserted_at)
    |> Repo.all()
  end

  @doc "Distinct user ids that currently have at least one pending candidate."
  def pending_user_ids(limit) when is_integer(limit) and limit > 0 do
    ProactiveCandidate
    |> where([c], c.status == "pending")
    |> select([c], c.user_id)
    |> distinct(true)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Records the planner's disposition for a candidate."
  def mark_planned(%ProactiveCandidate{} = candidate, disposition, reason) do
    candidate
    |> ProactiveCandidate.plan_changeset(disposition, reason)
    |> Repo.update()
  end

  @doc "Marks a candidate delivered."
  def mark_delivered(%ProactiveCandidate{} = candidate) do
    candidate
    |> ProactiveCandidate.status_changeset("delivered")
    |> Repo.update()
  end

  @doc "Marks a candidate held (planned but intentionally not sent this cycle)."
  def mark_held(%ProactiveCandidate{} = candidate) do
    candidate
    |> ProactiveCandidate.status_changeset("held")
    |> Repo.update()
  end

  @doc """
  Marks every pending candidate inserted before `cutoff` as expired.
  Returns `{count, nil}` like `Repo.update_all/3`.
  """
  def expire_stale(%DateTime{} = cutoff) do
    ProactiveCandidate
    |> where([c], c.status == "pending" and c.inserted_at < ^cutoff)
    |> Repo.update_all(set: [status: "expired", updated_at: DateTime.utc_now()])
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/proactive_queue_test.exs`
Expected: PASS — 6 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/telegram_assistant/proactive_queue.ex test/maraithon/telegram_assistant/proactive_queue_test.exs
git commit -m "Add ProactiveQueue context for proactive delivery candidates"
```

---

# Phase 2 — Sources enqueue (flag-gated)

Each source learns to enqueue a candidate instead of delivering directly — but only when `proactive_delivery_planner_enabled?/0` is true. With the flag off (the default, and the state every existing test runs in), all three paths behave exactly as today.

### Task 2.1: Feature flag + `enqueue_proactive_candidate/1` delegate

**Files:**
- Modify: `lib/maraithon/telegram_assistant.ex` (add functions next to `unified_push_enabled?/0` at line 47)
- Test: `test/maraithon/telegram_assistant/proactive_queue_test.exs` (extend)

- [ ] **Step 1: Write the failing test**

Append to `test/maraithon/telegram_assistant/proactive_queue_test.exs`:

```elixir
  describe "TelegramAssistant flag + delegate" do
    test "proactive_delivery_planner_enabled? reflects config" do
      original = Application.get_env(:maraithon, :telegram_assistant, [])

      on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, original) end)

      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.put(original, :proactive_delivery_planner_enabled, true)
      )

      assert Maraithon.TelegramAssistant.proactive_delivery_planner_enabled?()

      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.put(original, :proactive_delivery_planner_enabled, false)
      )

      refute Maraithon.TelegramAssistant.proactive_delivery_planner_enabled?()
    end

    test "enqueue_proactive_candidate/1 delegates to ProactiveQueue", %{user_id: user_id} do
      assert {:ok, candidate} =
               Maraithon.TelegramAssistant.enqueue_proactive_candidate(attrs(user_id))

      assert candidate.status == "pending"
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/proactive_queue_test.exs`
Expected: FAIL — `proactive_delivery_planner_enabled?/0` is undefined.

- [ ] **Step 3: Implement the flag and delegate**

In `lib/maraithon/telegram_assistant.ex`, immediately after the `unified_push_enabled?/0` function (ends around line 54), add:

```elixir
  @doc """
  Whether the model-driven proactive delivery planner is enabled.

  When `false` (the default), the legacy direct-delivery paths in `PushBroker`
  and `Proactive` run unchanged. When `true`, those paths enqueue
  `ProactiveCandidate` rows for `DeliveryPlanner` to plan and dispatch.
  """
  def proactive_delivery_planner_enabled? do
    :maraithon
    |> Application.get_env(:telegram_assistant, [])
    |> Keyword.get(:proactive_delivery_planner_enabled, false)
    |> case do
      true -> true
      _ -> false
    end
  end

  @doc "Delegates to `Maraithon.TelegramAssistant.ProactiveQueue.enqueue/1`."
  defdelegate enqueue_proactive_candidate(attrs),
    to: Maraithon.TelegramAssistant.ProactiveQueue,
    as: :enqueue
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/proactive_queue_test.exs`
Expected: PASS — 8 tests, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/telegram_assistant.ex test/maraithon/telegram_assistant/proactive_queue_test.exs
git commit -m "Add proactive delivery planner flag + enqueue delegate"
```

### Task 2.2: `PushBroker.deliver_insight/1` enqueues when the flag is on

**Files:**
- Modify: `lib/maraithon/telegram_assistant/push_broker.ex:23-68` (`deliver_insight/1`)
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (create — this file also hosts Phase 3 tests)

- [ ] **Step 1: Write the failing test**

Create `test/maraithon/telegram_assistant/delivery_planner_test.exs`:

```elixir
defmodule Maraithon.TelegramAssistant.DeliveryPlannerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.TelegramAssistant.{ProactiveCandidate, ProactiveQueue, PushBroker}

  setup do
    original = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original,
        telegram_unified_push_enabled: true,
        proactive_delivery_planner_enabled: true
      )
    )

    on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, original) end)

    user_id = "planner-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "987654",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id}
  end

  describe "PushBroker.deliver_insight/1 with planner enabled" do
    test "enqueues a candidate instead of sending", %{user_id: user_id} do
      {:ok, insight} =
        Maraithon.Insights.create_insight(%{
          user_id: user_id,
          title: "Vendor renewal in 3 days",
          summary: "Acme renews Friday; confirm or cancel.",
          status: "open"
        })

      {:ok, delivery} =
        Maraithon.InsightNotifications.Delivery
        |> struct(%{
          user_id: user_id,
          insight_id: insight.id,
          channel: "telegram",
          destination: "987654",
          score: 0.81,
          status: "pending"
        })
        |> Maraithon.Repo.insert()

      assert :ok = PushBroker.deliver_insight(delivery)

      assert [%ProactiveCandidate{} = candidate] = ProactiveQueue.list_pending_for_user(user_id)
      assert candidate.source == "insight"
      assert candidate.source_id == delivery.id
      assert candidate.dedupe_key == "insight_delivery:#{delivery.id}"
      assert candidate.urgency == 0.81

      # delivery stays pending — DeliveryPlanner owns the eventual send
      assert Maraithon.Repo.reload(delivery).status == "pending"
    end
  end
end
```

> Note: confirm the exact `Maraithon.Insights.create_insight/1` signature and `Delivery` field names against `lib/maraithon/insights.ex` and `lib/maraithon/insight_notifications/delivery.ex` while implementing; adjust the fixture to match. The behaviour under test — "a candidate is enqueued, the delivery is not sent" — does not change.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — `deliver_insight/1` still sends; no candidate is enqueued.

- [ ] **Step 3: Modify `deliver_insight/1`**

In `lib/maraithon/telegram_assistant/push_broker.ex`, wrap the existing body of `deliver_insight/1`. Replace lines 23-25:

```elixir
  def deliver_insight(%Delivery{} = delivery) do
    if TelegramAssistant.unified_push_enabled?() do
      delivery = Repo.preload(delivery, :insight)
      payload = Actions.telegram_payload(delivery)
```

with:

```elixir
  def deliver_insight(%Delivery{} = delivery) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_insight_candidate(delivery)

      true ->
        deliver_insight_now(delivery)
    end
  end

  defp deliver_insight_now(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)
```

Then change the closing `else {:fallback, :disabled} end` of the original function (lines 65-67) to just `end` — `deliver_insight_now/1` no longer needs the `unified_push_enabled?` guard because `deliver_insight/1` already checked it.

Add the new private function (place it after `deliver_insight_now/1`):

```elixir
  defp enqueue_insight_candidate(%Delivery{} = delivery) do
    delivery = Repo.preload(delivery, :insight)
    payload = Actions.telegram_payload(delivery)

    case TelegramAssistant.enqueue_proactive_candidate(%{
           user_id: delivery.user_id,
           source: "insight",
           source_id: delivery.id,
           dedupe_key: "insight_delivery:#{delivery.id}",
           title: delivery.insight && delivery.insight.title,
           body: payload.text,
           urgency: delivery.score || 0.0,
           why_now: delivery.insight && delivery.insight.summary,
           structured_data: %{
             "linked_delivery_id" => delivery.id,
             "linked_insight_id" => delivery.insight_id
           },
           telegram_opts: %{
             "parse_mode" => "HTML",
             "reply_markup" => payload.reply_markup
           }
         }) do
      {:ok, _candidate} -> :ok
      {:error, _changeset} -> :ok
    end
  end
```

> `telegram_opts` is stored as a `:map` column, so keys are strings. `DeliveryPlanner` (Task 3.3) converts them back to the keyword list `TelegramResponder.send/3` expects via a shared `telegram_opts_to_keyword/1` helper.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — 1 test, 0 failures.

- [ ] **Step 5: Run the insight delivery regression suite**

Run: `mix test test/maraithon/insight_notifications_test.exs test/maraithon/telegram_assistant/`
Expected: PASS — existing tests run with the planner flag off and the legacy `deliver_insight_now/1` path, unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/maraithon/telegram_assistant/push_broker.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Route insight pushes through the proactive queue when planner is enabled"
```

### Task 2.3: `PushBroker.deliver_brief/1` enqueues when the flag is on

**Files:**
- Modify: `lib/maraithon/telegram_assistant/push_broker.ex:70-82` (`deliver_brief/1`)
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (extend)

- [ ] **Step 1: Write the failing test**

Append a `describe` block to `test/maraithon/telegram_assistant/delivery_planner_test.exs`:

```elixir
  describe "PushBroker.deliver_brief/1 with planner enabled" do
    test "enqueues a brief candidate instead of sending", %{user_id: user_id} do
      {:ok, brief} =
        Maraithon.Briefs.Brief
        |> struct(%{
          user_id: user_id,
          title: "Morning brief",
          summary: "3 things need you today.",
          cadence: "daily",
          status: "pending",
          metadata: %{}
        })
        |> Maraithon.Repo.insert()

      assert :ok = PushBroker.deliver_brief(brief)

      assert [%ProactiveCandidate{} = candidate] = ProactiveQueue.list_pending_for_user(user_id)
      assert candidate.source == "brief"
      assert candidate.source_id == brief.id
      assert candidate.dedupe_key == "brief:#{brief.id}"

      # the brief itself is not marked sent — the planner owns delivery
      assert Maraithon.Repo.reload(brief).status == "pending"
    end
  end
```

> Confirm `Maraithon.Briefs.Brief` field names against `lib/maraithon/briefs/brief.ex` while implementing; adjust the fixture if needed.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — `deliver_brief/1` still delivers; no candidate enqueued.

- [ ] **Step 3: Modify `deliver_brief/1`**

In `lib/maraithon/telegram_assistant/push_broker.ex`, replace `deliver_brief/1` (lines 70-82):

```elixir
  def deliver_brief(%Brief{} = brief) do
    cond do
      not TelegramAssistant.unified_push_enabled?() ->
        {:fallback, :disabled}

      TelegramAssistant.proactive_delivery_planner_enabled?() ->
        enqueue_brief_candidate(brief)

      true ->
        todos = Briefs.todo_digest_todos(brief)

        if todos != [] do
          deliver_todo_digest_brief(brief, todos)
        else
          deliver_standard_brief(brief)
        end
    end
  end

  defp enqueue_brief_candidate(%Brief{} = brief) do
    todos = Briefs.todo_digest_todos(brief)

    {body, structured_data, telegram_opts} =
      if todos == [] do
        payload = Briefs.telegram_payload(brief)

        {payload.text, brief_structured_data(brief),
         %{"parse_mode" => "HTML", "reply_markup" => payload.reply_markup}}
      else
        {Briefs.todo_digest_intro_text(brief, todos),
         brief_structured_data(brief)
         |> Map.put("message_class", "todo_digest")
         |> Map.put("todo_ids", Enum.map(todos, & &1.id))
         |> Map.put("todo_count", length(todos)),
         %{"parse_mode" => "HTML"}}
      end

    case TelegramAssistant.enqueue_proactive_candidate(%{
           user_id: brief.user_id,
           source: "brief",
           source_id: brief.id,
           dedupe_key: "brief:#{brief.id}",
           title: brief.title,
           body: body,
           urgency: 0.7,
           why_now: brief.summary,
           structured_data: structured_data,
           telegram_opts: telegram_opts
         }) do
      {:ok, _candidate} -> :ok
      {:error, _changeset} -> :ok
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — 2 tests, 0 failures.

- [ ] **Step 5: Run the brief delivery regression suite**

Run: `mix test test/maraithon/briefs_test.exs test/maraithon/telegram_assistant/`
Expected: PASS — existing brief tests run with the flag off, unchanged.

- [ ] **Step 6: Commit**

```bash
git add lib/maraithon/telegram_assistant/push_broker.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Route brief pushes through the proactive queue when planner is enabled"
```

### Task 2.4: `Proactive.deliver_plan/4` enqueues when the flag is on

**Files:**
- Modify: `lib/maraithon/telegram_assistant/proactive.ex:119-178` (`deliver_plan/4`)
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (extend)

The proactive check-in's own model call still runs (it generates the message content + which todos matter). When the planner flag is on, instead of `deliver_plan/4` calling `PushBroker.deliver`, it enqueues the generated plan as a `proactive_check_in` candidate. The `DeliveryPlanner` then makes the *delivery* decision (interrupt vs. digest vs. hold) across this candidate and any insight/brief candidates together.

- [ ] **Step 1: Write the failing test**

Append a `describe` block to `test/maraithon/telegram_assistant/delivery_planner_test.exs`:

```elixir
  describe "Proactive.deliver_check_in/2 with planner enabled" do
    test "enqueues the proactive plan instead of delivering it", %{user_id: user_id} do
      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
          telegram_proactive_checkins_enabled: true
        )
      )

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "decision" => "send_now",
               "assistant_message" => "Quick nudge: the Acme contract is still open.",
               "message_class" => "assistant_push",
               "urgency" => 0.7,
               "interrupt_now" => false,
               "dedupe_key" => "proactive:acme",
               "todo_ids" => [],
               "summary" => "Open loop on the Acme contract."
             })
         }}
      end

      assert {:ok, result} =
               Maraithon.TelegramAssistant.deliver_proactive_check_in(user_id,
                 force: true,
                 llm_complete: llm_complete
               )

      assert result["decision"] == "queued"

      assert [%ProactiveCandidate{} = candidate] = ProactiveQueue.list_pending_for_user(user_id)
      assert candidate.source == "proactive_check_in"
      assert candidate.dedupe_key == "proactive:acme"
      assert candidate.body == "Quick nudge: the Acme contract is still open."
      assert candidate.urgency == 0.7
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — `deliver_plan/4` still calls `PushBroker.deliver`; result decision is `"sent_now"`/`"suppressed"`, not `"queued"`.

- [ ] **Step 3: Modify `deliver_plan/4`**

In `lib/maraithon/telegram_assistant/proactive.ex`, at the top of `deliver_plan/4` (line 119), branch before building the `PushBroker` candidate:

```elixir
  defp deliver_plan(user_id, chat_id, plan, opts) do
    trigger = proactive_trigger(user_id, chat_id, opts)
    dedupe_key = plan_dedupe_key(user_id, plan, trigger)

    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      enqueue_plan_candidate(user_id, plan, trigger, dedupe_key)
    else
      deliver_plan_now(user_id, chat_id, plan, trigger, dedupe_key)
    end
  end

  defp enqueue_plan_candidate(user_id, plan, trigger, dedupe_key) do
    case TelegramAssistant.enqueue_proactive_candidate(%{
           user_id: user_id,
           source: "proactive_check_in",
           source_id: Map.get(trigger, "id"),
           dedupe_key: dedupe_key,
           title: "Maraithon check-in",
           body: Map.fetch!(plan, "assistant_message"),
           urgency: Map.get(plan, "urgency", 0.0),
           why_now: Map.get(plan, "summary"),
           structured_data: %{
             "message_class" => Map.get(plan, "message_class"),
             "summary" => Map.get(plan, "summary"),
             "todo_ids" => Map.get(plan, "todo_ids", []),
             "interrupt_now_hint" => Map.get(plan, "interrupt_now", false),
             "trigger" => trigger
           },
           telegram_opts: %{}
         }) do
      {:ok, _candidate} ->
        {:ok,
         plan
         |> Map.put("decision", "queued")
         |> Map.put("dedupe_key", dedupe_key)}

      {:error, _changeset} ->
        {:ok, Map.put(plan, "decision", "queued")}
    end
  end
```

Rename the existing body of `deliver_plan/4` (the `case PushBroker.deliver(candidate) do ...` block, lines 120-177) into a new private function `deliver_plan_now/5` that takes `(user_id, chat_id, plan, trigger, dedupe_key)` — the `trigger` and `dedupe_key` are now passed in rather than recomputed, so delete the first two lines of the old body. Everything else in that function is unchanged.

Then update `deliver_due_check_ins/1`'s reducer (lines 79-86) to count the new decision — add one clause:

```elixir
        case deliver_check_in(account.user_id, opts) do
          {:ok, %{"decision" => "sent_now"}} -> %{acc | sent: acc.sent + 1}
          {:ok, %{"decision" => "queued"}} -> %{acc | sent: acc.sent + 1}
          {:ok, %{"decision" => "hold"}} -> %{acc | held: acc.held + 1}
          {:ok, %{"decision" => "suppressed"}} -> %{acc | suppressed: acc.suppressed + 1}
          {:ok, %{"decision" => "disabled"}} -> %{acc | disabled: acc.disabled + 1}
          {:ok, _other} -> acc
          {:error, _reason} -> %{acc | failed: acc.failed + 1}
        end
```

(Counting `queued` under `sent` keeps the cron's existing log line meaningful — "this many candidates were produced this cycle".)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — 3 tests, 0 failures.

- [ ] **Step 5: Run the proactive regression suite**

Run: `mix test test/maraithon/telegram_assistant/proactive_test.exs`
Expected: PASS — the existing proactive tests do not set `proactive_delivery_planner_enabled`, so they run the unchanged `deliver_plan_now/5` path.

- [ ] **Step 6: Commit**

```bash
git add lib/maraithon/telegram_assistant/proactive.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Route proactive check-in plans through the proactive queue when planner is enabled"
```

---

# Phase 3 — The DeliveryPlanner

The model contract and the module that gathers a user's pending candidates, makes one disposition call, and dispatches.

### Task 3.1: `AssistantHarness.plan_delivery/2` contract

**Files:**
- Modify: `lib/maraithon/assistant_harness.ex` (add near `proactive_plan/2` at line 253, `build_proactive_request/2` at line 229, `build_proactive_prompt/1` at line 430, `normalize_proactive/1`, and the `@valid_proactive_*` attributes near line 31)
- Test: `test/maraithon/assistant_harness_test.exs` (extend — confirm this file exists; if not, create it following `DataCase` conventions)

The contract: given a list of pending candidates plus context, the model returns one disposition per candidate and an optional digest intro.

```json
{
  "dispositions": [
    {"candidate_id": "uuid", "disposition": "interrupt_now|digest|hold", "reason": "short reason"}
  ],
  "digest_intro": "Telegram-ready intro for the bundled digest, or empty string when no candidates are in the digest",
  "summary": "short reasoning summary"
}
```

- [ ] **Step 1: Write the failing test**

Append to `test/maraithon/assistant_harness_test.exs`:

```elixir
  describe "plan_delivery/2" do
    test "normalizes a delivery plan with per-candidate dispositions" do
      llm_complete = fn params ->
        prompt = get_in(params, ["messages", Access.at(1), "content"])
        assert prompt =~ "Delivery planning contract:"
        assert prompt =~ "cand-1"

        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => "cand-1", "disposition" => "interrupt_now", "reason" => "timely"},
                 %{"candidate_id" => "cand-2", "disposition" => "digest", "reason" => "useful, not urgent"},
                 %{"candidate_id" => "cand-3", "disposition" => "hold", "reason" => "pushed recently"}
               ],
               "digest_intro" => "A couple of things worth a look when you have a minute.",
               "summary" => "One urgent item, one for the digest, one to hold."
             })
         }}
      end

      payload = %{
        candidates: [
          %{"id" => "cand-1", "source" => "insight", "body" => "Vendor renews Friday", "urgency" => 0.9},
          %{"id" => "cand-2", "source" => "brief", "body" => "Morning brief", "urgency" => 0.5},
          %{"id" => "cand-3", "source" => "proactive_check_in", "body" => "Nudge", "urgency" => 0.3}
        ],
        context: %{},
        recent_pushes: []
      }

      assert {:ok, plan} =
               Maraithon.AssistantHarness.plan_delivery(payload, llm_complete: llm_complete)

      assert plan["digest_intro"] == "A couple of things worth a look when you have a minute."
      assert plan["summary"] =~ "One urgent item"

      assert [d1, d2, d3] = plan["dispositions"]
      assert d1 == %{"candidate_id" => "cand-1", "disposition" => "interrupt_now", "reason" => "timely"}
      assert d2["disposition"] == "digest"
      assert d3["disposition"] == "hold"
    end

    test "rejects an unknown disposition value" do
      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [%{"candidate_id" => "cand-1", "disposition" => "yolo", "reason" => "x"}],
               "digest_intro" => "",
               "summary" => "bad"
             })
         }}
      end

      assert {:error, :assistant_harness_invalid_disposition} =
               Maraithon.AssistantHarness.plan_delivery(
                 %{candidates: [%{"id" => "cand-1"}], context: %{}, recent_pushes: []},
                 llm_complete: llm_complete
               )
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/assistant_harness_test.exs`
Expected: FAIL — `plan_delivery/2` is undefined.

- [ ] **Step 3: Implement the contract**

In `lib/maraithon/assistant_harness.ex`, add the module attribute next to `@valid_proactive_message_classes` (line 31):

```elixir
  @valid_dispositions ~w(interrupt_now digest hold)
```

Add the public functions next to `proactive_plan/2`:

```elixir
  @doc """
  Asks the model to assign a delivery disposition to each pending proactive
  candidate and, when any are bundled, draft a digest intro.
  """
  def plan_delivery(payload, opts \\ []) when is_map(payload) do
    params = build_delivery_plan_request(payload, opts)

    with {:ok, decoded} <- complete_json(params, opts),
         {:ok, normalized} <- normalize_delivery_plan(decoded) do
      {:ok, normalized}
    end
  end

  def build_delivery_plan_request(payload, opts \\ []) when is_map(payload) and is_list(opts) do
    policy = runtime_policy(opts)
    prompt = payload |> Map.put_new(:runtime_policy, policy) |> build_delivery_plan_prompt()

    %{
      "messages" => [
        %{"role" => "system", "content" => system_prompt()},
        %{"role" => "user", "content" => prompt}
      ],
      "max_tokens" => policy.proactive_request.max_tokens,
      "temperature" => policy.proactive_request.temperature,
      "reasoning_effort" => policy.proactive_request.reasoning_effort
    }
  end

  def build_delivery_plan_prompt(payload) do
    """
    Return ONLY valid JSON with this exact shape:
    {
      "dispositions":[
        {"candidate_id":"id of a candidate below","disposition":"interrupt_now|digest|hold","reason":"short reason"}
      ],
      "digest_intro":"Telegram-ready intro for the bundled digest, or empty string when nothing is in the digest",
      "summary":"short reasoning summary"
    }

    Delivery planning contract:
    - You are deciding HOW to deliver proactive messages that have already been drafted, not whether they are worth drafting.
    - Return exactly one disposition object per candidate id listed below. Do not invent ids.
    - "interrupt_now": send this candidate to Telegram immediately on its own. Use only for genuinely timely or high-stakes items.
    - "digest": fold this candidate into a single batched digest message so the user gets one interruption instead of many.
    - "hold": do not send this candidate now. Use when it was effectively covered by a recent push, is stale, or is not worth the user's attention this cycle. Held candidates stay queued and may be reconsidered later.
    - Prefer "digest" over multiple "interrupt_now" sends. A user should rarely get more than one stand-alone interruption per planning cycle.
    - "digest_intro" must be a human, chief-of-staff-voiced lead-in for the digest, and must be a non-empty string whenever at least one candidate has disposition "digest". It must be an empty string when no candidate is in the digest.
    - Do not use keyword heuristics. Reason over candidate bodies, urgency, the context snapshot, and recent push receipts.
    - Keep all copy compact and Telegram-friendly. Never expose internal scores or source names.

    Pending candidates JSON:
    #{PromptStability.encode!(Map.get(payload, :candidates) || Map.get(payload, "candidates") || [])}

    Context snapshot JSON:
    #{PromptStability.encode!(Map.get(payload, :context) || Map.get(payload, "context") || %{})}

    Recent proactive push receipts JSON:
    #{PromptStability.encode!(Map.get(payload, :recent_pushes) || Map.get(payload, "recent_pushes") || [])}

    Runtime policy JSON:
    #{PromptStability.encode!(map_value(payload, "runtime_policy", runtime_policy()))}
    """
  end
```

Add the normalizer next to `normalize_proactive/1`:

```elixir
  defp normalize_delivery_plan(%{} = parsed) do
    raw_dispositions = Map.get(parsed, "dispositions")
    digest_intro = normalize_message(Map.get(parsed, "digest_intro"))
    summary = normalize_message(Map.get(parsed, "summary"))

    with {:ok, dispositions} <- normalize_dispositions(raw_dispositions) do
      {:ok,
       %{
         "dispositions" => dispositions,
         "digest_intro" => digest_intro,
         "summary" => summary
       }}
    end
  end

  defp normalize_delivery_plan(_parsed), do: {:error, :assistant_harness_invalid_delivery_plan}

  defp normalize_dispositions(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn entry, {:ok, acc} ->
      candidate_id = normalize_message(Map.get(entry, "candidate_id"))
      disposition = Map.get(entry, "disposition")
      reason = normalize_message(Map.get(entry, "reason"))

      cond do
        candidate_id == "" ->
          {:halt, {:error, :assistant_harness_invalid_disposition}}

        disposition not in @valid_dispositions ->
          {:halt, {:error, :assistant_harness_invalid_disposition}}

        true ->
          {:cont,
           {:ok,
            [
              %{
                "candidate_id" => candidate_id,
                "disposition" => disposition,
                "reason" => reason
              }
              | acc
            ]}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_dispositions(_list), do: {:error, :assistant_harness_invalid_disposition}
```

> `normalize_message/1`, `map_value/2`, `complete_json/2`, `runtime_policy/1`, `system_prompt/0`, `PromptStability.encode!/1`, and `policy.proactive_request` are all existing helpers used by `build_proactive_request/2` / `normalize_proactive/1` — reuse them as-is.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/assistant_harness_test.exs`
Expected: PASS — including the two new `plan_delivery/2` tests.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/assistant_harness.ex test/maraithon/assistant_harness_test.exs
git commit -m "Add AssistantHarness.plan_delivery contract for the delivery planner"
```

### Task 3.2: `DeliveryPlanner` — gather and plan (no dispatch yet)

**Files:**
- Create: `lib/maraithon/telegram_assistant/delivery_planner.ex`
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (extend)

This task builds the gather-and-plan half: load pending candidates, call `plan_delivery/2`, write each disposition back via `ProactiveQueue.mark_planned/3`. Dispatch is Task 3.3.

- [ ] **Step 1: Write the failing test**

Append a `describe` block to `test/maraithon/telegram_assistant/delivery_planner_test.exs`:

```elixir
  describe "DeliveryPlanner.run_for_user/2 — planning" do
    alias Maraithon.TelegramAssistant.DeliveryPlanner

    test "writes the model's disposition back onto each candidate", %{user_id: user_id} do
      {:ok, c1} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i1",
          dedupe_key: "insight:1",
          body: "Vendor renews Friday.",
          urgency: 0.9
        })

      {:ok, c2} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "brief",
          source_id: "b1",
          dedupe_key: "brief:1",
          body: "Morning brief.",
          urgency: 0.5
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => c1.id, "disposition" => "interrupt_now", "reason" => "timely"},
                 %{"candidate_id" => c2.id, "disposition" => "hold", "reason" => "not now"}
               ],
               "digest_intro" => "",
               "summary" => "one urgent, one held"
             })
         }}
      end

      assert {:ok, summary} =
               DeliveryPlanner.run_for_user(user_id, llm_complete: llm_complete, dispatch: false)

      assert summary.planned == 2

      assert %{disposition: "interrupt_now", status: "planned"} =
               Maraithon.Repo.reload(c1) |> Map.take([:disposition, :status])

      assert %{disposition: "hold", status: "planned"} =
               Maraithon.Repo.reload(c2) |> Map.take([:disposition, :status])
    end

    test "returns :noop when the user has no pending candidates", %{user_id: user_id} do
      assert {:ok, %{planned: 0, dispatched: 0}} =
               DeliveryPlanner.run_for_user(user_id, llm_complete: fn _ -> flunk("should not call the model") end)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — `Maraithon.TelegramAssistant.DeliveryPlanner` is undefined.

- [ ] **Step 3: Implement the gather-and-plan half**

Create `lib/maraithon/telegram_assistant/delivery_planner.ex`:

```elixir
defmodule Maraithon.TelegramAssistant.DeliveryPlanner do
  @moduledoc """
  Model-driven planner that decides how a user's pending proactive candidates
  reach Telegram.

  For each user with pending `ProactiveCandidate` rows, the planner makes one
  `AssistantHarness.plan_delivery/2` call that assigns every candidate a
  disposition — `interrupt_now`, `digest`, or `hold` — then dispatches:

    * `interrupt_now` candidates are sent individually via `PushBroker.deliver/1`
    * `digest` candidates are bundled into one digest message plus per-candidate
      cards
    * `hold` candidates are left planned-but-undelivered in the queue

  This replaces the blunt per-source rate limiting in `PushBroker` with a single
  model judgement made with full cross-source context.
  """

  import Ecto.Query

  alias Maraithon.AssistantHarness
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{ProactiveCandidate, ProactiveQueue}

  require Logger

  @recent_push_limit 8

  @doc """
  Plans and dispatches one user's pending proactive candidates.

  Options:
    * `:llm_complete` — test stub forwarded to `AssistantHarness.plan_delivery/2`
    * `:dispatch` — when `false`, plan only and skip dispatch (default `true`)
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    case ProactiveQueue.list_pending_for_user(user_id) do
      [] ->
        {:ok, %{planned: 0, dispatched: 0}}

      candidates ->
        chat_id = ConnectedAccounts.telegram_destination(user_id)
        plan_and_dispatch(user_id, chat_id, candidates, opts)
    end
  end

  @doc """
  Runs `run_for_user/2` for every user with pending candidates, up to `:batch_size`.
  """
  def run_for_due_users(opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 25)

    batch_size
    |> ProactiveQueue.pending_user_ids()
    |> Enum.reduce(%{users: 0, planned: 0, dispatched: 0, failed: 0}, fn user_id, acc ->
      case run_for_user(user_id, opts) do
        {:ok, summary} ->
          %{
            acc
            | users: acc.users + 1,
              planned: acc.planned + Map.get(summary, :planned, 0),
              dispatched: acc.dispatched + Map.get(summary, :dispatched, 0)
          }

        {:error, reason} ->
          Logger.warning("Delivery planner failed for user",
            user_id: user_id,
            reason: inspect(reason)
          )

          %{acc | users: acc.users + 1, failed: acc.failed + 1}
      end
    end)
  end

  defp plan_and_dispatch(user_id, chat_id, candidates, opts) do
    payload = %{
      candidates: Enum.map(candidates, &candidate_for_prompt/1),
      context: %{"user_id" => user_id, "chat_id" => chat_id},
      recent_pushes: recent_pushes(user_id)
    }

    with {:ok, plan} <- AssistantHarness.plan_delivery(payload, opts) do
      by_id = Map.new(candidates, &{&1.id, &1})

      planned =
        plan
        |> Map.get("dispositions", [])
        |> Enum.reduce([], fn disposition, acc ->
          case Map.get(by_id, disposition["candidate_id"]) do
            %ProactiveCandidate{} = candidate ->
              {:ok, updated} =
                ProactiveQueue.mark_planned(
                  candidate,
                  disposition["disposition"],
                  disposition["reason"]
                )

              [updated | acc]

            nil ->
              acc
          end
        end)
        |> Enum.reverse()

      if Keyword.get(opts, :dispatch, true) do
        dispatched = dispatch(user_id, chat_id, planned, plan)
        {:ok, %{planned: length(planned), dispatched: dispatched}}
      else
        {:ok, %{planned: length(planned), dispatched: 0}}
      end
    end
  end

  defp candidate_for_prompt(%ProactiveCandidate{} = candidate) do
    %{
      "id" => candidate.id,
      "source" => candidate.source,
      "title" => candidate.title,
      "body" => candidate.body,
      "urgency" => candidate.urgency,
      "why_now" => candidate.why_now,
      "inserted_at" => DateTime.to_iso8601(candidate.inserted_at)
    }
  end

  defp recent_pushes(user_id) do
    Maraithon.TelegramAssistant.PushReceipt
    |> where([r], r.user_id == ^user_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(@recent_push_limit)
    |> Repo.all()
    |> Enum.map(fn r ->
      %{
        "dedupe_key" => r.dedupe_key,
        "origin_type" => r.origin_type,
        "decision" => r.decision,
        "inserted_at" => DateTime.to_iso8601(r.inserted_at)
      }
    end)
  end

  # dispatch/4 is implemented in Task 3.3. For Task 3.2 it is a stub so the
  # planning-only tests pass; Task 3.3 replaces it with the real implementation.
  defp dispatch(_user_id, _chat_id, _planned, _plan), do: 0
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — all `describe` blocks so far, including the two new planning tests.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/telegram_assistant/delivery_planner.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Add DeliveryPlanner gather-and-plan stage"
```

### Task 3.3: `DeliveryPlanner` — dispatch (interrupt-now, digest, hold)

**Files:**
- Modify: `lib/maraithon/telegram_assistant/delivery_planner.ex` (replace the `dispatch/4` stub)
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (extend)

Dispatch rules:
- **`interrupt_now`** → `PushBroker.deliver/1` with `origin_type` mapped from the candidate's `source` (`insight` → `"insight"`, `brief` → `"brief"`, `proactive_check_in` → `"assistant_digest"`); on `{:ok, %{decision: "sent_now"}}` mark the candidate `delivered`.
- **`digest`** → if ≥1 digest candidate, send ONE `PushBroker.deliver/1` with `origin_type: "assistant_digest"`, `body: digest_intro`, then one card turn per candidate via `TelegramAssistant.send_turn/4` (the pattern in `Proactive.send_todo_cards/3`, `proactive.ex:180-208`); mark each digest candidate `delivered` and record a `merged` `PushReceipt` for each. The digest parent's own `PushReceipt` is `sent_now` (written by `PushBroker.deliver/1`).
- **`hold`** → `ProactiveQueue.mark_held/1`; no Telegram send, no receipt.

`dispatch/4` returns the count of candidates actually delivered (interrupt-now sends + digest members).

- [ ] **Step 1: Write the failing test**

Append a `describe` block to `test/maraithon/telegram_assistant/delivery_planner_test.exs`. It uses `Maraithon.TestSupport.CapturingTelegram` exactly as `proactive_test.exs` does — copy that file's `setup` additions (the `:capturing_telegram_recorder` agent and the `telegram_module: CapturingTelegram` config) into this test module's `setup`, and copy its `telegram_messages/0` helper.

```elixir
  describe "DeliveryPlanner.run_for_user/2 — dispatch" do
    alias Maraithon.TelegramAssistant.DeliveryPlanner

    test "interrupt_now candidates are sent individually and marked delivered", %{user_id: user_id} do
      {:ok, candidate} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i1",
          dedupe_key: "insight:urgent",
          body: "Vendor renews Friday — confirm or cancel.",
          urgency: 0.95
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => candidate.id, "disposition" => "interrupt_now", "reason" => "timely"}
               ],
               "digest_intro" => "",
               "summary" => "one urgent send"
             })
         }}
      end

      assert {:ok, %{dispatched: 1}} =
               DeliveryPlanner.run_for_user(user_id, llm_complete: llm_complete)

      assert [message] = telegram_messages()
      assert message.text =~ "Vendor renews Friday"
      assert Maraithon.Repo.reload(candidate).status == "delivered"
    end

    test "digest candidates are bundled into one intro plus per-candidate cards", %{user_id: user_id} do
      {:ok, c1} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "brief",
          source_id: "b1",
          dedupe_key: "brief:1",
          body: "Three things need you today.",
          urgency: 0.5
        })

      {:ok, c2} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "proactive_check_in",
          source_id: "p1",
          dedupe_key: "proactive:1",
          body: "The Acme contract is still open.",
          urgency: 0.4
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => c1.id, "disposition" => "digest", "reason" => "useful"},
                 %{"candidate_id" => c2.id, "disposition" => "digest", "reason" => "useful"}
               ],
               "digest_intro" => "A couple of things worth a look when you have a minute.",
               "summary" => "two digest items"
             })
         }}
      end

      assert {:ok, %{dispatched: 2}} =
               DeliveryPlanner.run_for_user(user_id, llm_complete: llm_complete)

      messages = telegram_messages()
      assert length(messages) == 3
      [intro | cards] = messages
      assert intro.text =~ "A couple of things worth a look"
      card_text = Enum.map_join(cards, "\n", & &1.text)
      assert card_text =~ "Three things need you today."
      assert card_text =~ "The Acme contract is still open."

      assert Maraithon.Repo.reload(c1).status == "delivered"
      assert Maraithon.Repo.reload(c2).status == "delivered"

      # each digest member gets a `merged` receipt
      merged =
        Maraithon.TelegramAssistant.PushReceipt
        |> Maraithon.Repo.all()
        |> Enum.filter(&(&1.decision == "merged"))

      assert length(merged) == 2
    end

    test "hold candidates are marked held and not sent", %{user_id: user_id} do
      {:ok, candidate} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i2",
          dedupe_key: "insight:stale",
          body: "Something covered already.",
          urgency: 0.2
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => candidate.id, "disposition" => "hold", "reason" => "covered recently"}
               ],
               "digest_intro" => "",
               "summary" => "hold it"
             })
         }}
      end

      assert {:ok, %{dispatched: 0}} =
               DeliveryPlanner.run_for_user(user_id, llm_complete: llm_complete)

      assert telegram_messages() == []
      assert Maraithon.Repo.reload(candidate).status == "held"
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — `dispatch/4` is still the stub returning `0`; no Telegram messages sent.

- [ ] **Step 3: Implement `dispatch/4`**

In `lib/maraithon/telegram_assistant/delivery_planner.ex`, add aliases at the top:

```elixir
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{ProactiveCandidate, ProactiveQueue, PushBroker, PushReceipt}
  alias Maraithon.TelegramConversations.Conversation
```

(Merge with the existing `alias Maraithon.TelegramAssistant.{...}` line rather than duplicating it.)

Replace the `dispatch/4` stub with:

```elixir
  defp dispatch(user_id, chat_id, planned, plan) do
    grouped = Enum.group_by(planned, & &1.disposition)

    interrupt_count =
      grouped
      |> Map.get("interrupt_now", [])
      |> Enum.count(&dispatch_interrupt_now(user_id, chat_id, &1))

    digest_count =
      dispatch_digest(
        user_id,
        chat_id,
        Map.get(grouped, "digest", []),
        Map.get(plan, "digest_intro", "")
      )

    grouped
    |> Map.get("hold", [])
    |> Enum.each(&ProactiveQueue.mark_held/1)

    interrupt_count + digest_count
  end

  defp dispatch_interrupt_now(user_id, chat_id, %ProactiveCandidate{} = candidate) do
    case PushBroker.deliver(%{
           user_id: user_id,
           chat_id: chat_id,
           origin_type: origin_type(candidate.source),
           origin_id: candidate.source_id,
           dedupe_key: candidate.dedupe_key,
           title: candidate.title,
           body: candidate.body,
           urgency: candidate.urgency,
           interrupt_now: true,
           why_now: candidate.why_now,
           structured_data: candidate.structured_data,
           telegram_opts: telegram_opts_to_keyword(candidate.telegram_opts)
         }) do
      {:ok, %{decision: "sent_now"}} ->
        {:ok, _} = ProactiveQueue.mark_delivered(candidate)
        true

      _other ->
        false
    end
  end

  defp dispatch_digest(_user_id, _chat_id, [], _intro), do: 0

  defp dispatch_digest(user_id, chat_id, candidates, intro) do
    intro_text =
      if is_binary(intro) and intro != "",
        do: intro,
        else: "A few things worth a look when you have a minute."

    case PushBroker.deliver(%{
           user_id: user_id,
           chat_id: chat_id,
           origin_type: "assistant_digest",
           origin_id: "delivery_planner:#{Date.utc_today()}",
           dedupe_key: "delivery_digest:#{user_id}:#{Date.utc_today()}",
           title: "Maraithon digest",
           body: intro_text,
           urgency: digest_urgency(candidates),
           interrupt_now: true,
           why_now: "Batched proactive digest",
           structured_data: %{
             "message_class" => "delivery_digest",
             "candidate_ids" => Enum.map(candidates, & &1.id)
           },
           conversation_metadata: %{"mode" => "delivery_digest"},
           telegram_opts: [parse_mode: "HTML"]
         }) do
      {:ok, %{decision: "sent_now", conversation_id: conversation_id}} ->
        conversation = Repo.get(Conversation, conversation_id)
        Enum.count(candidates, &send_digest_card(conversation, user_id, &1))

      _other ->
        0
    end
  end

  defp send_digest_card(%Conversation{} = conversation, user_id, %ProactiveCandidate{} = candidate) do
    case TelegramAssistant.send_turn(
           conversation,
           conversation.chat_id,
           candidate.body,
           send_mode: :send,
           turn_kind: "assistant_push",
           origin_type: "assistant_digest",
           origin_id: candidate.source_id,
           structured_data: Map.put(candidate.structured_data, "message_class", "digest_item"),
           telegram_opts: telegram_opts_to_keyword(candidate.telegram_opts)
         ) do
      {:ok, _conversation, turn, _telegram_result} ->
        {:ok, _} = ProactiveQueue.mark_delivered(candidate)

        TelegramAssistant.record_push_receipt(%{
          user_id: user_id,
          dedupe_key: candidate.dedupe_key,
          origin_type: origin_type(candidate.source),
          origin_id: candidate.source_id,
          decision: "merged",
          conversation_turn_id: turn.id
        })

        true

      {:error, _reason} ->
        false
    end
  end

  defp send_digest_card(_conversation, _user_id, _candidate), do: false

  defp digest_urgency([]), do: 0.0

  defp digest_urgency(candidates) do
    candidates |> Enum.map(& &1.urgency) |> Enum.max()
  end

  defp origin_type("insight"), do: "insight"
  defp origin_type("brief"), do: "brief"
  defp origin_type(_proactive_check_in), do: "assistant_digest"

  defp telegram_opts_to_keyword(opts) when is_map(opts) do
    Enum.map(opts, fn
      {"parse_mode", value} -> {:parse_mode, value}
      {"reply_markup", value} -> {:reply_markup, value}
      {key, value} when is_atom(key) -> {key, value}
      {key, value} -> {String.to_existing_atom(key), value}
    end)
  end

  defp telegram_opts_to_keyword(opts) when is_list(opts), do: opts
  defp telegram_opts_to_keyword(_opts), do: []
```

> The `merged` and `queued_digest` decisions are already valid in `PushReceipt.@decisions` (`push_receipt.ex:16`) — this is the code path that finally produces `merged`. If `String.to_existing_atom/1` ever raises on an unexpected key, prefer adding the key explicitly to the `telegram_opts_to_keyword/1` clauses over switching to `String.to_atom/1`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — all `describe` blocks, including the three dispatch tests.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/telegram_assistant/delivery_planner.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Implement DeliveryPlanner dispatch: interrupt-now, digest, hold"
```

---

# Phase 4 — Wire into the cron, telemetry, config, and cutover prep

The planner now exists and is tested. This phase makes it run in production (flag-gated), traces it, records decisions to the `ActionLedger`, and wires the config so the flag can be flipped per environment.

### Task 4.1: Run the planner from `ProactiveCheckIn` each tick

**Files:**
- Modify: `lib/maraithon/runtime/proactive_check_in.ex:40-62` (`handle_info(:tick, ...)`)
- Test: `test/maraithon/runtime/proactive_check_in_test.exs` (extend — confirm it exists; if not, create following `test/maraithon/runtime/briefing_cron_test.exs` conventions)

- [ ] **Step 1: Write the failing test**

Append to `test/maraithon/runtime/proactive_check_in_test.exs`:

```elixir
  describe "run_delivery_planner/1" do
    test "drains pending candidates through the DeliveryPlanner when the flag is on" do
      original = Application.get_env(:maraithon, :telegram_assistant, [])

      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.merge(original,
          telegram_unified_push_enabled: true,
          proactive_delivery_planner_enabled: true
        )
      )

      on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, original) end)

      user_id = "cron-planner-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email(user_id)

      {:ok, _candidate} =
        Maraithon.TelegramAssistant.ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i1",
          dedupe_key: "insight:1",
          body: "An item for the planner.",
          urgency: 0.4
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [],
               "digest_intro" => "",
               "summary" => "nothing to do"
             })
         }}
      end

      summary = Maraithon.Runtime.ProactiveCheckIn.run_delivery_planner(llm_complete: llm_complete)
      assert summary.users == 1
    end

    test "is a no-op when the flag is off" do
      original = Application.get_env(:maraithon, :telegram_assistant, [])

      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.put(original, :proactive_delivery_planner_enabled, false)
      )

      on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, original) end)

      assert Maraithon.Runtime.ProactiveCheckIn.run_delivery_planner() == :disabled
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/runtime/proactive_check_in_test.exs`
Expected: FAIL — `run_delivery_planner/0,1` is undefined.

- [ ] **Step 3: Wire the planner into the cron**

In `lib/maraithon/runtime/proactive_check_in.ex`:

Add the alias near the top:

```elixir
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.DeliveryPlanner
```

Add the public function next to `run_once/1`:

```elixir
  @doc """
  Drains pending proactive candidates through the `DeliveryPlanner`.

  Returns `:disabled` when `proactive_delivery_planner_enabled?/0` is false.
  """
  def run_delivery_planner(opts \\ []) do
    if TelegramAssistant.proactive_delivery_planner_enabled?() do
      DeliveryPlanner.run_for_due_users(opts)
    else
      :disabled
    end
  end
```

In `handle_info(:tick, state)`, after `run_local_pattern_detectors()` (line 53) and before `schedule_tick(state.interval_ms)`:

```elixir
    run_local_pattern_detectors()

    case run_delivery_planner(batch_size: state.batch_size) do
      :disabled ->
        :ok

      %{users: users} = summary when users > 0 ->
        Logger.info("Proactive delivery planner cycle",
          users: summary.users,
          planned: summary.planned,
          dispatched: summary.dispatched,
          failed: summary.failed
        )

      _summary ->
        :ok
    end

    schedule_tick(state.interval_ms)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/runtime/proactive_check_in_test.exs`
Expected: PASS — including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/runtime/proactive_check_in.ex test/maraithon/runtime/proactive_check_in_test.exs
git commit -m "Run the DeliveryPlanner from the proactive check-in cron"
```

### Task 4.2: Trace the planner and record decisions to the ActionLedger

**Files:**
- Modify: `lib/maraithon/telegram_assistant/delivery_planner.ex` (`run_for_user/2` and `dispatch/4`)
- Test: `test/maraithon/telegram_assistant/delivery_planner_test.exs` (extend)

Wrap each `run_for_user/2` call in a `Maraithon.Tracing.with_span/3` span (the helper added in commit `472e7c9`, used in `runner.ex:23-30`), and record one `ActionLedger` entry per planning cycle so proactive delivery decisions are auditable the same way `Proactive.record_proactive_decision/5` records check-ins.

- [ ] **Step 1: Write the failing test**

Append to the `DeliveryPlanner.run_for_user/2 — dispatch` describe block:

```elixir
    test "records an ActionLedger entry for the planning cycle", %{user_id: user_id} do
      {:ok, candidate} =
        ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i9",
          dedupe_key: "insight:ledger",
          body: "Ledgered item.",
          urgency: 0.3
        })

      llm_complete = fn _params ->
        {:ok,
         %{
           content:
             Jason.encode!(%{
               "dispositions" => [
                 %{"candidate_id" => candidate.id, "disposition" => "hold", "reason" => "later"}
               ],
               "digest_intro" => "",
               "summary" => "held one item"
             })
         }}
      end

      assert {:ok, _summary} = DeliveryPlanner.run_for_user(user_id, llm_complete: llm_complete)

      assert [entry] =
               Maraithon.ActionLedger.list_recent(user_id,
                 event_type: "proactive.delivery_planned",
                 limit: 1
               )

      assert entry.status == "planned"
      assert entry.model_summary == "held one item"
      assert entry.metadata["interrupt_now_count"] == 0
      assert entry.metadata["digest_count"] == 0
      assert entry.metadata["hold_count"] == 1
    end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: FAIL — no `proactive.delivery_planned` ledger entry is recorded.

- [ ] **Step 3: Add tracing and ledger recording**

In `lib/maraithon/telegram_assistant/delivery_planner.ex`, add aliases:

```elixir
  alias Maraithon.ActionLedger
  alias Maraithon.Tracing
```

Wrap the body of `run_for_user/2`:

```elixir
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    Tracing.with_span(
      "telegram_assistant.delivery_planner",
      %{user_id: user_id},
      fn ->
        case ProactiveQueue.list_pending_for_user(user_id) do
          [] ->
            {:ok, %{planned: 0, dispatched: 0}}

          candidates ->
            chat_id = ConnectedAccounts.telegram_destination(user_id)
            plan_and_dispatch(user_id, chat_id, candidates, opts)
        end
      end
    )
  end
```

In `plan_and_dispatch/4`, after computing `planned` and before/around the dispatch, record the ledger entry. Replace the `if Keyword.get(opts, :dispatch, true) do ... end` block with:

```elixir
      result =
        if Keyword.get(opts, :dispatch, true) do
          dispatched = dispatch(user_id, chat_id, planned, plan)
          %{planned: length(planned), dispatched: dispatched}
        else
          %{planned: length(planned), dispatched: 0}
        end

      record_planning_decision(user_id, planned, plan, result)
      {:ok, result}
```

Add the recorder (mirrors `Proactive.record_proactive_decision/5` — best-effort, never raises):

```elixir
  defp record_planning_decision(user_id, planned, plan, result) do
    counts = Enum.frequencies_by(planned, & &1.disposition)

    ActionLedger.record(%{
      user_id: user_id,
      surface: "telegram",
      event_type: "proactive.delivery_planned",
      status: "planned",
      source_evidence: %{
        candidate_ids: Enum.map(planned, & &1.id),
        candidate_count: length(planned)
      },
      model_summary: Map.get(plan, "summary"),
      result_object_refs: %{
        dispatched: Map.get(result, :dispatched, 0)
      },
      metadata: %{
        "interrupt_now_count" => Map.get(counts, "interrupt_now", 0),
        "digest_count" => Map.get(counts, "digest", 0),
        "hold_count" => Map.get(counts, "hold", 0)
      }
    })

    :ok
  rescue
    _error -> :ok
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/maraithon/telegram_assistant/delivery_planner_test.exs`
Expected: PASS — all tests including the ledger test.

- [ ] **Step 5: Commit**

```bash
git add lib/maraithon/telegram_assistant/delivery_planner.ex test/maraithon/telegram_assistant/delivery_planner_test.exs
git commit -m "Trace the DeliveryPlanner and record delivery decisions to the ActionLedger"
```

### Task 4.3: Config wiring + stale-candidate expiry

**Files:**
- Modify: `config/config.exs:48` (the `:telegram_assistant` config line)
- Modify: `config/runtime.exs:245-248` (the `:telegram_assistant` runtime config block)
- Modify: `lib/maraithon/runtime/proactive_check_in.ex` (`handle_info(:tick, ...)` — call `ProactiveQueue.expire_stale/1`)
- Test: `test/maraithon/runtime/proactive_check_in_test.exs` (extend)

- [ ] **Step 1: Add the config defaults**

In `config/config.exs`, replace line 48:

```elixir
config :maraithon, :telegram_assistant, telegram_proactive_checkins_enabled: false
```

with:

```elixir
config :maraithon, :telegram_assistant,
  telegram_proactive_checkins_enabled: false,
  proactive_delivery_planner_enabled: false,
  proactive_candidate_ttl_minutes: 120
```

In `config/runtime.exs`, in the `config :maraithon, :telegram_assistant,` block (around line 245), add the env-driven flag alongside `telegram_proactive_checkins_enabled`:

```elixir
config :maraithon, :telegram_assistant,
  telegram_unified_push_enabled:
    boolean_env.("TELEGRAM_UNIFIED_PUSH_ENABLED", false),
  telegram_proactive_checkins_enabled:
    boolean_env.("TELEGRAM_PROACTIVE_CHECKINS_ENABLED", false),
  proactive_delivery_planner_enabled:
    boolean_env.("PROACTIVE_DELIVERY_PLANNER_ENABLED", false)
```

> Match the exact existing shape of that block — only *add* the `proactive_delivery_planner_enabled:` key; keep whatever keys are already there. `boolean_env` is the helper already defined earlier in `runtime.exs`.

- [ ] **Step 2: Write the failing test for expiry**

Append to `test/maraithon/runtime/proactive_check_in_test.exs`:

```elixir
  describe "expire_stale_candidates/0" do
    test "expires pending candidates older than the configured TTL" do
      original = Application.get_env(:maraithon, :telegram_assistant, [])

      Application.put_env(
        :maraithon,
        :telegram_assistant,
        Keyword.put(original, :proactive_candidate_ttl_minutes, 60)
      )

      on_exit(fn -> Application.put_env(:maraithon, :telegram_assistant, original) end)

      user_id = "expiry-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email(user_id)

      {:ok, stale} =
        Maraithon.TelegramAssistant.ProactiveQueue.enqueue(%{
          user_id: user_id,
          source: "insight",
          source_id: "i1",
          dedupe_key: "insight:old",
          body: "stale",
          urgency: 0.1
        })

      Maraithon.Repo.update_all(
        from(c in Maraithon.TelegramAssistant.ProactiveCandidate, where: c.id == ^stale.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -7200, :second)]
      )

      assert {1, _} = Maraithon.Runtime.ProactiveCheckIn.expire_stale_candidates()
    end
  end
```

(Add `import Ecto.Query` to the test module if it is not already imported.)

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/maraithon/runtime/proactive_check_in_test.exs`
Expected: FAIL — `expire_stale_candidates/0` is undefined.

- [ ] **Step 4: Implement expiry in the cron**

In `lib/maraithon/runtime/proactive_check_in.ex`, add:

```elixir
  @default_candidate_ttl_minutes 120

  @doc "Expires pending proactive candidates older than the configured TTL."
  def expire_stale_candidates do
    ttl_minutes =
      :maraithon
      |> Application.get_env(:telegram_assistant, [])
      |> Keyword.get(:proactive_candidate_ttl_minutes, @default_candidate_ttl_minutes)

    cutoff = DateTime.add(DateTime.utc_now(), -ttl_minutes * 60, :second)
    Maraithon.TelegramAssistant.ProactiveQueue.expire_stale(cutoff)
  end
```

In `handle_info(:tick, state)`, call it once per tick — immediately before `run_delivery_planner/1`:

```elixir
    expire_stale_candidates()

    case run_delivery_planner(batch_size: state.batch_size) do
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/maraithon/runtime/proactive_check_in_test.exs`
Expected: PASS — all tests including the expiry test.

- [ ] **Step 6: Verify config compiles in all environments**

Run: `MIX_ENV=prod mix compile --warnings-as-errors` then `mix compile --warnings-as-errors`
Expected: both succeed with no warnings.

- [ ] **Step 7: Commit**

```bash
git add config/config.exs config/runtime.exs lib/maraithon/runtime/proactive_check_in.ex test/maraithon/runtime/proactive_check_in_test.exs
git commit -m "Wire delivery planner config and stale-candidate expiry"
```

### Task 4.4: Full-suite verification and milestone wrap-up

**Files:**
- No code changes — verification only.

- [ ] **Step 1: Format check**

Run: `mix format --check-formatted`
Expected: no output, exit 0. If it fails, run `mix format`, review the diff, and commit it as `Format proactive delivery planner files`.

- [ ] **Step 2: Compile clean**

Run: `mix compile --warnings-as-errors`
Expected: no warnings, no errors.

- [ ] **Step 3: Full test suite**

Run: `mix test`
Expected: PASS — 0 failures. Pay special attention that `test/maraithon/telegram_assistant/proactive_test.exs`, `test/maraithon/insight_notifications_test.exs`, and `test/maraithon/briefs_test.exs` still pass: they run with `proactive_delivery_planner_enabled` unset (false), exercising the unchanged legacy `deliver_plan_now/5`, `deliver_insight_now/1`, and `deliver_brief/1` legacy branches.

- [ ] **Step 4: Confirm the migration round-trips**

Run: `mix ecto.rollback` then `mix ecto.migrate`
Expected: clean down and up of `proactive_candidates`.

- [ ] **Step 5: Final commit (if Step 1 produced formatting changes only)**

Otherwise nothing to commit — the milestone is complete on the branch.

---

## Cutover note (not a task — for the operator)

Every change above is dormant until `PROACTIVE_DELIVERY_PLANNER_ENABLED=true` is set (or `proactive_delivery_planner_enabled: true` in config). Recommended rollout once merged:

1. Enable in a staging/dev environment, watch the `telegram_assistant.delivery_planner` spans and `proactive.delivery_planned` `ActionLedger` entries for one or more proactive check-in cycles.
2. Confirm users receive at most one stand-alone interruption plus at most one digest per cycle, and that `proactive_candidates` rows reach `delivered`/`held`/`expired` (none stuck `pending`).
3. Enable in production. The legacy direct-delivery code paths can be removed in a follow-up once the flag has been on in production for a full release cycle with no regressions — that cleanup is intentionally **not** part of this milestone.

---

## Self-Review

**Spec coverage** — the milestone brief was "proactive delivery has no model-level interrupt decision and no real digest batching; scope the Proactive Delivery Planner."
- *Model-level interrupt decision* → Task 3.1 (`plan_delivery/2` contract with `interrupt_now`/`digest`/`hold`) + Task 3.2/3.3 (planner applies it). Insights and briefs, which previously hardcoded `interrupt_now: true`, now get a real model judgement — Tasks 2.2/2.3 route them through the queue.
- *Real digest batching* → Task 3.3 `dispatch_digest/4` bundles `digest` candidates into one intro + per-candidate cards, and produces the previously-dead `merged` `PushReceipt` decision. The blunt `suppress_for_rate_limit?` drop is superseded by model-judged `hold`.
- *Cross-source planning* → the `proactive_candidates` queue (Phase 1) is the shared collection point; all three sources enqueue into it (Phase 2); the planner decides over the whole set per user (Phase 3).
- *Production wiring* → Phase 4 (cron, tracing, ledger, config, expiry).

**Placeholder scan** — no `TBD`/`TODO`/"add error handling"/"similar to Task N". The one deliberate stub (`dispatch/4` in Task 3.2) is explicitly called out as a stub that Task 3.3 replaces, with the reason given. Two fixture caveats (Task 2.2 `Insights.create_insight/1`, Task 2.3 `Briefs.Brief` fields) are flagged because exact schema field names should be confirmed against the live files — the behaviour under test is fully specified regardless.

**Type consistency** — `ProactiveCandidate` fields are referenced consistently across schema (1.2), context (1.3), enqueue sites (2.2–2.4), and planner (3.2–3.3): `source`, `source_id`, `dedupe_key`, `body`, `urgency`, `why_now`, `structured_data`, `telegram_opts`, `status`, `disposition`, `plan_reason`. `ProactiveQueue` function names — `enqueue/1`, `list_pending_for_user/1`, `pending_user_ids/1`, `mark_planned/3`, `mark_delivered/1`, `mark_held/1`, `expire_stale/1` — are used identically everywhere. The `plan_delivery/2` response shape (`"dispositions"` list of `%{"candidate_id", "disposition", "reason"}`, `"digest_intro"`, `"summary"`) is consistent between the harness contract (3.1) and the planner's consumption of it (3.2/3.3). Disposition values `interrupt_now` / `digest` / `hold` match between `@valid_dispositions`, the schema's `@dispositions`, and the planner's `Enum.group_by`.

## Execution Handoff

Plan complete and saved to `.claude/plans/2026-05-14-proactive-delivery-planner.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?