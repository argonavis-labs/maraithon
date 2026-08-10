defmodule Maraithon.Runtime.Coordination.TaskAuthority do
  @moduledoc false
  use GenServer

  alias Maraithon.Runtime.Coordination.{TaskClaims, TaskSupervisor}
  @call_timeout 5_000
  @proof_timeout 2_000
  @max_proofs 512
  @supervisor_history_key {__MODULE__, :local_supervisor_history}
  @max_supervisor_history 256
  @persistence_retry_ms 1_000

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
      supervisor_id = Ecto.UUID.generate()
      predecessor_ids = :persistent_term.get(@supervisor_history_key, [])

      :persistent_term.put(
        @supervisor_history_key,
        [supervisor_id | Enum.take(predecessor_ids, @max_supervisor_history - 1)]
      )

      {:ok,
       %{
         supervisor_id: supervisor_id,
         proven_predecessor_ids: MapSet.new(predecessor_ids),
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
      Map.merge(identity, %{
        owner: owner,
        owner_ref: owner_ref,
        task_pid: nil,
        task_ref: nil,
        down_reason: nil
      })

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
    case exact(state, identity) do
      reservation when is_map(reservation) ->
        terminate_reservation(reservation, state)

      nil ->
        cond do
          identity.supervisor_id == state.supervisor_id and
              MapSet.member?(state.proofs, proof_key(identity)) ->
            {:reply, {:ok, :terminated}, state}

          MapSet.member?(state.proven_predecessor_ids, identity.supervisor_id) ->
            persist_predecessor_proof(identity, state)

          identity.supervisor_id != state.supervisor_id ->
            {:reply, {:unknown, :task_supervisor_incarnation_unreachable}, state}

          true ->
            # Registry or child-list absence is deliberately not proof.
            {:reply, {:unknown, :task_termination_unproven}, state}
        end
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

  def handle_info({:retry_persistence, task_id}, state) do
    case Map.get(state.reservations, task_id) do
      %{down_reason: reason} = reservation when not is_nil(reason) ->
        identity = public_identity(reservation)

        case persist_down_proof(identity, reason) do
          :ok ->
            {:noreply, remember_proof(delete(state, reservation), identity)}

          _ ->
            schedule_persistence_retry(task_id)
            {:noreply, state}
        end

      %{task_pid: nil} = reservation ->
        identity = public_identity(reservation)

        case abort_reserved(identity) do
          :ok ->
            {:noreply, remember_proof(delete(state, reservation), identity)}

          _ ->
            schedule_persistence_retry(task_id)
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  defp owner_down(task_id, state) do
    case Map.get(state.reservations, task_id) do
      %{down_reason: reason} = reservation when not is_nil(reason) ->
        state = detach_owner(state, reservation)
        identity = public_identity(reservation)

        case persist_down_proof(identity, reason) do
          :ok ->
            {:noreply, remember_proof(delete(state, reservation), identity)}

          _ ->
            schedule_persistence_retry(task_id)
            {:noreply, state}
        end

      %{task_pid: pid, owner_ref: owner_ref} = reservation when is_pid(pid) ->
        _ = terminate_child(pid)
        reservation = %{reservation | owner: nil, owner_ref: nil}

        {:noreply,
         %{
           state
           | reservations: Map.put(state.reservations, task_id, reservation),
             monitors: Map.delete(state.monitors, owner_ref)
         }}

      %{task_pid: nil} = reservation ->
        state = detach_owner(state, reservation)
        identity = public_identity(reservation)

        case abort_reserved(identity) do
          :ok ->
            {:noreply, remember_proof(delete(state, reservation), identity)}

          _ ->
            schedule_persistence_retry(task_id)
            {:noreply, state}
        end

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

        # The task monitor is exact physical termination proof. If PostgreSQL
        # is unavailable retain that proof-bearing reservation and retry; never
        # turn a transient persistence failure into forgotten authority.
        case persist_down_proof(identity, reason) do
          :ok ->
            {:noreply, remember_proof(delete(state, reservation), identity)}

          _ ->
            task_ref = reservation.task_ref
            reservation = %{reservation | task_pid: nil, task_ref: nil, down_reason: reason}
            state = retain_without_task_monitor(state, reservation, task_id, task_ref)
            schedule_persistence_retry(task_id)
            {:noreply, state}
        end
    end
  end

  defp terminate_reservation(%{down_reason: reason} = reservation, state)
       when not is_nil(reason) do
    identity = public_identity(reservation)

    case persist_down_proof(identity, reason) do
      :ok ->
        {:reply, {:ok, :terminated}, remember_proof(delete(state, reservation), identity)}

      _ ->
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  end

  defp terminate_reservation(%{task_pid: nil} = reservation, state) do
    identity = public_identity(reservation)
    # This exact Authority owns a reservation that never activated under its
    # coupled Task.Supervisor. Abort only the reserved ledger; do not manufacture
    # a physical-DOWN proof or any provider outcome.
    case abort_reserved(identity) do
      :ok ->
        {:reply, {:ok, :never_activated}, remember_proof(delete(state, reservation), identity)}

      _ ->
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
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
  catch
    _, _ -> {:error, :proof_persistence_failed}
  end

  defp persist_predecessor_proof(identity, state) do
    assignment = load_assignment(identity)

    result =
      case assignment.state do
        "reserved" ->
          abort_reserved(identity)

        terminal when terminal in ["settled", "outcome_ambiguous"] ->
          :ok

        _ ->
          persist_down_proof(identity, :supervisor_restarted)
      end

    case result do
      :ok -> {:reply, {:ok, :supervisor_restarted}, remember_proof(state, identity)}
      _ -> {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  rescue
    _ -> {:reply, {:unknown, :termination_proof_persistence_failed}, state}
  catch
    _, _ -> {:reply, {:unknown, :termination_proof_persistence_failed}, state}
  end

  defp abort_reserved(identity) do
    case TaskClaims.abort_reserved(load_assignment(identity)) do
      {:ok, _} -> :ok
      _ -> {:error, :abort_failed}
    end
  rescue
    _ -> {:error, :abort_failed}
  catch
    _, _ -> {:error, :abort_failed}
  end

  defp schedule_persistence_retry(task_id) do
    Process.send_after(self(), {:retry_persistence, task_id}, @persistence_retry_ms)
  end

  defp detach_owner(state, reservation) do
    owner_ref = reservation.owner_ref
    if is_reference(owner_ref), do: Process.demonitor(owner_ref, [:flush])
    reservation = %{reservation | owner: nil, owner_ref: nil}

    %{
      state
      | reservations: Map.put(state.reservations, reservation.local_task_id, reservation),
        monitors:
          if(is_reference(owner_ref),
            do: Map.delete(state.monitors, owner_ref),
            else: state.monitors
          )
    }
  end

  defp retain_without_task_monitor(state, reservation, task_id, task_ref) do
    %{
      state
      | reservations: Map.put(state.reservations, task_id, reservation),
        monitors:
          if(is_reference(task_ref),
            do: Map.delete(state.monitors, task_ref),
            else: state.monitors
          )
    }
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
