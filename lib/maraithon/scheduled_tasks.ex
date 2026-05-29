defmodule Maraithon.ScheduledTasks do
  @moduledoc """
  User-facing scheduled tasks with explicit schedule, run history, and failure
  delivery metadata.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.Normalization
  alias Maraithon.Repo
  alias Maraithon.RunErrorCopy
  alias Maraithon.ScheduledTasks.{Run, Task}

  @default_limit 50
  @max_limit 200
  @terminal_run_statuses ~w(completed failed cancelled)
  @days %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  def create_task(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    with {:ok, normalized} <- normalize_task_attrs(user_id, attrs) do
      %Task{}
      |> Task.changeset(normalized)
      |> Repo.insert()
      |> tap(fn
        {:ok, task} -> record_change(task, "created")
        _ -> :ok
      end)
    end
  end

  def create_task(_user_id, _attrs), do: {:error, :invalid_scheduled_task_attrs}

  def create_from_telegram(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put_new("source", "telegram")
      |> Map.put_new("failure_destination", %{"type" => "telegram"})

    create_task(user_id, attrs)
  end

  def create_from_telegram(_user_id, _attrs), do: {:error, :invalid_scheduled_task_attrs}

  def list_tasks(user_id, opts \\ [])

  def list_tasks(user_id, opts) when is_binary(user_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    status = Keyword.get(opts, :status)

    Task
    |> where([task], task.user_id == ^user_id)
    |> maybe_filter_status(status)
    |> order_by([task], asc_nulls_last: task.next_run_at, desc: task.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_tasks(_user_id, _opts), do: []

  def get_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    Repo.get_by(Task, id: task_id, user_id: user_id)
  end

  def get_task(_user_id, _task_id), do: nil

  def pause_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    update_task_status(user_id, task_id, "paused")
  end

  def cancel_task(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    update_task_status(user_id, task_id, "cancelled", %{next_run_at: nil})
  end

  def due_tasks(now \\ DateTime.utc_now(), opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    Task
    |> where([task], task.status == "active")
    |> where([task], not is_nil(task.next_run_at) and task.next_run_at <= ^now)
    |> order_by([task], asc: task.next_run_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def schedule_preview(attrs_or_schedule, opts \\ []) when is_list(opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, schedule} <- normalize_schedule(attrs_or_schedule),
         {:ok, next_run_at} <- next_run_at(schedule, now) do
      {:ok, %{schedule: schedule, next_run_at: next_run_at}}
    end
  end

  def record_run(%Task{} = task, status, attrs \\ %{}) when is_map(attrs) do
    now = DateTime.utc_now()
    status = normalize_status(status)
    scheduled_for = read_datetime(attrs, "scheduled_for") || task.next_run_at || now

    run_attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "task_id" => task.id,
        "user_id" => task.user_id,
        "status" => status,
        "scheduled_for" => scheduled_for,
        "started_at" => read_datetime(attrs, "started_at") || started_at(status, now),
        "finished_at" => read_datetime(attrs, "finished_at") || finished_at(status, now),
        "result" => read_map(attrs, "result"),
        "metadata" => read_map(attrs, "metadata")
      })

    Repo.transaction(fn ->
      with {:ok, run} <- %Run{} |> Run.changeset(run_attrs) |> Repo.insert(),
           {:ok, updated_task} <- maybe_advance_task(task, status, run.finished_at || now) do
        %{run: run, task: updated_task}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, %{run: run, task: updated_task}} -> {:ok, run, updated_task}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_runs(user_id, task_id, opts \\ [])

  def list_runs(user_id, task_id, opts)
      when is_binary(user_id) and is_binary(task_id) and is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    Run
    |> where([run], run.user_id == ^user_id and run.task_id == ^task_id)
    |> order_by([run], desc: run.scheduled_for)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_runs(_user_id, _task_id, _opts), do: []

  def serialize_task(%Task{} = task) do
    %{
      id: task.id,
      user_id: task.user_id,
      title: task.title,
      description: task.description,
      schedule: task.schedule || %{},
      timezone: task.timezone,
      status: task.status,
      command: task.command || %{},
      failure_destination: task.failure_destination || %{},
      source: task.source,
      metadata: task.metadata || %{},
      last_run_at: task.last_run_at,
      next_run_at: task.next_run_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  def serialize_run(%Run{} = run) do
    %{
      id: run.id,
      task_id: run.task_id,
      user_id: run.user_id,
      status: run.status,
      scheduled_for: run.scheduled_for,
      started_at: run.started_at,
      finished_at: run.finished_at,
      result: run.result || %{},
      error: RunErrorCopy.scheduled_task(run.error),
      metadata: run.metadata || %{},
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  defp normalize_task_attrs(user_id, attrs) do
    attrs = stringify_keys(attrs)

    with {:ok, title} <- required_string(attrs, "title"),
         {:ok, schedule} <- normalize_schedule(attrs),
         {:ok, next_run_at} <- next_run_at(schedule, DateTime.utc_now()),
         {:ok, command} <- normalize_command(attrs) do
      {:ok,
       %{
         "user_id" => String.trim(user_id),
         "title" => title,
         "description" => read_string(attrs, "description"),
         "schedule" => schedule,
         "timezone" => read_string(attrs, "timezone", "Etc/UTC"),
         "status" => read_string(attrs, "status", "active"),
         "command" => command,
         "failure_destination" => read_map(attrs, "failure_destination"),
         "source" => read_string(attrs, "source", "api"),
         "metadata" => read_map(attrs, "metadata"),
         "next_run_at" => next_run_at
       }}
    end
  end

  defp normalize_schedule(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    schedule =
      attrs
      |> Map.get("schedule", attrs)
      |> normalize_schedule_aliases(attrs)

    type = read_string(schedule, "type")

    case type do
      "once" ->
        with {:ok, at} <- schedule |> read_string("at") |> parse_datetime() do
          {:ok, %{"type" => "once", "at" => DateTime.to_iso8601(at)}}
        end

      "daily" ->
        with {:ok, time} <- schedule |> read_string("time") |> parse_time() do
          {:ok, %{"type" => "daily", "time" => Time.to_iso8601(time)}}
        end

      "weekly" ->
        with {:ok, day} <- schedule |> read_string("day") |> parse_day(),
             {:ok, time} <- schedule |> read_string("time") |> parse_time() do
          {:ok, %{"type" => "weekly", "day" => day, "time" => Time.to_iso8601(time)}}
        end

      _ ->
        {:error, :invalid_schedule}
    end
  end

  defp normalize_schedule(_attrs), do: {:error, :invalid_schedule}

  defp normalize_schedule_aliases(schedule, attrs) when is_map(schedule) do
    schedule = stringify_keys(schedule)

    cond do
      read_string(attrs, "once_at") ->
        %{"type" => "once", "at" => read_string(attrs, "once_at")}

      read_string(attrs, "daily_at") ->
        %{"type" => "daily", "time" => read_string(attrs, "daily_at")}

      read_string(attrs, "weekly_at") || read_string(attrs, "weekly_day") ->
        %{
          "type" => "weekly",
          "time" => read_string(attrs, "weekly_at"),
          "day" => read_string(attrs, "weekly_day")
        }

      true ->
        schedule
    end
  end

  defp normalize_schedule_aliases(_schedule, attrs), do: normalize_schedule_aliases(%{}, attrs)

  defp next_run_at(%{"type" => "once", "at" => at}, now) do
    with {:ok, datetime} <- parse_datetime(at) do
      if DateTime.compare(datetime, now) == :lt do
        {:error, :scheduled_time_in_past}
      else
        {:ok, datetime}
      end
    end
  end

  defp next_run_at(%{"type" => "daily", "time" => value}, now) do
    with {:ok, time} <- parse_time(value) do
      today = now |> DateTime.to_date() |> datetime_at!(time)

      next =
        if DateTime.compare(today, now) == :gt do
          today
        else
          now |> DateTime.to_date() |> Date.add(1) |> datetime_at!(time)
        end

      {:ok, next}
    end
  end

  defp next_run_at(%{"type" => "weekly", "day" => day, "time" => value}, now) do
    with {:ok, target_day} <- parse_day(day),
         {:ok, time} <- parse_time(value) do
      today = DateTime.to_date(now)
      current_day = Date.day_of_week(today)
      days_until = rem(target_day - current_day + 7, 7)
      candidate = today |> Date.add(days_until) |> datetime_at!(time)

      next =
        if days_until == 0 and DateTime.compare(candidate, now) != :gt do
          today |> Date.add(7) |> datetime_at!(time)
        else
          candidate
        end

      {:ok, next}
    end
  end

  defp next_run_at(_schedule, _now), do: {:error, :invalid_schedule}

  defp normalize_command(attrs) do
    command = read_map(attrs, "command")

    command =
      if map_size(command) == 0 do
        prompt = read_string(attrs, "prompt") || read_string(attrs, "message")

        if prompt do
          %{"type" => "assistant_prompt", "prompt" => prompt}
        else
          %{}
        end
      else
        command
      end

    case {read_string(command, "type"), map_size(command)} do
      {nil, _} -> {:error, :invalid_command}
      {_type, 0} -> {:error, :invalid_command}
      {_type, _size} -> {:ok, command}
    end
  end

  defp update_task_status(user_id, task_id, status, extra_attrs \\ %{}) do
    case get_task(user_id, task_id) do
      nil ->
        {:error, :not_found}

      %Task{} = task ->
        attrs = Map.merge(%{"status" => status}, stringify_keys(extra_attrs))

        task
        |> Task.changeset(attrs)
        |> Repo.update()
        |> tap(fn
          {:ok, updated_task} -> record_change(updated_task, status)
          _ -> :ok
        end)
    end
  end

  defp maybe_advance_task(%Task{} = task, status, finished_at)
       when status in @terminal_run_statuses do
    next_run_at =
      if task.status == "active" do
        case next_after_terminal_run(task.schedule || %{}, finished_at) do
          {:ok, next} -> next
          {:error, _reason} -> nil
        end
      end

    task
    |> Task.changeset(%{"last_run_at" => finished_at, "next_run_at" => next_run_at})
    |> Repo.update()
  end

  defp maybe_advance_task(%Task{} = task, _status, _finished_at), do: {:ok, task}

  defp next_after_terminal_run(%{"type" => "once"}, _finished_at), do: {:ok, nil}
  defp next_after_terminal_run(schedule, finished_at), do: next_run_at(schedule, finished_at)

  defp record_change(%Task{} = task, action) do
    ActionLedger.record(%{
      user_id: task.user_id,
      surface: task.source || "scheduled_tasks",
      event_type: "scheduled_task.changed",
      status: "completed",
      result_object_refs: %{"scheduled_task" => task.id},
      metadata: %{
        action: action,
        title: task.title,
        schedule_type: Map.get(task.schedule || %{}, "type"),
        next_run_at: task.next_run_at
      }
    })

    :ok
  rescue
    _error -> :ok
  end

  defp parse_datetime(value), do: Normalization.parse_datetime(value)

  defp parse_time(nil), do: {:error, :invalid_time}

  defp parse_time(%Time{} = time), do: {:ok, Time.truncate(time, :second)}

  defp parse_time(value) when is_binary(value) do
    value = String.trim(value)

    value =
      case String.split(value, ":") do
        [_hour, _minute] -> value <> ":00"
        _ -> value
      end

    case Time.from_iso8601(value) do
      {:ok, time} -> {:ok, Time.truncate(time, :second)}
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_time(_value), do: {:error, :invalid_time}

  defp parse_day(day) when is_integer(day) and day in 1..7, do: {:ok, day}

  defp parse_day(day) when is_binary(day) do
    day = day |> String.trim() |> String.downcase()

    cond do
      Map.has_key?(@days, day) ->
        {:ok, Map.fetch!(@days, day)}

      day in (@days |> Map.values() |> Enum.map(&Integer.to_string/1)) ->
        {:ok, String.to_integer(day)}

      true ->
        {:error, :invalid_day}
    end
  end

  defp parse_day(_day), do: {:error, :invalid_day}

  defp datetime_at!(%Date{} = date, %Time{} = time) do
    {:ok, datetime} = DateTime.new(date, time, "Etc/UTC")
    datetime
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query
  defp maybe_filter_status(query, status), do: where(query, [task], task.status == ^status)

  defp started_at("pending", _now), do: nil
  defp started_at(_status, now), do: now

  defp finished_at(status, now) when status in @terminal_run_statuses, do: now
  defp finished_at(_status, _now), do: nil

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: String.trim(status)
  defp normalize_status(_status), do: "pending"

  defp required_string(attrs, key) do
    case read_string(attrs, key) do
      nil -> {:error, :"missing_#{key}"}
      value -> {:ok, value}
    end
  end

  defp read_string(attrs, key, default \\ nil),
    do: Normalization.read_string(attrs, key, default)

  defp read_map(attrs, key), do: Normalization.read_map(attrs, key)

  defp read_datetime(attrs, key), do: Normalization.read_datetime(attrs, key)

  defp clamp_limit(value), do: Normalization.clamp_limit(value, @default_limit, @max_limit)

  defp stringify_keys(value), do: Normalization.stringify_keys(value)
end
