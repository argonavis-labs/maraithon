defmodule Maraithon.Runtime.Coordination.Planner do
  @moduledoc "Bounded deterministic partition assignment, stealing and rebalance planner."

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentRuntimeLease

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

    with {:finalize, {:ok, finalized}} <-
           {:finalize, run_stage(fn -> finalize_drained(leader, limit) end)},
         {:fence, {:ok, expired}} <-
           {:fence, run_stage(fn -> fence_expired(leader, max(limit - finalized, 0)) end)},
         {:assign, {:ok, assigned}} <-
           {:assign,
            run_stage(fn -> assign_unowned(leader, max(limit - finalized - expired, 0)) end)},
         {:rebalance, {:ok, rebalanced}} <-
           {:rebalance,
            run_stage(fn ->
              rebalance(leader, max(limit - finalized - expired - assigned, 0), cooldown_ms)
            end)} do
      {:ok, %{finalized: finalized, expired: expired, assigned: assigned, rebalanced: rebalanced}}
    else
      {stage, {:error, reason}} when stage in [:finalize, :fence, :assign, :rebalance] ->
        {:error, {stage, reason}}
    end
  end

  defp run_stage(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:error, {:database, database_error_code(error)}}
    _error -> {:error, :exception}
  catch
    :exit, _reason -> {:error, :exit}
  end

  defp database_error_code(%Postgrex.Error{postgres: %{code: code}})
       when code in [
              :check_violation,
              :foreign_key_violation,
              :insufficient_privilege,
              :lock_not_available,
              :query_canceled,
              :unique_violation,
              :undefined_column,
              :undefined_table
            ],
       do: code

  defp database_error_code(_error), do: :other

  defp finalize_drained(_leader, 0), do: {:ok, 0}

  defp finalize_drained(leader, limit) do
    unresolved_tasks =
      from assignment in TaskAssignment,
        where: assignment.partition_id == parent_as(:partition).partition_id,
        where: assignment.partition_epoch == parent_as(:partition).ownership_epoch,
        where:
          assignment.state in [
            "reserved",
            "running",
            "termination_requested",
            "termination_proven"
          ],
        select: 1

    live_agent_leases =
      from lease in AgentRuntimeLease,
        where: lease.coordination_partition_id == parent_as(:partition).partition_id,
        where: lease.coordination_partition_epoch == parent_as(:partition).ownership_epoch,
        select: 1

    ids =
      Repo.all(
        from p in Partition,
          as: :partition,
          where: p.state in ["draining", "blocked"],
          where: not exists(subquery(unresolved_tasks)),
          where: not exists(subquery(live_agent_leases)),
          order_by: [asc: p.draining_at, asc: p.partition_id],
          limit: ^limit,
          select: p.partition_id
      )

    count = Enum.count(ids, &release_ready?(leader, &1))

    {:ok, count}
  end

  defp release_ready?(leader, partition_id) do
    match?({:ok, :released}, Authority.release_drained_partition(leader, partition_id))
  rescue
    error in Postgrex.Error ->
      if release_gate_blocked?(error) or release_retryable?(error) do
        false
      else
        reraise error, __STACKTRACE__
      end
  end

  defp release_retryable?(%Postgrex.Error{postgres: %{code: code}})
       when code in [:lock_not_available, :query_canceled],
       do: true

  defp release_retryable?(_error), do: false

  defp release_gate_blocked?(%Postgrex.Error{
         postgres: %{code: :check_violation, message: message}
       })
       when is_binary(message),
       do: String.contains?(message, "partition cannot move before exact task proof")

  defp release_gate_blocked?(_error), do: false

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
