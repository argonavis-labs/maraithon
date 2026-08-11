defmodule Maraithon.Runtime.TaskGuardian do
  @moduledoc """
  Retains exact, monitor-derived physical task proofs outside coupled task groups.

  The guardian never turns lookup failure, a restart, or a timeout into proof.
  Generations and tasks become provable only through the `:DOWN` messages from
  monitors installed on their exact PIDs. Historical records are bounded; once
  a record is evicted, callers must obtain an external proof.
  """

  use GenServer

  @call_timeout 5_000
  @default_proof_wait_timeout 2_000
  @default_max_completed_generations 256
  @default_max_open_generations 32
  @default_max_identities 8_192
  @default_max_waiters 1_024
  @persistence_retry_ms 1_000
  @max_persistence_retry_batch 32
  @persistence_retry_callback_budget_ms 500
  @completion_fallback_errors [
    :coordination_task_completion_not_durable,
    :task_termination_proof_conflict
  ]
  @test_persistence_decisions Mix.env() == :test

  @effect_fields [:effect_id, :agent_id, :claim_token, :supervisor_id, :task_id]
  @coordinated_effect_fields [:assignment_id | @effect_fields]
  @coordination_fields [
    :work_kind,
    :work_id,
    :claim_token,
    :assignment_id,
    :supervisor_id,
    :local_task_id
  ]

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def open_generation(guardian_pid, kind, supervisor_pid)
      when is_pid(guardian_pid) and is_pid(supervisor_pid) do
    GenServer.call(guardian_pid, {:open_generation, kind, supervisor_pid}, @call_timeout)
  end

  def reserve(access, identity), do: call(access, {:reserve, identity, :without_capability})

  def reserve_with_termination_capability(access, identity),
    do: call(access, {:reserve, identity, :issue_termination_capability})

  def release(access, identity), do: call(access, {:release, identity})
  def cancel_reserved(access, identity), do: call(access, {:cancel_reserved, identity})
  def activate(access, identity, task_pid), do: call(access, {:activate, identity, task_pid})

  def activation_registered?(access, identity, task_pid),
    do: call(access, {:activation_registered?, identity, task_pid})

  def proof(access, identity), do: call(access, {:proof, identity})
  def tracked_active_identities(access), do: call(access, :tracked_active_identities)

  def await_proof(access, identity, timeout \\ @default_proof_wait_timeout)
      when is_integer(timeout) and timeout >= 0 do
    call(access, {:await_proof, identity, timeout}, timeout + @call_timeout)
  end

  def persist_termination(access, identity),
    do: call(access, {:persist_termination, identity}, @call_timeout * 2)

  def expect_completion(access, identity),
    do: call(access, {:expect_completion, identity})

  def cancel_expected_completion(access, identity),
    do: call(access, {:cancel_expected_completion, identity})

  def acknowledge_completion(access, identity),
    do: call(access, {:acknowledge_completion, identity}, @call_timeout * 2)

  defp call(%{guardian_pid: guardian_pid} = access, request) when is_pid(guardian_pid) do
    call(access, request, @call_timeout)
  end

  defp call(%{guardian_pid: guardian_pid} = access, request, timeout)
       when is_pid(guardian_pid) do
    GenServer.call(guardian_pid, {:access, access, request}, timeout)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       generations: %{},
       supervisor_pids: %{},
       supervisor_monitors: %{},
       controller_monitors: %{},
       task_monitors: %{},
       termination_capabilities: :ets.new(:task_termination_capabilities, [:set, :private]),
       completed_order: [],
       terminal_identity_order: [],
       identity_count: 0,
       waiters: %{},
       waiter_count: 0,
       pending_persistence: :queue.new(),
       pending_persistence_set: MapSet.new(),
       persistence_retry_timer: nil,
       test_persistence: test_persistence_config(opts),
       max_completed_generations:
         Keyword.get(opts, :max_completed_generations, @default_max_completed_generations),
       max_open_generations:
         Keyword.get(opts, :max_open_generations, @default_max_open_generations),
       max_identities: Keyword.get(opts, :max_identities, @default_max_identities),
       max_waiters: Keyword.get(opts, :max_waiters, @default_max_waiters)
     }}
  end

  @impl true
  def handle_call({:open_generation, kind, supervisor_pid}, {controller_pid, _tag}, state)
      when kind in [:effect, :coordination] and is_pid(supervisor_pid) do
    pid_key = {kind, supervisor_pid}

    case Map.get(state.supervisor_pids, pid_key) do
      nil ->
        if open_generation_count(state) >= state.max_open_generations do
          {:reply, {:error, :task_guardian_history_full}, state}
        else
          supervisor_id = Ecto.UUID.generate()
          token = make_ref()
          monitor_ref = Process.monitor(supervisor_pid)
          controller_ref = Process.monitor(controller_pid)
          generation_key = {kind, supervisor_id}

          generation = %{
            kind: kind,
            supervisor_id: supervisor_id,
            supervisor_pid: supervisor_pid,
            controller_pid: controller_pid,
            controller_ref: controller_ref,
            controller_down: nil,
            supervisor_ref: monitor_ref,
            supervisor_down: nil,
            token: token,
            identities: %{},
            proven: false
          }

          state = %{
            state
            | generations: Map.put(state.generations, generation_key, generation),
              supervisor_pids: Map.put(state.supervisor_pids, pid_key, generation_key),
              supervisor_monitors:
                Map.put(state.supervisor_monitors, monitor_ref, generation_key),
              controller_monitors:
                Map.put(state.controller_monitors, controller_ref, generation_key)
          }

          access = %{
            guardian_pid: self(),
            kind: kind,
            supervisor_id: supervisor_id,
            supervisor_pid: supervisor_pid,
            token: token
          }

          {:reply, {:ok, access}, state}
        end

      generation_key ->
        generation = Map.fetch!(state.generations, generation_key)

        if is_nil(generation.supervisor_down) and generation.controller_pid == controller_pid do
          access = %{
            guardian_pid: self(),
            kind: generation.kind,
            supervisor_id: generation.supervisor_id,
            supervisor_pid: generation.supervisor_pid,
            token: generation.token
          }

          {:reply, {:ok, access}, state}
        else
          reason =
            if generation.controller_pid == controller_pid,
              do: :task_supervisor_already_down,
              else: :task_guardian_controller_mismatch

          {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:open_generation, _kind, _supervisor_pid}, _from, state) do
    {:reply, {:error, :invalid_task_supervisor}, state}
  end

  def handle_call({:access, access, request}, {caller, _tag} = from, state) do
    case authorized_generation(state, access, caller) do
      {:ok, generation_key, generation} ->
        handle_access_call(request, from, generation_key, generation, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:retry_pending_task_terminations, state) do
    if is_reference(state.persistence_retry_timer),
      do: Process.cancel_timer(state.persistence_retry_timer)

    state =
      state
      |> Map.put(:persistence_retry_timer, nil)
      |> compact_pending_persistence()

    # Each production persistence call has its own 500 ms outer/PG bound. The
    # aggregate start deadline prevents one callback from serially spending
    # that bound on all 32 entries and monopolizing the Guardian for ~16 s.
    deadline_ms =
      System.monotonic_time(:millisecond) + @persistence_retry_callback_budget_ms

    work_count = min(MapSet.size(state.pending_persistence_set), @max_persistence_retry_batch)
    state = retry_pending_persistence(state, work_count, deadline_ms)
    {:noreply, schedule_persistence_retry(state)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case authenticate_down(state, ref, pid) do
      {:supervisor, generation_key, state} ->
        {:noreply, supervisor_down(state, generation_key, ref, pid, reason)}

      {:task, task_location, state} ->
        {:noreply, task_down(state, task_location, ref, pid, reason)}

      {:controller, generation_key, state} ->
        {:noreply, controller_down(state, generation_key, ref, pid, reason)}

      {:spoofed, state} ->
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:proof_wait_expired, waiter_key, tag}, state) do
    case pop_waiter(state, waiter_key, tag) do
      {nil, state} ->
        {:noreply, state}

      {%{from: from, identity: identity}, state} ->
        GenServer.reply(from, proof_result(state, waiter_key, identity))
        {:noreply, state}
    end
  end

  defp handle_access_call(
         {:reserve, identity, capability_mode},
         _from,
         generation_key,
         generation,
         state
       )
       when capability_mode in [:without_capability, :issue_termination_capability] do
    with nil <- generation.supervisor_down,
         nil <- generation.controller_down,
         {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         :ok <- ensure_identity_absent_or_exact(generation, identity_key, identity) do
      case Map.get(generation.identities, identity_key) do
        nil ->
          state = make_identity_capacity(state)
          generation = Map.fetch!(state.generations, generation_key)

          if state.identity_count >= state.max_identities do
            {:reply, {:error, :task_guardian_identity_history_full}, state}
          else
            {capability_id, capability_digest} =
              issue_termination_capability(state, capability_mode)

            record = %{
              identity: identity,
              phase: :reserved,
              task_pid: nil,
              task_ref: nil,
              down: nil,
              completion_requested: false,
              termination_capability_id: capability_id,
              termination_capability_digest: capability_digest,
              durable_disposition: if(is_nil(capability_id), do: :uncoordinated, else: nil)
            }

            generation = put_in(generation.identities[identity_key], record)
            state = put_generation(state, generation_key, generation)
            state = %{state | identity_count: state.identity_count + 1}

            reply = reservation_capability_reply(capability_id, capability_digest)
            {:reply, reply, state}
          end

        record ->
          {:reply, existing_reservation_reply(record, capability_mode), state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _closed_generation -> {:reply, {:error, :task_guardian_generation_closed}, state}
    end
  end

  defp handle_access_call({:release, identity}, _from, generation_key, generation, state) do
    with {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         {:ok, %{phase: :reserved} = record} <- exact_record(generation, identity_key, identity) do
      clear_capability_entry(state, record)
      generation = %{generation | identities: Map.delete(generation.identities, identity_key)}
      state = put_generation(state, generation_key, generation)
      state = drop_terminal_order(state, {generation_key, identity_key})
      {:reply, :ok, %{state | identity_count: state.identity_count - 1}}
    else
      {:ok, %{phase: :cancelled}} -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  defp handle_access_call(
         {:cancel_reserved, identity},
         _from,
         generation_key,
         generation,
         state
       ) do
    with {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         {:ok, record} <- exact_record(generation, identity_key, identity) do
      case record.phase do
        :reserved ->
          record = %{record | phase: :cancelled}
          generation = put_in(generation.identities[identity_key], record)

          state =
            state
            |> put_generation(generation_key, generation)
            |> remember_terminal_identity({generation_key, identity_key})
            |> enqueue_pending_persistence({generation_key, identity_key})
            |> resolve_waiters({generation_key, identity_key})

          {:reply, :ok, state}

        :cancelled ->
          {:reply, :ok, state}

        :active ->
          {:reply, {:error, :task_already_activated}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  defp handle_access_call(
         {:activate, identity, task_pid},
         _from,
         generation_key,
         generation,
         state
       )
       when is_pid(task_pid) do
    with nil <- generation.supervisor_down,
         {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         {:ok, record} <- exact_record(generation, identity_key, identity),
         :ok <- task_pid_available(generation, identity_key, task_pid) do
      case record do
        %{phase: :reserved} ->
          task_ref = Process.monitor(task_pid)

          record = %{
            record
            | phase: :active,
              task_pid: task_pid,
              task_ref: task_ref
          }

          generation = put_in(generation.identities[identity_key], record)

          state = %{
            state
            | generations: Map.put(state.generations, generation_key, generation),
              task_monitors:
                Map.put(state.task_monitors, task_ref, {generation_key, identity_key})
          }

          {:reply, :ok, state}

        %{phase: :active, task_pid: ^task_pid} ->
          {:reply, :ok, state}

        %{phase: :cancelled} ->
          {:reply, {:error, :task_activation_cancelled}, state}

        _ ->
          {:reply, {:error, :task_reservation_lost}, state}
      end
    else
      %{} -> {:reply, {:error, :task_supervisor_down}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :task_reservation_lost}, state}
    end
  end

  defp handle_access_call(
         {:activation_registered?, identity, task_pid},
         _from,
         _generation_key,
         generation,
         state
       )
       when is_pid(task_pid) do
    with {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         {:ok, %{phase: :active, task_pid: ^task_pid, down: nil}} <-
           exact_record(generation, identity_key, identity) do
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :task_activation_not_registered}, state}
    end
  end

  defp handle_access_call({:activate, _identity, _task_pid}, _from, _key, _generation, state) do
    {:reply, {:error, :invalid_task_pid}, state}
  end

  defp handle_access_call(
         {:activation_registered?, _identity, _task_pid},
         _from,
         _key,
         _generation,
         state
       ) do
    {:reply, {:error, :invalid_task_pid}, state}
  end

  defp handle_access_call({:proof, identity}, _from, _key, generation, state) do
    case proof_lookup_key(generation.kind, identity) do
      {:ok, waiter_key, normalized} ->
        {:reply, proof_result(state, waiter_key, normalized), state}

      {:error, reason} ->
        {:reply, {:unknown, reason}, state}
    end
  end

  defp handle_access_call(
         {:await_proof, identity, timeout},
         from,
         _generation_key,
         generation,
         state
       ) do
    await_result(identity, timeout, from, generation, state)
  end

  defp handle_access_call(
         {:expect_completion, identity},
         _from,
         generation_key,
         generation,
         state
       ) do
    with {:ok, normalized, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(normalized, generation),
         {:ok, record} <- exact_record(generation, identity_key, normalized) do
      record = %{record | completion_requested: true}
      generation = put_in(generation.identities[identity_key], record)
      {:reply, :ok, put_generation(state, generation_key, generation)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_access_call(
         {:cancel_expected_completion, identity},
         _from,
         generation_key,
         generation,
         state
       ) do
    with {:ok, normalized, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(normalized, generation),
         {:ok, record} <- exact_record(generation, identity_key, normalized) do
      record = %{record | completion_requested: false}
      generation = put_in(generation.identities[identity_key], record)
      {:reply, :ok, put_generation(state, generation_key, generation)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_access_call(
         {:acknowledge_completion, identity},
         _from,
         _authorized_generation_key,
         authorized_generation,
         state
       ) do
    case acknowledge_completion_result(state, authorized_generation.kind, identity) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_access_call(
         {:persist_termination, identity},
         _from,
         _authorized_generation_key,
         authorized_generation,
         state
       ) do
    case persist_termination_result(state, authorized_generation.kind, identity) do
      {:ok, proof_kind, state} -> {:reply, {:ok, proof_kind}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_access_call(:tracked_active_identities, _from, generation_key, generation, state) do
    identities =
      generation.identities
      |> Enum.flat_map(fn {_identity_key, record} ->
        if record.phase == :active and is_nil(record.down), do: [record.identity], else: []
      end)

    _ = generation_key
    {:reply, {:ok, identities}, state}
  end

  defp handle_access_call(_request, _from, _key, _generation, state) do
    {:reply, {:error, :unsupported_task_guardian_request}, state}
  end

  defp await_result(identity, timeout, from, generation, state) do
    with {:ok, waiter_key, normalized} <- proof_lookup_key(generation.kind, identity) do
      result = proof_result(state, waiter_key, normalized)

      if pending_proof?(result) and timeout > 0 and state.waiter_count < state.max_waiters do
        tag = make_ref()
        timer_ref = Process.send_after(self(), {:proof_wait_expired, waiter_key, tag}, timeout)
        waiter = %{from: from, timer_ref: timer_ref, tag: tag, identity: normalized}

        state = %{
          state
          | waiters: Map.update(state.waiters, waiter_key, [waiter], &[waiter | &1]),
            waiter_count: state.waiter_count + 1
        }

        {:noreply, state}
      else
        {:reply, result, state}
      end
    else
      {:error, reason} -> {:reply, {:unknown, reason}, state}
    end
  end

  defp authorized_generation(state, access, caller) when is_map(access) and is_pid(caller) do
    with kind when kind in [:effect, :coordination] <- Map.get(access, :kind),
         supervisor_id when is_binary(supervisor_id) <- Map.get(access, :supervisor_id),
         token when is_reference(token) <- Map.get(access, :token),
         generation_key = {kind, supervisor_id},
         %{} = generation <- Map.get(state.generations, generation_key),
         true <- generation.token == token,
         true <- generation.controller_pid == caller,
         true <- generation.supervisor_pid == Map.get(access, :supervisor_pid) do
      {:ok, generation_key, generation}
    else
      _ -> {:error, :task_guardian_access_lost}
    end
  end

  defp authenticate_down(state, ref, pid) do
    cond do
      generation_key = Map.get(state.supervisor_monitors, ref) ->
        authenticate_supervisor_down(state, generation_key, ref, pid)

      task_location = Map.get(state.task_monitors, ref) ->
        authenticate_task_down(state, task_location, ref, pid)

      generation_key = Map.get(state.controller_monitors, ref) ->
        authenticate_controller_down(state, generation_key, ref, pid)

      true ->
        :unknown
    end
  end

  defp authenticate_supervisor_down(state, generation_key, ref, pid) do
    case Map.get(state.generations, generation_key) do
      %{supervisor_ref: ^ref, supervisor_pid: ^pid} = generation ->
        if Process.demonitor(ref, [:info]) do
          new_ref = Process.monitor(pid)
          generation = %{generation | supervisor_ref: new_ref}

          state = %{
            state
            | generations: Map.put(state.generations, generation_key, generation),
              supervisor_monitors:
                state.supervisor_monitors
                |> Map.delete(ref)
                |> Map.put(new_ref, generation_key)
          }

          {:spoofed, state}
        else
          {:supervisor, generation_key, state}
        end

      _mismatch ->
        :unknown
    end
  end

  defp authenticate_controller_down(state, generation_key, ref, pid) do
    case Map.get(state.generations, generation_key) do
      %{controller_ref: ^ref, controller_pid: ^pid} = generation ->
        if Process.demonitor(ref, [:info]) do
          new_ref = Process.monitor(pid)
          generation = %{generation | controller_ref: new_ref}

          state = %{
            state
            | generations: Map.put(state.generations, generation_key, generation),
              controller_monitors:
                state.controller_monitors
                |> Map.delete(ref)
                |> Map.put(new_ref, generation_key)
          }

          {:spoofed, state}
        else
          {:controller, generation_key, state}
        end

      _mismatch ->
        :unknown
    end
  end

  defp authenticate_task_down(state, {generation_key, identity_key} = location, ref, pid) do
    with %{} = generation <- Map.get(state.generations, generation_key),
         %{task_ref: ^ref, task_pid: ^pid} = record <-
           Map.get(generation.identities, identity_key) do
      if Process.demonitor(ref, [:info]) do
        new_ref = Process.monitor(pid)
        record = %{record | task_ref: new_ref}
        generation = put_in(generation.identities[identity_key], record)

        state = %{
          state
          | generations: Map.put(state.generations, generation_key, generation),
            task_monitors: state.task_monitors |> Map.delete(ref) |> Map.put(new_ref, location)
        }

        {:spoofed, state}
      else
        {:task, location, state}
      end
    else
      _mismatch -> :unknown
    end
  end

  defp controller_down(state, generation_key, ref, pid, reason) do
    case Map.get(state.generations, generation_key) do
      %{controller_ref: ^ref, controller_pid: ^pid} = generation ->
        generation = %{
          generation
          | controller_ref: nil,
            controller_down: %{reason: proof_reason(reason)}
        }

        %{
          state
          | generations: Map.put(state.generations, generation_key, generation),
            controller_monitors: Map.delete(state.controller_monitors, ref)
        }

      _mismatch ->
        %{state | controller_monitors: Map.delete(state.controller_monitors, ref)}
    end
  end

  defp supervisor_down(state, generation_key, ref, pid, reason) do
    case Map.get(state.generations, generation_key) do
      %{supervisor_ref: ^ref, supervisor_pid: ^pid} = generation ->
        down = %{
          evidence_id: "supervisor-down:#{generation.supervisor_id}",
          reason: proof_reason(reason)
        }

        generation = %{
          generation
          | supervisor_ref: nil,
            supervisor_down: down
        }

        state = %{
          state
          | generations: Map.put(state.generations, generation_key, generation),
            supervisor_pids:
              Map.delete(state.supervisor_pids, {generation.kind, generation.supervisor_pid}),
            supervisor_monitors: Map.delete(state.supervisor_monitors, ref)
        }

        state
        |> maybe_complete_generation(generation_key)
        |> resolve_generation_waiters(generation_key)

      _ ->
        %{state | supervisor_monitors: Map.delete(state.supervisor_monitors, ref)}
    end
  end

  defp task_down(state, {generation_key, identity_key}, ref, pid, reason) do
    with %{} = generation <- Map.get(state.generations, generation_key),
         %{} = record <- Map.get(generation.identities, identity_key),
         ^ref <- record.task_ref,
         ^pid <- record.task_pid do
      down = %{
        evidence_id: task_evidence_id(generation.kind, record.identity),
        reason: proof_reason(reason)
      }

      record = %{record | task_ref: nil, down: down}
      generation = put_in(generation.identities[identity_key], record)

      state = %{
        state
        | generations: Map.put(state.generations, generation_key, generation),
          task_monitors: Map.delete(state.task_monitors, ref)
      }

      state
      |> remember_terminal_identity({generation_key, identity_key})
      |> enqueue_pending_persistence({generation_key, identity_key})
      |> maybe_complete_generation(generation_key)
      |> resolve_waiters({generation_key, identity_key})
      |> resolve_generation_waiters(generation_key)
    else
      _ -> %{state | task_monitors: Map.delete(state.task_monitors, ref)}
    end
  end

  defp maybe_complete_generation(state, generation_key) do
    generation = Map.fetch!(state.generations, generation_key)

    all_registered_tasks_down? =
      Enum.all?(generation.identities, fn {_key, record} ->
        record.phase != :active or not is_nil(record.down)
      end)

    if not generation.proven and not is_nil(generation.supervisor_down) and
         all_registered_tasks_down? do
      generation = %{generation | proven: true}

      state = %{
        state
        | generations: Map.put(state.generations, generation_key, generation),
          completed_order: [generation_key | state.completed_order]
      }

      state =
        Enum.reduce(generation.identities, state, fn {identity_key, _record}, acc ->
          acc
          |> remember_terminal_identity({generation_key, identity_key})
          |> enqueue_pending_persistence({generation_key, identity_key})
        end)

      trim_completed_generations(state)
    else
      state
    end
  end

  defp proof_result(state, {generation_key, identity_key} = _waiter_key, supplied_identity \\ nil) do
    with %{} = generation <- Map.get(state.generations, generation_key),
         %{} = record <- Map.get(generation.identities, identity_key),
         true <- is_nil(supplied_identity) or record.identity == supplied_identity do
      case record do
        %{phase: :active, down: %{} = down} ->
          {:ok, {:task_down, down}}

        %{phase: :cancelled} ->
          {:ok, :activation_cancelled}

        %{phase: :reserved} when generation.proven ->
          {:ok, {:supervisor_down_before_activation, generation.supervisor_down}}

        %{phase: :active} ->
          {:pending, :task_down_not_observed}

        %{phase: :reserved} ->
          {:pending, :supervisor_down_not_proven}
      end
    else
      false -> {:unknown, :task_identity_mismatch}
      _ -> {:unknown, :task_identity_untracked}
    end
  end

  defp acknowledge_completion_result(state, kind, identity) do
    with {:ok, {generation_key, identity_key} = waiter_key, normalized} <-
           proof_lookup_key(kind, identity),
         %{} = generation <- Map.get(state.generations, generation_key),
         {:ok, record} <- exact_record(generation, identity_key, normalized),
         {:ok, {:task_down, _proof}} <- proof_result(state, waiter_key, normalized),
         {:ok, disposition} <- acknowledge_completion_record(state, generation.kind, record) do
      clear_capability_entry(state, record)
      record = %{record | termination_capability_id: nil, durable_disposition: disposition}
      generation = put_in(generation.identities[identity_key], record)

      location = {generation_key, identity_key}

      state =
        state
        |> put_generation(generation_key, generation)
        |> remember_terminal_identity(location)
        |> drop_pending_persistence(location)

      {:ok, state}
    else
      nil -> {:error, :task_identity_untracked, state}
      {:pending, reason} -> {:error, reason, state}
      {:unknown, reason} -> {:error, reason, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp acknowledge_completion_record(_state, _kind, %{
         termination_capability_id: nil,
         durable_disposition: disposition
       })
       when disposition in [
              :completion,
              :never_activated,
              :supervisor_down,
              :external_destroyed,
              :uncoordinated,
              :uncommitted
            ],
       do: {:ok, disposition}

  defp acknowledge_completion_record(_state, _kind, %{termination_capability_id: nil}),
    do: {:error, :task_termination_disposition_unavailable}

  if @test_persistence_decisions do
    defp acknowledge_completion_record(state, :effect, record) do
      case test_persistence_decision(state, {:completion, record.identity}) do
        :continue -> acknowledge_capability_completion_record(state, record)
        {:error, _reason} = error -> error
      end
    end
  else
    defp acknowledge_completion_record(state, :effect, record),
      do: acknowledge_capability_completion_record(state, record)
  end

  defp acknowledge_completion_record(_state, _kind, _record),
    do: {:error, :unsupported_task_guardian_completion}

  defp acknowledge_capability_completion_record(state, record) do
    with {:ok, secret} <- fetch_termination_secret(state, record) do
      run_persistence(fn ->
        Maraithon.Effects.Cancellation.acknowledge_guardian_completion(
          record.identity,
          secret
        )
      end)
    end
  end

  defp persist_termination_result(state, kind, identity) do
    with {:ok, {generation_key, identity_key} = waiter_key, normalized} <-
           proof_lookup_key(kind, identity),
         %{} = generation <- Map.get(state.generations, generation_key),
         {:ok, record} <- exact_record(generation, identity_key, normalized) do
      case proof_result(state, waiter_key, normalized) do
        {:ok, {:task_down, proof}} ->
          persist_record(
            state,
            generation_key,
            identity_key,
            generation,
            record,
            "supervisor_down",
            proof.evidence_id
          )

        {:ok, :activation_cancelled} ->
          persist_record(
            state,
            generation_key,
            identity_key,
            generation,
            record,
            "never_activated",
            never_activated_evidence_id(generation.kind, record.identity)
          )

        {:ok, {:supervisor_down_before_activation, _proof}} ->
          persist_record(
            state,
            generation_key,
            identity_key,
            generation,
            record,
            "never_activated",
            never_activated_evidence_id(generation.kind, record.identity)
          )

        {:pending, reason} ->
          {:error, reason, state}

        {:unknown, reason} ->
          {:error, reason, state}
      end
    else
      nil -> {:error, :task_identity_untracked, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp persist_record(
         state,
         generation_key,
         identity_key,
         _generation,
         %{termination_capability_id: nil, durable_disposition: disposition},
         _proof_kind,
         _evidence_id
       )
       when disposition in [
              :completion,
              :never_activated,
              :supervisor_down,
              :external_destroyed,
              :uncoordinated,
              :uncommitted
            ] do
    location = {generation_key, identity_key}

    state =
      state
      |> remember_terminal_identity(location)
      |> drop_pending_persistence(location)

    {:ok, disposition, state}
  end

  defp persist_record(
         state,
         _generation_key,
         _identity_key,
         _generation,
         %{termination_capability_id: nil},
         _proof_kind,
         _evidence_id
       ),
       do: {:error, :task_termination_disposition_unavailable, state}

  if @test_persistence_decisions do
    defp persist_record(
           state,
           generation_key,
           identity_key,
           generation,
           record,
           proof_kind,
           evidence_id
         ) do
      decision =
        test_persistence_decision(
          state,
          {:termination, generation.kind, record.identity, proof_kind, evidence_id}
        )

      case decision do
        :continue ->
          persist_capability_record(
            state,
            generation_key,
            identity_key,
            generation,
            record,
            proof_kind,
            evidence_id
          )

        {:error, reason} ->
          {:error, reason, state}
      end
    end
  else
    defp persist_record(
           state,
           generation_key,
           identity_key,
           generation,
           record,
           proof_kind,
           evidence_id
         ) do
      persist_capability_record(
        state,
        generation_key,
        identity_key,
        generation,
        record,
        proof_kind,
        evidence_id
      )
    end
  end

  defp persist_capability_record(
         state,
         generation_key,
         identity_key,
         generation,
         record,
         proof_kind,
         evidence_id
       ) do
    with {:ok, secret} <- fetch_termination_secret(state, record),
         {:ok, disposition} <-
           run_persistence(fn ->
             persist_guardian_proof(
               generation.kind,
               record.identity,
               proof_kind,
               evidence_id,
               secret
             )
           end) do
      clear_capability_entry(state, record)
      record = %{record | termination_capability_id: nil, durable_disposition: disposition}
      generation = put_in(generation.identities[identity_key], record)

      location = {generation_key, identity_key}

      state =
        state
        |> put_generation(generation_key, generation)
        |> remember_terminal_identity(location)
        |> drop_pending_persistence(location)

      {:ok, disposition, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp fetch_termination_secret(state, %{termination_capability_id: capability_id})
       when is_reference(capability_id) do
    case :ets.lookup(state.termination_capabilities, capability_id) do
      [{^capability_id, secret, digest}]
      when is_binary(secret) and byte_size(secret) == 32 and is_binary(digest) ->
        {:ok, secret}

      [] ->
        {:error, :task_termination_capability_unavailable}
    end
  end

  defp fetch_termination_secret(_state, _record),
    do: {:error, :task_termination_capability_unavailable}

  defp clear_capability_entry(_state, %{termination_capability_id: nil}), do: :ok

  defp clear_capability_entry(state, %{termination_capability_id: capability_id})
       when is_reference(capability_id) do
    _ = :ets.delete(state.termination_capabilities, capability_id)
    :ok
  end

  defp never_activated_evidence_id(:effect, identity),
    do: "task-supervisor:never_activated:#{identity.task_id}"

  defp never_activated_evidence_id(:coordination, identity),
    do: "task-supervisor:never_activated:#{identity.local_task_id}"

  defp run_persistence(fun) do
    case fun.() do
      :ok ->
        :ok

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

      {:error, _reason} = error ->
        error

      _unexpected ->
        {:error, :task_termination_persistence_failed}
    end
  rescue
    _error -> {:error, :task_termination_persistence_failed}
  catch
    _kind, _reason -> {:error, :task_termination_persistence_failed}
  end

  defp persist_guardian_proof(:coordination, identity, proof_kind, evidence_id, secret) do
    Maraithon.Runtime.Coordination.TaskClaims.persist_guardian_termination(
      identity,
      proof_kind,
      evidence_id,
      secret
    )
  end

  defp persist_guardian_proof(:effect, identity, proof_kind, evidence_id, secret) do
    Maraithon.Effects.Cancellation.persist_guardian_termination(
      identity,
      proof_kind,
      evidence_id,
      secret
    )
  end

  defp persist_guardian_proof(_kind, _identity, _proof_kind, _evidence_id, _secret),
    do: {:error, :unsupported_task_guardian_persistence}

  if @test_persistence_decisions do
    defp test_persistence_config(opts) do
      # The named application Guardian never accepts test decisions. This seam
      # exists only in MIX_ENV=test isolated processes, can inject errors/delay
      # only, and runs before any private ETS capability lookup.
      if Keyword.get(opts, :name, __MODULE__) == nil do
        case Keyword.get(opts, :test_persistence) do
          %{
            test_pid: test_pid,
            acknowledge_error: acknowledge_error,
            persist_error: persist_error,
            delay_ms: delay_ms
          } = config
          when is_pid(test_pid) and
                 (is_nil(acknowledge_error) or is_atom(acknowledge_error)) and
                 (is_nil(persist_error) or is_atom(persist_error)) and is_integer(delay_ms) and
                 delay_ms in 0..1_000 ->
            config

          _disabled_or_invalid ->
            nil
        end
      end
    end

    defp test_persistence_decision(%{test_persistence: nil}, _event), do: :continue

    defp test_persistence_decision(
           %{
             test_persistence: %{
               test_pid: test_pid,
               acknowledge_error: acknowledge_error,
               persist_error: persist_error,
               delay_ms: delay_ms
             }
           },
           event
         ) do
      error =
        case event do
          {:completion, _identity} -> acknowledge_error
          {:termination, _kind, _identity, _proof_kind, _evidence_id} -> persist_error
        end

      if is_pid(test_pid) and is_atom(error) and not is_nil(error) and is_integer(delay_ms) and
           delay_ms in 0..1_000 do
        notify_test_persistence_attempt(test_pid, event)
        delay_test_persistence(delay_ms)
        {:error, error}
      else
        :continue
      end
    end

    defp test_persistence_decision(_state, _event), do: :continue

    defp notify_test_persistence_attempt(test_pid, {:completion, identity}) do
      send(test_pid, {:guardian_persistence_attempt, self(), :completion, identity})
    end

    defp notify_test_persistence_attempt(
           test_pid,
           {:termination, kind, identity, proof_kind, evidence_id}
         ) do
      send(
        test_pid,
        {:guardian_persistence_attempt, self(), :termination, kind, identity, proof_kind,
         evidence_id}
      )
    end

    defp delay_test_persistence(0), do: :ok

    defp delay_test_persistence(delay_ms) do
      tag = make_ref()
      _timer = Process.send_after(self(), {:guardian_persistence_delay_elapsed, tag}, delay_ms)

      receive do
        {:guardian_persistence_delay_elapsed, ^tag} -> :ok
      end
    end
  else
    defp test_persistence_config(_opts), do: nil
  end

  defp proof_lookup_key(kind, identity) do
    with {:ok, normalized, identity_key} <- normalize_identity(kind, identity) do
      waiter_key = {{kind, Map.fetch!(normalized, :supervisor_id)}, identity_key}
      {:ok, waiter_key, normalized}
    end
  end

  defp pending_proof?({:pending, _reason}), do: true
  defp pending_proof?(_result), do: false

  defp resolve_waiters(state, waiter_key) do
    case Map.pop(state.waiters, waiter_key) do
      {nil, _waiters} ->
        state

      {waiters, remaining} ->
        Enum.each(waiters, fn waiter ->
          _ = Process.cancel_timer(waiter.timer_ref)

          GenServer.reply(waiter.from, proof_result(state, waiter_key, waiter.identity))
        end)

        %{
          state
          | waiters: remaining,
            waiter_count: state.waiter_count - length(waiters)
        }
    end
  end

  defp resolve_generation_waiters(state, generation_key) do
    state.waiters
    |> Map.keys()
    |> Enum.filter(fn {key, _identity_key} -> key == generation_key end)
    |> Enum.reduce(state, fn waiter_key, acc ->
      if pending_proof?(proof_result(acc, waiter_key)) do
        acc
      else
        resolve_waiters(acc, waiter_key)
      end
    end)
  end

  defp pop_waiter(state, waiter_key, tag) do
    waiters = Map.get(state.waiters, waiter_key, [])

    case Enum.split_with(waiters, &(&1.tag == tag)) do
      {[], _remaining} ->
        {nil, state}

      {[waiter | _], remaining} ->
        waiters_map =
          if remaining == [],
            do: Map.delete(state.waiters, waiter_key),
            else: Map.put(state.waiters, waiter_key, remaining)

        {waiter,
         %{
           state
           | waiters: waiters_map,
             waiter_count: state.waiter_count - 1
         }}
    end
  end

  defp ensure_identity_absent_or_exact(generation, identity_key, identity) do
    case Map.get(generation.identities, identity_key) do
      nil -> :ok
      %{identity: ^identity} -> :ok
      _ -> {:error, :task_identity_mismatch}
    end
  end

  defp issue_termination_capability(_state, :without_capability), do: {nil, nil}

  defp issue_termination_capability(state, :issue_termination_capability) do
    capability_id = make_ref()
    secret = :crypto.strong_rand_bytes(32)
    digest = :crypto.hash(:sha256, secret)
    true = :ets.insert(state.termination_capabilities, {capability_id, secret, digest})
    {capability_id, digest}
  end

  defp reservation_capability_reply(nil, nil), do: :ok

  defp reservation_capability_reply(_capability_id, capability_digest),
    do: {:ok, %{termination_capability_digest: capability_digest}}

  defp existing_reservation_reply(
         %{termination_capability_id: nil},
         :without_capability
       ),
       do: :ok

  defp existing_reservation_reply(
         %{
           termination_capability_id: capability_id,
           termination_capability_digest: capability_digest
         },
         :issue_termination_capability
       ),
       do: reservation_capability_reply(capability_id, capability_digest)

  defp existing_reservation_reply(_record, _mode),
    do: {:error, :task_termination_capability_mismatch}

  defp exact_record(generation, identity_key, identity) do
    case Map.get(generation.identities, identity_key) do
      %{identity: ^identity} = record -> {:ok, record}
      nil -> {:error, :task_identity_untracked}
      _ -> {:error, :task_identity_mismatch}
    end
  end

  defp identity_belongs_to_generation(identity, generation) do
    if Map.get(identity, :supervisor_id) == generation.supervisor_id,
      do: :ok,
      else: {:error, :task_supervisor_identity_mismatch}
  end

  defp task_pid_available(generation, identity_key, task_pid) do
    duplicate =
      Enum.any?(generation.identities, fn
        {^identity_key, _record} -> false
        {_other_key, %{phase: :active, task_pid: ^task_pid}} -> true
        _ -> false
      end)

    if duplicate, do: {:error, :task_pid_already_registered}, else: :ok
  end

  defp normalize_identity(:effect, identity) when is_map(identity) do
    fields =
      if Map.has_key?(identity, :assignment_id),
        do: @coordinated_effect_fields,
        else: @effect_fields

    normalize_fields(identity, fields, :effect)
  end

  defp normalize_identity(:coordination, identity) when is_map(identity) do
    with {:ok, normalized, identity_key} <-
           normalize_fields(identity, @coordination_fields, :coordination),
         true <- normalized.work_kind in ~w(background_job effect) do
      {:ok, normalized, identity_key}
    else
      false -> {:error, :invalid_task_identity}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_identity(_kind, _identity), do: {:error, :invalid_task_identity}

  defp normalize_fields(identity, fields, kind) do
    normalized = Map.take(identity, fields)

    if map_size(normalized) == length(fields) and valid_uuid_fields?(kind, normalized) do
      {:ok, normalized, identity_key(kind, normalized)}
    else
      {:error, :invalid_task_identity}
    end
  end

  defp valid_uuid_fields?(:effect, identity) do
    identity
    |> Map.keys()
    |> Enum.all?(fn field -> valid_uuid?(Map.get(identity, field)) end)
  end

  defp valid_uuid_fields?(:coordination, identity) do
    identity.work_kind in ~w(background_job effect) and
      Enum.all?(@coordination_fields -- [:work_kind], fn field ->
        valid_uuid?(Map.get(identity, field))
      end)
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp identity_key(:effect, identity) do
    {:effect, Map.get(identity, :assignment_id), identity.effect_id, identity.claim_token,
     identity.supervisor_id, identity.task_id}
  end

  defp identity_key(:coordination, identity) do
    {:coordination, identity.assignment_id, identity.claim_token, identity.supervisor_id,
     identity.local_task_id}
  end

  defp task_evidence_id(:effect, identity), do: "task-down:#{identity.task_id}"

  defp task_evidence_id(:coordination, identity),
    do: "task-down:#{identity.local_task_id}"

  defp proof_reason(reason) when is_atom(reason), do: reason |> Atom.to_string() |> truncate()
  defp proof_reason({reason, _detail}) when is_atom(reason), do: proof_reason(reason)
  defp proof_reason(_reason), do: "terminated"
  defp truncate(value), do: binary_part(value, 0, min(byte_size(value), 64))

  defp open_generation_count(state) do
    Enum.count(state.generations, fn {_key, generation} -> not generation.proven end)
  end

  defp put_generation(state, key, generation) do
    %{state | generations: Map.put(state.generations, key, generation)}
  end

  defp remember_terminal_identity(state, location) do
    order = [location | Enum.reject(state.terminal_identity_order, &(&1 == location))]
    %{state | terminal_identity_order: order}
  end

  defp drop_terminal_order(state, location) do
    %{
      state
      | terminal_identity_order: Enum.reject(state.terminal_identity_order, &(&1 == location))
    }
  end

  defp enqueue_pending_persistence(state, location) do
    case record_at(state, location) do
      %{termination_capability_id: capability_id} when is_reference(capability_id) ->
        if MapSet.member?(state.pending_persistence_set, location) do
          state
        else
          state = %{
            state
            | pending_persistence: :queue.in(location, state.pending_persistence),
              pending_persistence_set: MapSet.put(state.pending_persistence_set, location)
          }

          schedule_persistence_retry(state)
        end

      _without_capability ->
        state
    end
  end

  defp drop_pending_persistence(state, location) do
    if MapSet.member?(state.pending_persistence_set, location) do
      queue =
        state.pending_persistence
        |> :queue.to_list()
        |> Enum.reject(&(&1 == location))
        |> :queue.from_list()

      %{
        state
        | pending_persistence: queue,
          pending_persistence_set: MapSet.delete(state.pending_persistence_set, location)
      }
    else
      state
    end
  end

  defp compact_pending_persistence(state) do
    # Direct acknowledgements can retire work before its tick. Keep the queue
    # physically aligned with the dedupe set so those tombstones never consume
    # the live batch budget or starve a later proof.
    {reversed, seen} =
      state.pending_persistence
      |> :queue.to_list()
      |> Enum.reduce({[], MapSet.new()}, fn location, {locations, seen} ->
        if MapSet.member?(state.pending_persistence_set, location) and
             not MapSet.member?(seen, location) do
          {[location | locations], MapSet.put(seen, location)}
        else
          {locations, seen}
        end
      end)

    missing =
      state.pending_persistence_set
      |> MapSet.difference(seen)
      |> Enum.sort()

    queue = reversed |> Enum.reverse() |> Kernel.++(missing) |> :queue.from_list()
    %{state | pending_persistence: queue}
  end

  defp retry_pending_persistence(state, 0, _deadline_ms), do: state

  defp retry_pending_persistence(state, remaining, deadline_ms) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      state
    else
      retry_next_pending_persistence(state, remaining, deadline_ms)
    end
  end

  defp retry_next_pending_persistence(state, remaining, deadline_ms) do
    case :queue.out(state.pending_persistence) do
      {:empty, _queue} ->
        state

      {{:value, location}, queue} ->
        state = %{state | pending_persistence: queue}

        if MapSet.member?(state.pending_persistence_set, location) do
          state = %{
            state
            | pending_persistence_set: MapSet.delete(state.pending_persistence_set, location)
          }

          state = retry_persistence_at(state, location)
          retry_pending_persistence(state, remaining - 1, deadline_ms)
        else
          retry_pending_persistence(state, remaining, deadline_ms)
        end
    end
  end

  defp retry_persistence_at(state, location) do
    case record_at(state, location) do
      %{identity: identity} = record ->
        {generation_key, _identity_key} = location
        {kind, _supervisor_id} = generation_key

        result = retry_persistence_result(state, kind, identity, location, record)

        case result do
          {:ok, _proof_kind, persisted} -> persisted
          {:error, _reason, retained} -> requeue_pending_persistence(retained, location)
        end

      nil ->
        state
    end
  end

  defp retry_persistence_result(
         state,
         kind,
         identity,
         location,
         %{completion_requested: true}
       ) do
    case acknowledge_completion_result(state, kind, identity) do
      {:ok, persisted} ->
        {:ok, :completion, persisted}

      {:error, reason, retained} when reason in @completion_fallback_errors ->
        retained = cancel_completion_expectation_at(retained, location)
        persist_termination_result(retained, kind, identity)

      {:error, reason, retained} ->
        {:error, reason, retained}
    end
  end

  defp retry_persistence_result(state, kind, identity, _location, _record),
    do: persist_termination_result(state, kind, identity)

  defp cancel_completion_expectation_at(state, {generation_key, identity_key}) do
    case Map.get(state.generations, generation_key) do
      %{identities: identities} = generation ->
        case Map.get(identities, identity_key) do
          %{} = record ->
            record = %{record | completion_requested: false}
            generation = put_in(generation.identities[identity_key], record)
            put_generation(state, generation_key, generation)

          nil ->
            state
        end

      nil ->
        state
    end
  end

  defp requeue_pending_persistence(state, location) do
    if MapSet.member?(state.pending_persistence_set, location) do
      state
    else
      %{
        state
        | pending_persistence: :queue.in(location, state.pending_persistence),
          pending_persistence_set: MapSet.put(state.pending_persistence_set, location)
      }
    end
  end

  defp schedule_persistence_retry(state) do
    if MapSet.size(state.pending_persistence_set) > 0 and
         is_nil(state.persistence_retry_timer) do
      timer = Process.send_after(self(), :retry_pending_task_terminations, @persistence_retry_ms)
      %{state | persistence_retry_timer: timer}
    else
      state
    end
  end

  defp record_at(state, {generation_key, identity_key}) do
    with %{} = generation <- Map.get(state.generations, generation_key),
         %{} = record <- Map.get(generation.identities, identity_key) do
      record
    else
      _ -> nil
    end
  end

  defp make_identity_capacity(state) do
    if state.identity_count < state.max_identities do
      state
    else
      evict_oldest_terminal_identity(state)
    end
  end

  defp evict_oldest_terminal_identity(%{terminal_identity_order: []} = state), do: state

  defp evict_oldest_terminal_identity(state) do
    evict_oldest_terminal_identity(state, length(state.terminal_identity_order))
  end

  defp evict_oldest_terminal_identity(state, 0), do: state

  defp evict_oldest_terminal_identity(state, remaining) do
    {location, order} = List.pop_at(state.terminal_identity_order, -1)
    {generation_key, identity_key} = location

    case Map.get(state.generations, generation_key) do
      nil ->
        evict_oldest_terminal_identity(%{state | terminal_identity_order: order}, remaining - 1)

      generation ->
        case Map.get(generation.identities, identity_key) do
          %{phase: :active, down: %{} = _down, termination_capability_id: nil} ->
            drop_identity(state, generation_key, generation, identity_key, order)

          %{phase: :cancelled, termination_capability_id: nil} ->
            drop_identity(state, generation_key, generation, identity_key, order)

          %{phase: :reserved, termination_capability_id: nil} when generation.proven ->
            drop_identity(state, generation_key, generation, identity_key, order)

          nil ->
            evict_oldest_terminal_identity(
              %{state | terminal_identity_order: order},
              remaining - 1
            )

          _temporarily_not_evictable ->
            # A terminal record that still carries its capability is retained,
            # but rotated to the newest end so other durable records can make
            # capacity. Successful persistence re-remembers it for later eviction.
            evict_oldest_terminal_identity(
              %{state | terminal_identity_order: [location | order]},
              remaining - 1
            )
        end
    end
  end

  defp drop_identity(state, generation_key, generation, identity_key, order) do
    record = Map.fetch!(generation.identities, identity_key)
    clear_capability_entry(state, record)
    generation = %{generation | identities: Map.delete(generation.identities, identity_key)}

    %{
      state
      | generations: Map.put(state.generations, generation_key, generation),
        terminal_identity_order: order,
        identity_count: state.identity_count - 1
    }
  end

  defp trim_completed_generations(state) do
    if length(state.completed_order) <= state.max_completed_generations do
      state
    else
      case oldest_clearable_generation(state) do
        nil ->
          state

        generation_key ->
          generation = Map.fetch!(state.generations, generation_key)
          identity_locations = Enum.map(Map.keys(generation.identities), &{generation_key, &1})

          if is_reference(generation.controller_ref),
            do: Process.demonitor(generation.controller_ref, [:flush])

          controller_monitors =
            if is_reference(generation.controller_ref),
              do: Map.delete(state.controller_monitors, generation.controller_ref),
              else: state.controller_monitors

          state = %{
            state
            | generations: Map.delete(state.generations, generation_key),
              controller_monitors: controller_monitors,
              completed_order: List.delete(state.completed_order, generation_key),
              terminal_identity_order:
                Enum.reject(state.terminal_identity_order, &(&1 in identity_locations)),
              identity_count: state.identity_count - map_size(generation.identities)
          }

          trim_completed_generations(state)
      end
    end
  end

  defp oldest_clearable_generation(state) do
    state.completed_order
    |> Enum.reverse()
    |> Enum.find(fn generation_key ->
      generation = Map.fetch!(state.generations, generation_key)

      Enum.all?(generation.identities, fn {_key, record} ->
        is_nil(record.termination_capability_id)
      end)
    end)
  end
end
