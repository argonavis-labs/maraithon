defmodule Maraithon.Runtime.IncidentLog do
  @moduledoc """
  Best-effort runtime incident logging and summary helpers.
  """

  import Ecto.Query

  alias Maraithon.Agents.AgentRun
  alias Maraithon.Effects.Effect
  alias Maraithon.Repo
  alias Maraithon.Runtime.RuntimeIncident
  alias Maraithon.Runtime.ScheduledJob

  require Logger

  @doc """
  Record a runtime incident.

  This function is intentionally best-effort: insert failures are returned and
  logged, but exceptions and exits are caught so instrumentation cannot bring
  down the runtime path that called it.
  """
  def record(attrs, opts \\ [])

  def record(attrs, opts) when is_map(attrs) or is_list(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    attrs =
      attrs
      |> Map.new()
      |> normalize_attrs()

    %RuntimeIncident{}
    |> RuntimeIncident.changeset(attrs)
    |> repo.insert()
  rescue
    error ->
      Logger.warning("Runtime incident record failed", reason: Exception.message(error))
      {:error, error}
  catch
    kind, reason ->
      Logger.warning("Runtime incident record exited",
        kind: inspect(kind),
        reason: inspect(reason)
      )

      {:error, reason}
  end

  def record(_attrs, _opts), do: {:error, :invalid_incident_attrs}

  def since(%DateTime{} = since, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    RuntimeIncident
    |> where([incident], incident.occurred_at >= ^since)
    |> order_by([incident], asc: incident.occurred_at)
    |> repo.all()
  end

  def between(%DateTime{} = since, %DateTime{} = until, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    RuntimeIncident
    |> where([incident], incident.occurred_at >= ^since)
    |> where([incident], incident.occurred_at <= ^until)
    |> order_by([incident], asc: incident.occurred_at)
    |> repo.all()
  end

  def by_kind(kind, since_or_opts \\ [])

  def by_kind(kind, %DateTime{} = since) do
    by_kind(kind, since: since)
  end

  def by_kind(kind, opts) when is_list(opts) do
    repo = Keyword.get(opts, :repo, Repo)
    kind = normalize_kind(kind)
    since = Keyword.get(opts, :since)

    RuntimeIncident
    |> where([incident], incident.kind == ^kind)
    |> maybe_since(since)
    |> order_by([incident], asc: incident.occurred_at)
    |> repo.all()
  end

  def count_by_kind(incidents) when is_list(incidents) do
    incidents
    |> Enum.reduce(%{}, fn
      %RuntimeIncident{kind: kind}, acc -> Map.update(acc, kind, 1, &(&1 + 1))
      %{kind: kind}, acc -> Map.update(acc, kind, 1, &(&1 + 1))
      %{"kind" => kind}, acc -> Map.update(acc, kind, 1, &(&1 + 1))
      _other, acc -> acc
    end)
  end

  def count_by_kind(%DateTime{} = since_at), do: since(since_at) |> count_by_kind()

  def uptime_segments(%DateTime{} = since, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    incidents =
      RuntimeIncident
      |> where([incident], incident.occurred_at >= ^since)
      |> where([incident], incident.occurred_at <= ^now)
      |> where([incident], incident.kind in ["node_boot", "node_shutdown"])
      |> order_by([incident], asc: incident.occurred_at)
      |> repo.all()

    {open_started_at, segments} =
      Enum.reduce(incidents, {nil, []}, fn incident, {open_started_at, segments} ->
        case {incident.kind, open_started_at} do
          {"node_boot", nil} ->
            {incident.occurred_at, segments}

          {"node_boot", started_at} ->
            {incident.occurred_at,
             [
               %{
                 started_at: started_at,
                 ended_at: incident.occurred_at,
                 clean_shutdown?: false
               }
               | segments
             ]}

          {"node_shutdown", started_at} when not is_nil(started_at) ->
            {nil,
             [
               %{
                 started_at: started_at,
                 ended_at: incident.occurred_at,
                 clean_shutdown?: true
               }
               | segments
             ]}

          _other ->
            {open_started_at, segments}
        end
      end)

    segments =
      if open_started_at do
        [
          %{started_at: open_started_at, ended_at: now, clean_shutdown?: nil}
          | segments
        ]
      else
        segments
      end

    Enum.reverse(segments)
  end

  def backlog_snapshot(opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    %{
      "pending_effects" => count_status(repo, Effect, "pending"),
      "failed_effects" => count_status(repo, Effect, "failed"),
      "pending_scheduled_jobs" => count_status(repo, ScheduledJob, "pending"),
      "running_agent_runs" => count_status(repo, AgentRun, "running")
    }
  rescue
    error ->
      %{"error" => Exception.message(error)}
  end

  defp normalize_attrs(attrs) do
    attrs
    |> maybe_put_default(:node, node_name())
    |> maybe_put_default(:occurred_at, DateTime.utc_now() |> DateTime.truncate(:microsecond))
    |> normalize_kind_attr()
    |> normalize_reason()
    |> normalize_metadata()
  end

  defp maybe_put_default(attrs, key, value) do
    if Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) do
      attrs
    else
      Map.put(attrs, key, value)
    end
  end

  defp normalize_kind_attr(attrs) do
    case Map.get(attrs, :kind) || Map.get(attrs, "kind") do
      nil -> attrs
      kind -> Map.put(attrs, :kind, normalize_kind(kind))
    end
  end

  defp normalize_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp normalize_kind(kind) when is_binary(kind), do: String.trim(kind)
  defp normalize_kind(kind), do: inspect(kind)

  defp normalize_reason(attrs) do
    case Map.get(attrs, :reason) || Map.get(attrs, "reason") do
      nil -> attrs
      reason when is_binary(reason) -> Map.put(attrs, :reason, String.trim(reason))
      reason -> Map.put(attrs, :reason, inspect(reason))
    end
  end

  defp normalize_metadata(attrs) do
    case Map.get(attrs, :metadata) || Map.get(attrs, "metadata") do
      metadata when is_map(metadata) -> Map.put(attrs, :metadata, metadata)
      nil -> Map.put(attrs, :metadata, %{})
      metadata -> Map.put(attrs, :metadata, %{"value" => inspect(metadata)})
    end
  end

  defp node_name, do: node() |> Atom.to_string()

  defp maybe_since(query, %DateTime{} = since),
    do: where(query, [incident], incident.occurred_at >= ^since)

  defp maybe_since(query, _since), do: query

  defp count_status(repo, schema, status) do
    schema
    |> where([row], row.status == ^status)
    |> repo.aggregate(:count, :id)
  end
end
