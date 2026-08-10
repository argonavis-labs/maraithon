defmodule Maraithon.Runtime.Coordination.Planner do
  @moduledoc "Bounded deterministic partition assignment, stealing and rebalance planner."

  import Ecto.Query
  alias Maraithon.Repo

  alias Maraithon.Runtime.Coordination.{
    Authority,
    Partition,
    Partitioning,
    TaskAssignment
  }

  @max_limit 16

  def plan_once(leader, opts \\ []) when is_map(leader) and is_list(opts) do
    limit = Keyword.get(opts, :limit, 4) |> max(1) |> min(@max_limit)
    cooldown_ms = Keyword.get(opts, :cooldown_ms, 60_000) |> max(1_000)

    with {:ok, finalized} <- finalize_drained(leader, limit),
         {:ok, expired} <- fence_expired(leader, max(limit - finalized, 0)),
         {:ok, assigned} <- assign_unowned(leader, max(limit - finalized - expired, 0)),
         {:ok, rebalanced} <-
           rebalance(leader, max(limit - finalized - expired - assigned, 0), cooldown_ms) do
      {:ok, %{finalized: finalized, expired: expired, assigned: assigned, rebalanced: rebalanced}}
    end
  end

  defp finalize_drained(_leader, 0), do: {:ok, 0}

  defp finalize_drained(leader, limit) do
    ids =
      Repo.all(
        from p in Partition,
          where: p.state in ["draining", "blocked"],
          order_by: [asc: p.draining_at, asc: p.partition_id],
          limit: ^limit,
          select: p.partition_id
      )

    count =
      Enum.count(ids, fn id ->
        match?({:ok, :released}, Authority.release_drained_partition(leader, id))
      end)

    {:ok, count}
  end

  defp fence_expired(_leader, 0), do: {:ok, 0}

  defp fence_expired(leader, limit) do
    partitions =
      Repo.all(
        from p in Partition,
          where: p.state in ["preparing", "ready"],
          where: p.lease_expires_at <= fragment("timezone('UTC', clock_timestamp())"),
          order_by: [asc: p.lease_expires_at, asc: p.partition_id],
          limit: ^limit
      )

    count =
      Enum.count(partitions, fn partition ->
        match?(
          {:ok, %Partition{}},
          Authority.begin_partition_drain(leader, partition.partition_id, kind: "lease_expired")
        )
      end)

    {:ok, count}
  end

  defp assign_unowned(_leader, 0), do: {:ok, 0}

  defp assign_unowned(leader, limit) do
    nodes = Authority.active_nodes()

    ids =
      Repo.all(
        from p in Partition,
          where: p.state == "unassigned",
          order_by: p.partition_id,
          limit: ^limit,
          select: p.partition_id
      )

    count =
      Enum.count(ids, fn id ->
        case Partitioning.rendezvous_owner(id, Enum.map(nodes, & &1.id)) do
          nil ->
            false

          target_id ->
            target = Enum.find(nodes, &(&1.id == target_id))
            match?({:ok, %Partition{}}, Authority.assign_partition(leader, target, id))
        end
      end)

    {:ok, count}
  end

  defp rebalance(_leader, 0, _cooldown), do: {:ok, 0}

  defp rebalance(leader, limit, cooldown_ms) do
    nodes = Authority.active_nodes()
    node_ids = Enum.map(nodes, & &1.id)

    if length(node_ids) < 2 do
      {:ok, 0}
    else
      candidates =
        Repo.all(
          from p in Partition,
            where: p.state == "ready",
            where:
              is_nil(p.last_moved_at) or
                p.last_moved_at <=
                  fragment(
                    "timezone('UTC', clock_timestamp()) - (? * interval '1 millisecond')",
                    ^cooldown_ms
                  ),
            order_by: [asc_nulls_first: p.last_moved_at, asc: p.partition_id],
            limit: ^(limit * 4)
        )

      moves =
        candidates
        |> Enum.filter(fn p ->
          Partitioning.rendezvous_owner(p.partition_id, node_ids) != p.owner_node_incarnation_id
        end)
        |> Enum.filter(&idle?/1)
        |> Enum.take(limit)

      count =
        Enum.count(moves, fn partition ->
          target = Partitioning.rendezvous_owner(partition.partition_id, node_ids)

          match?(
            {:ok, %Partition{}},
            Authority.begin_partition_drain(leader, partition.partition_id,
              kind: "rebalance",
              target_node_incarnation_id: target
            )
          )
        end)

      {:ok, count}
    end
  end

  defp idle?(partition) do
    not Repo.exists?(
      from a in TaskAssignment,
        where:
          a.partition_id == ^partition.partition_id and
            a.partition_epoch == ^partition.ownership_epoch and
            a.state in ["reserved", "running", "termination_requested", "termination_proven"]
    )
  end
end
