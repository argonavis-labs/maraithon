defmodule Maraithon.Runtime.EffectTaskAuthority do
  @moduledoc false

  use GenServer

  alias Maraithon.Runtime.TaskGuardian

  @task_supervisor Maraithon.Runtime.ExactEffectTaskSupervisor
  @call_timeout 5_000
  @termination_proof_timeout 2_000
  @cleanup_retry_min_ms 250
  @cleanup_retry_max_ms 30_000
  @cleanup_retry_batch 1
  @cleanup_retry_scan_batch 64

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def identity, do: GenServer.call(__MODULE__, :identity, @call_timeout)
  def active_identities, do: GenServer.call(__MODULE__, :active_identities, @call_timeout)

  def reserve_legacy(effect_id, agent_id, claim_token) do
    reserve(effect_id, agent_id, claim_token, :legacy, nil)
  end

  def reserve_coordinated(effect_id, agent_id, claim_token, assignment_id) do
    reserve(effect_id, agent_id, claim_token, :coordinated, assignment_id)
  end

  def reserve(effect_id, agent_id, claim_token),
    do: reserve_legacy(effect_id, agent_id, claim_token)

  def bind_task(identity, task_pid) when is_map(identity) and is_pid(task_pid) do
    with {:ok, identity} <- validate_identity(identity) do
      GenServer.call(__MODULE__, {:bind_task, identity, task_pid}, @call_timeout)
    end
  end

  def bind_task(_identity, _task_pid), do: {:error, :invalid_effect_task_identity}

  defp reserve(effect_id, agent_id, claim_token, mode, assignment_id) do
    with {:ok, effect_id} <- cast_uuid(effect_id),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, claim_token} <- cast_uuid(claim_token),
         {:ok, assignment_id} <- validate_assignment_binding(mode, assignment_id) do
      GenServer.call(
        __MODULE__,
        {:reserve, effect_id, agent_id, claim_token, mode, assignment_id},
        @call_timeout
      )
    end
  end

  def release(identity) when is_map(identity) do
    with {:ok, identity} <- validate_identity(identity) do
      GenServer.call(__MODULE__, {:release, identity}, @call_timeout)
    end
  end

  def release(_identity), do: {:error, :invalid_effect_task_identity}

  def activate(identity) when is_map(identity) do
    with {:ok, identity} <- validate_identity(identity) do
      GenServer.call(__MODULE__, {:activate, identity}, @call_timeout)
    end
  end

  def activate(_identity), do: {:error, :invalid_effect_task_identity}

  def authorize_activation(identity) when is_map(identity) do
    with {:ok, identity} <- validate_identity(identity) do
      GenServer.call(__MODULE__, {:authorize_activation, identity}, @call_timeout)
    end
  end

  def authorize_activation(_identity), do: {:error, :invalid_effect_task_identity}

  def terminate_exact(claim) when is_map(claim) do
    with {:ok, claim} <- validate_identity(claim) do
      GenServer.call(__MODULE__, {:terminate_exact, claim}, @call_timeout * 2)
    else
      {:error, _reason} -> {:unknown, :invalid_effect_task_identity}
    end
  end

  def terminate_exact(_claim), do: {:unknown, :invalid_effect_task_identity}

  def acknowledge_completed(identity) when is_map(identity) do
    with {:ok, identity} <- validate_identity(identity) do
      GenServer.call(__MODULE__, {:acknowledge_completed, identity}, @call_timeout)
    end
  end

  def acknowledge_completed(_identity), do: {:error, :invalid_effect_task_identity}

  @impl true
  def init(_opts) do
    with guardian_pid when is_pid(guardian_pid) <- Process.whereis(TaskGuardian),
         supervisor_pid when is_pid(supervisor_pid) <- Process.whereis(@task_supervisor),
         {:ok, guardian} <-
           TaskGuardian.open_generation(guardian_pid, :effect, supervisor_pid) do
      guardian_ref = Process.monitor(guardian_pid)

      {:ok,
       %{
         supervisor_id: guardian.supervisor_id,
         supervisor_pid: supervisor_pid,
         guardian: guardian,
         guardian_ref: guardian_ref,
         reservations: %{},
         monitor_index: %{},
         cleanup_queue: :queue.new(),
         cleanup_set: MapSet.new(),
         cleanup_timer: nil,
         cleanup_retry_ms: @cleanup_retry_min_ms
       }}
    else
      _ -> {:stop, :effect_task_guardian_unavailable}
    end
  end

  @impl true
  def handle_call(:identity, _from, state) do
    {:reply, {:ok, state.supervisor_id}, state}
  end

  def handle_call(:active_identities, _from, state) do
    case TaskGuardian.tracked_active_identities(state.guardian) do
      {:ok, identities} -> {:reply, {:ok, identities}, state}
      {:error, reason} -> {:stop, {:effect_task_guardian_lost, reason}, state}
    end
  end

  def handle_call(
        {:reserve, effect_id, agent_id, claim_token, mode, assignment_id},
        {owner, _tag},
        state
      ) do
    task_id = Ecto.UUID.generate()

    identity =
      %{
        effect_id: effect_id,
        agent_id: agent_id,
        claim_token: claim_token,
        supervisor_id: state.supervisor_id,
        task_id: task_id
      }
      |> maybe_bind_assignment(mode, assignment_id)

    reservation_result =
      case mode do
        :legacy -> TaskGuardian.reserve(state.guardian, identity)
        :coordinated -> TaskGuardian.reserve_with_termination_capability(state.guardian, identity)
      end

    case reservation_result do
      result
      when result == :ok or
             (is_tuple(result) and tuple_size(result) == 2 and elem(result, 0) == :ok) ->
        with {:ok, capability_digest} <- reservation_digest(mode, result) do
          owner_ref = Process.monitor(owner)

          reservation =
            identity
            |> Map.merge(%{
              reserved_by: owner,
              owner_ref: owner_ref,
              bound_task_pid: nil,
              bound_task_ref: nil,
              task_pid: nil,
              task_ref: nil,
              down: nil,
              completion_requested: false
            })
            |> maybe_put_capability_digest(capability_digest)

          state = %{
            state
            | reservations: Map.put(state.reservations, task_id, reservation),
              monitor_index: Map.put(state.monitor_index, owner_ref, {:owner, task_id})
          }

          public_reservation = maybe_put_capability_digest(identity, capability_digest)
          {:reply, {:ok, public_reservation}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:bind_task, identity, task_pid}, {owner, _tag}, state) do
    case exact_reservation(state, identity) do
      %{
        reserved_by: ^owner,
        bound_task_pid: nil,
        task_pid: nil,
        down: nil
      } = reservation ->
        if supervised_child?(state.supervisor_pid, task_pid) do
          bound_ref = Process.monitor(task_pid)

          reservation = %{
            reservation
            | bound_task_pid: task_pid,
              bound_task_ref: bound_ref
          }

          state =
            state
            |> put_reservation(reservation)
            |> put_monitor(bound_ref, {:bound_task, reservation.task_id})

          {:reply, :ok, state}
        else
          {:reply, {:error, :effect_task_not_supervised}, state}
        end

      %{reserved_by: ^owner, bound_task_pid: ^task_pid, task_pid: nil} ->
        {:reply, :ok, state}

      _foreign_or_bound ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  def handle_call({:release, identity}, {caller, _tag}, state) do
    case exact_reservation(state, identity) do
      %{reserved_by: ^caller, bound_task_pid: nil, task_pid: nil} = reservation ->
        case TaskGuardian.release(state.guardian, identity) do
          :ok ->
            {:reply, :ok, delete_reservation(state, reservation)}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :effect_task_guardian_lost, error, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _active_lost_or_foreign ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  def handle_call({:activate, identity}, {task_pid, _tag}, state) do
    case exact_reservation(state, identity) do
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
              | reservations: Map.put(state.reservations, reservation.task_id, reservation),
                monitor_index:
                  Map.put(state.monitor_index, task_ref, {:task, reservation.task_id})
            }

            {:reply, :ok, state}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :effect_task_guardian_lost, error, state}

          {:error, _reason} ->
            {:reply, {:error, :effect_task_reservation_lost}, state}
        end

      %{task_pid: ^task_pid} ->
        {:reply, :ok, state}

      _missing_or_wrong_task ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  def handle_call({:authorize_activation, identity}, {task_pid, _tag}, state) do
    case exact_reservation(state, identity) do
      %{task_pid: ^task_pid} ->
        case TaskGuardian.activation_registered?(state.guardian, identity, task_pid) do
          :ok ->
            {:reply, :ok, state}

          {:error, :task_guardian_access_lost} = error ->
            {:stop, :effect_task_guardian_lost, error, state}

          {:error, _reason} ->
            {:reply, {:error, :effect_task_activation_not_authorized}, state}
        end

      _foreign_or_unbound ->
        {:reply, {:error, :effect_task_activation_not_authorized}, state}
    end
  end

  def handle_call({:terminate_exact, claim}, _from, state) do
    case exact_reservation(state, claim) do
      %{task_pid: nil, down: nil} = reservation ->
        cancel_reserved(claim, reservation, state)

      %{down: %{} = down} = reservation ->
        persist_recorded_down(claim, down, reservation, state)

      %{task_pid: task_pid} = reservation when is_pid(task_pid) ->
        terminate_current_task(claim, reservation, state)

      nil ->
        persist_guardian_proof(claim, state)
    end
  end

  def handle_call({:acknowledge_completed, identity}, {caller, _tag}, state) do
    case exact_reservation(state, identity) do
      %{reserved_by: ^caller, task_pid: task_pid} = reservation when is_pid(task_pid) ->
        reservation = %{reservation | completion_requested: true}
        state = put_reservation(state, reservation)

        with :ok <- expect_completion(state, identity),
             {:ok, {:task_down, _proof}} <- await_guardian_proof(state, identity),
             :ok <- acknowledge_completion(state, identity) do
          {:reply, :ok, delete_reservation(state, reservation)}
        else
          {:error, reason} ->
            state =
              if reservation.down, do: enqueue_cleanup(state, reservation.task_id), else: state

            {:reply, {:error, reason}, state}

          _pending_or_unknown ->
            {:reply, {:error, :effect_task_termination_unproven}, state}
        end

      _missing_or_foreign ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  @impl true
  def handle_info(:retry_effect_task_cleanup, state) do
    state = %{state | cleanup_timer: nil}

    {state, scan_exhausted?} =
      retry_cleanup_batch(state, @cleanup_retry_batch, @cleanup_retry_scan_batch)

    {:noreply, finish_cleanup_tick(state, scan_exhausted?)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case authenticate_down(state, ref, pid) do
      {:guardian, state} ->
        {:stop, :effect_task_guardian_lost, state}

      {:owner, task_id, state} ->
        handle_owner_down(task_id, state)

      {:bound_task, task_id, state} ->
        handle_bound_task_down(task_id, ref, reason, state)

      {:task, task_id, state} ->
        handle_task_down(task_id, ref, reason, state)

      {:spoofed, state} ->
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
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
    case Map.get(state.monitor_index, ref) do
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
      %{reserved_by: ^pid, owner_ref: ^ref} = reservation when kind == :owner ->
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
        {:spoofed, %{state | monitor_index: Map.delete(state.monitor_index, ref)}}

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
          monitor_index: state.monitor_index |> Map.delete(ref) |> Map.put(new_ref, index)
      }

      {:spoofed, state}
    else
      {kind, task_id, state}
    end
  end

  defp handle_owner_down(task_id, state) do
    case Map.get(state.reservations, task_id) do
      %{bound_task_pid: task_pid, task_pid: nil} = reservation when is_pid(task_pid) ->
        _termination_attempt = terminate_child(state.supervisor_pid, task_pid)
        {:noreply, detach_dead_owner(state, reservation)}

      %{task_pid: task_pid} = reservation when is_pid(task_pid) ->
        _termination_attempt = terminate_child(state.supervisor_pid, task_pid)

        # The reservation remains until its exact task monitor delivers DOWN.
        {:noreply, detach_dead_owner(state, reservation)}

      %{} = reservation ->
        identity = public_identity(reservation)

        case TaskGuardian.cancel_reserved(state.guardian, identity) do
          :ok ->
            down = %{
              proof_kind: "never_activated",
              evidence_id: "task-supervisor:never_activated:#{identity.task_id}"
            }

            owner_ref = reservation.owner_ref
            reservation = %{reservation | reserved_by: nil, owner_ref: nil, down: down}

            state =
              state
              |> drop_monitor(owner_ref)
              |> put_reservation(reservation)
              |> enqueue_cleanup(task_id)

            {:noreply, state}

          {:error, _reason} ->
            {:stop, :effect_task_guardian_lost, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp handle_bound_task_down(task_id, ref, _reason, state) do
    case Map.get(state.reservations, task_id) do
      %{} = reservation ->
        identity = public_identity(reservation)

        case TaskGuardian.cancel_reserved(state.guardian, identity) do
          :ok ->
            down = %{
              proof_kind: "never_activated",
              evidence_id: "task-supervisor:never_activated:#{identity.task_id}"
            }

            reservation = %{
              reservation
              | bound_task_pid: nil,
                bound_task_ref: nil,
                down: down
            }

            {:noreply,
             state
             |> drop_monitor(ref)
             |> put_reservation(reservation)
             |> enqueue_cleanup(task_id)}

          {:error, _reason} ->
            {:stop, :effect_task_guardian_lost, state}
        end

      nil ->
        {:noreply, drop_monitor(state, ref)}
    end
  end

  defp handle_task_down(task_id, ref, _reason, state) do
    case Map.get(state.reservations, task_id) do
      %{} = reservation ->
        down = %{
          proof_kind: "supervisor_down",
          evidence_id: "task-down:#{reservation.task_id}"
        }

        reservation = %{reservation | task_ref: nil, down: down}

        {:noreply,
         state
         |> drop_monitor(ref)
         |> put_reservation(reservation)
         |> enqueue_cleanup(task_id)}

      nil ->
        {:noreply, drop_monitor(state, ref)}
    end
  end

  defp cancel_reserved(claim, reservation, state) do
    if is_pid(reservation.bound_task_pid),
      do: terminate_child(state.supervisor_pid, reservation.bound_task_pid)

    case TaskGuardian.cancel_reserved(state.guardian, claim) do
      :ok ->
        down = %{
          proof_kind: "never_activated",
          evidence_id: "task-supervisor:never_activated:#{claim.task_id}"
        }

        reservation = %{reservation | down: down}
        state = put_reservation(state, reservation)
        persist_recorded_down(claim, down, reservation, state)

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:error, _reason} ->
        {:reply, {:unknown, :effect_task_termination_unproven}, state}
    end
  end

  defp terminate_current_task(claim, reservation, state) do
    _termination_attempt = terminate_child(state.supervisor_pid, reservation.task_pid)

    case await_guardian_proof(state, claim) do
      {:ok, {:task_down, proof}} ->
        down = %{proof_kind: "supervisor_down", evidence_id: proof.evidence_id}
        reservation = %{reservation | task_ref: nil, down: down}
        state = put_reservation(state, reservation)
        persist_recorded_down(claim, down, reservation, state)

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      _pending_or_unknown ->
        {:reply, {:unknown, :effect_task_termination_unproven}, state}
    end
  end

  defp persist_recorded_down(claim, _down, reservation, state) do
    case persist_termination(state, claim) do
      {:ok, proof_kind} ->
        state = if reservation, do: delete_reservation(state, reservation), else: state
        {:reply, {:ok, proof_kind}, state}

      {:error, _reason} ->
        state = if reservation, do: enqueue_cleanup(state, reservation.task_id), else: state
        {:reply, {:unknown, :termination_proof_persistence_failed}, state}
    end
  end

  defp persist_guardian_proof(claim, state) do
    case await_guardian_proof(state, claim) do
      {:ok, {:task_down, proof}} ->
        persist_recorded_down(
          claim,
          %{proof_kind: "supervisor_down", evidence_id: proof.evidence_id},
          nil,
          state
        )

      {:ok, :activation_cancelled} ->
        persist_recorded_down(
          claim,
          %{
            proof_kind: "never_activated",
            evidence_id: "task-supervisor:never_activated:#{claim.task_id}"
          },
          nil,
          state
        )

      {:ok, {:supervisor_down_before_activation, _proof}} ->
        persist_recorded_down(
          claim,
          %{
            proof_kind: "never_activated",
            evidence_id: "task-supervisor:never_activated:#{claim.task_id}"
          },
          nil,
          state
        )

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:unknown, :task_identity_mismatch} ->
        {:reply, {:unknown, :effect_task_identity_mismatch}, state}

      _pending_untracked_or_evicted ->
        {:reply, {:unknown, :effect_task_owner_incarnation_unproven}, state}
    end
  end

  defp cancel_expected_completion(state, identity) do
    TaskGuardian.cancel_expected_completion(state.guardian, identity)
  rescue
    _error -> {:error, :effect_task_guardian_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_guardian_unavailable}
  end

  defp expect_completion(state, identity) do
    TaskGuardian.expect_completion(state.guardian, identity)
  rescue
    _error -> {:error, :effect_task_guardian_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_guardian_unavailable}
  end

  defp await_guardian_proof(state, identity) do
    TaskGuardian.await_proof(state.guardian, identity, @termination_proof_timeout)
  rescue
    _error -> {:error, :effect_task_guardian_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_guardian_unavailable}
  end

  defp acknowledge_completion(state, identity) do
    case TaskGuardian.acknowledge_completion(state.guardian, identity) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :effect_task_completion_acknowledgement_failed}
    end
  rescue
    _error -> {:error, :effect_task_completion_acknowledgement_failed}
  catch
    :exit, _reason -> {:error, :effect_task_completion_acknowledgement_failed}
  end

  defp persist_termination(state, claim) do
    case TaskGuardian.persist_termination(state.guardian, claim) do
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
        {:error, :termination_proof_persistence_failed}
    end
  rescue
    _error -> {:error, :termination_proof_persistence_failed}
  catch
    :exit, _reason -> {:error, :termination_proof_persistence_failed}
  end

  defp enqueue_cleanup(state, task_id) do
    if MapSet.member?(state.cleanup_set, task_id) do
      state
    else
      state = %{
        state
        | cleanup_queue: :queue.in(task_id, state.cleanup_queue),
          cleanup_set: MapSet.put(state.cleanup_set, task_id)
      }

      schedule_cleanup(state)
    end
  end

  # Reservation deletion tombstones queued IDs by dropping them from cleanup_set.
  # Skip those tombstones without spending the live retry budget, while bounding
  # total queue scans so one cleanup callback cannot monopolize the authority.
  defp retry_cleanup_batch(state, 0, _scan_remaining), do: {state, false}

  defp retry_cleanup_batch(state, _remaining, 0) do
    {state, not :queue.is_empty(state.cleanup_queue)}
  end

  defp retry_cleanup_batch(state, remaining, scan_remaining) do
    case :queue.out(state.cleanup_queue) do
      {:empty, _queue} ->
        {state, false}

      {{:value, task_id}, queue} ->
        state = %{state | cleanup_queue: queue}

        if MapSet.member?(state.cleanup_set, task_id) do
          state = %{state | cleanup_set: MapSet.delete(state.cleanup_set, task_id)}

          state =
            case Map.get(state.reservations, task_id) do
              %{down: %{} = _down, completion_requested: true} = reservation ->
                cleanup_expected_completion(state, reservation)

              %{down: %{} = _down} = reservation ->
                case persist_termination(state, public_identity(reservation)) do
                  {:ok, _proof_kind} -> delete_reservation(state, reservation)
                  {:error, _reason} -> requeue_cleanup(state, task_id)
                end

              _not_terminal ->
                state
            end

          retry_cleanup_batch(state, remaining - 1, scan_remaining - 1)
        else
          retry_cleanup_batch(state, remaining, scan_remaining - 1)
        end
    end
  end

  defp cleanup_expected_completion(state, reservation) do
    identity = public_identity(reservation)

    case acknowledge_completion(state, identity) do
      :ok ->
        delete_reservation(state, reservation)

      {:error, reason}
      when reason in [
             :coordination_task_completion_not_durable,
             :task_termination_proof_conflict
           ] ->
        case cancel_expected_completion(state, identity) do
          :ok ->
            reservation = %{reservation | completion_requested: false}
            state = put_reservation(state, reservation)

            case persist_termination(state, identity) do
              {:ok, _proof_kind} -> delete_reservation(state, reservation)
              {:error, _reason} -> requeue_cleanup(state, reservation.task_id)
            end

          _lost ->
            requeue_cleanup(state, reservation.task_id)
        end

      {:error, _storage_or_mismatch} ->
        requeue_cleanup(state, reservation.task_id)
    end
  rescue
    _error -> requeue_cleanup(state, reservation.task_id)
  catch
    :exit, _reason -> requeue_cleanup(state, reservation.task_id)
  end

  defp requeue_cleanup(state, task_id) do
    %{
      state
      | cleanup_queue: :queue.in(task_id, state.cleanup_queue),
        cleanup_set: MapSet.put(state.cleanup_set, task_id)
    }
  end

  defp finish_cleanup_tick(state, scan_exhausted?) do
    cond do
      MapSet.size(state.cleanup_set) == 0 and :queue.is_empty(state.cleanup_queue) ->
        %{state | cleanup_retry_ms: @cleanup_retry_min_ms}

      MapSet.size(state.cleanup_set) == 0 or scan_exhausted? ->
        schedule_cleanup(state, 0)

      true ->
        state = %{
          state
          | cleanup_retry_ms: min(state.cleanup_retry_ms * 2, @cleanup_retry_max_ms)
        }

        schedule_cleanup(state)
    end
  end

  defp schedule_cleanup(state), do: schedule_cleanup(state, state.cleanup_retry_ms)

  defp schedule_cleanup(%{cleanup_timer: timer} = state, _delay_ms) when is_reference(timer),
    do: state

  defp schedule_cleanup(state, delay_ms) do
    timer = Process.send_after(self(), :retry_effect_task_cleanup, delay_ms)
    %{state | cleanup_timer: timer}
  end

  defp put_reservation(state, reservation) do
    %{state | reservations: Map.put(state.reservations, reservation.task_id, reservation)}
  end

  defp put_monitor(state, ref, index) do
    %{state | monitor_index: Map.put(state.monitor_index, ref, index)}
  end

  defp supervised_child?(supervisor_pid, task_pid) do
    task_pid in Task.Supervisor.children(supervisor_pid)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp exact_reservation(state, identity) do
    case Map.get(state.reservations, identity.task_id) do
      %{} = reservation -> if reservation_matches?(reservation, identity), do: reservation
      nil -> nil
    end
  end

  defp reservation_matches?(reservation, identity) do
    public_identity(reservation) == identity
  end

  defp public_identity(reservation) do
    Map.take(reservation, [
      :effect_id,
      :agent_id,
      :assignment_id,
      :claim_token,
      :supervisor_id,
      :task_id
    ])
  end

  defp terminate_child(supervisor_pid, task_pid) do
    Task.Supervisor.terminate_child(supervisor_pid, task_pid)
  rescue
    _error -> {:error, :supervisor_unavailable}
  catch
    :exit, _reason -> {:error, :supervisor_unavailable}
  end

  defp detach_dead_owner(state, reservation) do
    owner_ref = reservation.owner_ref

    if is_reference(owner_ref) do
      Process.demonitor(owner_ref, [:flush])
    end

    reservation = %{reservation | reserved_by: nil, owner_ref: nil}

    %{
      state
      | reservations: Map.put(state.reservations, reservation.task_id, reservation),
        monitor_index:
          if(is_reference(owner_ref),
            do: Map.delete(state.monitor_index, owner_ref),
            else: state.monitor_index
          )
    }
  end

  defp delete_reservation(state, reservation) do
    indexed_refs =
      state.monitor_index
      |> Enum.flat_map(fn
        {ref, {_kind, task_id}} when task_id == reservation.task_id -> [ref]
        _other -> []
      end)

    refs =
      [reservation.owner_ref, reservation.task_ref | indexed_refs]
      |> Enum.filter(&is_reference/1)
      |> Enum.uniq()

    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | reservations: Map.delete(state.reservations, reservation.task_id),
        monitor_index: Map.drop(state.monitor_index, refs),
        cleanup_set: MapSet.delete(state.cleanup_set, reservation.task_id)
    }
  end

  defp drop_monitor(state, ref) do
    %{state | monitor_index: Map.delete(state.monitor_index, ref)}
  end

  defp validate_identity(identity) do
    with {:ok, effect_id} <- identity |> Map.get(:effect_id) |> cast_uuid(),
         {:ok, agent_id} <- identity |> Map.get(:agent_id) |> cast_uuid(),
         {:ok, claim_token} <- identity |> Map.get(:claim_token) |> cast_uuid(),
         {:ok, supervisor_id} <- identity |> Map.get(:supervisor_id) |> cast_uuid(),
         {:ok, task_id} <- identity |> Map.get(:task_id) |> cast_uuid(),
         {:ok, assignment_id} <- optional_assignment_id(identity) do
      normalized = %{
        effect_id: effect_id,
        agent_id: agent_id,
        claim_token: claim_token,
        supervisor_id: supervisor_id,
        task_id: task_id
      }

      {:ok, maybe_bind_assignment(normalized, assignment_id)}
    end
  end

  defp optional_assignment_id(identity) do
    if Map.has_key?(identity, :assignment_id),
      do: cast_uuid(Map.get(identity, :assignment_id)),
      else: {:ok, nil}
  end

  defp maybe_bind_assignment(identity, nil), do: identity

  defp maybe_bind_assignment(identity, assignment_id),
    do: Map.put(identity, :assignment_id, assignment_id)

  defp validate_assignment_binding(:legacy, nil), do: {:ok, nil}
  defp validate_assignment_binding(:coordinated, assignment_id), do: cast_uuid(assignment_id)

  defp validate_assignment_binding(_mode, _assignment_id),
    do: {:error, :invalid_effect_task_identity}

  defp maybe_bind_assignment(identity, :legacy, nil), do: identity

  defp maybe_bind_assignment(identity, :coordinated, assignment_id),
    do: Map.put(identity, :assignment_id, assignment_id)

  defp reservation_digest(:legacy, :ok), do: {:ok, nil}

  defp reservation_digest(
         :coordinated,
         {:ok, %{termination_capability_digest: digest}}
       )
       when is_binary(digest) and byte_size(digest) == 32,
       do: {:ok, digest}

  defp reservation_digest(_mode, _result), do: {:error, :effect_task_reservation_lost}

  defp maybe_put_capability_digest(identity, nil), do: identity

  defp maybe_put_capability_digest(identity, digest),
    do: Map.put(identity, :termination_capability_digest, digest)

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_task_identity}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_effect_task_identity}
end
