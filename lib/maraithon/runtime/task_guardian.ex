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

  @effect_fields [:effect_id, :agent_id, :claim_token, :supervisor_id, :task_id]
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

  def reserve(access, identity), do: call(access, {:reserve, identity})
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
       task_monitors: %{},
       completed_order: [],
       terminal_identity_order: [],
       identity_count: 0,
       waiters: %{},
       waiter_count: 0,
       max_completed_generations:
         Keyword.get(opts, :max_completed_generations, @default_max_completed_generations),
       max_open_generations:
         Keyword.get(opts, :max_open_generations, @default_max_open_generations),
       max_identities: Keyword.get(opts, :max_identities, @default_max_identities),
       max_waiters: Keyword.get(opts, :max_waiters, @default_max_waiters)
     }}
  end

  @impl true
  def handle_call({:open_generation, kind, supervisor_pid}, _from, state)
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
          generation_key = {kind, supervisor_id}

          generation = %{
            kind: kind,
            supervisor_id: supervisor_id,
            supervisor_pid: supervisor_pid,
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
              supervisor_monitors: Map.put(state.supervisor_monitors, monitor_ref, generation_key)
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

        if is_nil(generation.supervisor_down) do
          access = %{
            guardian_pid: self(),
            kind: generation.kind,
            supervisor_id: generation.supervisor_id,
            supervisor_pid: generation.supervisor_pid,
            token: generation.token
          }

          {:reply, {:ok, access}, state}
        else
          {:reply, {:error, :task_supervisor_already_down}, state}
        end
    end
  end

  def handle_call({:open_generation, _kind, _supervisor_pid}, _from, state) do
    {:reply, {:error, :invalid_task_supervisor}, state}
  end

  def handle_call({:access, access, request}, from, state) do
    case authorized_generation(state, access) do
      {:ok, generation_key, generation} ->
        handle_access_call(request, from, generation_key, generation, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    cond do
      generation_key = Map.get(state.supervisor_monitors, ref) ->
        state = supervisor_down(state, generation_key, ref, pid, reason)
        {:noreply, state}

      task_location = Map.get(state.task_monitors, ref) ->
        state = task_down(state, task_location, ref, pid, reason)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:proof_wait_expired, waiter_key, tag}, state) do
    case pop_waiter(state, waiter_key, tag) do
      {nil, state} ->
        {:noreply, state}

      {%{from: from}, state} ->
        GenServer.reply(from, proof_result(state, waiter_key))
        {:noreply, state}
    end
  end

  defp handle_access_call({:reserve, identity}, _from, generation_key, generation, state) do
    with {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         :ok <- ensure_identity_absent_or_exact(generation, identity_key, identity) do
      case Map.get(generation.identities, identity_key) do
        nil ->
          state = make_identity_capacity(state)
          generation = Map.fetch!(state.generations, generation_key)

          if state.identity_count >= state.max_identities do
            {:reply, {:error, :task_guardian_identity_history_full}, state}
          else
            record = %{
              identity: identity,
              phase: :reserved,
              task_pid: nil,
              task_ref: nil,
              down: nil
            }

            generation = put_in(generation.identities[identity_key], record)
            state = put_generation(state, generation_key, generation)
            {:reply, :ok, %{state | identity_count: state.identity_count + 1}}
          end

        _record ->
          {:reply, :ok, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp handle_access_call({:release, identity}, _from, generation_key, generation, state) do
    with {:ok, identity, identity_key} <- normalize_identity(generation.kind, identity),
         :ok <- identity_belongs_to_generation(identity, generation),
         {:ok, %{phase: :reserved} = record} <- exact_record(generation, identity_key, identity) do
      _ = record
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

  defp authorized_generation(state, access) when is_map(access) do
    with kind when kind in [:effect, :coordination] <- Map.get(access, :kind),
         supervisor_id when is_binary(supervisor_id) <- Map.get(access, :supervisor_id),
         token when is_reference(token) <- Map.get(access, :token),
         generation_key = {kind, supervisor_id},
         %{} = generation <- Map.get(state.generations, generation_key),
         true <- generation.token == token,
         true <- generation.supervisor_pid == Map.get(access, :supervisor_pid) do
      {:ok, generation_key, generation}
    else
      _ -> {:error, :task_guardian_access_lost}
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
          remember_terminal_identity(acc, {generation_key, identity_key})
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
    normalize_fields(identity, @effect_fields, :effect)
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
    Enum.all?(@effect_fields, fn field -> valid_uuid?(Map.get(identity, field)) end)
  end

  defp valid_uuid_fields?(:coordination, identity) do
    identity.work_kind in ~w(background_job effect) and
      Enum.all?(@coordination_fields -- [:work_kind], fn field ->
        valid_uuid?(Map.get(identity, field))
      end)
  end

  defp valid_uuid?(value), do: match?({:ok, _uuid}, Ecto.UUID.cast(value))

  defp identity_key(:effect, identity) do
    {:effect, identity.effect_id, identity.claim_token, identity.supervisor_id, identity.task_id}
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

  defp make_identity_capacity(state) do
    if state.identity_count < state.max_identities do
      state
    else
      evict_oldest_terminal_identity(state)
    end
  end

  defp evict_oldest_terminal_identity(%{terminal_identity_order: []} = state), do: state

  defp evict_oldest_terminal_identity(state) do
    location = List.last(state.terminal_identity_order)
    order = List.delete(state.terminal_identity_order, location)
    {generation_key, identity_key} = location

    case Map.get(state.generations, generation_key) do
      nil ->
        evict_oldest_terminal_identity(%{state | terminal_identity_order: order})

      generation ->
        case Map.get(generation.identities, identity_key) do
          %{phase: :active, down: %{} = _down} ->
            drop_identity(state, generation_key, generation, identity_key, order)

          %{phase: :cancelled} ->
            drop_identity(state, generation_key, generation, identity_key, order)

          %{phase: :reserved} when generation.proven ->
            drop_identity(state, generation_key, generation, identity_key, order)

          nil ->
            evict_oldest_terminal_identity(%{state | terminal_identity_order: order})

          _not_terminal ->
            evict_oldest_terminal_identity(%{state | terminal_identity_order: order})
        end
    end
  end

  defp drop_identity(state, generation_key, generation, identity_key, order) do
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
      generation_key = List.last(state.completed_order)
      generation = Map.fetch!(state.generations, generation_key)
      identity_locations = Enum.map(Map.keys(generation.identities), &{generation_key, &1})

      state = %{
        state
        | generations: Map.delete(state.generations, generation_key),
          completed_order: List.delete(state.completed_order, generation_key),
          terminal_identity_order:
            Enum.reject(state.terminal_identity_order, &(&1 in identity_locations)),
          identity_count: state.identity_count - map_size(generation.identities)
      }

      trim_completed_generations(state)
    end
  end
end
