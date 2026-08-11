defmodule Maraithon.Runtime.Coordination.TaskAuthority do
  @moduledoc false

  use GenServer

  alias Maraithon.Runtime.Coordination.TaskSupervisor
  alias Maraithon.Runtime.TaskGuardian

  @call_timeout 5_000
  @proof_timeout 2_000
  @proof_retry_ms 1_000
  @max_pending_proofs 8_192
  @max_retry_batch 8

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def identity, do: GenServer.call(__MODULE__, :identity, @call_timeout)

  def bind_task(identity, task_pid) when is_map(identity) and is_pid(task_pid) do
    case validate(identity, true) do
      {:ok, valid} -> GenServer.call(__MODULE__, {:bind_task, valid, task_pid}, @call_timeout)
      {:error, _reason} -> {:error, :invalid_task_identity}
    end
  end

  def bind_task(_identity, _task_pid), do: {:error, :invalid_task_identity}

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
  def authorize_activation(identity), do: call_valid(identity, :authorize_activation)

  def terminate_exact(identity),
    do: call_valid(identity, :terminate_exact, {:unknown, :invalid_task_identity})

  def retry_pending_proofs(server \\ __MODULE__) do
    GenServer.call(server, :retry_pending_proofs, @call_timeout)
  end

  @impl true
  def init(opts) do
    with guardian_pid when is_pid(guardian_pid) <- Process.whereis(TaskGuardian),
         supervisor_pid when is_pid(supervisor_pid) <-
           Keyword.get_lazy(opts, :task_supervisor_pid, fn ->
             Process.whereis(TaskSupervisor.task_supervisor())
           end),
         {:ok, guardian} <-
           TaskGuardian.open_generation(guardian_pid, :coordination, supervisor_pid) do
      guardian_ref = Process.monitor(guardian_pid)

      {:ok,
       %{
         supervisor_id: guardian.supervisor_id,
         supervisor_pid: supervisor_pid,
         guardian: guardian,
         guardian_ref: guardian_ref,
         reservations: %{},
         monitors: %{},
         pending_proofs: %{},
         proof_retry_timer: nil
       }}
    else
      _ -> {:stop, :coordinated_task_guardian_unavailable}
    end
  end

  @impl true
  def handle_call(:identity, _from, state), do: {:reply, {:ok, state.supervisor_id}, state}

  def handle_call({:reserve, _base}, _from, %{pending_proofs: pending} = state)
      when map_size(pending) >= @max_pending_proofs do
    {:reply, {:error, :task_proof_persistence_backlog}, state}
  end

  def handle_call({:reserve, base}, {owner, _}, state) do
    identity = base |> Map.put(:supervisor_id, state.supervisor_id)

    case TaskGuardian.reserve_with_termination_capability(state.guardian, identity) do
      {:ok, capability} ->
        owner_ref = Process.monitor(owner)

        reservation =
          Map.merge(identity, %{
            owner: owner,
            owner_ref: owner_ref,
            bound_task_pid: nil,
            bound_task_ref: nil,
            task_pid: nil,
            task_ref: nil,
            down: nil,
            termination_capability_digest: capability.termination_capability_digest
          })

        state = %{
          state
          | reservations: Map.put(state.reservations, identity.local_task_id, reservation),
            monitors: Map.put(state.monitors, owner_ref, {:owner, identity.local_task_id})
        }

        public_reservation =
          Map.put(
            identity,
            :termination_capability_digest,
            capability.termination_capability_digest
          )

        {:reply, {:ok, public_reservation}, state}

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :coordinated_task_guardian_lost, error, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bind_task, identity, task_pid}, {owner, _}, state) do
    case exact(state, identity) do
      %{owner: ^owner, bound_task_pid: nil, task_pid: nil, down: nil} = reservation ->
        if supervised_child?(state.supervisor_pid, task_pid) do
          bound_ref = Process.monitor(task_pid)
          reservation = %{reservation | bound_task_pid: task_pid, bound_task_ref: bound_ref}

          state = %{
            state
            | reservations: Map.put(state.reservations, reservation.local_task_id, reservation),
              monitors:
                Map.put(state.monitors, bound_ref, {:bound_task, reservation.local_task_id})
          }

          {:reply, :ok, state}
        else
          {:reply, {:error, :task_not_supervised}, state}
        end

      %{owner: ^owner, bound_task_pid: ^task_pid, task_pid: nil} ->
        {:reply, :ok, state}

      _foreign_or_bound ->
        {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  def handle_call({:release, identity}, {caller, _}, state) do
    case exact(state, identity) do
      %{owner: ^caller, bound_task_pid: nil, task_pid: nil} = reservation ->
        case TaskGuardian.release(state.guardian, identity) do
          :ok ->
            {:reply, :ok, delete(state, reservation)}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :coordinated_task_guardian_lost, error, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  def handle_call({:activate, identity}, {task_pid, _}, state) do
    case exact(state, identity) do
      %{
        bound_task_pid: ^task_pid,
        bound_task_ref: task_ref,
        task_pid: nil
      } = reservation
      when is_reference(task_ref) ->
        case TaskGuardian.activate(state.guardian, identity, task_pid) do
          :ok ->
            reservation = %{
              reservation
              | bound_task_pid: nil,
                bound_task_ref: nil,
                task_pid: task_pid,
                task_ref: task_ref
            }

            state = %{
              state
              | reservations: Map.put(state.reservations, identity.local_task_id, reservation),
                monitors: Map.put(state.monitors, task_ref, {:task, identity.local_task_id})
            }

            {:reply, :ok, state}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :coordinated_task_guardian_lost, error, state}

          {:error, _reason} ->
            {:reply, {:error, :task_reservation_lost}, state}
        end

      %{task_pid: ^task_pid} ->
        {:reply, :ok, state}

      _ ->
        {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  def handle_call({:authorize_activation, identity}, {task_pid, _}, state) do
    case exact(state, identity) do
      %{task_pid: ^task_pid, down: nil} ->
        case TaskGuardian.activation_registered?(state.guardian, identity, task_pid) do
          :ok ->
            {:reply, :ok, state}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :coordinated_task_guardian_lost, error, state}

          {:error, _reason} ->
            {:reply, {:error, :task_activation_not_registered}, state}
        end

      _ ->
        {:reply, {:error, :task_activation_not_registered}, state}
    end
  end

  def handle_call({:terminate_exact, identity}, _from, state) do
    case exact(state, identity) do
      %{task_pid: nil} = reservation ->
        terminate_reserved(identity, reservation, state)

      %{down: %{} = proof} = reservation ->
        persist_observed_task_proof(identity, proof, reservation, state)

      %{task_pid: task_pid} = reservation when is_pid(task_pid) ->
        terminate_active(identity, reservation, state)

      nil ->
        terminate_from_guardian(identity, state)
    end
  end

  def handle_call(:retry_pending_proofs, _from, state) do
    {state, persisted, remaining} = retry_pending(state)
    {:reply, {:ok, %{persisted: persisted, remaining: remaining}}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case authenticate_down(state, ref, pid) do
      {:guardian, state} ->
        {:stop, :coordinated_task_guardian_lost, state}

      {:owner, task_id, state} ->
        owner_down(task_id, state)

      {:bound_task, task_id, state} ->
        bound_task_down(task_id, ref, reason, state)

      {:task, task_id, state} ->
        task_down(task_id, ref, reason, state)

      {:spoofed, state} ->
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(:retry_task_proofs, state) do
    state = %{state | proof_retry_timer: nil}
    {state, _persisted, _remaining} = retry_pending(state)
    {:noreply, state}
  end

  defp authenticate_down(%{guardian_ref: ref} = state, ref, pid) do
    if pid == state.guardian.guardian_pid do
      if Process.demonitor(ref, [:info]) do
        {:spoofed, %{state | guardian_ref: Process.monitor(pid)}}
      else
        {:guardian, state}
      end
    else
      :unknown
    end
  end

  defp authenticate_down(state, ref, pid) do
    case Map.get(state.monitors, ref) do
      {:owner, task_id} = index ->
        authenticate_reservation_down(state, ref, pid, task_id, :owner, index)

      {:bound_task, task_id} = index ->
        authenticate_reservation_down(state, ref, pid, task_id, :bound_task, index)

      {:task, task_id} = index ->
        authenticate_reservation_down(state, ref, pid, task_id, :task, index)

      nil ->
        :unknown
    end
  end

  defp authenticate_reservation_down(state, ref, pid, task_id, kind, index) do
    case Map.get(state.reservations, task_id) do
      %{owner: ^pid, owner_ref: ^ref} = reservation when kind == :owner ->
        authenticate_or_remonitor(state, ref, pid, reservation, :owner_ref, index, kind, task_id)

      %{bound_task_pid: ^pid, bound_task_ref: ^ref} = reservation when kind == :bound_task ->
        authenticate_or_remonitor(
          state,
          ref,
          pid,
          reservation,
          :bound_task_ref,
          index,
          kind,
          task_id
        )

      %{task_pid: ^pid, task_ref: ^ref} = reservation when kind == :task ->
        authenticate_or_remonitor(state, ref, pid, reservation, :task_ref, index, kind, task_id)

      nil ->
        {:spoofed, %{state | monitors: Map.delete(state.monitors, ref)}}

      _mismatch ->
        :unknown
    end
  end

  defp authenticate_or_remonitor(state, ref, pid, reservation, ref_field, index, kind, task_id) do
    if Process.demonitor(ref, [:info]) do
      new_ref = Process.monitor(pid)
      reservation = Map.put(reservation, ref_field, new_ref)

      state = %{
        state
        | reservations: Map.put(state.reservations, task_id, reservation),
          monitors: state.monitors |> Map.delete(ref) |> Map.put(new_ref, index)
      }

      {:spoofed, state}
    else
      {kind, task_id, state}
    end
  end

  defp owner_down(task_id, state) do
    case Map.get(state.reservations, task_id) do
      %{bound_task_pid: pid, task_pid: nil, owner_ref: owner_ref} = reservation
      when is_pid(pid) ->
        _ = terminate_child(state.supervisor_pid, pid)
        reservation = %{reservation | owner: nil, owner_ref: nil}

        {:noreply,
         %{
           state
           | reservations: Map.put(state.reservations, task_id, reservation),
             monitors: Map.delete(state.monitors, owner_ref)
         }}

      %{task_pid: pid, owner_ref: owner_ref} = reservation when is_pid(pid) ->
        _ = terminate_child(state.supervisor_pid, pid)
        reservation = %{reservation | owner: nil, owner_ref: nil}

        {:noreply,
         %{
           state
           | reservations: Map.put(state.reservations, task_id, reservation),
             monitors: Map.delete(state.monitors, owner_ref)
         }}

      %{} = reservation ->
        identity = public_identity(reservation)

        case TaskGuardian.cancel_reserved(state.guardian, identity) do
          :ok ->
            state = detach_owner(state, reservation)

            case persist_guardian_termination(state, identity) do
              {:ok, _disposition} ->
                {:noreply, complete_persistence(state, identity)}

              {:error, _reason} ->
                {:noreply, queue_pending(state, :never_activated, identity, nil)}
            end

          {:error, _reason} ->
            {:stop, :coordinated_task_guardian_lost, state}
        end

      nil ->
        {:noreply, state}
    end
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

  defp bound_task_down(task_id, ref, _reason, state) do
    case Map.get(state.reservations, task_id) do
      %{} = reservation ->
        identity = public_identity(reservation)

        case TaskGuardian.cancel_reserved(state.guardian, identity) do
          :ok ->
            proof = %{
              evidence_id: "task-supervisor:never_activated:#{identity.local_task_id}",
              reason: "bound_task_down"
            }

            reservation = %{
              reservation
              | bound_task_pid: nil,
                bound_task_ref: nil,
                down: proof
            }

            state = %{
              state
              | reservations: Map.put(state.reservations, task_id, reservation),
                monitors: Map.delete(state.monitors, ref)
            }

            case persist_guardian_termination(state, identity) do
              {:ok, _disposition} ->
                {:noreply, complete_persistence(state, identity)}

              {:error, _reason} ->
                {:noreply, queue_pending(state, :never_activated, identity, proof)}
            end

          {:error, _reason} ->
            {:stop, :coordinated_task_guardian_lost, state}
        end

      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
    end
  end

  defp task_down(task_id, ref, reason, state) do
    case Map.get(state.reservations, task_id) do
      nil ->
        {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}

      reservation ->
        identity = public_identity(reservation)

        proof = %{
          evidence_id: "task-down:#{identity.local_task_id}",
          reason: proof_reason(reason)
        }

        reservation = %{reservation | task_ref: nil, down: proof}

        state = %{
          state
          | reservations: Map.put(state.reservations, task_id, reservation),
            monitors: Map.delete(state.monitors, ref)
        }

        case persist_guardian_termination(state, identity) do
          {:ok, _disposition} -> {:noreply, complete_persistence(state, identity)}
          {:error, _reason} -> {:noreply, queue_pending(state, :task_down, identity, proof)}
        end
    end
  end

  defp terminate_reserved(identity, reservation, state) do
    if is_pid(reservation.bound_task_pid),
      do: terminate_child(state.supervisor_pid, reservation.bound_task_pid)

    case TaskGuardian.cancel_reserved(state.guardian, identity) do
      :ok ->
        case persist_guardian_termination(state, identity) do
          {:ok, disposition} ->
            {:reply, {:ok, disposition}, complete_persistence(state, identity)}

          {:error, _reason} ->
            state = queue_pending(state, :never_activated, identity, nil)
            {:reply, {:unknown, :termination_proof_persistence_failed}, state}
        end

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :coordinated_task_guardian_lost, error, state}

      {:error, _reason} ->
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  defp terminate_active(identity, reservation, state) do
    _termination_attempt = terminate_child(state.supervisor_pid, reservation.task_pid)

    case TaskGuardian.await_proof(state.guardian, identity, @proof_timeout) do
      {:ok, {:task_down, proof}} ->
        persist_task_proof(identity, proof, state)

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :coordinated_task_guardian_lost, error, state}

      _pending_or_unknown ->
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  defp terminate_from_guardian(identity, state) do
    case TaskGuardian.await_proof(state.guardian, identity, @proof_timeout) do
      {:ok, {:task_down, proof}} ->
        persist_task_proof(identity, proof, state)

      {:ok, :activation_cancelled} ->
        persist_old_reservation(identity, state)

      {:ok, {:supervisor_down_before_activation, _proof}} ->
        persist_old_reservation(identity, state)

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :coordinated_task_guardian_lost, error, state}

      {:unknown, :task_identity_mismatch} ->
        {:reply, {:unknown, :task_identity_mismatch}, state}

      _pending_untracked_or_evicted ->
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  defp persist_observed_task_proof(identity, proof, _reservation, state) do
    case TaskGuardian.await_proof(state.guardian, identity, @proof_timeout) do
      {:ok, {:task_down, _guardian_proof}} ->
        persist_task_proof(identity, proof, state)

      _pending_or_unknown ->
        state = queue_pending(state, :task_down, identity, proof)
        {:reply, {:unknown, :task_termination_unproven}, state}
    end
  end

  defp persist_task_proof(identity, proof, state) do
    case persist_guardian_termination(state, identity) do
      {:ok, disposition} ->
        {:reply, {:ok, disposition}, complete_persistence(state, identity)}

      {:error, _reason} ->
        state = queue_pending(state, :task_down, identity, proof)
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  end

  defp persist_old_reservation(identity, state) do
    case persist_guardian_termination(state, identity) do
      {:ok, disposition} ->
        {:reply, {:ok, disposition}, complete_persistence(state, identity)}

      {:error, _reason} ->
        state = queue_pending(state, :never_activated, identity, nil)
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  end

  defp persist_guardian_termination(state, identity) do
    case TaskGuardian.persist_termination(state.guardian, identity) do
      {:ok, disposition}
      when disposition in [
             :completion,
             :never_activated,
             :supervisor_down,
             :external_destroyed,
             :uncoordinated,
             :uncommitted
           ] ->
        {:ok, disposition}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :proof_persistence_failed}
    end
  rescue
    _error -> {:error, :proof_persistence_failed}
  catch
    :exit, _reason -> {:error, :proof_persistence_failed}
  end

  defp queue_pending(state, kind, identity, proof) do
    key = proof_key(identity)
    pending = %{kind: kind, identity: identity, proof: proof}

    state = %{
      state
      | pending_proofs: Map.put(state.pending_proofs, key, pending)
    }

    schedule_proof_retry(state)
  end

  defp retry_pending(state) do
    state = cancel_retry_timer(state)
    {batch, deferred} = state.pending_proofs |> Map.to_list() |> Enum.split(@max_retry_batch)
    state = %{state | pending_proofs: Map.new(deferred)}

    {state, persisted} =
      Enum.reduce(batch, {state, 0}, fn {key, pending}, {acc, count} ->
        case retry_one(acc, pending) do
          {:ok, _disposition} ->
            {complete_persistence(acc, pending.identity), count + 1}

          {:error, _reason} ->
            {%{acc | pending_proofs: Map.put(acc.pending_proofs, key, pending)}, count}
        end
      end)

    state = schedule_proof_retry(state)
    {state, persisted, map_size(state.pending_proofs)}
  end

  defp retry_one(state, %{identity: identity}),
    do: persist_guardian_termination(state, identity)

  defp schedule_proof_retry(%{pending_proofs: pending} = state) when map_size(pending) == 0,
    do: state

  defp schedule_proof_retry(%{proof_retry_timer: timer} = state) when is_reference(timer),
    do: state

  defp schedule_proof_retry(state) do
    timer = Process.send_after(self(), :retry_task_proofs, @proof_retry_ms)
    %{state | proof_retry_timer: timer}
  end

  defp cancel_retry_timer(%{proof_retry_timer: nil} = state), do: state

  defp cancel_retry_timer(state) do
    _ = Process.cancel_timer(state.proof_retry_timer)
    %{state | proof_retry_timer: nil}
  end

  defp complete_persistence(state, identity) do
    key = proof_key(identity)
    state = %{state | pending_proofs: Map.delete(state.pending_proofs, key)}

    case exact(state, identity) do
      %{} = reservation -> delete(state, reservation)
      nil -> state
    end
  end

  defp exact(state, identity) do
    case Map.get(state.reservations, identity.local_task_id) do
      reservation when is_map(reservation) ->
        if public_identity(reservation) == public_identity(identity), do: reservation

      _ ->
        nil
    end
  end

  defp public_identity(value) do
    Map.take(value, [
      :work_kind,
      :work_id,
      :claim_token,
      :assignment_id,
      :supervisor_id,
      :local_task_id
    ])
  end

  defp proof_key(identity) do
    {identity.assignment_id, identity.claim_token, identity.supervisor_id, identity.local_task_id}
  end

  defp delete(state, reservation) do
    indexed_refs =
      state.monitors
      |> Enum.flat_map(fn
        {ref, {_kind, task_id}} when task_id == reservation.local_task_id -> [ref]
        _other -> []
      end)

    refs =
      [reservation.owner_ref, reservation.task_ref | indexed_refs]
      |> Enum.filter(&is_reference/1)
      |> Enum.uniq()

    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | reservations: Map.delete(state.reservations, reservation.local_task_id),
        monitors: Map.drop(state.monitors, refs)
    }
  end

  defp supervised_child?(supervisor_pid, task_pid) do
    task_pid in Task.Supervisor.children(supervisor_pid)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp terminate_child(supervisor_pid, task_pid) do
    Task.Supervisor.terminate_child(supervisor_pid, task_pid)
  rescue
    _error -> {:error, :supervisor_unavailable}
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

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
      {:ok,
       Map.take(identity, [
         :work_kind,
         :work_id,
         :claim_token,
         :assignment_id,
         :supervisor_id,
         :local_task_id
       ])}
    else
      _ -> {:error, :invalid_task_identity}
    end
  end
end
