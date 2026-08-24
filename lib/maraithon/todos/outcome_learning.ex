defmodule Maraithon.Todos.OutcomeLearning do
  @moduledoc """
  Captures human todo outcomes transactionally and delivers them through the
  durable per-user model queue.
  """

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJobs
  alias Maraithon.Todos.{OutcomeLearner, Todo, TodoLearningEvent}

  require Logger

  @job_type "runtime_partition:todo_outcome_learning"
  @queue "runtime_model_user"
  @terminal_statuses ~w(done dismissed)
  @open_statuses ~w(open snoozed)
  @max_recovery_attempts 25

  def job_type, do: @job_type

  def record_user_opened(user_id, todo_id, opts \\ [])

  def record_user_opened(user_id, todo_id, opts)
      when is_binary(user_id) and is_binary(todo_id) and is_list(opts) do
    if user_actor?(opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

      Todo
      |> where([todo], todo.id == ^todo_id and todo.user_id == ^user_id)
      |> where([todo], todo.status in ^@open_statuses and is_nil(todo.first_user_opened_at))
      |> Repo.update_all(set: [first_user_opened_at: now])
      |> case do
        {1, _rows} ->
          :ok

        {0, _rows} ->
          if(Repo.get_by(Todo, id: todo_id, user_id: user_id),
            do: :ok,
            else: {:error, :not_found}
          )
      end
    else
      :ok
    end
  end

  def record_user_opened(_user_id, _todo_id, _opts), do: {:error, :not_found}

  @doc false
  def maybe_enqueue(%Todo{} = previous, %Todo{} = updated, opts) when is_list(opts) do
    if eligible_transition?(previous, updated, opts) do
      {outcome, strength} = classify(updated.status, not is_nil(previous.first_user_opened_at))
      surface = normalize_surface(Keyword.get(opts, :source) || Keyword.get(opts, :surface))

      attrs = %{
        user_id: updated.user_id,
        todo_id: updated.id,
        outcome: outcome,
        signal_strength: strength,
        resolution_status: updated.status,
        opened_before_resolution: not is_nil(previous.first_user_opened_at),
        surface: surface,
        status: "pending"
      }

      with {:ok, event} <-
             %TodoLearningEvent{} |> TodoLearningEvent.changeset(attrs) |> Repo.insert(),
           {:ok, _job} <- enqueue_event(event) do
        {:ok, event}
      end
    else
      {:ok, nil}
    end
  end

  def maybe_enqueue(_previous, _updated, _opts), do: {:ok, nil}

  def process_event(event_id) when is_binary(event_id) do
    with {:ok, event} <- begin_attempt(event_id),
         {:ok, result} <- OutcomeLearner.learn(event) do
      {:ok, result}
    else
      {:already_processed, result} ->
        {:ok, result}

      {:error, reason} = error ->
        mark_attempt_failed(event_id, reason)
        error
    end
  end

  def process_event(_event_id), do: {:error, :invalid_todo_learning_event_id}

  @doc "Repairs learning events whose original queue row exhausted retries or disappeared."
  def recover_pending(limit \\ 100)

  def recover_pending(limit) when is_integer(limit) and limit > 0 do
    cutoff = DateTime.add(DateTime.utc_now(), -10, :minute)

    events =
      TodoLearningEvent
      |> where([event], event.status in ["pending", "processing", "failed"])
      |> where([event], event.attempts < ^@max_recovery_attempts)
      |> where([event], event.updated_at <= ^cutoff)
      |> order_by([event], asc: event.updated_at, asc: event.inserted_at)
      |> limit(^min(limit, 500))
      |> Repo.all()

    {enqueued, failed} =
      Enum.reduce(events, {0, 0}, fn event, {ok_count, error_count} ->
        case enqueue_event(event) do
          {:ok, _job} -> {ok_count + 1, error_count}
          {:error, _reason} -> {ok_count, error_count + 1}
        end
      end)

    {:ok, %{discovered: length(events), enqueued: enqueued, failed: failed}}
  end

  def recover_pending(_limit), do: {:error, :invalid_todo_learning_recovery_limit}

  defp eligible_transition?(%Todo{} = previous, %Todo{} = updated, opts) do
    previous.status in @open_statuses and updated.status in @terminal_statuses and
      user_actor?(opts) and not is_nil(previous.model_selected_at) and
      Keyword.get(opts, :skip_outcome_learning?, false) != true
  end

  defp user_actor?(opts) do
    Keyword.get(opts, :actor_type) in [:user, "user"]
  end

  defp classify("dismissed", false), do: {"bad", -1.0}
  defp classify("dismissed", true), do: {"weak_bad", -0.5}
  defp classify("done", false), do: {"ok", 0.45}
  defp classify("done", true), do: {"great", 1.0}

  defp enqueue_event(%TodoLearningEvent{} = event) do
    BackgroundJobs.enqueue(@job_type, %{
      user_id: event.user_id,
      queue: @queue,
      dedupe_key: "todo-outcome-learning:#{event.id}",
      partition_key: "user:#{event.user_id}",
      rate_limit_key: "model",
      max_attempts: 8,
      payload: %{"event_id" => event.id}
    })
  end

  defp begin_attempt(event_id) do
    Repo.transaction(fn ->
      event =
        TodoLearningEvent
        |> where([event], event.id == ^event_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case event do
        nil ->
          Repo.rollback(:todo_learning_event_not_found)

        %TodoLearningEvent{status: "processed"} = processed ->
          Repo.rollback({:already_processed, processed_result(processed)})

        %TodoLearningEvent{} = current ->
          current
          |> TodoLearningEvent.changeset(%{
            status: "processing",
            attempts: current.attempts + 1,
            last_error: nil
          })
          |> Repo.update!()
      end
    end)
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, {:already_processed, result}} -> {:already_processed, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_attempt_failed(event_id, reason) do
    now = DateTime.utc_now()
    status = if terminal_attempt_count?(event_id), do: "failed", else: "pending"

    TodoLearningEvent
    |> where([event], event.id == ^event_id and event.status != "processed")
    |> Repo.update_all(set: [status: status, last_error: error_text(reason), updated_at: now])

    :ok
  rescue
    error ->
      Logger.warning("todo outcome learning failure could not be recorded",
        event_id: event_id,
        reason: Exception.message(error)
      )

      :ok
  end

  defp terminal_attempt_count?(event_id) do
    case Repo.get(TodoLearningEvent, event_id) do
      %TodoLearningEvent{attempts: attempts} -> attempts >= @max_recovery_attempts
      _ -> false
    end
  end

  defp processed_result(event) do
    %{
      event_id: event.id,
      operation: event.operation,
      memory_id: event.memory_id,
      idempotent: true
    }
  end

  defp normalize_surface(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 100)
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_surface(_value), do: nil

  defp error_text(reason),
    do: reason |> inspect(limit: 30, printable_limit: 1_000) |> String.slice(0, 2_000)
end
