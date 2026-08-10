defmodule Maraithon.Runtime.Coordination.Scope do
  @moduledoc "Fail-closed access to the current DB-owned node and partition scope."
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

  def active_or_legacy do
    case Protocol.mode() do
      :dark -> :legacy
      :active -> current()
      blocked -> {:error, blocked}
    end
  end
end
