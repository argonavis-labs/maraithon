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
  @timeout_ms 240_000
  @poll_interval_ms 1_000

  def run do
    user_id = validation_user_id()

    try do
      with {:ok, _user} <- create_user(user_id),
           {:ok, todo} <- create_todo(user_id),
           {:ok, %{todo: dismissed}} <- dismiss_todo(user_id, todo.id),
           :ok <- require_status(dismissed.status, "dismissed", :todo_not_dismissed),
           %TodoLearningEvent{} = event <- learning_event(todo.id),
           :ok <- validate_event(event),
           %BackgroundJob{} = job <- learning_job(event.id),
           :ok <- validate_job(job),
           {:ok, processed_event, completed_job} <- await_processing(event.id, job.id) do
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
      cleanup(user_id)
    end
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
        {:error, :todo_outcome_validation_processing_failed}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, :todo_outcome_validation_timeout}

      true ->
        Process.sleep(@poll_interval_ms)
        await_processing(event_id, job_id, deadline)
    end
  end

  defp require_status(value, value, _reason), do: :ok
  defp require_status(_actual, _expected, reason), do: {:error, reason}

  defp validation_user_id do
    token = Ecto.UUID.generate() |> String.replace("-", "")
    "todo-outcome-validation-#{token}@validation.maraithon.invalid"
  end

  defp cleanup(user_id) do
    {:ok, :ok} =
      Repo.transaction(fn ->
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
