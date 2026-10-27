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
  alias Maraithon.AgentSubscriptions
  alias Maraithon.Normalization
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLifecycleOperation
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentRestartGuard
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.DatabaseClock

  @default_limit 50
  @max_limit 200

  def upsert_binding(agent_or_id, attrs \\ %{})

  def upsert_binding(%Agent{} = agent, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      locked_agent = lock_agent!(agent.id)
      binding = lock_binding(locked_agent)
      _guard = lock_guard(locked_agent.id)
      _lease = lock_lease(locked_agent.id)
      _operation = lock_operation(locked_agent.id)

      ensure_same_user!(locked_agent, attrs)

      case binding do
        nil -> create_inactive_binding!(locked_agent, attrs)
        %Binding{} = binding -> patch_binding!(locked_agent, binding, attrs)
      end
    end)
    |> unwrap_transaction()
  end

  def upsert_binding(agent_id, attrs) when is_binary(agent_id) and is_map(attrs) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %Agent{} = agent -> upsert_binding(agent, attrs)
      nil -> {:error, :agent_not_found}
    end
  end

  @doc false
  def validate_binding_consent_input(user_id, consent)
      when is_binary(user_id) and is_map(consent) do
    case validate_explicit_consent(%Agent{user_id: user_id}, consent) do
      {:ok, _proof} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_binding_consent_input(_user_id, _consent),
    do: {:error, :binding_consent_required}

  @doc """
  Creates or activates a Binding from an explicit, same-user consent envelope.

  The caller must provide every authority-bearing scope map; omission is never
  interpreted as an empty grant. The proof fields and ActionLedger audit row are
  committed in the same transaction as the Binding transition.
  """
  def grant_binding_consent(agent_or_id, consent)

  def grant_binding_consent(%Agent{} = agent, consent) when is_map(consent) do
    with {:ok, proof} <- validate_explicit_consent(agent, consent) do
      Repo.transaction(fn ->
        locked_agent = lock_agent!(agent.id)
        binding = lock_binding(locked_agent)
        _guard = lock_guard(locked_agent.id)
        lease = lock_lease(locked_agent.id)
        operation = lock_operation(locked_agent.id)

        ensure_consent_owner!(locked_agent, proof)

        if match?(%Binding{}, binding) and binding.user_id != locked_agent.user_id,
          do: Repo.rollback(:binding_user_mismatch)

        if operation, do: Repo.rollback(:agent_drain_pending)
        if lease, do: Repo.rollback(:agent_drain_pending)

        now = DatabaseClock.now!()
        consent_token = Ecto.UUID.generate()

        attrs =
          proof.binding_attrs
          |> Map.merge(%{
            "agent_id" => locked_agent.id,
            "user_id" => locked_agent.user_id,
            "status" => "active",
            "consent_token" => consent_token,
            "consent_actor_id" => proof.actor_id,
            "consented_at" => now,
            "consent_digest" => proof.digest
          })

        consented =
          case binding do
            nil -> %Binding{} |> Binding.changeset(attrs) |> Repo.insert!()
            %Binding{} = existing -> existing |> Binding.changeset(attrs) |> Repo.update!()
          end

        case record_consent(consented, proof, consent_token) do
          {:ok, _audit} ->
            sync_delivery!(locked_agent)
            consented

          {:error, reason} ->
            Repo.rollback({:binding_consent_audit_failed, reason})
        end
      end)
      |> unwrap_transaction()
    end
  end

  def grant_binding_consent(agent_id, consent) when is_binary(agent_id) and is_map(consent) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %Agent{} = agent -> grant_binding_consent(agent, consent)
      nil -> {:error, :agent_not_found}
    end
  end

  def grant_binding_consent(_agent_or_id, _consent), do: {:error, :binding_consent_required}

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

  defp create_inactive_binding!(agent, attrs) do
    attrs = stringify_keys(attrs)
    requested_status = Map.get(attrs, "status", "paused")

    if requested_status == "active", do: Repo.rollback(:binding_consent_required)

    base = %{
      "agent_id" => agent.id,
      "user_id" => agent.user_id,
      "identity_key" => read_string(attrs, "identity_key", "agent:#{agent.id}"),
      "status" => requested_status,
      "credential_refs" => read_map(attrs, "credential_refs"),
      "connector_scope" => read_map(attrs, "connector_scope", agent.connector_grants || %{}),
      "memory_scope" => read_map(attrs, "memory_scope", agent.memory_scope || %{}),
      "tool_policy" => read_map(attrs, "tool_policy"),
      "routing_bindings" => read_map(attrs, "routing_bindings"),
      "metadata" => read_map(attrs, "metadata")
    }

    binding = %Binding{} |> Binding.changeset(base) |> Repo.insert!()
    sync_delivery!(agent)
    record_change(binding, "created_inactive")
    binding
  end

  defp patch_binding!(agent, binding, attrs) do
    if binding.user_id != agent.user_id, do: Repo.rollback(:binding_user_mismatch)

    attrs = stringify_keys(attrs)
    requested_status = Map.get(attrs, "status", binding.status)

    if requested_status == "active" and binding.status != "active" do
      Repo.rollback(:binding_consent_required)
    end

    if authority_change?(binding, attrs), do: Repo.rollback(:binding_consent_required)

    patch =
      attrs
      |> Map.take([
        "identity_key",
        "status",
        "credential_refs",
        "connector_scope",
        "memory_scope",
        "tool_policy",
        "routing_bindings",
        "metadata"
      ])

    binding = binding |> Binding.changeset(patch) |> Repo.update!()
    sync_delivery!(agent)
    record_change(binding, "updated")
    binding
  end

  defp authority_change?(binding, attrs) do
    Enum.any?(
      ~w(identity_key credential_refs connector_scope memory_scope tool_policy routing_bindings),
      fn field ->
        case Map.fetch(attrs, field) do
          :error -> false
          {:ok, incoming} -> incoming != Map.get(binding, String.to_existing_atom(field))
        end
      end
    )
  end

  defp validate_explicit_consent(%Agent{} = agent, consent) do
    consent = stringify_keys(consent)

    required = [
      "actor_id",
      "user_id",
      "identity_key",
      "credential_refs",
      "connector_scope",
      "memory_scope",
      "tool_policy",
      "routing_bindings"
    ]

    with true <- is_binary(agent.user_id) and agent.user_id != "",
         true <- Enum.all?(required, &Map.has_key?(consent, &1)),
         actor_id when is_binary(actor_id) <- consent["actor_id"],
         user_id when is_binary(user_id) <- consent["user_id"],
         true <- actor_id == agent.user_id and user_id == agent.user_id,
         identity_key when is_binary(identity_key) <- consent["identity_key"],
         true <- String.trim(identity_key) != "",
         true <-
           Enum.all?(
             ~w(credential_refs connector_scope memory_scope tool_policy routing_bindings),
             &is_map(consent[&1])
           ),
         metadata when is_map(metadata) <- Map.get(consent, "metadata", %{}),
         {:ok, canonical} <-
           AgentLifecycleOperations.canonical_payload(%{
             "actor_id" => actor_id,
             "user_id" => user_id,
             "identity_key" => identity_key,
             "credential_refs" => consent["credential_refs"],
             "connector_scope" => consent["connector_scope"],
             "memory_scope" => consent["memory_scope"],
             "tool_policy" => consent["tool_policy"],
             "routing_bindings" => consent["routing_bindings"],
             "metadata" => metadata
           }) do
      {:ok,
       %{
         actor_id: actor_id,
         digest: AgentLifecycleOperations.digest(canonical),
         canonical: canonical,
         binding_attrs: Map.drop(canonical, ["actor_id"])
       }}
    else
      _invalid -> {:error, :binding_consent_required}
    end
  end

  defp ensure_consent_owner!(agent, proof) do
    if agent.user_id == proof.actor_id and agent.user_id == proof.canonical["user_id"],
      do: :ok,
      else: Repo.rollback(:binding_user_mismatch)
  end

  defp ensure_same_user!(agent, attrs) do
    attrs = stringify_keys(attrs)

    case Map.fetch(attrs, "user_id") do
      {:ok, user_id} when user_id != agent.user_id -> Repo.rollback(:binding_user_mismatch)
      _same_or_missing -> :ok
    end
  end

  defp sync_delivery!(agent) do
    case AgentSubscriptions.sync_for_agent_locked(agent) do
      {:ok, _subscriptions} -> :ok
      {:error, reason} -> Repo.rollback({:binding_delivery_sync_failed, reason})
    end
  end

  defp record_consent(binding, proof, consent_token) do
    ActionLedger.record(%{
      user_id: binding.user_id,
      agent_id: binding.agent_id,
      surface: "agent_isolation",
      event_type: "agent_isolation.consent_granted",
      status: "completed",
      result_object_refs: %{
        "agent_isolation_binding" => binding.id,
        "consent_token" => consent_token
      },
      metadata: %{
        "actor_id" => proof.actor_id,
        "consent_digest" => Base.encode16(proof.digest, case: :lower),
        "credential_ref_keys" => proof.canonical["credential_refs"] |> Map.keys() |> Enum.sort(),
        "connector_scope_keys" => proof.canonical["connector_scope"] |> Map.keys() |> Enum.sort(),
        "memory_scope_keys" => proof.canonical["memory_scope"] |> Map.keys() |> Enum.sort(),
        "tool_policy_keys" => proof.canonical["tool_policy"] |> Map.keys() |> Enum.sort(),
        "routing_keys" => proof.canonical["routing_bindings"] |> Map.keys() |> Enum.sort()
      }
    })
  end

  defp lock_agent!(agent_id) do
    case Repo.one(from(agent in Agent, where: agent.id == ^agent_id, lock: "FOR UPDATE")) do
      %Agent{} = agent -> agent
      nil -> Repo.rollback(:agent_not_found)
    end
  end

  defp lock_binding(%Agent{id: agent_id, user_id: user_id}) when is_binary(user_id) do
    Repo.one(
      from(binding in Binding,
        where: binding.agent_id == ^agent_id,
        where: binding.user_id == ^user_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_binding(_agent), do: nil

  defp lock_guard(agent_id) do
    Repo.one(
      from(guard in AgentRestartGuard,
        where: guard.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_lease(agent_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_operation(agent_id) do
    Repo.one(
      from(operation in AgentLifecycleOperation,
        where: operation.agent_id == ^agent_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

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

  defp clamp_limit(value), do: Normalization.clamp_limit(value, @default_limit, @max_limit)

  defp read_string(attrs, key, default), do: Normalization.read_string(attrs, key, default)

  defp read_map(attrs, key, default \\ %{}), do: Normalization.read_map(attrs, key, default)

  defp read_datetime(attrs, key), do: Normalization.read_datetime(attrs, key)

  defp normalize_list(value), do: Normalization.string_list(value)

  defp stringify_keys(value), do: Normalization.stringify_keys(value)
end
