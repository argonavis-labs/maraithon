defmodule Maraithon.Todos.ProductionValidator do
  @moduledoc """
  Runs the narrow, aggregate-only production check for the explicitly authorized
  launch account. It may repair Gmail watch state and perform an incremental
  sync, but never returns message, Todo, project, account, or token content.
  """

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Agents.Agent
  alias Maraithon.Connectors.Gmail
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.Crm.Observation
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Projects.Project
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.Todos.Todo

  @authorized_email "kent@runner.now"
  @known_sources ~w(gmail slack google_calendar calendar local_calendar calendar_local imessage messages local_messages voice_memos notes reminders files browser_history whatsapp)

  def run(@authorized_email = email) do
    started_at = DateTime.utc_now()

    case Accounts.get_user_by_email(email) do
      nil ->
        {:error, :authorized_user_not_found}

      user ->
        accounts = connected_accounts(user.id)
        google_result = repair_google_ingestion(user.id, accounts)
        queue_result = await_relationship_jobs(user.id, started_at)

        {:ok,
         %{
           authorized_user: true,
           confirmed_user: not is_nil(user.confirmed_at),
           connected_account_families: account_family_counts(accounts),
           runtime: runtime_summary(user.id),
           google_ingestion: google_result,
           relationship_jobs: queue_result,
           observations: observation_counts(user.id),
           todos: todo_counts(user.id),
           projects: project_counts(user.id)
         }}
    end
  end

  def run(_email), do: {:error, :unauthorized_validation_target}

  defp connected_accounts(user_id) do
    ConnectedAccount
    |> where([account], account.user_id == ^user_id and account.status == "connected")
    |> order_by([account], asc: account.id)
    |> Repo.all()
  end

  defp runtime_summary(user_id) do
    chief_counts =
      from(agent in Agent,
        where: agent.user_id == ^user_id and agent.behavior == "ai_chief_of_staff",
        select: %{
          installed: count(agent.id),
          enabled: fragment("count(*) FILTER (WHERE ? = 'enabled')", agent.install_status),
          running: fragment("count(*) FILTER (WHERE ? = 'running')", agent.status)
        }
      )
      |> Repo.one()

    %{
      coordination: protocol_label(CoordinationProtocol.mode()),
      effects: protocol_label(EffectProtocol.mode()),
      chief_of_staff: chief_counts
    }
  end

  defp repair_google_ingestion(user_id, accounts) do
    results =
      accounts
      |> Enum.filter(&(provider_family(&1.provider) == "google"))
      |> Enum.map(&repair_google_account(user_id, &1))

    %{
      accounts_checked: length(results),
      watches_active: Enum.count(results, &(&1.watch == "active")),
      syncs_completed: Enum.count(results, &(&1.sync == "completed")),
      messages_seen: Enum.reduce(results, 0, &(&1.messages_seen + &2)),
      unavailable: Enum.count(results, &(&1.sync == "unavailable"))
    }
  end

  defp repair_google_account(user_id, account) do
    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, account.provider) do
      watch = repair_gmail_watch(user_id, account, access_token)

      case Gmail.sync_history(user_id, account, provider: account.provider) do
        {:ok, result} ->
          %{
            watch: watch,
            sync: "completed",
            messages_seen: non_negative_count(result[:count] || result["count"])
          }

        {:error, _reason} ->
          %{watch: watch, sync: "unavailable", messages_seen: 0}
      end
    else
      {:error, _reason} -> %{watch: "unavailable", sync: "unavailable", messages_seen: 0}
    end
  rescue
    _error -> %{watch: "unavailable", sync: "unavailable", messages_seen: 0}
  end

  defp repair_gmail_watch(user_id, account, access_token) do
    case Gmail.setup_watch(user_id, access_token) do
      {:ok, watch} ->
        attrs = %{"watch_expires_at" => watch.expiration}

        attrs =
          if watch.history_id,
            do: Map.put(attrs, "value", to_string(watch.history_id)),
            else: attrs

        case SourceCursors.put(account, "gmail_history_id", attrs) do
          {:ok, _cursor} -> "active"
          _other -> "unavailable"
        end

      {:error, _reason} ->
        "unavailable"
    end
  rescue
    _error -> "unavailable"
  end

  defp await_relationship_jobs(user_id, started_at) do
    deadline = System.monotonic_time(:millisecond) + 90_000
    await_relationship_jobs(user_id, started_at, deadline)
  end

  defp await_relationship_jobs(user_id, started_at, deadline) do
    counts = relationship_job_counts(user_id, started_at)
    active = Map.get(counts, "pending", 0) + Map.get(counts, "running", 0)

    if active > 0 and System.monotonic_time(:millisecond) < deadline do
      Process.sleep(2_000)
      await_relationship_jobs(user_id, started_at, deadline)
    else
      %{
        completed: Map.get(counts, "completed", 0),
        failed: Map.get(counts, "failed", 0),
        active: active
      }
    end
  end

  defp relationship_job_counts(user_id, started_at) do
    from(job in BackgroundJob,
      where: job.user_id == ^user_id,
      where: job.job_type == "relationship_ingestion",
      where: job.inserted_at >= ^started_at,
      group_by: job.status,
      select: {job.status, count(job.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp account_family_counts(accounts) do
    counts = Enum.frequencies_by(accounts, &provider_family(&1.provider))

    %{
      google: Map.get(counts, "google", 0),
      slack: Map.get(counts, "slack", 0),
      other:
        Enum.reduce(counts, 0, fn {family, count}, total ->
          if family in ["google", "slack"], do: total, else: total + count
        end)
    }
  end

  defp observation_counts(user_id) do
    counts =
      from(observation in Observation,
        where: observation.user_id == ^user_id and observation.source in ^@known_sources,
        group_by: observation.source,
        select: {observation.source, count(observation.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      gmail: Map.get(counts, "gmail", 0),
      slack: Map.get(counts, "slack", 0),
      calendar: Map.get(counts, "google_calendar", 0)
    }
  end

  defp todo_counts(user_id) do
    total = Repo.aggregate(from(todo in Todo, where: todo.user_id == ^user_id), :count, :id)

    source_counts =
      from(todo in Todo,
        where: todo.user_id == ^user_id and todo.source in ^@known_sources,
        group_by: todo.source,
        select: {todo.source, count(todo.id)}
      )
      |> Repo.all()
      |> Map.new()

    actionability =
      from(todo in Todo,
        where: todo.user_id == ^user_id,
        group_by: todo.agent_actionability,
        select: {todo.agent_actionability, count(todo.id)}
      )
      |> Repo.all()
      |> Map.new()

    %{
      total: total,
      connected_source_total:
        Enum.reduce(source_counts, 0, fn {_source, count}, sum -> sum + count end),
      gmail: Map.get(source_counts, "gmail", 0),
      slack: Map.get(source_counts, "slack", 0),
      can_prepare: Map.get(actionability, "can_prepare", 0),
      can_execute: Map.get(actionability, "can_execute", 0),
      needs_you: Map.get(actionability, "needs_you", 0),
      assigned_to_project:
        Repo.aggregate(
          from(todo in Todo, where: todo.user_id == ^user_id and not is_nil(todo.project_id)),
          :count,
          :id
        )
    }
  end

  defp project_counts(user_id) do
    %{
      total:
        Repo.aggregate(from(project in Project, where: project.user_id == ^user_id), :count, :id)
    }
  end

  defp provider_family("google"), do: "google"
  defp provider_family("google:" <> _), do: "google"
  defp provider_family("slack"), do: "slack"
  defp provider_family("slack:" <> _), do: "slack"
  defp provider_family(_provider), do: "other"

  defp protocol_label(:dark), do: "dark"
  defp protocol_label(:legacy), do: "legacy"
  defp protocol_label(:active), do: "active"
  defp protocol_label(:exact), do: "exact"
  defp protocol_label(_blocked), do: "blocked"

  defp non_negative_count(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_count(_value), do: 0
end
