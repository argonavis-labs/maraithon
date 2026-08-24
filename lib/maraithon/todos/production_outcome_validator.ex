defmodule Maraithon.Todos.ProductionOutcomeValidator do
  @moduledoc """
  Runs an isolated, aggregate-only production smoke check for the durable todo
  outcome-learning queue.
  """

  import Ecto.Query

  alias Maraithon.Accounts.User
  alias Maraithon.Memory.Item
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Todos
  alias Maraithon.Todos.{OutcomeLearning, Todo, TodoLearningEvent}

  @surface "production_validation"
  @timeout_ms 480_000
  @poll_interval_ms 1_000

  def run do
    try do
      do_run()
    rescue
      error in Postgrex.Error ->
        {:error,
         {:database_error, current_stage(), database_error_code(error),
          stacktrace_site(__STACKTRACE__)}}

      error ->
        {:error,
         {:validator_exception, current_stage(), error.__struct__,
          stacktrace_site(__STACKTRACE__)}}
    catch
      kind, _reason ->
        {:error, {:validator_exit, current_stage(), kind, stacktrace_site(__STACKTRACE__)}}
    after
      Process.delete(stage_key())
    end
  end

  def error_code(reason) when is_atom(reason), do: Atom.to_string(reason)

  def error_code({:todo_outcome_validation_processing_failed, category})
      when is_binary(category),
      do: "todo_outcome_validation_processing_failed:#{category}"

  def error_code({:todo_outcome_validation_timeout, category}) when is_binary(category),
    do: "todo_outcome_validation_timeout:#{category}"

  def error_code({:database_error, stage, code, site}),
    do: "database_error:#{stage}:#{code}:#{site}"

  def error_code({:validator_exception, stage, module, site}) when is_atom(module),
    do: "validator_exception:#{stage}:#{inspect(module)}:#{site}"

  def error_code({:validator_exit, stage, kind, site}) when is_atom(kind),
    do: "validator_exit:#{stage}:#{kind}:#{site}"

  def error_code(_reason), do: "todo_outcome_validation_failed"

  defp do_run do
    user_id = validation_user_id()

    try do
      with {:ok, _user} <- at_stage(:create_user, fn -> create_user(user_id) end),
           {:ok, todo} <- at_stage(:create_todo, fn -> create_todo(user_id) end),
           {:ok, %{todo: dismissed}} <-
             at_stage(:dismiss_todo, fn -> dismiss_todo(user_id, todo.id) end),
           :ok <- require_status(dismissed.status, "dismissed", :todo_not_dismissed),
           %TodoLearningEvent{} = event <-
             at_stage(:load_event, fn -> learning_event(todo.id) end),
           :ok <- validate_event(event),
           %BackgroundJob{} = job <- at_stage(:load_job, fn -> learning_job(event.id) end),
           :ok <- validate_job(job),
           {:ok, processed_event, completed_job} <-
             at_stage(:await_processing, fn -> await_processing(event.id, job.id) end),
           :ok <- validate_processed_result(processed_event, completed_job) do
        {:ok,
         %{
           isolated_user: true,
           outcome: processed_event.outcome,
           event_status: processed_event.status,
           event_attempts: processed_event.attempts,
           learning_operation: processed_event.operation,
           memory_written: not is_nil(processed_event.memory_id),
           queue: completed_job.queue,
           job_status: completed_job.status,
           job_attempts: completed_job.attempts
         }}
      else
        nil -> {:error, :todo_outcome_validation_record_missing}
        {:error, _reason} = error -> error
        _other -> {:error, :todo_outcome_validation_failed}
      end
    after
      at_stage(:cleanup, fn -> cleanup(user_id) end)
    end
  end

  defp at_stage(stage, fun) when is_atom(stage) and is_function(fun, 0) do
    Process.put(stage_key(), stage)
    fun.()
  end

  defp current_stage, do: Process.get(stage_key(), :unknown)
  defp stage_key, do: {__MODULE__, :validation_stage}

  defp stacktrace_site(stacktrace) do
    Enum.find_value(stacktrace, "unknown", fn
      {module, function, arity_or_args, _location} when is_atom(module) and is_atom(function) ->
        module_name = Atom.to_string(module)

        if String.starts_with?(module_name, "Elixir.Maraithon.") do
          arity = if is_integer(arity_or_args), do: arity_or_args, else: length(arity_or_args)
          "#{inspect(module)}.#{function}/#{arity}"
        end

      _frame ->
        nil
    end)
  end

  defp create_user(user_id) do
    %User{}
    |> User.changeset(%{id: user_id, email: user_id, confirmed_at: DateTime.utc_now()})
    |> Repo.insert()
  end

  defp create_todo(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    %Todo{}
    |> Todo.changeset(%{
      user_id: user_id,
      owner_user_id: user_id,
      source: @surface,
      kind: "general",
      title: "Validate durable outcome learning",
      summary: "Synthetic release validation item with no user content.",
      next_action: "Dismiss the synthetic release validation item.",
      dedupe_key: "todo-outcome-validation:#{Ecto.UUID.generate()}",
      model_selected_at: now,
      metadata: %{"production_validation" => true}
    })
    |> Repo.insert()
  end

  defp dismiss_todo(user_id, todo_id) do
    Todos.see_less_like(user_id, todo_id,
      actor_type: "user",
      actor_id: user_id,
      source: @surface
    )
  end

  defp learning_event(todo_id) do
    Repo.get_by(TodoLearningEvent, todo_id: todo_id)
  end

  defp learning_job(event_id) do
    Repo.get_by(BackgroundJob,
      dedupe_key: "todo-outcome-learning:#{event_id}",
      job_type: OutcomeLearning.job_type()
    )
  end

  defp validate_event(%TodoLearningEvent{} = event) do
    cond do
      event.outcome != "bad" ->
        {:error, :todo_outcome_validation_classification_failed}

      event.resolution_status != "dismissed" ->
        {:error, :todo_outcome_validation_resolution_failed}

      event.opened_before_resolution ->
        {:error, :todo_outcome_validation_open_state_failed}

      event.surface != @surface ->
        {:error, :todo_outcome_validation_surface_failed}

      event.status not in ["pending", "processing", "processed"] ->
        {:error, :todo_outcome_validation_event_state_failed}

      true ->
        :ok
    end
  end

  defp validate_job(%BackgroundJob{} = job) do
    cond do
      job.queue != "runtime_model_user" ->
        {:error, :todo_outcome_validation_queue_failed}

      job.partition_key != "user:#{job.user_id}" ->
        {:error, :todo_outcome_validation_partition_failed}

      job.status not in ["pending", "running", "completed"] ->
        {:error, :todo_outcome_validation_job_state_failed}

      true ->
        :ok
    end
  end

  defp validate_processed_result(event, job) do
    cond do
      event.attempts != 1 -> {:error, :todo_outcome_validation_event_attempts_failed}
      event.operation != "noop" -> {:error, :todo_outcome_validation_operation_failed}
      not is_nil(event.memory_id) -> {:error, :todo_outcome_validation_memory_write_failed}
      job.attempts != 0 -> {:error, :todo_outcome_validation_job_attempts_failed}
      true -> :ok
    end
  end

  defp await_processing(event_id, job_id) do
    deadline = System.monotonic_time(:millisecond) + @timeout_ms
    await_processing(event_id, job_id, deadline)
  end

  defp await_processing(event_id, job_id, deadline) do
    event = Repo.get(TodoLearningEvent, event_id)
    job = Repo.get(BackgroundJob, job_id)

    cond do
      is_nil(event) or is_nil(job) ->
        {:error, :todo_outcome_validation_record_disappeared}

      event.status == "processed" and job.status == "completed" ->
        {:ok, event, job}

      event.status == "failed" or job.status in ["failed", "cancelled"] ->
        {:error,
         {:todo_outcome_validation_processing_failed, processing_error_category(event, job)}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:todo_outcome_validation_timeout, timeout_category(event, job)}}

      true ->
        Process.sleep(@poll_interval_ms)
        await_processing(event_id, job_id, deadline)
    end
  end

  defp timeout_category(event, job) do
    event_status = aggregate_status(event.status, ~w(pending processing processed failed))
    job_status = aggregate_status(job.status, ~w(pending running completed failed cancelled))
    event_attempts = aggregate_attempts(event.attempts)
    job_attempts = aggregate_attempts(job.attempts)
    error = processing_error_category(event, job)

    "event_#{event_status}:job_#{job_status}:" <>
      "event_attempts_#{event_attempts}:job_attempts_#{job_attempts}:error_#{error}"
  end

  defp aggregate_attempts(0), do: "zero"
  defp aggregate_attempts(1), do: "one"
  defp aggregate_attempts(value) when is_integer(value) and value > 1, do: "many"
  defp aggregate_attempts(_value), do: "unknown"

  defp aggregate_status(status, allowed) when is_binary(status) and is_list(allowed) do
    if status in allowed, do: status, else: "unknown"
  end

  defp aggregate_status(_status, _allowed), do: "unknown"

  defp processing_error_category(event, job) do
    error = [event.last_error, job.last_error] |> Enum.find(&is_binary/1) || ""

    cond do
      String.contains?(error, "todo_outcome_learning_invalid_json") -> "invalid_json"
      String.contains?(error, "todo_outcome_learning_missing_pattern") -> "missing_pattern"
      String.contains?(error, "todo_learning_source_not_found") -> "source_not_found"
      String.contains?(error, "insufficient_privilege") -> "database_privilege"
      String.contains?(error, "permission denied") -> "database_privilege"
      String.contains?(error, "http_status") -> "llm_http_status"
      String.contains?(error, "http_error") -> "llm_http_error"
      String.contains?(error, "rate_limit") -> "llm_rate_limit"
      String.contains?(error, "timeout") -> "timeout"
      true -> "unknown"
    end
  end

  defp database_error_code(%Postgrex.Error{postgres: postgres}) when is_map(postgres),
    do: Map.get(postgres, :code, :unknown)

  defp database_error_code(_error), do: :unknown

  defp require_status(value, value, _reason), do: :ok
  defp require_status(_actual, _expected, reason), do: {:error, reason}

  defp validation_user_id do
    token = Ecto.UUID.generate() |> String.replace("-", "")
    "todo-outcome-validation-#{token}@validation.maraithon.invalid"
  end

  defp cleanup(user_id) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        # Exact durable-history mode requires its writer marker even for deleting
        # this isolated, synthetic, terminal queue row.
        Repo.query!(
          "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
          [],
          log: false
        )

        Repo.delete_all(from(job in BackgroundJob, where: job.user_id == ^user_id))
        Repo.delete_all(from(event in TodoLearningEvent, where: event.user_id == ^user_id))
        Repo.delete_all(from(todo in Todo, where: todo.user_id == ^user_id))
        Repo.delete_all(from(item in Item, where: item.user_id == ^user_id))
        Repo.delete_all(from(user in User, where: user.id == ^user_id))

        if Repo.exists?(from(user in User, where: user.id == ^user_id)),
          do: Repo.rollback(:todo_outcome_validation_cleanup_failed),
          else: :ok
      end)

    :ok
  end
end
