defmodule Maraithon.Runtime.Coordination.TaskAuthority do
  @moduledoc false
  use GenServer

  alias Maraithon.Runtime.Coordination.{TaskClaims, TaskSupervisor}
  @call_timeout 5_000
  @proof_timeout 2_000
  @max_proofs 512

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def identity, do: GenServer.call(__MODULE__, :identity, @call_timeout)

  def reserve(work_kind, work_id, claim_token, assignment_id) do
    with {:ok, identity} <-
           validate(
             %{
               work_kind: to_string(work_kind),
               work_id: work_id,
               claim_token: claim_token,
               assignment_id: assignment_id,
               supervisor_id: Ecto.UUID.generate(),
               local_task_id: Ecto.UUID.generate()
             },
             false
           ) do
      GenServer.call(__MODULE__, {:reserve, Map.drop(identity, [:supervisor_id])}, @call_timeout)
    end
  end

  def release(identity), do: call_valid(identity, :release)
  def activate(identity), do: call_valid(identity, :activate)

  def terminate_exact(identity),
    do: call_valid(identity, :terminate_exact, {:unknown, :invalid_task_identity})

  @impl true
  def init(_opts) do
    if is_nil(Process.whereis(TaskSupervisor.task_supervisor())) do
      {:ok,
       %{
         supervisor_id: Ecto.UUID.generate(),
         reservations: %{},
         monitors: %{},
         proofs: MapSet.new(),
         proof_order: []
       }}
    else
      # Restarting this authority alone cannot manufacture absence of tasks in
      # the still-live supervisor incarnation.
      {:stop, :coordinated_task_supervisor_predecessor_still_running}
    end
  end

  @impl true
  def handle_call(:identity, _from, state), do: {:reply, {:ok, state.supervisor_id}, state}

  def handle_call({:reserve, base}, {owner, _}, state) do
    identity = base |> Map.put(:supervisor_id, state.supervisor_id)
    owner_ref = Process.monitor(owner)

    reservation =
      Map.merge(identity, %{owner: owner, owner_ref: owner_ref, task_pid: nil, task_ref: nil})

    state = %{
      state
      | reservations: Map.put(state.reservations, identity.local_task_id, reservation),
        monitors: Map.put(state.monitors, owner_ref, {:owner, identity.local_task_id})
    }

    {:reply, {:ok, identity}, state}
  end

  def handle_call({:release, identity}, {caller, _}, state) do
    case exact(state, identity) do
      %{owner: ^caller, task_pid: nil} = reservation -> {:reply, :ok, delete(state, reservation)}
      _ -> {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  def handle_call({:activate, identity}, {task_pid, _}, state) do
    case exact(state, identity) do
      %{task_pid: nil} = reservation ->
        if supervised?(task_pid) do
          task_ref = Process.monitor(task_pid)
          reservation = %{reservation | task_pid: task_pid, task_ref: task_ref}

          state = %{
            state
            | reservations: Map.put(state.reservations, identity.local_task_id, reservation),
              monitors: Map.put(state.monitors, task_ref, {:task, identity.local_task_id})
          }

          {:reply, :ok, state}
        else
          {:reply, {:error, :task_not_supervised}, state}
        end

      %{task_pid: ^task_pid} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  def handle_call({:terminate_exact, identity}, _from, state) do
    cond do
      identity.supervisor_id != state.supervisor_id ->
        {:reply, {:unknown, :task_supervisor_incarnation_unreachable}, state}

      reservation = exact(state, identity) ->
        terminate_reservation(reservation, state)

      MapSet.member?(state.proofs, proof_key(identity)) ->
        {:reply, {:ok, :terminated}, state}

      true ->
        # Registry or child-list absence is deliberately not proof.
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      {:owner, task_id} -> owner_down(task_id, state)
      {:task, task_id} -> task_down(task_id, reason, state)
      nil -> {:noreply, state}
    end
  end

  defp owner_down(task_id, state) do
    case Map.get(state.reservations, task_id) do
      %{task_pid: pid, owner_ref: owner_ref} = reservation when is_pid(pid) ->
        _ = terminate_child(pid)
        reservation = %{reservation | owner: nil, owner_ref: nil}

        {:noreply,
         %{
           state
           | reservations: Map.put(state.reservations, task_id, reservation),
             monitors: Map.delete(state.monitors, owner_ref)
         }}

      %{} = reservation ->
        {:noreply, delete(state, reservation)}

      nil ->
        {:noreply, state}
    end
  end

  defp task_down(task_id, reason, state) do
    case Map.get(state.reservations, task_id) do
      nil ->
        {:noreply, state}

      reservation ->
        identity = public_identity(reservation)
        # The monitor is exact physical termination proof. Persistence failure
        # retains the reservation/proof in memory; it is never converted from a
        # Registry miss, timeout, lease expiry or node event.
        _ = persist_down_proof(identity, reason)
        state = remember_proof(delete(state, reservation), identity)
        {:noreply, state}
    end
  end

  defp terminate_reservation(%{task_pid: nil} = reservation, state) do
    identity = public_identity(reservation)
    # This exact Authority owns a reservation that never activated under its
    # coupled Task.Supervisor. Abort only the reserved ledger; do not manufacture
    # a physical-DOWN proof or any provider outcome.
    case TaskClaims.abort_reserved(load_assignment(identity)) do
      {:ok, _} ->
        {:reply, {:ok, :never_activated}, remember_proof(delete(state, reservation), identity)}

      _ ->
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  rescue
    _ -> {:reply, {:unknown, :termination_proof_persistence_failed}, state}
  end

  defp terminate_reservation(%{task_pid: pid, task_ref: ref} = reservation, state) do
    result = terminate_child(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        identity = public_identity(reservation)

        case persist_down_proof(identity, reason) do
          :ok ->
            {:reply, {:ok, :terminated}, remember_proof(delete(state, reservation), identity)}

          _ ->
            {:reply, {:unknown, :termination_proof_persistence_failed}, state}
        end
    after
      @proof_timeout ->
        _ = result
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  defp persist_down_proof(identity, reason) do
    assignment = load_assignment(identity)

    case assignment.state do
      state when state in ["settled", "outcome_ambiguous"] ->
        :ok

      _ ->
        with {:ok, requested} <- normalize(TaskClaims.request_termination(assignment)),
             {:ok, _proof} <-
               normalize(
                 TaskClaims.record_local_termination(
                   requested,
                   "supervisor_down",
                   "task-down:#{identity.local_task_id}:#{proof_reason(reason)}"
                 )
               ) do
          :ok
        end
    end
  rescue
    _ -> {:error, :proof_persistence_failed}
  end

  defp load_assignment(identity) do
    case TaskClaims.get(identity.assignment_id) do
      nil -> raise "task assignment missing"
      assignment -> assignment
    end
  end

  defp normalize({:ok, value}), do: {:ok, value}
  defp normalize(value) when is_struct(value), do: {:ok, value}
  defp normalize(other), do: {:error, other}

  defp exact(state, identity) do
    case Map.get(state.reservations, identity.local_task_id) do
      reservation when is_map(reservation) ->
        if public_identity(reservation) == identity, do: reservation

      _ ->
        nil
    end
  end

  defp public_identity(value),
    do:
      Map.take(value, [
        :work_kind,
        :work_id,
        :claim_token,
        :assignment_id,
        :supervisor_id,
        :local_task_id
      ])

  defp proof_key(identity),
    do:
      {identity.assignment_id, identity.claim_token, identity.supervisor_id,
       identity.local_task_id}

  defp remember_proof(state, identity) do
    key = proof_key(identity)
    order = [key | Enum.reject(state.proof_order, &(&1 == key))] |> Enum.take(@max_proofs)
    %{state | proof_order: order, proofs: MapSet.new(order)}
  end

  defp delete(state, reservation) do
    refs = Enum.filter([reservation.owner_ref, reservation.task_ref], &is_reference/1)
    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | reservations: Map.delete(state.reservations, reservation.local_task_id),
        monitors: Map.drop(state.monitors, refs)
    }
  end

  defp supervised?(pid), do: pid in Task.Supervisor.children(TaskSupervisor.task_supervisor())

  defp terminate_child(pid),
    do: Task.Supervisor.terminate_child(TaskSupervisor.task_supervisor(), pid)

  defp proof_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp proof_reason(_), do: "terminated"

  defp call_valid(identity, action, invalid \\ {:error, :invalid_task_identity}) do
    case validate(identity, true) do
      {:ok, valid} -> GenServer.call(__MODULE__, {action, valid}, @call_timeout)
      {:error, _} -> invalid
    end
  end

  defp validate(identity, require_supervisor?) when is_map(identity) do
    fields = [:work_id, :claim_token, :assignment_id, :local_task_id]
    fields = if require_supervisor?, do: [:supervisor_id | fields], else: fields

    with true <- Map.get(identity, :work_kind) in ~w(background_job effect),
         true <- Enum.all?(fields, &match?({:ok, _}, Ecto.UUID.cast(Map.get(identity, &1)))) do
      {:ok, identity}
    else
      _ -> {:error, :invalid_task_identity}
    end
  end
end
