defmodule Maraithon.Runtime.EffectTaskAuthority do
  @moduledoc false

  use GenServer

  alias Maraithon.Runtime.EffectTaskSupervisor

  @registry Maraithon.Runtime.EffectTaskRegistry
  @task_supervisor Maraithon.Runtime.ExactEffectTaskSupervisor
  @call_timeout 5_000
  @termination_proof_timeout 2_000
  @supervisor_history_key {__MODULE__, :local_supervisor_history}
  @max_supervisor_history 256

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
    # A successful new Authority incarnation is proof-bearing only when the
    # coupled Task.Supervisor is already absent. Normal :one_for_all recovery
    # guarantees that ordering; an administrative Authority-only restart does
    # not and is rejected rather than manufacturing absence proof.
    if is_nil(Process.whereis(@task_supervisor)) do
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
         monitor_index: %{}
       }}
    else
      {:stop, :effect_task_supervisor_predecessor_still_running}
    end
  end

  @impl true
  def handle_call(:identity, _from, state) do
    {:reply, {:ok, state.supervisor_id}, state}
  end

  def handle_call(:active_identities, _from, state) do
    identities =
      state.reservations
      |> Map.values()
      |> Enum.filter(fn reservation ->
        is_pid(reservation.task_pid) and Process.alive?(reservation.task_pid) and
          supervised_child?(reservation.task_pid)
      end)
      |> Enum.map(
        &Map.take(&1, [
          :effect_id,
          :agent_id,
          :claim_token,
          :supervisor_id,
          :task_id
        ])
      )

    {:reply, {:ok, identities}, state}
  end

  def handle_call({:reserve, effect_id, agent_id, claim_token}, {owner, _tag}, state) do
    task_id = Ecto.UUID.generate()
    owner_ref = Process.monitor(owner)

    reservation = %{
      effect_id: effect_id,
      agent_id: agent_id,
      claim_token: claim_token,
      supervisor_id: state.supervisor_id,
      task_id: task_id,
      reserved_by: owner,
      owner_ref: owner_ref,
      task_pid: nil,
      task_ref: nil
    }

    identity =
      Map.take(reservation, [
        :effect_id,
        :agent_id,
        :claim_token,
        :supervisor_id,
        :task_id
      ])

    state = %{
      state
      | reservations: Map.put(state.reservations, task_id, reservation),
        monitor_index: Map.put(state.monitor_index, owner_ref, {:owner, task_id})
    }

    {:reply, {:ok, identity}, state}
  end

  def handle_call({:release, identity}, {caller, _tag}, state) do
    case exact_reservation(state, identity) do
      %{reserved_by: ^caller, task_pid: nil} = reservation ->
        {:reply, :ok, delete_reservation(state, reservation)}

      _active_lost_or_foreign ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  def handle_call({:activate, identity}, {task_pid, _tag}, state) do
    case exact_reservation(state, identity) do
      %{task_pid: nil} = reservation ->
        if supervised_child?(task_pid) do
          task_ref = Process.monitor(task_pid)
          reservation = %{reservation | task_pid: task_pid, task_ref: task_ref}

          state = %{
            state
            | reservations: Map.put(state.reservations, reservation.task_id, reservation),
              monitor_index: Map.put(state.monitor_index, task_ref, {:task, reservation.task_id})
          }

          {:reply, :ok, state}
        else
          {:reply, {:error, :effect_task_not_supervised}, state}
        end

      %{task_pid: ^task_pid} ->
        {:reply, :ok, state}

      _missing_or_wrong_task ->
        {:reply, {:error, :effect_task_reservation_lost}, state}
    end
  end

  def handle_call({:terminate_exact, claim}, _from, state) do
    cond do
      claim.supervisor_id == state.supervisor_id ->
        terminate_current_supervisor_claim(claim, state)

      MapSet.member?(state.proven_predecessor_ids, claim.supervisor_id) ->
        # Registry -> authority -> Task.Supervisor are :one_for_all. The local
        # predecessor history survives group restarts in this BEAM only, so it
        # proves the matching older Task.Supervisor was synchronously stopped.
        {:reply, {:ok, :supervisor_restarted}, state}

      true ->
        # A fresh VM may reuse the same distributed node name while an isolated
        # predecessor is still alive. Registry emptiness or an arbitrary UUID
        # mismatch on that new incarnation is never absence proof.
        {:reply, {:unknown, :effect_task_owner_incarnation_unproven}, state}
    end
  end

  @impl true
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
        _termination_attempt = terminate_child(task_pid)

        # Retain the exact reservation until its task monitor delivers DOWN.
        # Task.Supervisor return values and child-list absence are not physical
        # termination proof on their own.
        {:noreply, detach_dead_owner(state, reservation)}

      %{} = reservation ->
        # The runner died before a supervised task activated. No command could
        # have crossed its authorization boundary.
        {:noreply, delete_reservation(state, reservation)}

      nil ->
        {:noreply, state}
    end
  end

  defp terminate_current_supervisor_claim(claim, state) do
    case Map.get(state.reservations, claim.task_id) do
      %{} = reservation ->
        if reservation_matches?(reservation, claim) do
          case reservation.task_pid do
            nil ->
              # Cancellation won before Authority activation. Atomically remove
              # the reservation so a later Registry registration cannot
              # activate and cross the command boundary. The Effect still
              # settles ambiguous because this in-memory proof is not a durable
              # provider pre-entry ledger.
              {:reply, {:ok, :authority_absence}, delete_reservation(state, reservation)}

            pid when is_pid(pid) ->
              terminate_known_pid(pid, reservation, state)
          end
        else
          {:reply, {:unknown, :effect_task_identity_mismatch}, state}
        end

      nil ->
        case exact_registry_pid(claim) do
          {:ok, nil} ->
            # This is the same authority incarnation that reserved the identity.
            # A reservation can disappear only before activation or after its
            # monitored exact task ended. This is not Registry-only proof.
            {:reply, {:ok, :authority_absence}, state}

          {:ok, pid} ->
            if supervised_child?(pid) do
              terminate_known_pid(pid, nil, state)
            else
              {:reply, {:unknown, :effect_task_identity_mismatch}, state}
            end

          {:error, _reason} ->
            {:reply, {:unknown, :effect_task_registry_unavailable}, state}
        end
    end
  end

  defp terminate_known_pid(pid, reservation, state) do
    {task_ref, temporary_ref?} = termination_monitor(pid, reservation)
    termination_result = terminate_child(pid)

    case await_task_down(task_ref, pid) do
      :down ->
        state = if reservation, do: delete_reservation(state, reservation), else: state

        proof =
          if termination_result == {:error, :not_found},
            do: :authority_absence,
            else: :terminated

        {:reply, {:ok, proof}, state}

      :timeout ->
        if temporary_ref?, do: Process.demonitor(task_ref, [:flush])

        reason =
          if termination_result in [:ok, {:error, :not_found}],
            do: :effect_task_termination_unproven,
            else: :effect_task_termination_failed

        {:reply, {:unknown, reason}, state}
    end
  end

  defp termination_monitor(_pid, %{task_ref: task_ref}) when is_reference(task_ref),
    do: {task_ref, false}

  defp termination_monitor(pid, _reservation), do: {Process.monitor(pid), true}

  defp await_task_down(task_ref, pid) do
    receive do
      {:DOWN, ^task_ref, :process, ^pid, _reason} -> :down
    after
      @termination_proof_timeout -> :timeout
    end
  end

  defp exact_reservation(state, identity) do
    case Map.get(state.reservations, identity.task_id) do
      %{} = reservation -> if reservation_matches?(reservation, identity), do: reservation
      nil -> nil
    end
  end

  defp reservation_matches?(reservation, identity) do
    reservation.effect_id == identity.effect_id and
      reservation.agent_id == identity.agent_id and
      reservation.claim_token == identity.claim_token and
      reservation.supervisor_id == identity.supervisor_id and
      reservation.task_id == identity.task_id
  end

  defp exact_registry_pid(claim) do
    key = EffectTaskSupervisor.registry_key(claim)

    case Registry.lookup(@registry, key) do
      [] ->
        {:ok, nil}

      [{pid, metadata}] when is_pid(pid) ->
        if metadata_matches?(metadata, claim),
          do: {:ok, pid},
          else: {:error, :effect_task_identity_mismatch}

      _unexpected ->
        {:error, :effect_task_identity_mismatch}
    end
  rescue
    _error -> {:error, :effect_task_registry_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_registry_unavailable}
  end

  defp metadata_matches?(metadata, claim) when is_map(metadata) do
    metadata.agent_id == claim.agent_id and
      metadata.effect_id == claim.effect_id and
      metadata.claim_token == claim.claim_token and
      metadata.supervisor_id == claim.supervisor_id and
      metadata.task_id == claim.task_id
  end

  defp metadata_matches?(_metadata, _claim), do: false

  defp supervised_child?(pid) when is_pid(pid) do
    pid in Task.Supervisor.children(@task_supervisor)
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp terminate_child(pid) do
    Task.Supervisor.terminate_child(@task_supervisor, pid)
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
