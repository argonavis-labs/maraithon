defmodule Maraithon.Runtime.Coordination.Session do
  @moduledoc """
  Local participant in the PostgreSQL-owned coordination protocol.

  Worker processes start fail-closed. This process is supervised last, verifies
  them, registers a joining incarnation, and publishes node readiness last. It
  is therefore stopped first: graceful shutdown revokes DB readiness and fences
  partitions before local workers are terminated.
  """

  use GenServer
  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.Config

  alias Maraithon.Runtime.Coordination.{
    Authority,
    NodeIncarnation,
    Planner,
    Protocol,
    TaskAssignment,
    TaskClaims,
    TaskSupervisor
  }

  alias Maraithon.Runtime.EffectTaskSupervisor

  @default_tick 2_000
  @default_node_ttl 30_000
  @default_partition_ttl 30_000
  @default_leader_ttl 15_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 30_000,
      type: :worker
    }
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def current do
    GenServer.call(__MODULE__, :current, 5_000)
  catch
    :exit, _ -> {:error, :coordination_session_unavailable}
  end

  def prepare_shutdown, do: GenServer.call(__MODULE__, :prepare_shutdown, 30_000)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session: nil,
      leader: nil,
      phase: :dormant,
      tick_ms:
        Keyword.get(opts, :tick_ms, Config.positive_integer(:coordination_tick_ms, @default_tick)),
      node_ttl_ms:
        Keyword.get(
          opts,
          :node_ttl_ms,
          Config.positive_integer(:coordination_node_ttl_ms, @default_node_ttl)
        ),
      partition_ttl_ms:
        Keyword.get(
          opts,
          :partition_ttl_ms,
          Config.positive_integer(:coordination_partition_ttl_ms, @default_partition_ttl)
        ),
      leader_ttl_ms:
        Keyword.get(
          opts,
          :leader_ttl_ms,
          Config.positive_integer(:coordination_leader_ttl_ms, @default_leader_ttl)
        ),
      transition_limit:
        Keyword.get(
          opts,
          :transition_limit,
          Config.positive_integer(:coordination_transition_limit, 4)
        ),
      required_workers: Keyword.get(opts, :required_workers, required_workers())
    }

    send(self(), :coordinate)
    {:ok, state}
  end

  @impl true
  def handle_call(
        :current,
        _from,
        %{phase: :ready, session: %NodeIncarnation{} = session} = state
      ),
      do: {:reply, {:ok, session}, state}

  def handle_call(:current, _from, state),
    do: {:reply, {:error, {:coordination_not_ready, state.phase}}, state}

  def handle_call(:prepare_shutdown, _from, state) do
    {reply, state} = drain(state)
    {:reply, reply, state}
  end

  @impl true
  def handle_info(:coordinate, state) do
    state = coordinate(state)
    Process.send_after(self(), :coordinate, state.tick_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    _ = drain(state)
    :ok
  end

  defp coordinate(%{phase: :dormant} = state) do
    if Config.multinode_coordination_enabled?() and Protocol.mode() == :active do
      case Authority.register_node(ttl_ms: state.node_ttl_ms) do
        {:ok, %NodeIncarnation{} = session} -> %{state | session: session, phase: :joining}
        _ -> state
      end
    else
      state
    end
  end

  defp coordinate(%{phase: :joining, session: session} = state) do
    if workers_ready?(state.required_workers) do
      case Authority.mark_node_ready(session) do
        {:ok, %NodeIncarnation{} = ready} ->
          %{state | session: ready, phase: :ready} |> ready_cycle()

        _ ->
          fail_closed(state)
      end
    else
      state
    end
  end

  defp coordinate(%{phase: :ready} = state), do: ready_cycle(state)
  defp coordinate(%{phase: :uncertain} = state), do: cleanup_uncertain(state)
  defp coordinate(state), do: state

  defp ready_cycle(state) do
    with {:ok, %NodeIncarnation{} = session} <-
           Authority.renew_node(state.session, state.node_ttl_ms),
         {:ok, _partitions} <- Authority.renew_partitions(session, state.partition_ttl_ms) do
      state = %{state | session: session}
      state = refresh_leader(state)
      _ = publish_preparing_partitions(session)
      _ = drain_revoked_partitions(session)
      _ = TaskClaims.reconcile_proven(100)
      if state.leader, do: Planner.plan_once(state.leader, limit: state.transition_limit)
      state
    else
      _ -> fail_closed(state)
    end
  end

  defp refresh_leader(%{leader: nil} = state) do
    case Authority.acquire_leader(state.session, state.leader_ttl_ms) do
      {:ok, preparing} ->
        case Authority.mark_leader_ready(preparing) do
          {:ok, ready} -> %{state | leader: ready}
          _ -> state
        end

      {:error, :leader_held} ->
        state

      _ ->
        state
    end
  end

  defp refresh_leader(%{leader: leader} = state) do
    case Authority.renew_leader(leader, state.leader_ttl_ms) do
      {:ok, renewed} -> %{state | leader: renewed}
      _ -> %{state | leader: nil}
    end
  end

  defp publish_preparing_partitions(session) do
    Authority.owned_partitions(session, ["preparing"])
    |> Enum.each(fn partition ->
      # All scoped pollers were verified before node readiness; partition ready
      # is the final authority publication, never an acquisition side effect.
      _ = Authority.mark_partition_ready(session, partition.partition_id)
    end)
  end

  defp drain_revoked_partitions(session) do
    Authority.locally_owned_revoked_partitions(session)
    |> Enum.each(fn partition ->
      _ = Authority.revoke_partition_workload(session, partition.partition_id)
      terminate_partition_tasks(session, partition.partition_id, partition.ownership_epoch)
    end)
  end

  defp terminate_partition_tasks(session, partition_id, epoch) do
    Repo.all(
      from a in TaskAssignment,
        where:
          a.node_incarnation_id == ^session.id and a.partition_id == ^partition_id and
            a.partition_epoch == ^epoch and a.state == "termination_requested",
        order_by: a.id
    )
    |> Enum.each(&terminate_exact_task/1)
  end

  defp terminate_exact_task(%TaskAssignment{work_kind: "background_job"} = assignment) do
    identity = task_identity(assignment)

    case TaskSupervisor.terminate_exact(identity) do
      {:ok, :never_activated} -> :ok
      {:ok, _proof} -> :ok
      {:unknown, _reason} -> :blocked
      _ -> :blocked
    end
  end

  defp terminate_exact_task(%TaskAssignment{work_kind: "effect"} = assignment) do
    claim = %{
      effect_id: assignment.work_id,
      agent_id: effect_agent_id(assignment.work_id),
      claim_token: assignment.claim_token,
      supervisor_id: assignment.supervisor_id,
      task_id: assignment.local_task_id
    }

    case EffectTaskSupervisor.terminate_exact(claim) do
      {:ok, proof} ->
        evidence = "effect-task-supervisor:#{proof}:#{assignment.local_task_id}"

        _ =
          Maraithon.Effects.Cancellation.record_local_coordination_termination(
            assignment,
            evidence
          )

        :ok

      {:unknown, _reason} ->
        :blocked

      _ ->
        :blocked
    end
  end

  defp task_identity(assignment),
    do: %{
      work_kind: assignment.work_kind,
      work_id: assignment.work_id,
      claim_token: assignment.claim_token,
      assignment_id: assignment.id,
      supervisor_id: assignment.supervisor_id,
      local_task_id: assignment.local_task_id
    }

  defp effect_agent_id(effect_id) do
    case Repo.query("SELECT agent_id FROM public.effects WHERE id = $1::uuid", [
           Ecto.UUID.dump!(effect_id)
         ]) do
      {:ok, %{rows: [[id]]}} -> Ecto.UUID.load!(id)
      _ -> nil
    end
  end

  defp drain(%{session: %NodeIncarnation{} = session} = state) do
    # PostgreSQL revocation happens before any local termination attempt.
    case Authority.begin_node_drain(session) do
      {:ok, :draining} ->
        terminate_local_agents()
        drain_revoked_partitions(%{session | state: "draining", ready_at: nil})
        _ = TaskClaims.reconcile_proven(100)

        _ =
          Authority.revoke_node(%{
            session
            | state: "draining",
              ready_at: nil,
              draining_at: session.draining_at || session.updated_at
          })

        {:ok, %{state | phase: :draining, leader: nil}}

      {:error, reason} ->
        {{:error, reason}, fail_closed(state)}
    end
  end

  defp drain(state), do: {:ok, state}

  defp terminate_local_agents do
    DynamicSupervisor.which_children(Maraithon.Runtime.AgentSupervisor)
    |> Enum.each(fn
      {_id, pid, _type, _modules} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(Maraithon.Runtime.AgentSupervisor, pid)

      _ ->
        :ok
    end)
  catch
    :exit, _ -> :ok
  end

  defp cleanup_uncertain(%{session: %NodeIncarnation{} = session} = state) do
    terminate_local_agents()
    terminate_local_tasks(session)
    _ = drain_revoked_partitions(session)
    _ = TaskClaims.reconcile_proven(100)
    %{state | phase: :uncertain, leader: nil}
  end

  defp cleanup_uncertain(state), do: %{state | phase: :uncertain, leader: nil}

  defp terminate_local_tasks(session) do
    Repo.all(
      from a in TaskAssignment,
        where: a.node_incarnation_id == ^session.id,
        where: a.state in ["reserved", "running", "termination_requested"],
        order_by: a.id
    )
    |> Enum.each(fn assignment ->
      assignment =
        if assignment.state in ["reserved", "running"] do
          case TaskClaims.request_termination(assignment) do
            {:ok, requested} -> requested
            _ -> assignment
          end
        else
          assignment
        end

      if assignment.state == "termination_requested", do: terminate_exact_task(assignment)
    end)
  rescue
    _ -> :blocked
  catch
    :exit, _ -> :blocked
  end

  defp fail_closed(state) do
    # Uncertainty revokes all local execution immediately. Durable settlement
    # still requires exact monitored termination proof and PostgreSQL fences.
    cleanup_uncertain(state)
  end

  defp workers_ready?(workers), do: Enum.all?(workers, &is_pid(Process.whereis(&1)))

  defp required_workers do
    [
      Maraithon.Runtime.BackgroundJobRunner,
      Maraithon.Runtime.EffectRunner,
      Maraithon.Runtime.Scheduler,
      Maraithon.Runtime.WakeCoordinator,
      Maraithon.Runtime.AgentWatcher
    ]
  end
end
