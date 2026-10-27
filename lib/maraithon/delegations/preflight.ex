defmodule Maraithon.Delegations.Preflight do
  @moduledoc "Durable read-only grant previews; only an explicit submission creates authority."
  import Ecto.Query
  alias Maraithon.{Accounts.ConnectedAccount, AssistantIdentities, Repo, SourceErrorCopy}
  alias Maraithon.AssistantChat.Execution
  alias Maraithon.Delegations.{Gates, Preferences, Scope}

  alias Maraithon.Runtime.{
    BackgroundJob,
    BackgroundJobs,
    JobAuthority,
    PeriodicJobs,
    TokenRefresher
  }

  alias Maraithon.Todos.Todo

  @job_type "delegation_preflight"

  def preview(user_id, todo_id, attrs) do
    with {:ok, todo} <- todo(user_id, todo_id),
         true <-
           attrs["actor"] in ~w(as_user as_assistant) and
             attrs["kind"] in ~w(information scheduling coordination),
         {:ok, job} <- find_or_start(todo, attrs),
         true <- job.payload["attrs"] == Map.take(attrs, ~w(actor kind)) do
      response(job, todo)
    else
      false -> {:error, :invalid_delegation_scope}
      error -> error
    end
  end

  def scope(user_id, todo_id, attrs) do
    with {:ok, todo} <- todo(user_id, todo_id),
         {:ok, job} <- fetch(user_id, todo_id, attrs["preflight_id"]),
         {:ok, %{scope: %{} = scope}} <- response(job, todo) do
      Scope.reviewed(todo, scope, attrs)
    else
      {:ok, _} -> {:error, :preflight_pending}
      error -> error
    end
  end

  def execute(%BackgroundJob{job_type: @job_type} = job) do
    job = BackgroundJob.hydrate_payloads(job)

    Execution.with_authority(job, fn ->
      with {:ok, :ok} <- JobAuthority.transaction(job, fn -> :ok end),
           true <- DateTime.diff(DateTime.utc_now(), job.inserted_at) < 86_400,
           {:ok, todo} <- todo(job.user_id, job.payload["todo_id"]),
           true <- Scope.todo_fingerprint(todo) == job.payload["todo_fingerprint"],
           true <- configuration(todo) == job.payload["configuration"] do
        case Scope.preview(todo, job.payload["attrs"], page_progress: job.result["progress"]) do
          {:ok, scope} ->
            {:ok, %{"scope" => scope}}

          {:pending, progress} ->
            {:ok, %{"progress" => progress}, {:reschedule_in, 1_000}}

          {:error, {:rate_limited, seconds, _}} when is_integer(seconds) ->
            {:error, {:retry_after, max(seconds, 30), :rate_limited}}

          {:error, {:rate_limited, _}} ->
            {:error, {:retry_after, 30, :rate_limited}}

          error ->
            error
        end
      else
        false -> {:error, {:discard, :preflight_expired}}
        error -> error
      end
    end)
  end

  defp find_or_start(todo, %{"preflight_id" => id}) when is_binary(id),
    do: fetch(todo.user_id, todo.id, id)

  defp find_or_start(todo, attrs) do
    attrs = Map.take(attrs, ~w(actor kind))
    fingerprint = Scope.todo_fingerprint(todo)
    configuration = configuration(todo)
    key = "preflight:#{todo.user_id}:#{Scope.hash([todo.id, attrs, fingerprint, configuration])}"
    cutoff = DateTime.add(DateTime.utc_now(), -1_800, :second)

    existing =
      Repo.one(
        from j in BackgroundJob,
          where: j.user_id == ^todo.user_id and j.job_type == @job_type and j.dedupe_key == ^key,
          where:
            j.status in ~w(pending running) or
              (j.status == "completed" and j.completed_at > ^cutoff),
          order_by: [desc: j.inserted_at],
          limit: 1
      )

    with nil <- existing,
         %ConnectedAccount{status: "connected"} = account <-
           Repo.get_by(ConnectedAccount, id: todo.source_account_id, user_id: todo.user_id) do
      BackgroundJobs.enqueue(@job_type, %{
        user_id: todo.user_id,
        queue: "runtime_provider_account",
        partition_key: PeriodicJobs.provider_partition(todo.user_id, account.provider),
        rate_limit_key: TokenRefresher.provider_family(account.provider),
        dedupe_key: key,
        max_attempts: 3,
        payload: %{
          "todo_id" => todo.id,
          "todo_fingerprint" => fingerprint,
          "configuration" => configuration,
          "attrs" => attrs
        }
      })
    else
      %BackgroundJob{} = job -> {:ok, BackgroundJob.hydrate_payloads(job)}
      _ -> {:error, :delegation_source_unavailable}
    end
  end

  defp fetch(user_id, todo_id, id) do
    with {:ok, _} <- Ecto.UUID.cast(id),
         %BackgroundJob{} = job <-
           Repo.get_by(BackgroundJob, id: id, user_id: user_id, job_type: @job_type)
           |> BackgroundJob.hydrate_payloads(),
         true <- job.payload["todo_id"] == todo_id do
      {:ok, job}
    else
      _ -> {:error, :preflight_expired}
    end
  end

  defp response(job, todo) do
    cond do
      job.payload["todo_fingerprint"] != Scope.todo_fingerprint(todo) ->
        {:error, :todo_changed}

      job.payload["configuration"] != configuration(todo) ->
        {:error, :scope_changed}

      job.status == "completed" and is_map(job.result["scope"]) and not is_nil(job.completed_at) and
          DateTime.diff(DateTime.utc_now(), job.completed_at) < 1_800 ->
        {:ok, %{scope: job.result["scope"], preflight: %{id: job.id, status: "ready"}}}

      job.status in ~w(pending running) ->
        delay = DateTime.diff(job.scheduled_at, DateTime.utc_now(), :millisecond)

        {:ok,
         %{
           preflight: %{
             id: job.id,
             status: "pending",
             retry_after_ms: min(max(delay, 2_000), 30_000)
           }
         }}

      job.status == "failed" ->
        {:error, {:preflight_failed, SourceErrorCopy.reason(job.last_error)}}

      true ->
        {:error, :preflight_expired}
    end
  end

  # Local settings changes invalidate a saved review without another provider scan.
  defp configuration(todo) do
    assistant = AssistantIdentities.get(todo.user_id)
    account = Repo.get_by(ConnectedAccount, id: todo.source_account_id, user_id: todo.user_id)

    Scope.hash([
      Preferences.get(todo.user_id),
      assistant && Map.take(assistant, [:id, :gmail_connected_account_id, :gmail_mode, :data]),
      account && Map.take(account, [:id, :provider, :external_account_id, :status, :scopes])
    ])
  end

  defp todo(user_id, id) do
    with true <- Gates.enabled?(user_id),
         {:ok, _} <- Ecto.UUID.cast(id),
         %Todo{} = todo <- Repo.get_by(Todo, id: id, user_id: user_id),
         true <- Maraithon.Delegations.available?(todo) do
      {:ok, todo}
    else
      _ -> {:error, :delegation_source_unavailable}
    end
  end
end
