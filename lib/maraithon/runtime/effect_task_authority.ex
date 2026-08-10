defmodule Maraithon.Runtime.EffectTaskAuthority do
  @moduledoc false

  use GenServer

  alias Maraithon.Runtime.TaskGuardian

  @task_supervisor Maraithon.Runtime.ExactEffectTaskSupervisor
  @call_timeout 5_000
  @termination_proof_timeout 2_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def identity, do: GenServer.call(__MODULE__, :identity, @call_timeout)
  def active_identities, do: GenServer.call(__MODULE__, :active_identities, @call_timeout)

  def reserve(effect_id, agent_id, claim_token) do
    with {:ok, effect_id} <- cast_uuid(effect_id),
         {:ok, agent_id} <- cast_uuid(agent_id),
         {:ok, claim_token} <- cast_uuid(claim_token) do
      GenServer.call(__MODULE__, {:reserve, effect_id, agent_id, claim_token}, @call_timeout)
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

  def terminate_exact(claim) when is_map(claim) do
    with {:ok, claim} <- validate_identity(claim) do
      GenServer.call(__MODULE__, {:terminate_exact, claim}, @call_timeout)
    else
      {:error, _reason} -> {:unknown, :invalid_effect_task_identity}
    end
  end

  def terminate_exact(_claim), do: {:unknown, :invalid_effect_task_identity}

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
         monitor_index: %{}
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

  def handle_call({:reserve, effect_id, agent_id, claim_token}, {owner, _tag}, state) do
    task_id = Ecto.UUID.generate()

    identity = %{
      effect_id: effect_id,
      agent_id: agent_id,
      claim_token: claim_token,
      supervisor_id: state.supervisor_id,
      task_id: task_id
    }

    case TaskGuardian.reserve(state.guardian, identity) do
      :ok ->
        owner_ref = Process.monitor(owner)

        reservation =
          Map.merge(identity, %{
            reserved_by: owner,
            owner_ref: owner_ref,
            task_pid: nil,
            task_ref: nil
          })

        state = %{
          state
          | reservations: Map.put(state.reservations, task_id, reservation),
            monitor_index: Map.put(state.monitor_index, owner_ref, {:owner, task_id})
        }

        {:reply, {:ok, identity}, state}

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, identity}, {caller, _tag}, state) do
    case exact_reservation(state, identity) do
      %{reserved_by: ^caller, task_pid: nil} = reservation ->
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
      %{task_pid: nil} = reservation ->
        case TaskGuardian.activate(state.guardian, identity, task_pid) do
          :ok ->
            task_ref = Process.monitor(task_pid)
            reservation = %{reservation | task_pid: task_pid, task_ref: task_ref}

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

  def handle_call({:terminate_exact, claim}, _from, state) do
    case exact_reservation(state, claim) do
      %{task_pid: nil} = reservation ->
        cancel_reserved(claim, reservation, state)

      %{task_pid: task_pid} = reservation when is_pid(task_pid) ->
        terminate_current_task(claim, reservation, state)

      nil ->
        reply_from_guardian_proof(claim, state)
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{guardian_ref: ref} = state) do
    {:stop, :effect_task_guardian_lost, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitor_index, ref) do
      {:owner, task_id} ->
        handle_owner_down(task_id, state)

      {:task, task_id} ->
        case Map.get(state.reservations, task_id) do
          %{} = reservation -> {:noreply, delete_reservation(state, reservation)}
          nil -> {:noreply, drop_monitor(state, ref)}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp handle_owner_down(task_id, state) do
    case Map.get(state.reservations, task_id) do
      %{task_pid: task_pid} = reservation when is_pid(task_pid) ->
        _termination_attempt = terminate_child(state.supervisor_pid, task_pid)

        # The reservation remains until its exact task monitor delivers DOWN.
        {:noreply, detach_dead_owner(state, reservation)}

      %{} = reservation ->
        case TaskGuardian.cancel_reserved(state.guardian, public_identity(reservation)) do
          :ok -> {:noreply, delete_reservation(state, reservation)}
          {:error, _reason} -> {:stop, :effect_task_guardian_lost, state}
        end

      nil ->
        {:noreply, state}
    end
  end

  defp cancel_reserved(claim, reservation, state) do
    case TaskGuardian.cancel_reserved(state.guardian, claim) do
      :ok ->
        {:reply, {:ok, :never_activated}, delete_reservation(state, reservation)}

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:error, _reason} ->
        {:reply, {:unknown, :effect_task_termination_unproven}, state}
    end
  end

  defp terminate_current_task(claim, reservation, state) do
    _termination_attempt = terminate_child(state.supervisor_pid, reservation.task_pid)

    case TaskGuardian.await_proof(
           state.guardian,
           claim,
           @termination_proof_timeout
         ) do
      {:ok, {:task_down, _proof}} ->
        {:reply, {:ok, :terminated}, delete_reservation(state, reservation)}

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      _pending_or_unknown ->
        {:reply, {:unknown, :effect_task_termination_unproven}, state}
    end
  end

  defp reply_from_guardian_proof(claim, state) do
    case TaskGuardian.await_proof(state.guardian, claim, @termination_proof_timeout) do
      {:ok, {:task_down, _proof}} ->
        {:reply, {:ok, :terminated}, state}

      {:ok, {:supervisor_down_before_activation, _proof}} ->
        {:reply, {:ok, :supervisor_down}, state}

      {:ok, :activation_cancelled} ->
        {:reply, {:ok, :never_activated}, state}

      {:error, :task_guardian_access_lost} = error ->
        {:stop, :effect_task_guardian_lost, error, state}

      {:unknown, :task_identity_mismatch} ->
        {:reply, {:unknown, :effect_task_identity_mismatch}, state}

      _pending_untracked_or_evicted ->
        {:reply, {:unknown, :effect_task_owner_incarnation_unproven}, state}
    end
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
    refs = Enum.filter([reservation.owner_ref, reservation.task_ref], &is_reference/1)
    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    %{
      state
      | reservations: Map.delete(state.reservations, reservation.task_id),
        monitor_index: Map.drop(state.monitor_index, refs)
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
         {:ok, task_id} <- identity |> Map.get(:task_id) |> cast_uuid() do
      {:ok,
       %{
         effect_id: effect_id,
         agent_id: agent_id,
         claim_token: claim_token,
         supervisor_id: supervisor_id,
         task_id: task_id
       }}
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_task_identity}
    end
  end

  defp cast_uuid(_value), do: {:error, :invalid_effect_task_identity}
end
