defmodule Maraithon.Runtime.NudgeSweep do
  @moduledoc """
  The time-based follow-up firing engine (SPEC 01 R4).

  Every tick it finds todos whose moment has arrived — a follow-up cadence
  (`next_nudge_at`) that elapsed, a snooze that expired, a due date that is
  overdue or inside the due-soon horizon — runs one bounded, best-effort LLM
  decision pass per affected user ("is a nudge/resurface appropriate right
  now?"), and enqueues the model-approved moments as `ProactiveCandidate`
  rows through the EXISTING delivery gate (`DeliveryPlanner` →
  `ProactiveQualityGate` → interruption budget → `PushBroker` quiet hours +
  receipt dedupe). It never sends anything directly and never messages a
  counterparty — the outbound nudge stays behind the operator's explicit
  "Send" confirm (`close_or_nudge_todo/3`), which is also the only path that
  may call `Todos.record_nudge_sent/3`.

  Mechanism choice (deliberate, per SPEC 01): this is a self-contained
  periodic GenServer in the `TodoCompletionSweep`/`TokenRefresher` shape, NOT
  per-todo `Scheduler.schedule_at` wakeups. A scheduled wakeup fires the full
  `AIChiefOfStaff` skill cycle, which has no nudge skill to consume the
  payload and is gated by that agent's effect budget/health — coupling
  follow-ups to it means a nudge silently never fires whenever the agent is
  unhealthy for unrelated reasons. A supervised sweep runs independently and
  inherits quiet hours, budget, and dedupe from the delivery gate for free.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.LLM
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.TelegramAssistant.ProactiveQueue
  alias Maraithon.Todos
  alias Maraithon.Todos.ActionDrafts
  alias Maraithon.Todos.Todo

  require Logger

  @name __MODULE__
  @default_interval_ms :timer.minutes(30)
  @default_todos_per_user 20
  @default_due_soon_horizon_hours 4
  @default_nudge_cap 4
  @default_llm_timeout_ms 60_000
  @default_max_tokens 2_048

  @open_statuses ~w(open snoozed)

  # A todo can match several reasons at once; the user gets exactly one
  # coherent card per todo per tick, keyed and phrased on the most urgent
  # reason (SPEC 01 edge cases): overdue > nudge-due > due-soon > snooze-expiry.
  @reason_priority %{
    overdue: 0,
    nudge_limit: 1,
    nudge_due: 1,
    due_soon: 2,
    snooze_expiry: 3
  }

  @reason_default_urgency %{
    overdue: 0.75,
    nudge_limit: 0.6,
    nudge_due: 0.6,
    due_soon: 0.65,
    snooze_expiry: 0.55
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @impl true
  def init(opts) do
    interval_ms =
      Keyword.get(
        opts,
        :interval_ms,
        Config.positive_integer(:nudge_sweep_interval_ms, @default_interval_ms)
      )

    initial_delay_ms =
      Keyword.get(
        opts,
        :initial_delay_ms,
        Config.positive_integer(:nudge_sweep_initial_delay_ms, interval_ms)
      )

    state = %{interval_ms: interval_ms}

    schedule_tick(initial_delay_ms)
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    summary = run_once()

    if summary.proposed > 0 or summary.errors > 0 do
      Logger.info("Nudge sweep cycle",
        users: summary.users,
        checked: summary.checked,
        proposed: summary.proposed,
        held: summary.held,
        cadence_updates: summary.cadence_updates,
        errors: summary.errors
      )
    end

    # `schedule_tick` deliberately runs after the cycle's work completes
    # (mirroring TokenRefresher), so overlapping ticks can never stack when a
    # run takes longer than the interval.
    schedule_tick(state.interval_ms)
    {:noreply, state}
  rescue
    error ->
      Logger.warning("Nudge sweep cycle failed", reason: Exception.message(error))
      schedule_tick(state.interval_ms)
      {:noreply, state}
  end

  @doc """
  Runs one full sweep synchronously (directly callable in tests, no timer).
  """
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    horizon_hours = due_soon_horizon_hours(opts)

    user_ids =
      case Keyword.get(opts, :user_ids) do
        user_ids when is_list(user_ids) -> user_ids
        _other -> due_user_ids(now, horizon_hours)
      end
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    empty = %{
      users: length(user_ids),
      checked: 0,
      proposed: 0,
      held: 0,
      cadence_updates: 0,
      skipped: 0,
      errors: 0
    }

    Enum.reduce(user_ids, empty, fn user_id, acc ->
      case run_for_user(user_id, opts) do
        %{} = result ->
          %{
            acc
            | checked: acc.checked + result.checked,
              proposed: acc.proposed + result.proposed,
              held: acc.held + result.held,
              cadence_updates: acc.cadence_updates + result.cadence_updates
          }

        {:skip, _reason} ->
          %{acc | skipped: acc.skipped + 1}

        {:error, _reason} ->
          %{acc | errors: acc.errors + 1}
      end
    end)
  end

  @doc """
  Runs the decision pass for one user. Returns a count map, `{:skip, reason}`
  when nothing is due, or `{:error, reason}` when the model call fails.
  Tests may inject `:llm_complete` as a one-arity function.
  """
  def run_for_user(user_id, opts \\ []) when is_binary(user_id) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    horizon_hours = due_soon_horizon_hours(opts)
    nudge_cap = positive_integer(Keyword.get(opts, :nudge_cap), @default_nudge_cap)

    todos = due_todos(user_id, now, horizon_hours, opts)

    case todos do
      [] ->
        {:skip, :none_due}

      todos ->
        timezone_context = Todos.user_timezone_context(user_id)
        reasons = Map.new(todos, fn todo -> {todo.id, todo_reason(todo, now, nudge_cap)} end)

        case decide(user_id, todos, reasons, now, timezone_context, opts) do
          {:ok, decisions} ->
            apply_decisions(user_id, todos, reasons, decisions, now, timezone_context)

          {:error, reason} ->
            Logger.warning("Nudge sweep decision pass failed",
              user_id: user_id,
              checked: length(todos),
              reason: inspect(reason)
            )

            {:error, reason}
        end
    end
  rescue
    error ->
      Logger.warning("Nudge sweep user pass crashed",
        user_id: user_id,
        reason: Exception.message(error)
      )

      {:error, error}
  end

  # ── Selection ─────────────────────────────────────────────────────────────

  # Every user with a due todo is enumerated: a capped enumeration with no
  # rotation would starve users past the cutoff forever, and user counts are
  # small.
  defp due_user_ids(now, horizon_hours) do
    horizon_end = DateTime.add(now, horizon_hours * 3600, :second)

    Repo.all(
      from(t in Todo,
        where: t.status in @open_statuses,
        where:
          (t.direction == "owed_to_me" and not is_nil(t.next_nudge_at) and
             t.next_nudge_at <= ^now) or
            (t.status == "snoozed" and not is_nil(t.snoozed_until) and
               t.snoozed_until <= ^now) or
            (not is_nil(t.due_at) and t.due_at <= ^horizon_end and
               (t.status == "open" or
                  (not is_nil(t.snoozed_until) and t.snoozed_until <= ^now))),
        distinct: true,
        select: t.user_id
      )
    )
  end

  defp due_todos(user_id, now, horizon_hours, opts) do
    horizon_end = DateTime.add(now, horizon_hours * 3600, :second)
    todo_limit = positive_integer(Keyword.get(opts, :todos_per_user), @default_todos_per_user)

    Repo.all(
      from(t in Todo,
        where: t.user_id == ^user_id,
        where: t.status in @open_statuses,
        where:
          (t.direction == "owed_to_me" and not is_nil(t.next_nudge_at) and
             t.next_nudge_at <= ^now) or
            (t.status == "snoozed" and not is_nil(t.snoozed_until) and
               t.snoozed_until <= ^now) or
            # A due/overdue todo only fires while it is open or its snooze
            # has elapsed — snoozing a past-due todo must actually silence it.
            (not is_nil(t.due_at) and t.due_at <= ^horizon_end and
               (t.status == "open" or
                  (not is_nil(t.snoozed_until) and t.snoozed_until <= ^now))),
        order_by: [asc_nulls_last: t.due_at, asc: t.inserted_at],
        limit: ^todo_limit
      )
    )
  end

  defp todo_reason(%Todo{} = todo, now, nudge_cap) do
    nudge_count = todo.nudge_count || 0

    nudge_due? =
      todo.direction == "owed_to_me" and match?(%DateTime{}, todo.next_nudge_at) and
        DateTime.compare(todo.next_nudge_at, now) != :gt

    cond do
      match?(%DateTime{}, todo.due_at) and DateTime.compare(todo.due_at, now) != :gt ->
        :overdue

      nudge_due? and nudge_count >= nudge_cap ->
        # Anti-nag cap (SPEC 01 R7): after N sends without a reply, stop
        # proposing more nudges and surface a one-time decision instead.
        :nudge_limit

      nudge_due? ->
        :nudge_due

      match?(%DateTime{}, todo.due_at) ->
        :due_soon

      todo.status == "snoozed" and match?(%DateTime{}, todo.snoozed_until) and
          DateTime.compare(todo.snoozed_until, now) != :gt ->
        :snooze_expiry

      true ->
        :snooze_expiry
    end
  end

  # ── Decision (bounded, best-effort LLM pass) ──────────────────────────────

  defp decide(user_id, todos, reasons, now, timezone_context, opts) do
    prompt = build_prompt(user_id, todos, reasons, now, timezone_context)
    llm_complete = Keyword.get(opts, :llm_complete) || (&default_llm_complete(&1, opts))
    timeout_ms = positive_integer(Keyword.get(opts, :llm_timeout_ms), @default_llm_timeout_ms)

    # Bounded per-user model call: a slow or rate-limited call for one user
    # must never block the sweep for every other user in the same tick
    # (mirrors CrossSourceCompletion's Task.yield/brutal_kill pattern).
    task = Task.async(fn -> llm_complete.(prompt) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, response}} -> decode_response(response)
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, other} -> {:error, {:unexpected_llm_result, other}}
      {:exit, reason} -> {:error, {:llm_task_exit, reason}}
      nil -> {:error, {:llm_timeout, timeout_ms}}
    end
  end

  defp build_prompt(_user_id, todos, reasons, now, timezone_context) do
    items =
      Enum.map(todos, fn todo ->
        reason = Map.fetch!(reasons, todo.id)

        %{
          "todo_id" => todo.id,
          "reason" => reason_label(reason),
          "direction" => todo.direction,
          "status" => todo.status,
          "title" => todo.title,
          "summary" => truncate(todo.summary, 300),
          "next_action" => truncate(todo.next_action, 200),
          "counterparty" => todo.counterparty_label,
          "nudge_count" => todo.nudge_count || 0,
          "due_at_local" => local_label(todo.due_at, timezone_context),
          "snoozed_until_local" => local_label(todo.snoozed_until, timezone_context),
          "last_nudged_at_local" => local_label(todo.last_nudged_at, timezone_context),
          "follow_up_was_scheduled_for_local" =>
            local_label(todo.next_nudge_at, timezone_context),
          "captured_at_local" =>
            local_label(todo.source_occurred_at || todo.inserted_at, timezone_context),
          "days_waiting" => days_between(todo.source_occurred_at || todo.inserted_at, now)
        }
        |> compact_map()
      end)

    """
    You are the follow-up timing decider for a chief-of-staff product. Each
    item below is due RIGHT NOW for one of these reasons:
    - follow_up_due: the operator is waiting on someone (owed_to_me) and the scheduled follow-up moment arrived.
    - follow_up_limit_reached: #{@default_nudge_cap}+ nudges already went out with no reply — propose a one-time keep-chasing / snooze / drop decision, not another routine nudge.
    - overdue / due_soon: a hard deadline passed or is within a few hours (any direction).
    - snooze_expired: the operator snoozed this and the snooze elapsed.

    Decide, per item, whether to surface it to the operator right now.
    Rules:
    - Bias to HOLD. If the counterparty likely already replied since capture,
      or you cannot tell, or the item looks stale/irrelevant, do not surface it —
      nudging someone who already answered damages trust.
    - You are only proposing the moment to the operator. Nothing you return is
      ever sent to the counterparty; the operator confirms every send.
    - For a surfaced item write a short title and a why-now body the operator
      can act on immediately (who, waiting since when, what to do). Address
      the operator as "you".
    - For a surfaced follow_up_due item also write draft_text: concise
      suggested follow-up wording in the operator's voice to the counterparty.
    - For a follow_up_due item you HOLD, set next_nudge_at to the ISO-8601
      datetime when the follow-up should be re-checked instead (size it to the
      counterparty/urgency; omit it to leave the schedule unchanged).
    - All *_local timestamps below are already in the operator's local time.

    CURRENT_LOCAL_TIME: #{local_label(now, timezone_context)}

    DUE_ITEMS_JSON:
    #{Jason.encode!(items)}

    Respond with only this JSON shape, no prose:
    {
      "decisions": [
        {
          "todo_id": "uuid",
          "surface": true,
          "title": "short card title",
          "body": "why-now text the operator sees",
          "urgency": 0.0,
          "why_now": "one short sentence",
          "draft_text": "suggested follow-up wording, or omitted",
          "next_nudge_at": "ISO-8601 datetime, only when surface=false for follow_up_due"
        }
      ]
    }
    Return {"decisions": []} to hold everything.
    """
  end

  defp reason_label(:nudge_due), do: "follow_up_due"
  defp reason_label(:nudge_limit), do: "follow_up_limit_reached"
  defp reason_label(:overdue), do: "overdue"
  defp reason_label(:due_soon), do: "due_soon"
  defp reason_label(:snooze_expiry), do: "snooze_expired"

  defp default_llm_complete(prompt, opts) when is_binary(prompt) do
    config = Application.get_env(:maraithon, :todos, [])

    LLM.complete(%{
      "messages" => [%{"role" => "user", "content" => prompt}],
      "max_tokens" => Keyword.get(opts, :max_tokens, @default_max_tokens),
      "temperature" => 0.1,
      "reasoning_effort" => Keyword.get(config, :reasoning_effort, LLM.intelligence()),
      "timeout_ms" => Keyword.get(opts, :llm_timeout_ms, @default_llm_timeout_ms)
    })
  end

  defp decode_response(response) do
    content =
      case response do
        %{"content" => content} when is_binary(content) -> content
        %{content: content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _other -> nil
      end

    with content when is_binary(content) <- content,
         json when is_binary(json) <- extract_json(content),
         {:ok, %{"decisions" => decisions}} when is_list(decisions) <- Jason.decode(json) do
      {:ok, Enum.filter(decisions, &is_map/1)}
    else
      _other -> {:error, :nudge_sweep_invalid_response}
    end
  end

  defp extract_json(content) do
    with {start, _length} <- :binary.match(content, "{"),
         [_ | _] = closers <- :binary.matches(content, "}") do
      {finish, _length} = List.last(closers)
      binary_part(content, start, finish - start + 1)
    else
      _other -> nil
    end
  end

  # ── Apply (runtime enforcement) ───────────────────────────────────────────

  defp apply_decisions(user_id, todos, reasons, decisions, now, timezone_context) do
    todos_by_id = Map.new(todos, &{&1.id, &1})

    cadence_updates =
      Enum.count(decisions, fn decision ->
        apply_cadence_update(user_id, todos_by_id, reasons, decision, now, timezone_context)
      end)

    surfaced =
      decisions
      |> Enum.filter(&(&1["surface"] == true))
      |> Enum.flat_map(fn decision ->
        with todo_id when is_binary(todo_id) <- decision["todo_id"],
             %Todo{} = todo <- Map.get(todos_by_id, todo_id),
             # Snooze re-open race guard: re-check status at the moment the
             # candidate is about to be enqueued, not just at query time —
             # never resurrect a todo the completion sweeps closed meanwhile.
             %Todo{status: status} = fresh <- Todos.get_for_user(user_id, todo_id),
             true <- status in @open_statuses do
          [%{todo: fresh, reason: Map.fetch!(reasons, todo.id), decision: decision}]
        else
          _other -> []
        end
      end)

    Enum.each(surfaced, fn %{todo: todo, reason: reason, decision: decision} ->
      maybe_refresh_action_draft(user_id, todo, reason, decision, now)
    end)

    proposed =
      surfaced
      |> bundle_by_counterparty()
      |> Enum.count(fn bundle -> enqueue_bundle(user_id, bundle, now, timezone_context) end)

    # Held is implicit: a missing decision or surface=false simply enqueues
    # nothing this tick (bias-to-hold) — the item re-enters selection on the
    # next tick unless the model re-armed its cadence above.
    %{
      checked: length(todos),
      proposed: proposed,
      held: length(todos) - length(surfaced),
      cadence_updates: cadence_updates
    }
  end

  # Model held a follow_up_due item and proposed the next check-in moment.
  # Runtime validates: owed_to_me only, still open, strictly in the future,
  # coerced through the same lenient timezone-aware parser as ingest.
  defp apply_cadence_update(user_id, todos_by_id, reasons, decision, now, timezone_context) do
    with false <- decision["surface"] == true,
         todo_id when is_binary(todo_id) <- decision["todo_id"],
         %Todo{direction: "owed_to_me"} <- Map.get(todos_by_id, todo_id),
         :nudge_due <- Map.get(reasons, todo_id),
         raw when not is_nil(raw) <- decision["next_nudge_at"],
         %DateTime{} = next_nudge_at <-
           Todos.parse_flexible_datetime(raw, timezone_context || user_id),
         :gt <- DateTime.compare(next_nudge_at, now) do
      next_nudge_at = DateTime.truncate(next_nudge_at, :second)
      stamped_at = DateTime.truncate(now, :second)

      {count, _rows} =
        Todo
        |> where(
          [todo],
          todo.id == ^todo_id and todo.user_id == ^user_id and
            todo.direction == "owed_to_me" and todo.status in @open_statuses
        )
        |> Repo.update_all(set: [next_nudge_at: next_nudge_at, updated_at: stamped_at])

      count == 1
    else
      _other -> false
    end
  end

  # SPEC 01 R4: a surfaced follow-up card must be able to offer "Send", not
  # just "Draft" — refresh the todo's draft with the model's wording, but
  # only over an absent/write-boundary-generic draft, never over real
  # prepared material.
  defp maybe_refresh_action_draft(user_id, %Todo{} = todo, reason, decision, now)
       when reason in [:nudge_due, :nudge_limit] do
    draft_text = decision["draft_text"]

    if is_binary(draft_text) and String.trim(draft_text) != "" and
         not real_draft_present?(todo) do
      draft = %{
        "kind" => "message",
        "label" => "Follow-up nudge draft",
        "text" => String.trim(draft_text),
        "source" => "nudge_sweep",
        "style" => "counterparty_nudge",
        "channel" => todo.source
      }

      Todo
      |> where([t], t.id == ^todo.id and t.user_id == ^user_id)
      |> Repo.update_all(set: [action_draft: draft, updated_at: DateTime.truncate(now, :second)])

      :ok
    else
      :ok
    end
  end

  defp maybe_refresh_action_draft(_user_id, _todo, _reason, _decision, _now), do: :ok

  defp real_draft_present?(%Todo{action_draft: draft}) when is_map(draft) do
    text = ActionDrafts.preview(draft)

    generic? =
      Map.get(draft, "kind") == "next_step" or Map.get(draft, "source") == "todo_write_boundary"

    is_binary(text) and String.trim(text) != "" and not generic?
  end

  defp real_draft_present?(_todo), do: false

  # Per-counterparty cap (SPEC 01 R7): several due todos waiting on the same
  # person in one tick become one proposed candidate, not one card each.
  defp bundle_by_counterparty(surfaced) do
    surfaced
    |> Enum.group_by(fn %{todo: todo} ->
      cond do
        is_binary(todo.counterparty_person_id) ->
          {:person, todo.counterparty_person_id}

        is_binary(todo.counterparty_label) and String.trim(todo.counterparty_label) != "" ->
          {:label, todo.counterparty_label |> String.trim() |> String.downcase()}

        true ->
          {:todo, todo.id}
      end
    end)
    |> Map.values()
    |> Enum.map(fn members ->
      Enum.sort_by(members, fn %{todo: todo, reason: reason} ->
        {Map.fetch!(@reason_priority, reason), due_sort_value(todo)}
      end)
    end)
  end

  defp due_sort_value(%Todo{due_at: %DateTime{} = due_at}), do: DateTime.to_unix(due_at, :second)
  defp due_sort_value(_todo), do: 9_999_999_999

  defp enqueue_bundle(user_id, [primary | rest] = _bundle, now, timezone_context) do
    %{todo: todo, reason: reason, decision: decision} = primary
    todo_ids = [todo.id | Enum.map(rest, & &1.todo.id)]

    title =
      decision["title"]
      |> presence()
      |> Kernel.||(default_title(todo, reason))
      |> truncate(200)

    body =
      decision["body"]
      |> presence()
      |> Kernel.||(todo.next_action || todo.summary || title)
      |> append_bundle_note(rest)
      |> truncate(4_000)

    attrs = %{
      user_id: user_id,
      source: "nudge",
      source_id: todo.id,
      dedupe_key: dedupe_key(todo, reason, now, timezone_context),
      title: title,
      body: body,
      urgency: clamp_urgency(decision["urgency"], Map.fetch!(@reason_default_urgency, reason)),
      why_now: decision["why_now"] |> presence() |> truncate(1_000),
      structured_data: %{
        "todo_ids" => todo_ids,
        "message_class" => "todo_digest",
        "nudge_reason" => reason_label(reason)
      }
    }

    case ProactiveQueue.enqueue(attrs) do
      {:ok, _candidate} ->
        true

      {:error, reason_error} ->
        # Ids/field-names only — never inspect a full changeset here, its
        # `changes` would put todo summary/body content into the logs.
        Logger.warning("Nudge sweep could not enqueue candidate",
          user_id: user_id,
          todo_id: todo.id,
          nudge_reason: reason_label(reason),
          reason: enqueue_error_summary(reason_error)
        )

        false
    end
  end

  defp enqueue_error_summary(%Ecto.Changeset{errors: errors}) do
    "invalid_candidate:#{errors |> Keyword.keys() |> Enum.map_join(",", &to_string/1)}"
  end

  defp enqueue_error_summary(other), do: inspect(other)

  defp append_bundle_note(body, []), do: body

  defp append_bundle_note(body, rest) do
    titles =
      rest
      |> Enum.map(fn %{todo: todo} -> "- #{todo.title}" end)
      |> Enum.join("\n")

    body <> "\n\nAlso due with the same person:\n" <> titles
  end

  defp default_title(%Todo{} = todo, :nudge_limit) do
    "No reply after #{todo.nudge_count || 0} nudges — keep chasing, snooze, or drop it?"
  end

  defp default_title(%Todo{} = todo, _reason), do: todo.title

  # Dedupe key design (SPEC 01 R4): the key changes only when the underlying
  # reason changes. Nudge-due keys are keyed on nudge_count (advances only
  # when a real send goes out via record_nudge_sent/3); horizon-based reasons
  # are bucketed on the LOCAL calendar day so they fire at most once per day
  # per todo. Never a raw timestamp — that would defeat dedupe entirely.
  defp dedupe_key(%Todo{} = todo, :nudge_due, _now, _timezone_context) do
    "nudge:#{todo.id}:nudge_due:#{todo.nudge_count || 0}"
  end

  defp dedupe_key(%Todo{} = todo, :nudge_limit, _now, _timezone_context) do
    "nudge:#{todo.id}:nudge_limit:#{todo.nudge_count || 0}"
  end

  defp dedupe_key(%Todo{} = todo, reason, now, timezone_context)
       when reason in [:overdue, :due_soon, :snooze_expiry] do
    "nudge:#{todo.id}:#{reason}:#{Date.to_iso8601(local_today(now, timezone_context))}"
  end

  defp local_today(now, timezone_context) do
    offset =
      case timezone_context do
        %{offset_hours: offset} when is_integer(offset) -> offset
        _other -> 0
      end

    Todos.brief_local_date(now, offset)
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp local_label(nil, _timezone_context), do: nil

  defp local_label(%DateTime{} = datetime, timezone_context) do
    offset =
      case timezone_context do
        %{offset_hours: offset} when is_integer(offset) -> offset
        _other -> 0
      end

    local = DateTime.add(datetime, offset, :hour)
    label = if offset >= 0, do: "UTC+#{offset}", else: "UTC#{offset}"

    "#{Calendar.strftime(local, "%Y-%m-%d %H:%M")} local (#{label})"
  end

  defp days_between(%DateTime{} = from, %DateTime{} = to) do
    div(max(DateTime.diff(to, from, :second), 0), 86_400)
  end

  defp days_between(_from, _to), do: nil

  defp due_soon_horizon_hours(opts) do
    positive_integer(
      Keyword.get(
        opts,
        :due_soon_horizon_hours,
        Config.positive_integer(
          :nudge_sweep_due_soon_horizon_hours,
          @default_due_soon_horizon_hours
        )
      ),
      @default_due_soon_horizon_hours
    )
  end

  defp clamp_urgency(value, _default) when is_float(value), do: value |> max(0.0) |> min(1.0)

  defp clamp_urgency(value, default) when is_integer(value),
    do: clamp_urgency(value / 1, default)

  defp clamp_urgency(_value, default), do: default

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil

  defp truncate(nil, _max), do: nil

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max - 1) <> "…"
    end
  end

  defp compact_map(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  defp schedule_tick(delay_ms) when is_integer(delay_ms) and delay_ms > 0 do
    Process.send_after(self(), :tick, delay_ms)
  end
end
