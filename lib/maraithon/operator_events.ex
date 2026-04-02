defmodule Maraithon.OperatorEvents do
  @moduledoc """
  Persistence and lookup for canonical operator events.
  """

  import Ecto.Query

  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Repo

  def record(attrs) when is_map(attrs) do
    normalized = normalize_attrs(attrs)

    case existing_event(normalized) do
      %OperatorEvent{} = event ->
        {:ok, event}

      nil ->
        %OperatorEvent{}
        |> OperatorEvent.changeset(normalized)
        |> Repo.insert()
        |> handle_dedupe_conflict(normalized)
    end
  end

  def record(_attrs), do: {:error, :invalid_operator_event}

  def list_events(opts \\ []) do
    user_id = Keyword.get(opts, :user_id)
    project_id = Keyword.get(opts, :project_id)
    source = Keyword.get(opts, :source)
    event_type = Keyword.get(opts, :event_type)
    limit = Keyword.get(opts, :limit, 50)

    OperatorEvent
    |> maybe_filter_user(user_id)
    |> maybe_filter_project(project_id)
    |> maybe_filter_source(source)
    |> maybe_filter_event_type(event_type)
    |> order_by([event], desc: event.occurred_at, desc: event.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent_for_user(user_id, limit \\ 20)

  def list_recent_for_user(user_id, limit) when is_binary(user_id) and is_integer(limit) do
    list_events(user_id: user_id, limit: limit)
  end

  def list_recent_for_user(_user_id, _limit), do: []

  defp existing_event(%{user_id: user_id, dedupe_key: dedupe_key})
       when is_binary(user_id) and is_binary(dedupe_key) do
    Repo.get_by(OperatorEvent, user_id: user_id, dedupe_key: dedupe_key)
  end

  defp existing_event(_attrs), do: nil

  defp handle_dedupe_conflict({:ok, %OperatorEvent{} = event}, _attrs), do: {:ok, event}

  defp handle_dedupe_conflict({:error, changeset}, %{user_id: user_id, dedupe_key: dedupe_key}) do
    case Repo.get_by(OperatorEvent, user_id: user_id, dedupe_key: dedupe_key) do
      %OperatorEvent{} = event -> {:ok, event}
      nil -> {:error, changeset}
    end
  end

  defp handle_dedupe_conflict({:error, changeset}, _attrs), do: {:error, changeset}

  defp maybe_filter_user(query, nil), do: query
  defp maybe_filter_user(query, ""), do: query

  defp maybe_filter_user(query, user_id) when is_binary(user_id) do
    where(query, [event], event.user_id == ^user_id)
  end

  defp maybe_filter_project(query, nil), do: query
  defp maybe_filter_project(query, ""), do: query

  defp maybe_filter_project(query, project_id) when is_binary(project_id) do
    where(query, [event], event.project_id == ^project_id)
  end

  defp maybe_filter_source(query, nil), do: query
  defp maybe_filter_source(query, ""), do: query

  defp maybe_filter_source(query, source) when is_binary(source) do
    where(query, [event], event.source == ^source)
  end

  defp maybe_filter_event_type(query, nil), do: query
  defp maybe_filter_event_type(query, ""), do: query

  defp maybe_filter_event_type(query, event_type) when is_binary(event_type) do
    where(query, [event], event.event_type == ^event_type)
  end

  defp normalize_attrs(attrs) do
    user_id = read_string(attrs, "user_id")
    project_id = read_string(attrs, "project_id")
    source = read_string(attrs, "source", "system")
    event_type = read_string(attrs, "event_type", "event.recorded")
    source_item_id = read_string(attrs, "source_item_id")
    payload = read_map(attrs, "payload")

    %{
      user_id: user_id,
      project_id: project_id,
      source: source,
      event_type: event_type,
      scope: inferred_scope(read_string(attrs, "scope"), project_id),
      source_item_id: source_item_id,
      dedupe_key:
        read_string(attrs, "dedupe_key", default_dedupe_key(source, event_type, source_item_id)),
      occurred_at: read_datetime(attrs, "occurred_at"),
      payload: payload,
      metadata: read_map(attrs, "metadata")
    }
  end

  defp inferred_scope("project", _project_id), do: "project"
  defp inferred_scope("global", nil), do: "global"
  defp inferred_scope(_scope, project_id) when is_binary(project_id), do: "project"
  defp inferred_scope(_, _project_id), do: "global"

  defp default_dedupe_key(source, event_type, nil),
    do: "#{source}:#{event_type}:#{Ecto.UUID.generate()}"

  defp default_dedupe_key(source, event_type, source_item_id),
    do: "#{source}:#{event_type}:#{source_item_id}"

  defp read_string(attrs, key, default \\ nil)

  defp read_string(attrs, key, default) when is_map(attrs) do
    atom_key = String.to_existing_atom(key)
    value = Map.get(attrs, key, Map.get(attrs, atom_key, default))

    case value do
      nil -> default
      "" -> default
      binary when is_binary(binary) -> String.trim(binary)
      other -> to_string(other)
    end
  rescue
    ArgumentError ->
      case Map.get(attrs, key, default) do
        nil -> default
        "" -> default
        binary when is_binary(binary) -> String.trim(binary)
        other -> to_string(other)
      end
  end

  defp read_map(attrs, key) when is_map(attrs) do
    atom_key = safe_existing_atom(key)

    case Map.get(attrs, key, atom_key && Map.get(attrs, atom_key, %{})) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    atom_key = safe_existing_atom(key)

    case Map.get(attrs, key, atom_key && Map.get(attrs, atom_key)) do
      %DateTime{} = value -> value
      binary when is_binary(binary) -> parse_datetime(binary)
      _ -> DateTime.utc_now()
    end
  end

  defp parse_datetime(binary) do
    case DateTime.from_iso8601(binary) do
      {:ok, datetime, _offset} -> datetime
      _ -> DateTime.utc_now()
    end
  end

  defp safe_existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
