defmodule Maraithon.Todos.SlackNameRepair do
  @moduledoc "Repairs source-backed names on the provider lane, including unaccepted Triage items."
  alias Maraithon.{Repo, Todos}
  alias Maraithon.Runtime.{BackgroundJobs, PeriodicJobs}
  alias Maraithon.Todos.{SlackNames, Todo}

  @job_type "runtime_partition:slack_todo_names"
  def job_type, do: @job_type

  def enqueue(%Todo{} = todo) do
    if todo.status in ~w(triage open snoozed) and SlackNames.needed?(todo) do
      BackgroundJobs.enqueue(@job_type, %{
        user_id: todo.user_id,
        queue: "runtime_provider_account",
        partition_key: PeriodicJobs.provider_partition(todo.user_id, "slack_names"),
        dedupe_key: "slack-todo-names:#{todo.id}:#{DateTime.to_iso8601(todo.updated_at)}",
        max_attempts: 3,
        payload: %{"todo_id" => todo.id}
      })
    else
      {:ok, nil}
    end
  end

  def run(user_id, todo_id) when is_binary(todo_id) do
    case Repo.get_by(Todo, id: todo_id, user_id: user_id) do
      %Todo{status: status} = todo when status in ~w(triage open snoozed) ->
        with {:ok, updated} <- Todos.resolve_slack_names(todo) do
          if SlackNames.needed?(updated),
            do: {:error, :slack_todo_identity_unresolved},
            else: {:ok, %{resolved: true}}
        end

      _ ->
        {:ok, %{skipped: true}}
    end
  end

  def run(_, _), do: {:error, :missing_todo_id}
end
