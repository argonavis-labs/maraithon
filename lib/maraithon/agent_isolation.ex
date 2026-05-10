defmodule Maraithon.AgentIsolation do
  @moduledoc """
  Per-agent isolation primitives for identity, credentials, sessions, routing,
  and tool-policy binding.
  """

  import Ecto.Query

  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.AgentIsolation.{Binding, Session}
  alias Maraithon.Repo

  @default_limit 50
  @max_limit 200

  def upsert_binding(agent_or_id, attrs \\ %{})

  def upsert_binding(%Agent{} = agent, attrs) when is_map(attrs) do
    attrs = binding_attrs(agent, attrs)

    case Repo.get_by(Binding, agent_id: agent.id) do
      nil ->
        %Binding{}
        |> Binding.changeset(attrs)
        |> Repo.insert()
        |> tap(fn
          {:ok, binding} -> record_change(binding, "created")
          _ -> :ok
        end)

      %Binding{} = binding ->
        binding
        |> Binding.changeset(attrs)
        |> Repo.update()
        |> tap(fn
          {:ok, updated_binding} -> record_change(updated_binding, "updated")
          _ -> :ok
        end)
    end
  end

  def upsert_binding(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %Agent{} = agent -> upsert_binding(agent, attrs)
      nil -> {:error, :agent_not_found}
    end
  end

  def get_binding(agent_id) when is_binary(agent_id) do
    Repo.get_by(Binding, agent_id: agent_id)
  end

  def get_binding(%Agent{} = agent), do: get_binding(agent.id)
  def get_binding(_agent_id), do: nil

  def list_bindings(opts \\ []) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    user_id = Keyword.get(opts, :user_id)
    status = Keyword.get(opts, :status)

    Binding
    |> maybe_filter(:user_id, user_id)
    |> maybe_filter(:status, status)
    |> order_by([binding], desc: binding.updated_at, desc: binding.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def put_session(agent_or_id, session_key, attrs \\ %{})

  def put_session(%Agent{} = agent, session_key, attrs)
      when is_binary(session_key) and is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "agent_id" => agent.id,
        "user_id" => agent.user_id,
        "session_key" => session_key,
        "status" => read_string(attrs, "status", "active"),
        "last_seen_at" => read_datetime(attrs, "last_seen_at") || DateTime.utc_now()
      })

    case Repo.get_by(Session, agent_id: agent.id, session_key: session_key) do
      nil -> %Session{} |> Session.changeset(attrs) |> Repo.insert()
      %Session{} = session -> session |> Session.changeset(attrs) |> Repo.update()
    end
  end

  def put_session(agent_id, session_key, attrs)
      when is_binary(agent_id) and is_binary(session_key) and is_map(attrs) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %Agent{} = agent -> put_session(agent, session_key, attrs)
      nil -> {:error, :agent_not_found}
    end
  end

  def get_session(agent_id, session_key, now \\ DateTime.utc_now())
      when is_binary(agent_id) and is_binary(session_key) do
    case Repo.get_by(Session, agent_id: agent_id, session_key: session_key, status: "active") do
      %Session{} = session ->
        if expired?(session, now), do: nil, else: session

      nil ->
        nil
    end
  end

  def route_for(agent_id, route_key, default \\ nil)
      when is_binary(agent_id) and is_binary(route_key) do
    case get_binding(agent_id) do
      %Binding{status: "active", routing_bindings: routing_bindings}
      when is_map(routing_bindings) ->
        Map.get(routing_bindings, route_key, default)

      _ ->
        default
    end
  end

  def policy_context(agent_or_id, attrs \\ %{}) when is_map(attrs) do
    case get_binding(agent_or_id) do
      %Binding{status: "active"} = binding ->
        attrs
        |> Map.new()
        |> Map.put_new(:agent_id, binding.agent_id)
        |> Map.put_new(:user_id, binding.user_id)
        |> Map.put(:agent_policy, binding.tool_policy || %{})
        |> Map.put(:agent_isolation, %{
          identity_key: binding.identity_key,
          credential_ref_keys: binding.credential_refs |> Map.keys() |> Enum.sort(),
          connector_scope: binding.connector_scope || %{},
          memory_scope: binding.memory_scope || %{},
          routing_keys: binding.routing_bindings |> Map.keys() |> Enum.sort()
        })

      _ ->
        attrs
    end
  end

  def tool_allowed?(%Binding{} = binding, tool_name) when is_binary(tool_name) do
    allowed_by_policy?(binding.tool_policy || %{}, tool_name)
  end

  def tool_allowed?(_binding, _tool_name), do: false

  def serialize_binding(%Binding{} = binding) do
    %{
      id: binding.id,
      agent_id: binding.agent_id,
      user_id: binding.user_id,
      identity_key: binding.identity_key,
      status: binding.status,
      credential_ref_keys: binding.credential_refs |> Map.keys() |> Enum.sort(),
      connector_scope: binding.connector_scope || %{},
      memory_scope: binding.memory_scope || %{},
      tool_policy: binding.tool_policy || %{},
      routing_keys: binding.routing_bindings |> Map.keys() |> Enum.sort(),
      metadata: binding.metadata || %{},
      inserted_at: binding.inserted_at,
      updated_at: binding.updated_at
    }
  end

  def serialize_session(%Session{} = session) do
    %{
      id: session.id,
      agent_id: session.agent_id,
      user_id: session.user_id,
      session_key: session.session_key,
      status: session.status,
      state_keys: session.state |> Map.keys() |> Enum.sort(),
      expires_at: session.expires_at,
      last_seen_at: session.last_seen_at,
      metadata: session.metadata || %{},
      inserted_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end

  defp binding_attrs(%Agent{} = agent, attrs) do
    attrs = stringify_keys(attrs)

    %{
      "agent_id" => agent.id,
      "user_id" => agent.user_id,
      "identity_key" => read_string(attrs, "identity_key", "agent:#{agent.id}"),
      "status" => read_string(attrs, "status", "active"),
      "credential_refs" => read_map(attrs, "credential_refs"),
      "connector_scope" => read_map(attrs, "connector_scope", agent.connector_grants || %{}),
      "memory_scope" => read_map(attrs, "memory_scope", agent.memory_scope || %{}),
      "tool_policy" => read_map(attrs, "tool_policy"),
      "routing_bindings" => read_map(attrs, "routing_bindings"),
      "metadata" => read_map(attrs, "metadata")
    }
  end

  defp allowed_by_policy?(policy, tool_name) when is_map(policy) do
    policy = stringify_keys(policy)
    denied_tools = policy |> Map.get("denied_tools", []) |> normalize_list()
    allowed_tools = policy |> Map.get("allowed_tools", []) |> normalize_list()

    cond do
      tool_name in denied_tools -> false
      allowed_tools != [] and tool_name not in allowed_tools -> false
      true -> true
    end
  end

  defp allowed_by_policy?(_policy, _tool_name), do: true

  defp expired?(%Session{expires_at: nil}, _now), do: false

  defp expired?(%Session{expires_at: expires_at}, now),
    do: DateTime.compare(expires_at, now) == :lt

  defp record_change(%Binding{} = binding, action) do
    ActionLedger.record(%{
      user_id: binding.user_id,
      agent_id: binding.agent_id,
      surface: "agent_isolation",
      event_type: "agent_isolation.changed",
      status: "completed",
      result_object_refs: %{"agent_isolation_binding" => binding.id},
      metadata: %{
        action: action,
        identity_key: binding.identity_key,
        connector_scope_keys: binding.connector_scope |> Map.keys() |> Enum.sort(),
        memory_scope_keys: binding.memory_scope |> Map.keys() |> Enum.sort(),
        routing_keys: binding.routing_bindings |> Map.keys() |> Enum.sort()
      }
    })

    :ok
  rescue
    _error -> :ok
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query

  defp maybe_filter(query, field, value) when field in [:user_id, :status] do
    where(query, [binding], field(binding, ^field) == ^value)
  end

  defp clamp_limit(value) when is_integer(value), do: min(max(value, 1), @max_limit)
  defp clamp_limit(_value), do: @default_limit

  defp read_string(attrs, key, default) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, key, default) do
      nil -> default
      "" -> default
      value when is_binary(value) -> value |> String.trim() |> blank_to_default(default)
      value -> value |> to_string() |> String.trim() |> blank_to_default(default)
    end
  end

  defp read_map(attrs, key, default \\ %{}) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, key, default) do
      value when is_map(value) -> stringify_keys(value)
      _ -> default
    end
  end

  defp read_datetime(attrs, key) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    case Map.get(attrs, key) do
      %DateTime{} = datetime ->
        datetime

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp blank_to_default("", default), do: default
  defp blank_to_default(value, _default), do: value

  defp normalize_list(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalize_list(_value), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value
end
