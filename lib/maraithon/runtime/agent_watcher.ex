defmodule Maraithon.Runtime.AgentWatcher do
  @moduledoc """
  Monitors exact Agent incarnations and durably records ownership loss.

  An exact local DOWN is actionable only when the registered PID/token pair,
  local lease, lease-bound database capability, original monitor ref, and
  one-shot watcher capability all match. Capability preimages live only in
  watcher-owned private ETS across monitoring and persistence retry.

  Local capability-bearing identities are hard-bounded across preparation,
  adopted monitoring, and durable DOWN retry. Capacity exhaustion rejects new
  preparation without evicting a live monitor or pending proof.
  """

  use GenServer

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Events
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLocalDownWitness
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentSupervisor
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.Config
  alias Maraithon.Runtime.IncidentLog

  require Logger

  @name __MODULE__
  @default_poll_interval_ms 2_000
  @default_crash_loop_max 3
  @default_crash_loop_window_ms 600_000
  @default_reresume_backoffs [5_000, 15_000, 30_000]
  @default_down_retry_backoffs [100, 500, 1_000, 5_000, 15_000, 30_000]
  @default_total_capability_capacity 4_096
  @default_preparation_capacity 256
  @default_preparation_per_controller_capacity 4
  @default_preparation_ttl_ms 60_000
  @max_total_capability_capacity 4_096
  @max_preparation_capacity 4_096
  @max_preparation_per_controller_capacity 64
  @max_preparation_ttl_ms 60_000
  @shutdown_down_barrier_ms 25_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def ensure_available(server \\ @name) do
    GenServer.call(server, :ping)
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  @doc false
  def prepare_lease_capability(server, agent_id, owner_token)
      when is_binary(agent_id) and is_binary(owner_token) do
    server
    |> GenServer.call({:prepare_lease_capability, agent_id, owner_token})
    |> confirm_lease_preparation(agent_id, owner_token)
  rescue
    _error -> {:error, :watcher_unavailable}
  catch
    _kind, _reason -> {:error, :watcher_unavailable}
  end

  def prepare_lease_capability(_server, _agent_id, _owner_token),
    do: {:error, :invalid_agent_owner}

  defp confirm_lease_preparation(
         {:ok, digest, capability_id, capability},
         agent_id,
         owner_token
       )
       when is_binary(digest) and byte_size(digest) == 32 and is_reference(capability_id) do
    expected = {agent_id, owner_token, digest, capability_id}

    with true <- is_function(capability, 1),
         {:module, __MODULE__} <- :erlang.fun_info(capability, :module),
         {:type, :local} <- :erlang.fun_info(capability, :type),
         :ok <- capability.(expected) do
      {:ok, digest}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :watcher_unavailable}
    end
  end

  defp confirm_lease_preparation({:error, _reason} = error, _agent_id, _owner_token),
    do: error

  defp confirm_lease_preparation(_invalid, _agent_id, _owner_token),
    do: {:error, :watcher_unavailable}

  @doc false
  def discard_lease_capability(server, agent_id, owner_token)
      when is_binary(agent_id) and is_binary(owner_token) do
    GenServer.call(server, {:discard_lease_capability, agent_id, owner_token})
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  def discard_lease_capability(_server, _agent_id, _owner_token),
    do: {:error, :invalid_agent_owner}

  @doc """
  Synchronously adopts the watcher-private capability for one exact lease owner.

  The preparing controller owns the first handoff and same-controller
  lost-response replay; a foreign controller cannot replay that track.
  """
  def track(pid, agent_id, owner_token) when is_pid(pid) do
    track(@name, pid, agent_id, owner_token)
  end

  def track(server, pid, agent_id, owner_token)
      when is_pid(pid) and is_binary(agent_id) and is_binary(owner_token) do
    GenServer.call(server, {:track, pid, agent_id, owner_token})
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  def track(_server, _pid, _agent_id, _owner_token), do: {:error, :invalid_agent_owner}

  @doc """
  Persists an ambiguous owner-loss request without claiming physical DOWN.

  This compatibility entry point is intentionally non-proving.  Only the
  monitor message handled by this GenServer can create local DOWN proof.
  """
  def record_owner_down(server, agent_id, owner_token, pid, reason)
      when is_binary(agent_id) and is_binary(owner_token) and is_pid(pid) do
    GenServer.call(server, {:record_owner_down, agent_id, owner_token, pid, reason}, 30_000)
  catch
    :exit, _reason -> {:error, :watcher_unavailable}
  end

  def record_owner_down(_server, _agent_id, _owner_token, _pid, _reason),
    do: {:error, :invalid_agent_owner}

  @doc false
  def consume_local_down_witness(%AgentLocalDownWitness{} = witness) do
    expected =
      {witness.watcher_pid, witness.monitor_ref, witness.pid, witness.agent_id,
       witness.lease_token, witness.monitor_started_at, witness.down_reason,
       witness.capability_id}

    with true <- witness.watcher_pid == self(),
         true <- is_function(witness.capability, 1),
         {:module, __MODULE__} <- :erlang.fun_info(witness.capability, :module),
         {:type, :local} <- :erlang.fun_info(witness.capability, :type),
         {:ok, _seal, phase, termination_capability}
         when phase in [:first, :replay] and is_binary(termination_capability) and
                byte_size(termination_capability) == 32 <- witness.capability.(expected) do
      {:ok, termination_capability}
    else
      _other -> {:error, :local_down_witness_required}
    end
  rescue
    _error -> {:error, :local_down_witness_required}
  catch
    _kind, _reason -> {:error, :local_down_witness_required}
  end

  def consume_local_down_witness(_witness),
    do: {:error, :local_down_witness_required}

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.get(opts, :name, @name),
      monitors: %{},
      owners: %{},
      pids: %{},
      pending_downs: %{},
      prepared_lease_capabilities: :ets.new(:agent_prepared_lease_capabilities, [:set, :private]),
      preparations: %{},
      preparation_controller_refs: %{},
      preparation_counts: %{},
      total_capability_capacity:
        bounded_preparation_option(
          opts,
          :total_capability_capacity,
          @default_total_capability_capacity,
          @max_total_capability_capacity
        ),
      preparation_capacity:
        bounded_preparation_option(
          opts,
          :preparation_capacity,
          @default_preparation_capacity,
          @max_preparation_capacity
        ),
      preparation_per_controller_capacity:
        bounded_preparation_option(
          opts,
          :preparation_per_controller_capacity,
          @default_preparation_per_controller_capacity,
          @max_preparation_per_controller_capacity
        ),
      preparation_ttl_ms:
        bounded_preparation_option(
          opts,
          :preparation_ttl_ms,
          @default_preparation_ttl_ms,
          @max_preparation_ttl_ms
        ),
      local_down_capabilities: :ets.new(:agent_local_down_capabilities, [:set, :private]),
      recoveries: MapSet.new(),
      agent_supervisor: Keyword.get(opts, :agent_supervisor, AgentSupervisor),
      reconcile?: Keyword.get(opts, :reconcile?, true),
      recover?: Keyword.get(opts, :recover?, true),
      poll_interval_ms:
        Keyword.get(opts, :poll_interval_ms) ||
          Config.positive_integer(:agent_watcher_poll_interval_ms, @default_poll_interval_ms),
      crash_loop_max:
        opts
        |> Keyword.get(
          :crash_loop_max,
          Config.positive_integer(:agent_crash_loop_max, @default_crash_loop_max)
        )
        |> max(1)
        |> min(100),
      crash_loop_window_ms:
        opts
        |> Keyword.get(
          :crash_loop_window_ms,
          Config.positive_integer(
            :agent_crash_loop_window_ms,
            @default_crash_loop_window_ms
          )
        )
        |> max(1_000)
        |> min(86_400_000),
      reresume_backoffs:
        opts
        |> Keyword.get(:reresume_backoffs, configured_backoffs())
        |> normalize_backoffs(),
      down_retry_backoffs:
        opts
        |> Keyword.get(:down_retry_backoffs, @default_down_retry_backoffs)
        |> normalize_down_retry_backoffs(),
      down_persist_gate: normalize_down_persist_gate(Keyword.get(opts, :down_persist_gate)),
      shutdown_down_barrier_ms:
        opts
        |> Keyword.get(:shutdown_down_barrier_ms, @shutdown_down_barrier_ms)
        |> max(0)
        |> min(30_000)
    }

    if state.reconcile?, do: send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Runtime.Supervisor stops its Agent children before the application stops
    # this parent-level guardian. Consume their real monitor signals and commit
    # proofs while Repo is still online; a timeout remains ambiguous.
    deadline = System.monotonic_time(:millisecond) + state.shutdown_down_barrier_ms

    state
    |> drain_shutdown_downs(deadline)
    |> drain_shutdown_pending_downs(deadline)

    :ok
  end

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :ok, state}

  def handle_call({:prepare_lease_capability, agent_id, owner_token}, from, state) do
    controller_pid = controller_pid(from)
    key = {agent_id, owner_token}

    with :ok <- validate_exact_owner(agent_id, owner_token),
         :ok <- ensure_owner_not_tracked(state, key) do
      case existing_preparation(state, key, controller_pid) do
        {:ok, preparation} ->
          {:reply, preparation_reply(preparation), state}

        :new ->
          with :ok <- ensure_preparation_capacity(state, controller_pid),
               {:ok, preparation, state} <-
                 create_preparation(state, key, controller_pid) do
            {:reply, preparation_reply(preparation), state}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:issue_lease_capability, _agent_id, _owner_token}, _from, state) do
    {:reply, {:error, :agent_termination_preparation_required}, state}
  end

  def handle_call(
        {:confirm_lease_capability, capability_id,
         {agent_id, owner_token, digest, capability_id} = supplied},
        from,
        state
      ) do
    key = {agent_id, owner_token}
    controller_pid = controller_pid(from)

    with {:ok, preparation} <- authorized_preparation(state, key, controller_pid),
         true <- preparation.capability_id == capability_id,
         true <- preparation.digest == digest,
         true <- preparation.expected == supplied,
         true <- preparation.phase in [:issued, :confirmed],
         :ok <- validate_prepared_secret(state, key, preparation.digest) do
      state = put_in(state.preparations[key].phase, :confirmed)
      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _mismatch -> {:reply, {:error, :agent_termination_capability_mismatch}, state}
    end
  end

  def handle_call({:confirm_lease_capability, _capability_id, _supplied}, _from, state),
    do: {:reply, {:error, :agent_termination_capability_mismatch}, state}

  def handle_call({:discard_lease_capability, agent_id, owner_token}, from, state) do
    key = {agent_id, owner_token}
    controller_pid = controller_pid(from)

    with :ok <- validate_exact_owner(agent_id, owner_token),
         {:ok, _preparation} <- authorized_preparation(state, key, controller_pid) do
      {:reply, :ok, scrub_preparation(state, key)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:track, pid, agent_id, owner_token}, from, state) do
    key = {agent_id, owner_token}
    controller_pid = controller_pid(from)

    with :ok <- validate_exact_owner(agent_id, owner_token) do
      case tracked_handoff(state, pid, key, controller_pid) do
        :same_controller ->
          {:reply, :ok, state}

        :foreign_controller ->
          {:reply, {:error, :agent_termination_controller_mismatch}, state}

        :untracked ->
          with {:ok, preparation} <- authorized_preparation(state, key, controller_pid),
               :ok <- ensure_confirmed_preparation(preparation),
               {:ok, lease_digest} <- validate_exact_registration(pid, agent_id, owner_token),
               {:ok, termination_capability} <-
                 prepared_termination_capability(state, key, lease_digest),
               {:ok, tracked} <-
                 monitor_agent(
                   state,
                   agent_id,
                   owner_token,
                   pid,
                   termination_capability,
                   controller_pid
                 ) do
            {:reply, :ok, scrub_preparation(tracked, key)}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:record_owner_down, agent_id, owner_token, _pid, reason},
        _from,
        state
      ) do
    case validate_exact_owner(agent_id, owner_token) do
      :ok ->
        result = AgentTerminations.request_ambiguous(agent_id, owner_token, reason)
        {:reply, {:ok, result}, state}

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile_agents(state)

    if Application.get_env(:maraithon, :start_background_workers, true) do
      _requested = AgentTerminations.request_expired_batch(100)
      _reconciled = AgentTerminations.reconcile_due(100)
    end

    schedule_reconcile(state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case authenticate_preparation_controller_down(state, ref, pid) do
      {:observed, state} ->
        {:noreply, state}

      {:spoofed, state} ->
        Logger.warning("Rejected forged Agent capability-controller DOWN mailbox tuple")
        {:noreply, state}

      :unknown ->
        {:noreply, handle_down_message(ref, pid, reason, state, true)}
    end
  end

  def handle_info({:expire_lease_capability, key, capability_id, timer_tag}, state) do
    case authenticate_preparation_expiry(state, key, capability_id, timer_tag) do
      {:expired, state} ->
        {:noreply, state}

      {:spoofed, state} ->
        Logger.warning("Rejected forged Agent capability-preparation expiry tuple")
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_local_down, key, retry_tag}, state) do
    case Map.get(state.pending_downs, key) do
      %{retry_tag: ^retry_tag} = pending ->
        state =
          put_in(state.pending_downs[key], %{
            pending
            | retry_timer: nil,
              retry_tag: nil
          })

        {_result, state} = attempt_pending_down(key, state, true)
        {:noreply, state}

      _stale_retry ->
        {:noreply, state}
    end
  end

  def handle_info({:recover_agent, agent_id, guard_generation, crash_count}, state) do
    key = {agent_id, guard_generation}

    if MapSet.member?(state.recoveries, key) do
      watcher = state.name
      supervisor = state.agent_supervisor

      case Task.Supervisor.start_child(
             Maraithon.Runtime.AgentRecoveryTaskSupervisor,
             fn ->
               result = launch_recovery(supervisor, watcher, agent_id, guard_generation)
               send(watcher, {:recovery_result, agent_id, guard_generation, crash_count, result})
             end
           ) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          send(
            watcher,
            {:recovery_result, agent_id, guard_generation, crash_count,
             {:error, {:recovery_task_start_failed, reason}}}
          )
      end

      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(
        {:recovery_result, agent_id, guard_generation, crash_count, result},
        state
      ) do
    key = {agent_id, guard_generation}
    state = %{state | recoveries: MapSet.delete(state.recoveries, key)}

    case result do
      {:ok, _pid} ->
        IncidentLog.record(%{
          kind: :agent_resumed,
          agent_id: agent_id,
          metadata: %{
            "resume_trigger" => "targeted_reresume",
            "guard_generation" => guard_generation,
            "crash_count_in_window" => crash_count
          }
        })

        {:noreply, state}

      {:error, :agent_restart_backoff} ->
        case AgentRestartGuards.get(agent_id) do
          %{generation: ^guard_generation, needs_recovery: true, tripped: false} = guard ->
            {:noreply, schedule_recovery(agent_id, guard, state)}

          _stale ->
            {:noreply, state}
        end

      {:error, reason} when reason in [:runtime_lease_owned, :stale_recovery_generation] ->
        {:noreply, state}

      {:error, reason} ->
        IncidentLog.record(%{
          kind: :agent_stopped_unexpectedly,
          agent_id: agent_id,
          reason: reason,
          metadata: %{
            "recovery_failed" => true,
            "guard_generation" => guard_generation,
            "crash_count_in_window" => crash_count
          }
        })

        {:noreply, state}
    end
  end

  defp launch_recovery(supervisor, watcher, agent_id, guard_generation) do
    case Agents.get_agent(agent_id, include_removed: true) do
      %{status: status, install_status: "enabled"} = agent
      when status in ["running", "degraded"] ->
        AgentSupervisor.start_agent(agent,
          admission: :recovery,
          recovery_generation: guard_generation,
          supervisor: supervisor,
          watcher: watcher
        )

      nil ->
        {:error, :not_found}

      _inactive ->
        {:error, :agent_not_resumable}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp lease_preparation_capability(watcher_pid, capability_id) do
    fn supplied ->
      GenServer.call(
        watcher_pid,
        {:confirm_lease_capability, capability_id, supplied}
      )
    end
  end

  defp controller_pid({pid, _tag}) when is_pid(pid), do: pid

  defp ensure_owner_not_tracked(state, key) do
    if Map.has_key?(state.owners, key),
      do: {:error, :owner_already_tracked},
      else: :ok
  end

  defp ensure_preparation_capacity(state, controller_pid) do
    controller_count = Map.get(state.preparation_counts, controller_pid, 0)

    cond do
      map_size(state.preparations) >= state.preparation_capacity ->
        {:error, :agent_termination_preparation_capacity}

      controller_count >= state.preparation_per_controller_capacity ->
        {:error, :agent_termination_controller_capacity}

      total_capability_count(state) >= state.total_capability_capacity ->
        {:error, :agent_termination_capability_capacity}

      true ->
        :ok
    end
  end

  # The three maps are steady-state phases of one local identity. Handoffs move
  # an identity between them; no live monitor or durable-retry entry is evicted.
  defp total_capability_count(state) do
    map_size(state.preparations) + map_size(state.monitors) + map_size(state.pending_downs)
  end

  defp existing_preparation(state, key, controller_pid) do
    case Map.get(state.preparations, key) do
      nil ->
        :new

      %{controller_pid: ^controller_pid} = preparation ->
        case validate_prepared_secret(state, key, preparation.digest) do
          :ok -> {:ok, preparation}
          {:error, _reason} = error -> error
        end

      _foreign ->
        {:error, :agent_termination_controller_mismatch}
    end
  end

  defp authorized_preparation(state, key, controller_pid) do
    case Map.get(state.preparations, key) do
      nil ->
        {:error, :agent_termination_capability_required}

      %{controller_pid: ^controller_pid} = preparation ->
        {:ok, preparation}

      _foreign ->
        {:error, :agent_termination_controller_mismatch}
    end
  end

  defp create_preparation(state, {agent_id, owner_token} = key, controller_pid) do
    termination_capability = :crypto.strong_rand_bytes(32)
    digest = :crypto.hash(:sha256, termination_capability)
    capability_id = make_ref()
    expected = {agent_id, owner_token, digest, capability_id}
    controller_ref = Process.monitor(controller_pid)
    timer_tag = make_ref()

    timer_ref =
      Process.send_after(
        self(),
        {:expire_lease_capability, key, capability_id, timer_tag},
        state.preparation_ttl_ms
      )

    if :ets.insert_new(
         state.prepared_lease_capabilities,
         {key, termination_capability}
       ) do
      preparation = %{
        phase: :issued,
        digest: digest,
        capability_id: capability_id,
        expected: expected,
        controller_pid: controller_pid,
        controller_ref: controller_ref,
        timer_ref: timer_ref,
        timer_tag: timer_tag
      }

      state = %{
        state
        | preparations: Map.put(state.preparations, key, preparation),
          preparation_controller_refs:
            Map.put(state.preparation_controller_refs, controller_ref, key),
          preparation_counts: Map.update(state.preparation_counts, controller_pid, 1, &(&1 + 1))
      }

      {:ok, preparation, state}
    else
      _ = Process.cancel_timer(timer_ref)
      _ = Process.demonitor(controller_ref, [:flush])
      {:error, :agent_termination_capability_mismatch}
    end
  end

  defp preparation_reply(preparation) do
    {:ok, preparation.digest, preparation.capability_id,
     lease_preparation_capability(self(), preparation.capability_id)}
  end

  defp ensure_confirmed_preparation(%{phase: :confirmed}), do: :ok

  defp ensure_confirmed_preparation(_preparation),
    do: {:error, :agent_termination_capability_mismatch}

  defp validate_prepared_secret(state, key, digest) do
    with {:ok, termination_capability} <- fetch_prepared_secret(state, key),
         true <- secure_digest_match?(termination_capability, digest) do
      :ok
    else
      _invalid -> {:error, :agent_termination_capability_mismatch}
    end
  end

  defp fetch_prepared_secret(state, key) do
    case :ets.lookup(state.prepared_lease_capabilities, key) do
      [{^key, termination_capability}]
      when is_binary(termination_capability) and byte_size(termination_capability) == 32 ->
        {:ok, termination_capability}

      _invalid ->
        {:error, :agent_termination_capability_mismatch}
    end
  end

  defp secure_digest_match?(termination_capability, digest)
       when is_binary(digest) and byte_size(digest) == 32 do
    termination_capability
    |> then(&:crypto.hash(:sha256, &1))
    |> Plug.Crypto.secure_compare(digest)
  end

  defp secure_digest_match?(_termination_capability, _digest), do: false

  defp prepared_termination_capability(state, key, lease_digest) do
    with %{phase: :confirmed, digest: prepared_digest} <- Map.get(state.preparations, key),
         {:ok, termination_capability} <- fetch_prepared_secret(state, key),
         true <- secure_digest_match?(termination_capability, prepared_digest),
         true <- secure_digest_match?(termination_capability, lease_digest) do
      {:ok, termination_capability}
    else
      nil -> {:error, :agent_termination_capability_required}
      _invalid -> {:error, :agent_termination_capability_mismatch}
    end
  end

  defp authenticate_preparation_controller_down(state, ref, pid) do
    with {:ok, key} <- Map.fetch(state.preparation_controller_refs, ref),
         %{controller_ref: ^ref, controller_pid: ^pid} = preparation <-
           Map.get(state.preparations, key) do
      if Process.demonitor(ref, [:info]) do
        new_ref = Process.monitor(pid)
        preparation = %{preparation | controller_ref: new_ref}

        state = %{
          state
          | preparations: Map.put(state.preparations, key, preparation),
            preparation_controller_refs:
              state.preparation_controller_refs
              |> Map.delete(ref)
              |> Map.put(new_ref, key)
        }

        {:spoofed, state}
      else
        {:observed, scrub_preparation(state, key)}
      end
    else
      _unknown_or_mismatched -> :unknown
    end
  end

  defp authenticate_preparation_expiry(state, key, capability_id, timer_tag) do
    case Map.get(state.preparations, key) do
      %{capability_id: ^capability_id, timer_tag: ^timer_tag, timer_ref: timer_ref} = preparation ->
        case Process.cancel_timer(timer_ref) do
          false ->
            {:expired, scrub_preparation(state, key)}

          remaining when is_integer(remaining) ->
            new_timer_tag = make_ref()

            new_timer_ref =
              Process.send_after(
                self(),
                {:expire_lease_capability, key, capability_id, new_timer_tag},
                max(remaining, 1)
              )

            preparation = %{
              preparation
              | timer_ref: new_timer_ref,
                timer_tag: new_timer_tag
            }

            {:spoofed, put_in(state.preparations[key], preparation)}
        end

      _unknown ->
        :unknown
    end
  end

  defp scrub_preparation(state, key) do
    case Map.pop(state.preparations, key) do
      {nil, _preparations} ->
        state

      {preparation, preparations} ->
        _ = Process.cancel_timer(preparation.timer_ref)
        _ = Process.demonitor(preparation.controller_ref, [:flush])
        true = :ets.delete(state.prepared_lease_capabilities, key)

        preparation_counts =
          decrement_preparation_count(
            state.preparation_counts,
            preparation.controller_pid
          )

        %{
          state
          | preparations: preparations,
            preparation_controller_refs:
              Map.delete(
                state.preparation_controller_refs,
                preparation.controller_ref
              ),
            preparation_counts: preparation_counts
        }
    end
  end

  defp decrement_preparation_count(counts, controller_pid) do
    case Map.get(counts, controller_pid, 0) do
      count when count > 1 -> Map.put(counts, controller_pid, count - 1)
      _last_or_missing -> Map.delete(counts, controller_pid)
    end
  end

  defp reconcile_agents(state) do
    # A watcher restart cannot reconstruct the lease capability from its digest.
    # Existing processes therefore remain deliberately unadopted: only the
    # supervisor's synchronous claim/spawn/track handoff can install a proving
    # monitor, and a restart gap must converge through external evidence.
    state
  end

  defp tracked_handoff(state, pid, {agent_id, owner_token}, controller_pid) do
    with {:ok, ref} <- Map.fetch(state.pids, pid),
         %{agent_id: ^agent_id, owner_token: ^owner_token} = monitor <-
           Map.get(state.monitors, ref) do
      if monitor.handoff_controller_pid == controller_pid,
        do: :same_controller,
        else: :foreign_controller
    else
      _not_exactly_tracked -> :untracked
    end
  end

  defp monitor_agent(
         %{pids: pids} = state,
         agent_id,
         owner_token,
         pid,
         _termination_capability,
         handoff_controller_pid
       )
       when is_map_key(pids, pid) do
    ref = Map.fetch!(pids, pid)

    case Map.fetch!(state.monitors, ref) do
      %{
        agent_id: ^agent_id,
        owner_token: ^owner_token,
        handoff_controller_pid: ^handoff_controller_pid
      } ->
        {:ok, state}

      %{agent_id: ^agent_id, owner_token: ^owner_token} ->
        {:error, :agent_termination_controller_mismatch}

      _other ->
        {:error, :pid_owner_conflict}
    end
  end

  defp monitor_agent(
         state,
         agent_id,
         owner_token,
         pid,
         termination_capability,
         handoff_controller_pid
       ) do
    owner = {agent_id, owner_token}

    if Map.has_key?(state.owners, owner) do
      {:error, :owner_already_tracked}
    else
      ref = Process.monitor(pid)
      monitor_started_at = DateTime.utc_now()
      expected = {self(), ref, pid, agent_id, owner_token, monitor_started_at}

      {capability_id, capability} =
        local_down_capability(
          state.local_down_capabilities,
          :monitoring,
          expected,
          termination_capability
        )

      monitor = %{
        agent_id: agent_id,
        owner_token: owner_token,
        pid: pid,
        started_at: monitor_started_at,
        handoff_controller_pid: handoff_controller_pid,
        capability_id: capability_id,
        capability: capability
      }

      {:ok,
       %{
         state
         | monitors: Map.put(state.monitors, ref, monitor),
           owners: Map.put(state.owners, owner, ref),
           pids: Map.put(state.pids, pid, ref)
       }}
    end
  end

  defp local_down_capability(
         table,
         phase,
         expected_or_builder,
         termination_capability
       )
       when phase in [:monitoring, :observed] do
    capability_id = make_ref()

    expected =
      if is_function(expected_or_builder, 1),
        do: expected_or_builder.(capability_id),
        else: expected_or_builder

    seal = make_ref()

    true =
      :ets.insert(
        table,
        {capability_id, phase, expected, seal, termination_capability}
      )

    capability = fn supplied ->
      consume_issued_capability(table, capability_id, supplied)
    end

    {capability_id, capability}
  end

  defp consume_issued_capability(table, capability_id, supplied) do
    case :ets.lookup(table, capability_id) do
      [{^capability_id, :monitoring, ^supplied, seal, termination_capability}] ->
        true = :ets.delete(table, capability_id)
        {:ok, seal, :first, termination_capability}

      [{^capability_id, :observed, ^supplied, seal, termination_capability}] ->
        true =
          :ets.insert(
            table,
            {capability_id, :observed_replay, supplied, seal, termination_capability}
          )

        {:ok, seal, :first, termination_capability}

      [{^capability_id, :observed_replay, ^supplied, seal, termination_capability}] ->
        {:ok, seal, :replay, termination_capability}

      [{^capability_id, _phase, _expected, _seal, _termination_capability}] ->
        {:error, :local_down_witness_mismatch}

      [] ->
        {:error, :local_down_capability_consumed}
    end
  end

  defp handle_down_message(ref, pid, reason, state, schedule_retry?) do
    case take_authenticated_down(state, ref, pid) do
      {:observed, monitor, state} ->
        {_result, state} =
          handle_agent_down(
            monitor.agent_id,
            monitor.owner_token,
            ref,
            pid,
            reason,
            monitor.started_at,
            monitor.capability_id,
            monitor.capability,
            state,
            schedule_retry?
          )

        state

      {:spoofed, state} ->
        Logger.warning("Rejected forged Agent DOWN mailbox tuple")
        state

      {:unknown, state} ->
        state
    end
  end

  defp take_authenticated_down(state, ref, pid) do
    case Map.get(state.monitors, ref) do
      %{pid: ^pid} = monitor ->
        if Process.demonitor(ref, [:info]) do
          {:spoofed, remonitor_after_spoof(state, ref, pid, monitor)}
        else
          {monitor, state} = pop_monitor(state, ref, pid)
          {:observed, monitor, state}
        end

      _mismatch ->
        {:unknown, state}
    end
  end

  defp remonitor_after_spoof(state, ref, pid, monitor) do
    termination_capability =
      private_termination_capability(
        state.local_down_capabilities,
        monitor.capability_id,
        :monitoring
      )

    {_monitor, state} = pop_monitor(state, ref, pid)
    true = :ets.delete(state.local_down_capabilities, monitor.capability_id)

    case termination_capability do
      {:ok, termination_capability} ->
        case monitor_agent(
               state,
               monitor.agent_id,
               monitor.owner_token,
               pid,
               termination_capability,
               monitor.handoff_controller_pid
             ) do
          {:ok, state} -> state
          {:error, _reason} -> state
        end

      :error ->
        state
    end
  end

  defp private_termination_capability(table, capability_id, phase) do
    case :ets.lookup(table, capability_id) do
      [{^capability_id, ^phase, _expected, _seal, termination_capability}]
      when is_binary(termination_capability) and byte_size(termination_capability) == 32 ->
        {:ok, termination_capability}

      _other ->
        :error
    end
  end

  defp pop_monitor(state, ref, pid) do
    case Map.get(state.monitors, ref) do
      %{pid: ^pid, agent_id: agent_id, owner_token: owner_token} = monitor ->
        {monitor,
         %{
           state
           | monitors: Map.delete(state.monitors, ref),
             owners: Map.delete(state.owners, {agent_id, owner_token}),
             pids: Map.delete(state.pids, pid)
         }}

      _mismatch ->
        {nil, state}
    end
  end

  defp handle_agent_down(
         agent_id,
         owner_token,
         monitor_ref,
         pid,
         reason,
         monitor_started_at,
         capability_id,
         capability,
         state,
         schedule_retry?
       ) do
    monitor = %{
      agent_id: agent_id,
      owner_token: owner_token,
      started_at: monitor_started_at,
      capability_id: capability_id,
      capability: capability
    }

    case authorize_local_down(monitor_ref, pid, reason, monitor, state) do
      {:ok, witness} ->
        key = {agent_id, owner_token}

        pending = %{
          witness: witness,
          attempts: 0,
          retry_timer: nil,
          retry_tag: nil
        }

        state = put_in(state.pending_downs[key], pending)
        attempt_pending_down(key, state, schedule_retry?)

      {:error, error} = result ->
        true = :ets.delete(state.local_down_capabilities, capability_id)

        Logger.warning("Exact Agent DOWN witness authorization failed",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(error)
        )

        {result, state}
    end
  end

  defp authorize_local_down(monitor_ref, pid, reason, monitor, state) do
    expected =
      {self(), monitor_ref, pid, monitor.agent_id, monitor.owner_token, monitor.started_at}

    with {:ok, _seal, :first, termination_capability} <- monitor.capability.(expected) do
      {capability_id, capability} =
        local_down_capability(
          state.local_down_capabilities,
          :observed,
          fn capability_id ->
            {self(), monitor_ref, pid, monitor.agent_id, monitor.owner_token, monitor.started_at,
             reason, capability_id}
          end,
          termination_capability
        )

      {:ok,
       %AgentLocalDownWitness{
         watcher_pid: self(),
         monitor_ref: monitor_ref,
         pid: pid,
         agent_id: monitor.agent_id,
         lease_token: monitor.owner_token,
         monitor_started_at: monitor.started_at,
         down_reason: reason,
         capability_id: capability_id,
         capability: capability
       }}
    else
      _other -> {:error, :local_down_witness_required}
    end
  end

  defp attempt_pending_down(key, state, schedule_retry?) do
    case Map.get(state.pending_downs, key) do
      nil ->
        {{:ignored, :stale_owner}, state}

      %{witness: witness} ->
        result = safe_record_down(witness, guard_opts(state), state.down_persist_gate)

        case result do
          {:recorded, guard} ->
            {pending, state} = finish_pending_down(state, key)
            {agent_id, owner_token} = key

            {result,
             record_exact_crash(
               agent_id,
               owner_token,
               pending.witness.pid,
               pending.witness.down_reason,
               guard,
               state
             )}

          {:duplicate, guard} ->
            {_pending, state} = finish_pending_down(state, key)
            {agent_id, owner_token} = key
            {result, recover_and_schedule(agent_id, owner_token, guard, state)}

          {status, _detail} when status in [:reconciled_without_loss, :ignored] ->
            {_pending, state} = finish_pending_down(state, key)
            {result, state}

          {:error, error} ->
            handle_pending_down_error(key, result, error, state, schedule_retry?)
        end
    end
  end

  defp handle_pending_down_error(key, result, error, state, schedule_retry?) do
    {agent_id, _owner_token} = key

    Logger.warning("Exact Agent DOWN reconciliation failed",
      agent_reference: Maraithon.Redaction.fingerprint(agent_id),
      failure_code: Maraithon.Redaction.error_class(error)
    )

    cond do
      not retryable_down_error?(error) ->
        {_pending, state} = finish_pending_down(state, key)
        {result, state}

      schedule_retry? ->
        {result, schedule_pending_down_retry(state, key)}

      true ->
        {result, state}
    end
  end

  defp finish_pending_down(state, key) do
    pending = Map.fetch!(state.pending_downs, key)
    if pending.retry_timer, do: Process.cancel_timer(pending.retry_timer)
    true = :ets.delete(state.local_down_capabilities, pending.witness.capability_id)
    {pending, %{state | pending_downs: Map.delete(state.pending_downs, key)}}
  end

  defp schedule_pending_down_retry(state, key) do
    pending = Map.fetch!(state.pending_downs, key)
    if pending.retry_timer, do: Process.cancel_timer(pending.retry_timer)

    attempts = pending.attempts + 1
    retry_tag = make_ref()

    timer =
      Process.send_after(
        self(),
        {:retry_local_down, key, retry_tag},
        retry_delay(state.down_retry_backoffs, attempts)
      )

    put_in(state.pending_downs[key], %{
      pending
      | attempts: attempts,
        retry_timer: timer,
        retry_tag: retry_tag
    })
  end

  defp guard_opts(state) do
    [
      window_ms: state.crash_loop_window_ms,
      max_crashes: state.crash_loop_max,
      backoffs_ms: state.reresume_backoffs
    ]
  end

  defp retry_delay(backoffs, attempts),
    do: Enum.at(backoffs, min(attempts - 1, length(backoffs) - 1))

  defp retryable_down_error?(error)
       when error in [
              :invalid_agent_termination,
              :local_down_witness_required,
              :stale_agent_owner,
              :termination_proof_mismatch
            ],
       do: false

  defp retryable_down_error?(_error), do: true

  defp record_exact_crash(agent_id, owner_token, pid, reason, guard, state) do
    metadata =
      agent_metadata(agent_id)
      |> Map.merge(%{
        "pid" => inspect(pid),
        "owner_generation" => owner_token,
        "guard_generation" => guard.generation,
        "restart_count_in_window" => guard.crash_count,
        "crash_loop_window_ms" => state.crash_loop_window_ms
      })

    IncidentLog.record(%{
      kind: :agent_crash,
      agent_id: agent_id,
      reason: reason,
      metadata: metadata
    })

    if guard.tripped do
      IncidentLog.record(%{
        kind: :agent_stopped_unexpectedly,
        agent_id: agent_id,
        reason: "crash_loop_threshold",
        metadata: metadata
      })
    end

    # A tripped guard forbids replacement but still must recover or dead-letter
    # the exact failed generation's in-flight directive.
    recover_and_schedule(agent_id, owner_token, guard, state)
  end

  defp recover_and_schedule(agent_id, owner_token, guard, state) do
    case AgentDirectives.recover_generation(agent_id, owner_token) do
      {:ok, _directive_or_nil} ->
        schedule_recovery(agent_id, guard, state)

      {:error, reason} ->
        Logger.warning("Exact Agent directive recovery deferred",
          agent_reference: Maraithon.Redaction.fingerprint(agent_id),
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        state
    end
  end

  defp schedule_recovery(_agent_id, _guard, %{recover?: false} = state), do: state
  defp schedule_recovery(_agent_id, %{tripped: true}, state), do: state

  defp schedule_recovery(agent_id, guard, state) do
    key = {agent_id, guard.generation}

    if MapSet.member?(state.recoveries, key) do
      state
    else
      Process.send_after(
        self(),
        {:recover_agent, agent_id, guard.generation, guard.crash_count},
        recovery_delay_ms(guard.blocked_until)
      )

      %{state | recoveries: MapSet.put(state.recoveries, key)}
    end
  end

  defp safe_record_down(%AgentLocalDownWitness{} = witness, opts, persist_gate) do
    case persist_gate.() do
      :ok ->
        AgentTerminations.record_watcher_down(witness, opts)

      {:error, _reason} = error ->
        with {:ok, _termination_capability} <- consume_local_down_witness(witness), do: error

      _invalid ->
        {:error, :invalid_down_persist_gate}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp recovery_delay_ms(nil), do: 0

  defp recovery_delay_ms(blocked_until) do
    max(0, DateTime.diff(blocked_until, DateTime.utc_now(), :millisecond))
  end

  defp agent_metadata(agent_id) do
    agent = Agents.get_agent(agent_id)

    %{
      "behavior" => agent && agent.behavior,
      "user_id" => agent && agent.user_id,
      "last_sequence_num" => safe_latest_sequence_num(agent_id),
      "last_running_run_id" => last_running_run_id(agent_id)
    }
  end

  defp safe_latest_sequence_num(agent_id) do
    Events.latest_sequence_num(agent_id)
  rescue
    _error -> nil
  end

  defp last_running_run_id(agent_id) do
    AgentRun
    |> where([run], run.agent_id == ^agent_id and run.status == "running")
    |> order_by([run], desc: run.started_at)
    |> select([run], run.id)
    |> limit(1)
    |> Repo.one()
  rescue
    _error -> nil
  end

  defp validate_exact_registration(pid, agent_id, owner_token) do
    with :ok <- validate_exact_owner(agent_id, owner_token),
         :ok <- validate_registry_owner(pid, agent_id, owner_token),
         {:ok, lease_digest} <- validate_local_lease(agent_id, owner_token) do
      {:ok, lease_digest}
    end
  end

  defp validate_registry_owner(pid, agent_id, owner_token) do
    case Registry.lookup(AgentRegistry, agent_id) do
      [{^pid, ^owner_token}] -> :ok
      _other -> {:error, :agent_registry_owner_mismatch}
    end
  catch
    :exit, _reason -> {:error, :agent_registry_unavailable}
  end

  defp validate_local_lease(agent_id, owner_token) do
    local_node = Atom.to_string(node())

    case AgentLeases.get(agent_id) do
      %{
        owner_token: ^owner_token,
        owner_node: ^local_node,
        termination_capability_digest: digest
      }
      when is_binary(digest) and byte_size(digest) == 32 ->
        {:ok, digest}

      %{owner_token: ^owner_token, owner_node: ^local_node} ->
        {:error, :agent_termination_capability_mismatch}

      _other ->
        {:error, :agent_runtime_lease_mismatch}
    end
  rescue
    _error -> {:error, :agent_runtime_lease_unavailable}
  catch
    :exit, _reason -> {:error, :agent_runtime_lease_unavailable}
  end

  defp validate_exact_owner(agent_id, owner_token) do
    with {:ok, _agent_id} <- Ecto.UUID.cast(agent_id),
         {:ok, _owner_token} <- Ecto.UUID.cast(owner_token) do
      :ok
    else
      :error -> {:error, :invalid_agent_owner}
    end
  end

  defp bounded_preparation_option(opts, key, default, maximum) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> min(value, maximum)
      _invalid -> default
    end
  end

  defp normalize_down_persist_gate(gate) when is_function(gate, 0), do: gate
  defp normalize_down_persist_gate(_gate), do: fn -> :ok end

  defp configured_backoffs do
    Config.get(:agent_reresume_backoffs, @default_reresume_backoffs)
  end

  defp normalize_backoffs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 >= 0))
    |> Enum.map(&min(&1, 3_600_000))
    |> case do
      [] -> @default_reresume_backoffs
      valid -> valid
    end
  end

  defp normalize_backoffs(_other), do: @default_reresume_backoffs

  defp normalize_down_retry_backoffs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_integer(&1) and &1 in 1..30_000))
    |> case do
      [] -> @default_down_retry_backoffs
      valid -> valid
    end
  end

  defp normalize_down_retry_backoffs(_other), do: @default_down_retry_backoffs

  defp drain_shutdown_downs(%{monitors: monitors} = state, _deadline)
       when map_size(monitors) == 0,
       do: state

  defp drain_shutdown_downs(state, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:DOWN, ref, :process, pid, reason} ->
        state = handle_down_message(ref, pid, reason, state, false)
        drain_shutdown_downs(state, deadline)
    after
      remaining -> state
    end
  end

  defp drain_shutdown_pending_downs(%{pending_downs: pending} = state, _deadline)
       when map_size(pending) == 0,
       do: state

  defp drain_shutdown_pending_downs(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      state
    else
      state =
        state.pending_downs
        |> Map.keys()
        |> Enum.reduce(state, fn key, acc ->
          {_result, acc} = attempt_pending_down(key, acc, false)
          acc
        end)

      if map_size(state.pending_downs) == 0 do
        state
      else
        receive do
        after
          min(100, remaining) -> drain_shutdown_pending_downs(state, deadline)
        end
      end
    end
  end

  defp schedule_reconcile(delay_ms), do: Process.send_after(self(), :reconcile, delay_ms)
end
