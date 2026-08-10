defmodule Maraithon.Runtime.Coordination.Scope do
  @moduledoc "Fail-closed access to the current DB-owned node and partition scope."
  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.Coordination.{Authority, Partitioning, Protocol, Session}

  def enabled?, do: Protocol.mode() == :active

  def current do
    if Config.multinode_coordination_enabled?() and Protocol.active?(),
      do: Session.current(),
      else: {:error, :coordination_not_enabled}
  end

  def ready_partitions do
    with {:ok, session} <- current() do
      {:ok, Authority.owned_partitions(session, ["ready"])}
    end
  end

  def partition_for_user(user_id) do
    with {:ok, session} <- current(),
         tenant when is_binary(tenant) <- Partitioning.tenant_key(user_id),
         partition_id when is_integer(partition_id) <- Partitioning.partition_for(tenant),
         partition when not is_nil(partition) <-
           Enum.find(
             Authority.owned_partitions(session, ["ready"]),
             &(&1.partition_id == partition_id)
           ) do
      {:ok, session, partition}
    else
      _ -> {:error, :partition_not_owned}
    end
  end

  def partition_for_agent_owner(agent_id, owner_generation) do
    with {:ok, session} <- current(),
         {:ok, agent_id} <- Ecto.UUID.cast(agent_id),
         {:ok, owner_generation} <- Ecto.UUID.cast(owner_generation),
         {:ok, %{rows: [[partition_id, partition_epoch]]}} <-
           SQL.query(
             Repo,
             """
             SELECT lease.coordination_partition_id, lease.coordination_partition_epoch
             FROM public.agent_runtime_leases AS lease
             JOIN public.runtime_partitions AS partition
               ON partition.partition_id = lease.coordination_partition_id
              AND partition.activation_epoch = lease.coordination_activation_epoch
              AND partition.ownership_epoch = lease.coordination_partition_epoch
              AND partition.owner_node_incarnation_id = lease.coordination_node_incarnation_id
              AND partition.state = 'ready' AND partition.ready_at IS NOT NULL
              AND partition.lease_expires_at > timezone('UTC', clock_timestamp())
             WHERE lease.agent_id = $1::uuid AND lease.owner_token = $2::uuid
               AND lease.ready_at IS NOT NULL AND lease.draining_at IS NULL
               AND lease.lease_until > timezone('UTC', clock_timestamp())
               AND lease.coordination_activation_epoch = $3::uuid
               AND lease.coordination_node_incarnation_id = $4::uuid
             """,
             [
               Ecto.UUID.dump!(agent_id),
               Ecto.UUID.dump!(owner_generation),
               Ecto.UUID.dump!(session.activation_epoch),
               Ecto.UUID.dump!(session.id)
             ]
           ),
         partition when not is_nil(partition) <-
           Enum.find(
             Authority.owned_partitions(session, ["ready"]),
             &(&1.partition_id == partition_id and &1.ownership_epoch == partition_epoch)
           ) do
      {:ok, session, partition}
    else
      _ -> {:error, :agent_partition_not_owned}
    end
  end

  def active_or_legacy do
    case Protocol.mode() do
      :dark -> :legacy
      :active -> current()
      blocked -> {:error, blocked}
    end
  end
end
