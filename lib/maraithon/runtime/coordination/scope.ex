defmodule Maraithon.Runtime.Coordination.Scope do
  @moduledoc "Fail-closed access to the current DB-owned node and partition scope."

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.Config

  require Logger

  alias Maraithon.Runtime.Coordination.{
    NodeIncarnation,
    Partition,
    Partitioning,
    Protocol,
    Session
  }

  @active_mode "partition_fenced_v1"
  @protocol_name "runtime"
  @ready_states ["ready"]
  @owner_states ["ready", "draining"]

  def enabled?, do: Protocol.mode() == :active

  @doc "Returns the local session only while PostgreSQL still proves ready node authority."
  def current do
    with :ok <- coordination_enabled(),
         :active <- Protocol.mode(),
         {:ok, %NodeIncarnation{} = session} <- current_session(),
         :ok <- live_ready_session(session) do
      {:ok, session}
    else
      :dark -> {:error, :coordination_not_enabled}
      {:blocked, _reason} = blocked -> {:error, blocked}
      {:error, _reason} = error -> error
      _stale -> {:error, :coordination_session_stale}
    end
  rescue
    _ -> {:error, :coordination_session_unavailable}
  catch
    :exit, _ -> {:error, :coordination_session_unavailable}
  end

  def ready_partitions do
    with {:ok, session} <- current() do
      {:ok, ready_partitions(session)}
    end
  rescue
    _ -> {:error, :coordination_session_unavailable}
  catch
    :exit, _ -> {:error, :coordination_session_unavailable}
  end

  def partition_for_user(user_id) do
    with {:ok, session} <- current(),
         tenant when is_binary(tenant) <- Partitioning.tenant_key(user_id),
         %Partition{} = partition <- ready_partition(session, tenant) do
      {:ok, session, partition}
    else
      _ -> {:error, :partition_not_owned}
    end
  rescue
    _ -> {:error, :partition_not_owned}
  catch
    :exit, _ -> {:error, :partition_not_owned}
  end

  @doc "Proves a live ready Agent lease belongs to the current exact partition incarnation."
  def partition_for_agent_owner(agent_id, owner_generation) do
    with {:ok, session} <- current(),
         {:ok, agent_id} <- Ecto.UUID.cast(agent_id),
         {:ok, owner_generation} <- Ecto.UUID.cast(owner_generation),
         %Partition{} = partition <- ready_agent_partition(session, agent_id, owner_generation) do
      {:ok, session, partition}
    else
      _ -> {:error, :agent_partition_not_owned}
    end
  rescue
    _ -> {:error, :agent_partition_not_owned}
  catch
    :exit, _ -> {:error, :agent_partition_not_owned}
  end

  @doc "Adds the current ready node/partition proof to an Agent-scoped SQL query."
  def scope_ready_agent(query, %NodeIncarnation{} = session, agent_binding \\ :agent)
      when is_atom(agent_binding) do
    from [{^agent_binding, agent}] in query,
      where:
        fragment(
          """
          EXISTS (
            SELECT 1
            FROM public.runtime_coordination_protocols AS coordination_protocol
            JOIN public.runtime_partitions AS coordination_partition
              ON coordination_partition.activation_epoch = coordination_protocol.activation_epoch
            JOIN public.runtime_node_incarnations AS coordination_node
              ON coordination_node.id = coordination_partition.owner_node_incarnation_id
             AND coordination_node.activation_epoch = coordination_partition.activation_epoch
            WHERE coordination_protocol.name = 'runtime'
              AND coordination_protocol.mode = 'partition_fenced_v1'
              AND coordination_protocol.activation_epoch = ?::uuid
              AND coordination_node.id = ?::uuid
              AND coordination_node.state = 'ready'
              AND coordination_node.ready_at IS NOT NULL
              AND coordination_node.lease_expires_at > timezone('UTC', clock_timestamp())
              AND coordination_partition.partition_id =
                    public.runtime_partition_for('user:' || ?)
              AND coordination_partition.activation_epoch = ?::uuid
              AND coordination_partition.ownership_epoch > 0
              AND coordination_partition.owner_node_incarnation_id = ?::uuid
              AND coordination_partition.state = 'ready'
              AND coordination_partition.ready_at IS NOT NULL
              AND coordination_partition.lease_expires_at >
                    timezone('UTC', clock_timestamp())
          )
          """,
          type(^session.activation_epoch, :binary_id),
          type(^session.id, :binary_id),
          agent.user_id,
          type(^session.activation_epoch, :binary_id),
          type(^session.id, :binary_id)
        )
  end

  @doc "Adds exact live Agent-lease and current ready partition proof to a SQL query."
  def scope_ready_agent_lease(
        query,
        %NodeIncarnation{} = session,
        agent_binding \\ :agent,
        lease_binding \\ :lease
      )
      when is_atom(agent_binding) and is_atom(lease_binding) do
    from [{^agent_binding, agent}, {^lease_binding, lease}] in query,
      where:
        fragment(
          """
          EXISTS (
            SELECT 1
            FROM public.runtime_coordination_protocols AS coordination_protocol
            JOIN public.runtime_partitions AS coordination_partition
              ON coordination_partition.activation_epoch = coordination_protocol.activation_epoch
             AND coordination_partition.partition_id = ?
             AND coordination_partition.ownership_epoch = ?
             AND coordination_partition.owner_node_incarnation_id = ?::uuid
            JOIN public.runtime_node_incarnations AS coordination_node
              ON coordination_node.id = coordination_partition.owner_node_incarnation_id
             AND coordination_node.activation_epoch = coordination_partition.activation_epoch
            WHERE coordination_protocol.name = 'runtime'
              AND coordination_protocol.mode = 'partition_fenced_v1'
              AND coordination_protocol.activation_epoch = ?::uuid
              AND coordination_node.id = ?::uuid
              AND coordination_node.state = 'ready'
              AND coordination_node.ready_at IS NOT NULL
              AND coordination_node.lease_expires_at > timezone('UTC', clock_timestamp())
              AND coordination_partition.partition_id =
                    public.runtime_partition_for('user:' || ?)
              AND coordination_partition.activation_epoch = ?::uuid
              AND coordination_partition.state = 'ready'
              AND coordination_partition.ready_at IS NOT NULL
              AND coordination_partition.lease_expires_at >
                    timezone('UTC', clock_timestamp())
              AND ? = ?::uuid
              AND ? = ?::uuid
              AND ? > timezone('UTC', clock_timestamp())
          )
          """,
          lease.coordination_partition_id,
          lease.coordination_partition_epoch,
          lease.coordination_node_incarnation_id,
          type(^session.activation_epoch, :binary_id),
          type(^session.id, :binary_id),
          agent.user_id,
          type(^session.activation_epoch, :binary_id),
          lease.coordination_activation_epoch,
          type(^session.activation_epoch, :binary_id),
          lease.coordination_node_incarnation_id,
          type(^session.id, :binary_id),
          lease.lease_until
        )
  end

  @doc "Executes one bounded Agent query in legacy or current ready-partition scope."
  def all_ready_agent(query, agent_binding \\ :agent) do
    case active_or_legacy() do
      :legacy -> Repo.all(query)
      {:ok, session} -> query |> scope_ready_agent(session, agent_binding) |> Repo.all()
      {:error, _reason} -> []
    end
  end

  @doc "Executes one live Agent-lease query in legacy or current ready-partition scope."
  def all_ready_agent_lease(query, agent_binding \\ :agent, lease_binding \\ :lease) do
    case active_or_legacy() do
      :legacy ->
        Repo.all(query)

      {:ok, session} ->
        query
        |> scope_ready_agent_lease(session, agent_binding, lease_binding)
        |> Repo.all()

      {:error, _reason} ->
        []
    end
  end

  @doc "Checks one live Agent-lease query in legacy or current ready-partition scope."
  def exists_ready_agent_lease(query, agent_binding \\ :agent, lease_binding \\ :lease) do
    case active_or_legacy() do
      :legacy ->
        Repo.exists?(query)

      {:ok, session} ->
        query
        |> scope_ready_agent_lease(session, agent_binding, lease_binding)
        |> Repo.exists?()

      {:error, _reason} ->
        false
    end
  end

  @doc "Installs exact transaction-local reconciliation evidence after DB authority proof."
  def authorize_reconciliation!(agent) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Agent reconciliation authority requires transaction")

    case Protocol.mode() do
      :dark ->
        if legacy_scope_allowed?(),
          do: :legacy,
          else: Repo.rollback(:runtime_coordination_not_active)

      :active ->
        with {:ok, session} <- current(),
             tenant when is_binary(tenant) <- Partitioning.tenant_key(agent.user_id),
             %Partition{} = partition <- ready_partition(session, tenant) do
          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.runtime_agent_reconciliation', $1, true)",
            [agent.id]
          )

          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.runtime_node_action', $1, true)",
            [session.id]
          )

          %{session: session, partition: partition}
        else
          _ -> Repo.rollback(:partition_not_owned)
        end

      blocked ->
        Repo.rollback({:coordination_protocol_blocked, blocked})
    end
  end

  @doc "Adds a statement-time exact reconciliation fence to a mutation query."
  def scope_reconciliation_mutation(query, :legacy), do: query

  def scope_reconciliation_mutation(
        query,
        %{session: %NodeIncarnation{} = session, partition: %Partition{} = partition}
      ) do
    authority =
      dynamic(
        [],
        fragment(
          """
          EXISTS (
            SELECT 1
            FROM public.runtime_coordination_protocols AS coordination_protocol
            JOIN public.runtime_partitions AS coordination_partition
              ON coordination_partition.activation_epoch = coordination_protocol.activation_epoch
            JOIN public.runtime_node_incarnations AS coordination_node
              ON coordination_node.id = coordination_partition.owner_node_incarnation_id
             AND coordination_node.activation_epoch = coordination_partition.activation_epoch
            WHERE coordination_protocol.name = 'runtime'
              AND coordination_protocol.mode = 'partition_fenced_v1'
              AND coordination_protocol.activation_epoch = ?::uuid
              AND coordination_partition.partition_id = ?
              AND coordination_partition.activation_epoch = ?::uuid
              AND coordination_partition.ownership_epoch = ?
              AND coordination_partition.owner_node_incarnation_id = ?::uuid
              AND coordination_partition.state = 'ready'
              AND coordination_partition.ready_at IS NOT NULL
              AND coordination_partition.lease_expires_at >
                    timezone('UTC', clock_timestamp())
              AND coordination_node.id = ?::uuid
              AND coordination_node.state = 'ready'
              AND coordination_node.ready_at IS NOT NULL
              AND coordination_node.lease_expires_at > timezone('UTC', clock_timestamp())
          )
          """,
          type(^session.activation_epoch, :binary_id),
          ^partition.partition_id,
          type(^partition.activation_epoch, :binary_id),
          ^partition.ownership_epoch,
          type(^session.id, :binary_id),
          type(^session.id, :binary_id)
        )
      )

    where(query, ^authority)
  end

  @doc """
  Fences an existing Agent lease against its exact current partition incarnation.

  Pass the `session` already proven earlier in the same transaction (before any
  row locks were taken) so the fence never waits on the coordination Session
  while holding node or partition locks the Session's own tick must update.
  Without a session the current one is resolved from the published scope.
  """
  def fence_lease!(lease, mode, session \\ nil)

  def fence_lease!(%AgentRuntimeLease{} = lease, mode, session)
      when mode in [:ready, :owner] and (is_nil(session) or is_struct(session, NodeIncarnation)) do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Agent lease partition fence requires transaction")

    case Protocol.mode() do
      :dark ->
        if legacy_scope_allowed?(),
          do: :ok,
          else: Repo.rollback(:runtime_coordination_not_active)

      :active ->
        with {:ok, session} <- fence_session(session),
             true <- lease.coordination_activation_epoch == session.activation_epoch,
             true <- lease.coordination_node_incarnation_id == session.id,
             :ok <- lock_live_lease_partition(session, lease, mode) do
          :ok
        else
          failure ->
            Logger.warning("Agent lease partition fence refused",
              failure_code: fence_failure_class(failure)
            )

            Repo.rollback(:partition_authority_lost)
        end

      blocked ->
        Repo.rollback({:coordination_protocol_blocked, blocked})
    end
  end

  defp fence_session(nil), do: current()

  defp fence_session(%NodeIncarnation{} = session) do
    case live_ready_session(session) do
      :ok -> {:ok, session}
      {:error, _reason} = error -> error
      _stale -> {:error, :coordination_session_stale}
    end
  end

  defp fence_failure_class({:error, reason}), do: Maraithon.Redaction.error_class(reason)
  defp fence_failure_class(false), do: "lease_session_mismatch"
  defp fence_failure_class(other), do: Maraithon.Redaction.error_class(other)

  def active_or_legacy do
    case Protocol.mode() do
      :dark ->
        if legacy_scope_allowed?(),
          do: :legacy,
          else: {:error, :runtime_coordination_not_active}

      :active ->
        current()

      blocked ->
        {:error, blocked}
    end
  end

  def ensure_ready_or_legacy do
    case active_or_legacy() do
      :legacy -> :ok
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_session do
    # This config hook is compiled to `nil` outside tests. Indirect dispatch keeps
    # newer compilers from treating the test-only struct branch as unreachable.
    case apply(Config, :coordination_test_session, []) do
      %NodeIncarnation{} = session -> {:ok, session}
      nil -> Session.current()
    end
  end

  defp legacy_scope_allowed? do
    EffectProtocol.mode() == :legacy or Config.protocol_test_bypass?()
  end

  defp coordination_enabled do
    if Config.multinode_coordination_enabled?(),
      do: :ok,
      else: {:error, :coordination_not_enabled}
  end

  defp live_ready_session(%NodeIncarnation{} = session) do
    case SQL.query(
           Repo,
           """
           SELECT 1
           FROM public.runtime_coordination_protocols AS protocol
           JOIN public.runtime_node_incarnations AS node
             ON node.activation_epoch = protocol.activation_epoch
           WHERE protocol.name = $1 AND protocol.mode = $2
             AND protocol.activation_epoch = $3::uuid
             AND node.id = $4::uuid
             AND node.state = 'ready' AND node.ready_at IS NOT NULL
             AND node.lease_expires_at > timezone('UTC', clock_timestamp())
           LIMIT 1
           """,
           [
             @protocol_name,
             @active_mode,
             Ecto.UUID.dump!(session.activation_epoch),
             Ecto.UUID.dump!(session.id)
           ]
         ) do
      {:ok, %{rows: [[1]]}} -> :ok
      {:ok, _missing} -> {:error, :coordination_session_stale}
      {:error, _reason} -> {:error, :coordination_session_unavailable}
    end
  end

  defp ready_partitions(%NodeIncarnation{} = session) do
    Repo.all(
      from partition in Partition,
        join: node in NodeIncarnation,
        on:
          node.id == partition.owner_node_incarnation_id and
            node.activation_epoch == partition.activation_epoch,
        join: protocol in "runtime_coordination_protocols",
        on:
          field(protocol, :name) == @protocol_name and
            field(protocol, :mode) == @active_mode and
            field(protocol, :activation_epoch) == partition.activation_epoch,
        where: partition.activation_epoch == ^session.activation_epoch,
        where: partition.owner_node_incarnation_id == ^session.id,
        where: partition.state == "ready" and not is_nil(partition.ready_at),
        where: partition.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        where: node.id == ^session.id,
        where: node.state == "ready" and not is_nil(node.ready_at),
        where: node.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        order_by: partition.partition_id,
        select: partition
    )
  end

  defp ready_partition(%NodeIncarnation{} = session, tenant) do
    session
    |> ready_partition_query(tenant)
    |> Repo.one()
  end

  defp ready_partition_query(%NodeIncarnation{} = session, tenant) do
    from partition in Partition,
      join: node in NodeIncarnation,
      on:
        node.id == partition.owner_node_incarnation_id and
          node.activation_epoch == partition.activation_epoch,
      join: protocol in "runtime_coordination_protocols",
      on:
        field(protocol, :name) == @protocol_name and field(protocol, :mode) == @active_mode and
          field(protocol, :activation_epoch) == partition.activation_epoch,
      where: partition.partition_id == fragment("public.runtime_partition_for(?)", ^tenant),
      where: partition.activation_epoch == ^session.activation_epoch,
      where: partition.owner_node_incarnation_id == ^session.id,
      where: partition.state == "ready" and not is_nil(partition.ready_at),
      where: partition.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
      where: node.id == ^session.id,
      where: node.state == "ready" and not is_nil(node.ready_at),
      where: node.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
      select: partition
  end

  defp ready_agent_partition(session, agent_id, owner_generation) do
    Repo.one(
      from lease in AgentRuntimeLease,
        join: agent in Maraithon.Agents.Agent,
        on: agent.id == lease.agent_id,
        join: partition in Partition,
        on:
          partition.partition_id == lease.coordination_partition_id and
            partition.activation_epoch == lease.coordination_activation_epoch and
            partition.ownership_epoch == lease.coordination_partition_epoch and
            partition.owner_node_incarnation_id == lease.coordination_node_incarnation_id,
        join: node in NodeIncarnation,
        on:
          node.id == partition.owner_node_incarnation_id and
            node.activation_epoch == partition.activation_epoch,
        join: protocol in "runtime_coordination_protocols",
        on:
          field(protocol, :name) == @protocol_name and field(protocol, :mode) == @active_mode and
            field(protocol, :activation_epoch) == partition.activation_epoch,
        where: lease.agent_id == ^agent_id and lease.owner_token == ^owner_generation,
        where: lease.lease_until > fragment("timezone('UTC', clock_timestamp())"),
        where: not is_nil(lease.ready_at) and is_nil(lease.draining_at),
        where: lease.coordination_activation_epoch == ^session.activation_epoch,
        where: lease.coordination_node_incarnation_id == ^session.id,
        where:
          partition.partition_id ==
            fragment("public.runtime_partition_for('user:' || ?)", agent.user_id),
        where: partition.state == "ready" and not is_nil(partition.ready_at),
        where: partition.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        where: node.id == ^session.id,
        where: node.state == "ready" and not is_nil(node.ready_at),
        where: node.lease_expires_at > fragment("timezone('UTC', clock_timestamp())"),
        select: partition
    )
  end

  defp lock_live_lease_partition(session, lease, mode) do
    states = if mode == :ready, do: @ready_states, else: @owner_states
    ready_required = mode == :ready
    activation_epoch = Ecto.UUID.dump!(session.activation_epoch)
    node_incarnation_id = Ecto.UUID.dump!(session.id)

    with {:ok, %{rows: [[1]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM public.runtime_node_incarnations
             WHERE id = $1::uuid AND activation_epoch = $2::uuid
             FOR SHARE
             """,
             [node_incarnation_id, activation_epoch]
           ),
         {:ok, %{rows: [[1]]}} <-
           SQL.query(
             Repo,
             """
             SELECT 1
             FROM public.runtime_partitions
             WHERE partition_id = $1 AND activation_epoch = $2::uuid
               AND ownership_epoch = $3
               AND owner_node_incarnation_id = $4::uuid
             FOR SHARE
             """,
             [
               lease.coordination_partition_id,
               activation_epoch,
               lease.coordination_partition_epoch,
               node_incarnation_id
             ]
           ),
         {:ok, %{rows: [[partition_id]]}} when partition_id == lease.coordination_partition_id <-
           SQL.query(
             Repo,
             """
             SELECT partition.partition_id
             FROM public.runtime_coordination_protocols AS protocol
             JOIN public.runtime_partitions AS partition
               ON partition.activation_epoch = protocol.activation_epoch
             JOIN public.runtime_node_incarnations AS node
               ON node.id = partition.owner_node_incarnation_id
              AND node.activation_epoch = partition.activation_epoch
             JOIN public.agents AS agent ON agent.id = $7::uuid
             WHERE protocol.name = $1 AND protocol.mode = $2
               AND protocol.activation_epoch = $3::uuid
               AND partition.partition_id = $4
               AND partition.activation_epoch = $3::uuid
               AND partition.ownership_epoch = $5
               AND partition.owner_node_incarnation_id = $6::uuid
               AND partition.partition_id =
                     public.runtime_partition_for('user:' || agent.user_id)
               AND partition.state = ANY($8::text[])
               AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
               AND node.id = $6::uuid AND node.state = ANY($8::text[])
               AND node.lease_expires_at > timezone('UTC', clock_timestamp())
               AND (NOT $9::boolean OR
                    (partition.state = 'ready' AND partition.ready_at IS NOT NULL AND
                     node.state = 'ready' AND node.ready_at IS NOT NULL))
             LIMIT 1
             """,
             [
               @protocol_name,
               @active_mode,
               activation_epoch,
               lease.coordination_partition_id,
               lease.coordination_partition_epoch,
               node_incarnation_id,
               Ecto.UUID.dump!(lease.agent_id),
               states,
               ready_required
             ]
           ) do
      :ok
    else
      _ -> {:error, :partition_authority_lost}
    end
  end
end
