defmodule MaraithonWeb.RuntimeController do
  @moduledoc """
  Operator endpoints for the exact runtime's coordination lifecycle.

  `drain` asks this node to hand its partitions, Agents, and tasks back to
  PostgreSQL with local proofs before a revision replacement; `status` reports
  what the node still owns so a deploy can wait for a clean handover; `rejoin`
  lets a drained node register a fresh incarnation if the deploy is aborted.
  """
  use MaraithonWeb, :controller

  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.Coordination.{Partition, Session, TaskAssignment}

  def drain(conn, _params) do
    :ok = Session.request_drain()
    json(conn, Map.put(status_payload(), :drain_requested, true))
  end

  def status(conn, _params), do: json(conn, status_payload())

  def rejoin(conn, _params) do
    case Session.rejoin() do
      :ok -> json(conn, Map.put(status_payload(), :rejoin_requested, true))
      {:error, reason} -> conn |> put_status(409) |> json(%{error: inspect(reason)})
    end
  rescue
    _error -> conn |> put_status(503) |> json(%{error: "coordination_session_unavailable"})
  catch
    :exit, _reason ->
      conn |> put_status(503) |> json(%{error: "coordination_session_unavailable"})
  end

  defp status_payload do
    %{phase: phase, node_incarnation_id: node_id} = Session.status()

    %{
      phase: Atom.to_string(phase),
      node_incarnation_id: node_id,
      owned_partitions:
        count_owned(node_id, Partition, :owner_node_incarnation_id, [
          "preparing",
          "ready",
          "draining"
        ]),
      open_tasks:
        count_owned(node_id, TaskAssignment, :node_incarnation_id, [
          "reserved",
          "running",
          "termination_requested",
          "termination_proven"
        ]),
      # `open_tasks` only describes this serving incarnation. A task reserved
      # by an earlier, lost incarnation can keep its partition draining even
      # when this node is otherwise clean. Surface that global fence so deploy
      # tooling cannot mistake a local drain for a safe handover.
      unproven_tasks: count_unproven_tasks(),
      local_agent_leases: count_leases(node_id)
    }
  end

  defp count_owned(nil, _schema, _field, _states), do: 0

  defp count_owned(node_id, schema, field, states) do
    Repo.one(
      from(row in schema,
        where: field(row, ^field) == ^node_id and row.state in ^states,
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_unproven_tasks do
    Repo.one(
      from(task in TaskAssignment,
        where:
          task.state in ["reserved", "running", "termination_requested", "termination_proven"],
        select: count()
      )
    )
  rescue
    _error -> nil
  end

  defp count_leases(nil), do: 0

  defp count_leases(node_id) do
    Repo.one(
      from(lease in AgentRuntimeLease,
        where: lease.coordination_node_incarnation_id == ^node_id,
        select: count()
      )
    )
  rescue
    _error -> nil
  end
end
