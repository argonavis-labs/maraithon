defmodule Maraithon.Runtime.EffectRunner do
  @moduledoc """
  Polls and executes effects from the outbox.
  """

  use GenServer

  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Effects
  alias Maraithon.LLM
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.Config, as: RuntimeConfig
  alias Maraithon.Runtime.DbResilience
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.Effects.CommandFactory
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  require Logger

  @default_poll_interval_ms 1_000
  # Must exceed the longest-running effect (LLM calls may take up to 20 minutes
  # plus busy retries). Crashed tasks and stale claims are terminalized as
  # ambiguous rather than released for unsafe re-execution.
  @default_claim_timeout_ms 1_500_000
  @default_batch_size 10
  @default_rate_limit_retry_ms 60_000
  @max_rate_limit_retry_ms 300_000
  @completion_write_attempts 5
  @completion_write_backoff_ms 100
  @completion_write_backoff_cap_ms 1_000
  @max_stale_finalizations 200
  @ambiguous_outcome :effect_outcome_ambiguous
  @task_termination_timeout_ms 2_000
  @task_termination_rpc_timeout_ms 2_500
  @continuation_check_timeout_ms 1_000
  @max_runtime_nodes 32
  @llm_lanes [:chat, :reasoning, :default]
  @execution_lane_key "__maraithon_execution_lane"
  @legacy_llm_scan_limit 200
  @shutdown_timeout_ms 15_000

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: @shutdown_timeout_ms,
      type: :worker
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Fences every active effect for an agent in the database, then terminates only
  supervised command tasks whose exact claim generations were fenced. Claimed
  work without termination proof becomes terminally ambiguous.
  """
  def cancel_active_for_agent(agent_id, reason)
      when is_binary(agent_id) and byte_size(agent_id) in 1..255 and is_binary(reason) and
             byte_size(reason) in 1..255 do
    if valid_effect_cancellation_text?(agent_id) and valid_effect_cancellation_text?(reason) do
      case Effects.begin_cancel_active_for_agent(agent_id, reason) do
        {:ok, %{overflow?: true}} ->
          # Keep exact claim generations in the fenced `cancelling` state so a
          # bounded retry can still discover and terminate them.
          {:error, :effect_task_termination_incomplete}

        {:ok, %{claims: []} = cancellation} ->
          case Effects.finish_cancel_active_for_agent(agent_id, []) do
            {:ok, _summary} -> {:ok, cancellation.count}
            {:error, _reason} -> {:error, :effect_cancellation_finalization_failed}
          end

        {:ok, cancellation} ->
          case terminate_cancelled_agent_tasks(agent_id, cancellation.claims) do
            {:ok, _terminated_claims} ->
              case Effects.finish_cancel_active_for_agent(agent_id, cancellation.claims) do
                {:ok, _summary} -> {:ok, cancellation.count}
                {:error, _reason} -> {:error, :effect_cancellation_finalization_failed}
              end

            {:error, _reason} = error ->
              # Do not erase the claim token after a failed kill. A later stop,
              # recovery, or stale sweep can retry by the same generation.
              error
          end

        {:error, _reason} ->
          {:error, :effect_cancellation_failed}
      end
    else
      {:error, :invalid_effect_cancellation}
    end
  end

  def cancel_active_for_agent(_agent_id, _reason),
    do: {:error, :invalid_effect_cancellation}

  @doc false
  def terminate_cancelled_agent_tasks_local(agent_id, claims)
      when is_binary(agent_id) and byte_size(agent_id) in 1..255 and is_list(claims) and
             length(claims) <= 512 do
    if valid_effect_cancellation_text?(agent_id) and valid_cancellation_claims?(claims) do
      case Process.whereis(__MODULE__) do
        pid when is_pid(pid) ->
          GenServer.call(
            pid,
            {:terminate_cancelled_agent_tasks, agent_id, claims},
            @task_termination_timeout_ms
          )

        _pid ->
          case registered_effect_tasks_for_agent(agent_id) do
            {:ok, []} -> {:ok, []}
            {:ok, _registered_tasks} -> {:error, :effect_runner_unavailable}
            {:error, _reason} -> {:error, :effect_runner_unavailable}
          end
      end
    else
      {:error, :invalid_effect_cancellation}
    end
  catch
    :exit, _reason -> {:error, :effect_runner_unavailable}
  end

  def terminate_cancelled_agent_tasks_local(_agent_id, _claims),
    do: {:error, :invalid_effect_cancellation}

  @doc false
  def persist_completed_once(%Effect{} = effect, result), do: mark_completed(effect, result)

  @impl true
  def init(opts) do
    completion_writer = option_function(opts, :completion_writer, &mark_completed/2, 2)
    completion_sleeper = option_function(opts, :completion_sleeper, &Process.sleep/1, 1)
    task_starter = option_function(opts, :task_starter, &execute_effect_async/3, 3)

    poll_interval_ms =
      RuntimeConfig.positive_integer(:effect_poll_interval_ms, @default_poll_interval_ms)

    claim_timeout_ms =
      RuntimeConfig.positive_integer(:effect_claim_timeout_ms, @default_claim_timeout_ms)

    batch_size = RuntimeConfig.positive_integer(:effect_batch_size, @default_batch_size)

    schedule_poll(poll_interval_ms)

    {:ok,
     %{
       running: %{},
       tasks: %{},
       monitors: %{},
       completion_writer: completion_writer,
       completion_sleeper: completion_sleeper,
       task_starter: task_starter,
       poll_interval_ms: poll_interval_ms,
       claim_timeout_ms: claim_timeout_ms,
       batch_size: batch_size,
       llm_lane_cursor: 0,
       legacy_llm_cursor: nil,
       poll_retry_attempts: 0
     }}
  end

  @impl true
  def terminate(_reason, state) do
    _state = finalize_and_terminate_running(state, dispatch?: false)
    :ok
  end

  @impl true
  def handle_info(:poll, state) do
    if BootGate.open?() do
      handle_open_poll(state)
    else
      schedule_poll(state.poll_interval_ms)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(
        {:effect_done, effect_id, claimed_by, claimed_at, _result},
        state
      ) do
    case Map.get(state.running, effect_id) do
      %Effect{claimed_by: ^claimed_by, claimed_at: ^claimed_at} ->
        {:noreply, drop_effect_task(state, effect_id)}

      _stale_or_unknown ->
        {:noreply, state}
    end
  end

  # Task.Supervisor.async_nolink reply for a task whose :effect_done message
  # already cleaned up — nothing left to do beyond dropping the monitor.
  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
  end

  # A task that exits without durably reporting completion may already have
  # crossed an external side-effect boundary. Terminalize its exact claim as
  # ambiguous; never release an unknown outcome for re-execution.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      effect_id ->
        effect = Map.get(state.running, effect_id)
        state = drop_effect_task(state, effect_id, demonitor?: false)

        if effect do
          if reason != :normal do
            Logger.error("Effect task crashed",
              effect_reference: Maraithon.Redaction.fingerprint(effect_id),
              failure_code: Maraithon.Redaction.error_class(reason)
            )
          end

          case finalize_ambiguous_claim(effect) do
            :ok -> dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
            :claim_lost -> :ok
            {:error, _reason} -> :ok
          end
        end

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    Logger.debug("EffectRunner ignoring unexpected message",
      failure_code: "unexpected_message"
    )

    {:noreply, state}
  end

  defp handle_open_poll(state) do
    case DbResilience.with_database("effect runner poll", fn ->
           finalize_stale_effects(state.claim_timeout_ms)

           {effects, next_llm_lane_cursor, next_legacy_llm_cursor} =
             fetch_pending_effects(
               state.batch_size,
               state.running,
               state.llm_lane_cursor,
               state.legacy_llm_cursor
             )

           terminal_results = Effects.list_terminal_results_for_dispatch()
           {effects, next_llm_lane_cursor, next_legacy_llm_cursor, terminal_results}
         end) do
      {:ok, {effects, next_llm_lane_cursor, next_legacy_llm_cursor, terminal_results}} ->
        Enum.each(terminal_results, &dispatch_terminal_result/1)
        running_before_poll = state.running

        state =
          Enum.reduce(effects, state, fn effect, acc ->
            case claim_effect(effect) do
              {:ok, claimed} ->
                case start_effect_task(
                       acc.task_starter,
                       claimed,
                       acc.completion_writer,
                       acc.completion_sleeper
                     ) do
                  {:ok, task} ->
                    %{
                      acc
                      | running: Map.put(acc.running, effect.id, claimed),
                        tasks: Map.put(acc.tasks, effect.id, task),
                        monitors: Map.put(acc.monitors, task.ref, effect.id)
                    }

                  {:error, _reason} ->
                    Logger.error("Effect task could not be supervised",
                      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
                      failure_code: "effect_supervisor_unavailable"
                    )

                    case finalize_ambiguous_claim(claimed) do
                      :ok ->
                        dispatch_terminal_result(claimed, {:error, @ambiguous_outcome})

                      :claim_lost ->
                        :ok

                      {:error, _reason} ->
                        :ok
                    end

                    acc
                end

              :already_claimed ->
                acc

              {:error, _reason} ->
                acc
            end
          end)

        llm_admitted? =
          Enum.any?(effects, fn effect ->
            effect.effect_type == "llm_call" and
              not Map.has_key?(running_before_poll, effect.id) and
              Map.has_key?(state.running, effect.id)
          end)

        llm_lane_cursor =
          if llm_admitted?, do: next_llm_lane_cursor, else: state.llm_lane_cursor

        schedule_poll(state.poll_interval_ms)

        {:noreply,
         %{
           state
           | poll_retry_attempts: 0,
             llm_lane_cursor: llm_lane_cursor,
             legacy_llm_cursor: next_legacy_llm_cursor
         }}

      {:error, _reason} ->
        retry_in_ms = DbResilience.backoff_ms(state.poll_interval_ms, state.poll_retry_attempts)
        schedule_poll(retry_in_ms)
        {:noreply, %{state | poll_retry_attempts: state.poll_retry_attempts + 1}}
    end
  end

  @impl true
  def handle_call(:clear_running, _from, state) do
    state = finalize_and_terminate_running(state, dispatch?: true)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:terminate_cancelled_agent_tasks, agent_id, claims}, _from, state) do
    case registered_effect_tasks_for_agent(agent_id) do
      {:ok, registered_tasks} ->
        state_tasks = state_effect_tasks_for_agent(state, agent_id)
        task_entries = Enum.uniq_by(state_tasks ++ registered_tasks, &{&1.effect_id, &1.pid})
        claim_ids = Enum.map(claims, & &1.id)

        verification =
          DbResilience.with_database("effect runner verify cancelling tasks", fn ->
            Repo.all(
              from(effect in Effect,
                where: effect.agent_id == ^agent_id,
                where: effect.id in ^claim_ids,
                where: effect.status == "cancelling",
                select: %{
                  id: effect.id,
                  claimed_by: effect.claimed_by,
                  claimed_at: effect.claimed_at
                }
              )
            )
          end)

        case verification do
          {:ok, verified_claims} ->
            {terminated_ids, failure_count} =
              terminate_verified_effect_tasks(task_entries, verified_claims)

            state =
              Enum.reduce(terminated_ids, state, fn effect_id, acc ->
                drop_effect_task(acc, effect_id)
              end)

            reply =
              if failure_count == 0,
                do: {:ok, verified_claims},
                else: {:error, :effect_task_termination_incomplete}

            {:reply, reply, state}

          {:error, _reason} ->
            {:reply, {:error, :effect_cancellation_verification_failed}, state}
        end

      {:error, _reason} ->
        {:reply, {:error, :effect_task_registry_unavailable}, state}
    end
  end

  # Private functions

  defp fetch_pending_effects(limit, running, llm_lane_cursor, legacy_llm_cursor) do
    available_slots = max(limit - map_size(running), 0)
    lane_order = rotate_llm_lanes(llm_lane_cursor)
    next_llm_lane_cursor = rem(llm_lane_cursor + 1, length(@llm_lanes))

    non_llm_candidates =
      if available_slots > 0 do
        pending_effects_query()
        |> where([e], e.effect_type != "llm_call")
        |> limit(^available_slots)
        |> Repo.all()
      else
        []
      end

    llm_fetch_limit =
      cond do
        non_llm_candidates == [] -> available_slots
        available_slots <= 1 -> available_slots
        true -> available_slots - 1
      end

    {lane_slots, llm_capacity} = llm_lane_slots(running)

    {llm_effects, next_legacy_llm_cursor} =
      if llm_fetch_limit > 0 and llm_capacity > 0 do
        {fetched, cursor} = fetch_llm_effects(lane_slots, lane_order, legacy_llm_cursor)
        {Enum.take(fetched, min(llm_fetch_limit, llm_capacity)), cursor}
      else
        {[], legacy_llm_cursor}
      end

    effects =
      if available_slots == 1 and non_llm_candidates != [] and llm_effects != [] do
        (non_llm_candidates ++ llm_effects)
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
        |> Enum.take(1)
      else
        non_llm_effects =
          Enum.take(non_llm_candidates, max(available_slots - length(llm_effects), 0))

        (non_llm_effects ++ llm_effects)
        |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
      end

    {effects, next_llm_lane_cursor, next_legacy_llm_cursor}
  end

  defp pending_effects_query do
    from(e in Effect,
      where: e.status == "pending",
      where: is_nil(e.retry_after) or e.retry_after <= fragment("timezone('UTC', NOW())"),
      order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp fetch_llm_effects(lane_slots, lane_order, legacy_llm_cursor) do
    tagged_by_lane =
      Map.new(lane_order, fn lane ->
        lane_limit = Map.get(lane_slots, lane, 0)

        effects =
          if lane_limit > 0 do
            pending_effects_query()
            |> where([e], e.effect_type == "llm_call")
            |> where(
              [e],
              fragment(
                "? ->> '__maraithon_execution_lane' = ?",
                e.params,
                ^to_string(lane)
              )
            )
            |> limit(^lane_limit)
            |> Repo.all()
          else
            []
          end

        {lane, effects}
      end)

    {legacy_effects, next_legacy_llm_cursor} =
      if Enum.any?(lane_slots, fn {_lane, count} -> count > 0 end) do
        fetch_legacy_llm_window(legacy_llm_cursor)
      else
        {[], legacy_llm_cursor}
      end

    legacy_by_lane = Enum.group_by(legacy_effects, &effect_execution_lane/1)

    effects_by_lane =
      Map.new(lane_order, fn lane ->
        effects =
          (Map.get(tagged_by_lane, lane, []) ++ Map.get(legacy_by_lane, lane, []))
          |> Enum.uniq_by(& &1.id)
          |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
          |> Enum.take(Map.get(lane_slots, lane, 0))

        {lane, effects}
      end)

    {round_robin_lane_effects(effects_by_lane, lane_order), next_legacy_llm_cursor}
  end

  defp fetch_legacy_llm_window(cursor) do
    query = legacy_llm_query_after(cursor)
    effects = Repo.all(query)

    effects =
      if effects == [] and not is_nil(cursor) do
        Repo.all(legacy_llm_query_after(nil))
      else
        effects
      end

    next_cursor =
      case List.last(effects) do
        %Effect{inserted_at: inserted_at, id: id} -> {inserted_at, id}
        nil -> nil
      end

    {effects, next_cursor}
  end

  defp legacy_llm_query_after(cursor) do
    query =
      pending_effects_query()
      |> where([e], e.effect_type == "llm_call")
      |> where(
        [e],
        fragment(
          "(? ->> '__maraithon_execution_lane') IS NULL OR (? ->> '__maraithon_execution_lane') NOT IN ('chat', 'reasoning', 'default')",
          e.params,
          e.params
        )
      )

    query =
      case cursor do
        {%DateTime{} = inserted_at, id} when is_binary(id) ->
          where(
            query,
            [e],
            e.inserted_at > ^inserted_at or (e.inserted_at == ^inserted_at and e.id > ^id)
          )

        _no_cursor ->
          query
      end

    limit(query, ^@legacy_llm_scan_limit)
  end

  defp llm_lane_slots(running) do
    status = LLMRateLimiter.status()

    if Map.get(status, :blocked_for_ms, 0) > 0 do
      {Map.new(@llm_lanes, &{&1, 0}), 0}
    else
      running_counts =
        running
        |> Map.values()
        |> Enum.filter(&match?(%Effect{effect_type: "llm_call"}, &1))
        |> Enum.frequencies_by(&effect_execution_lane/1)

      case Map.get(status, :buckets) do
        buckets when is_map(buckets) and map_size(buckets) > 0 ->
          slots =
            Map.new(@llm_lanes, fn lane ->
              bucket = Map.get(buckets, lane, %{})
              limit = positive_count(Map.get(bucket, :max_concurrency, 0))
              limiter_in_flight = non_negative_count(Map.get(bucket, :in_flight, 0))
              runner_in_flight = Map.get(running_counts, lane, 0)
              {lane, max(limit - max(limiter_in_flight, runner_in_flight), 0)}
            end)

          {slots, slots |> Map.values() |> Enum.sum()}

        _missing_bucket_status ->
          limit = positive_count(Map.get(status, :max_concurrency, 1))
          limiter_in_flight = non_negative_count(Map.get(status, :in_flight, 0))
          runner_in_flight = running_counts |> Map.values() |> Enum.sum()
          available = max(limit - max(limiter_in_flight, runner_in_flight), 0)
          {Map.new(@llm_lanes, &{&1, available}), available}
      end
    end
  end

  defp effect_execution_lane(%Effect{params: params}) when is_map(params) do
    case Map.get(params, @execution_lane_key) do
      "chat" -> :chat
      "reasoning" -> :reasoning
      "default" -> :default
      _legacy_or_invalid -> LLM.execution_bucket(params)
    end
  end

  defp effect_execution_lane(_effect), do: :default

  defp rotate_llm_lanes(cursor) do
    offset = rem(max(cursor, 0), length(@llm_lanes))
    Enum.drop(@llm_lanes, offset) ++ Enum.take(@llm_lanes, offset)
  end

  defp round_robin_lane_effects(effects_by_lane, lane_order) do
    do_round_robin_lane_effects(effects_by_lane, lane_order, [])
  end

  defp do_round_robin_lane_effects(effects_by_lane, lane_order, acc) do
    {round, next_by_lane} =
      Enum.map_reduce(lane_order, effects_by_lane, fn lane, by_lane ->
        case Map.get(by_lane, lane, []) do
          [effect | rest] -> {effect, Map.put(by_lane, lane, rest)}
          [] -> {nil, by_lane}
        end
      end)

    round = Enum.reject(round, &is_nil/1)

    if round == [] do
      Enum.reverse(acc)
    else
      next_acc = Enum.reduce(round, acc, fn effect, current -> [effect | current] end)
      do_round_robin_lane_effects(next_by_lane, lane_order, next_acc)
    end
  end

  defp positive_count(value) when is_integer(value) and value > 0, do: value
  defp positive_count(_value), do: 0

  defp non_negative_count(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_count(_value), do: 0

  defp claim_effect(effect) do
    node_id = node() |> to_string()

    case DbResilience.with_database("effect runner claim effect", fn ->
           query =
             from(e in Effect,
               where: e.id == ^effect.id,
               where: e.status == "pending",
               where:
                 is_nil(e.retry_after) or e.retry_after <= fragment("timezone('UTC', NOW())"),
               update: [
                 set: [
                   status: "claimed",
                   claimed_by: ^node_id,
                   claimed_at: fragment("timezone('UTC', NOW())"),
                   updated_at: fragment("timezone('UTC', NOW())")
                 ]
               ],
               select: e
             )

           Repo.update_all(query, [])
         end) do
      {:ok, {1, [%Effect{} = claimed]}} ->
        {:ok, claimed}

      {:ok, {0, _rows}} ->
        :already_claimed

      {:ok, {_count, _rows}} ->
        {:error, :unexpected_claim_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp register_effect_task!(%Effect{} = effect) do
    key = {effect.id, effect.claimed_by, effect.claimed_at}

    {:ok, _owner} =
      Registry.register(Maraithon.Runtime.EffectTaskRegistry, key, %{
        agent_id: effect.agent_id,
        effect_id: effect.id
      })

    :ok
  end

  defp start_effect_task(starter, effect, completion_writer, completion_sleeper) do
    case starter.(effect, completion_writer, completion_sleeper) do
      %Task{} = task -> {:ok, task}
      {:error, _reason} = error -> error
      _unexpected -> {:error, :invalid_effect_task_start}
    end
  rescue
    _error -> {:error, :effect_supervisor_unavailable}
  catch
    _kind, _reason -> {:error, :effect_supervisor_unavailable}
  end

  defp execute_effect_async(effect, completion_writer, completion_sleeper) do
    parent = self()

    Task.Supervisor.async_nolink(
      Maraithon.Runtime.EffectSupervisor,
      fn ->
        register_effect_task!(effect)
        result = execute_effect(effect, completion_writer, completion_sleeper)

        send(
          parent,
          {:effect_done, effect.id, effect.claimed_by, effect.claimed_at, result}
        )

        :ok
      end,
      shutdown: :brutal_kill
    )
  end

  defp execute_effect(effect, completion_writer, completion_sleeper) do
    Logger.info("Executing effect",
      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
      effect_type: effect.effect_type
    )

    result =
      try do
        execute_with_command(effect)
      rescue
        exception ->
          {:error, {:effect_exception, Maraithon.Redaction.error_class(exception)}}
      catch
        kind, _value ->
          {:error, {:effect_exception, to_string(kind)}}
      end

    case result do
      {:ok, data} ->
        case Maraithon.Effects.prepare_result(data) do
          {:ok, bounded_data} ->
            case persist_completed(
                   effect,
                   bounded_data,
                   completion_writer,
                   completion_sleeper
                 ) do
              :ok ->
                dispatch_terminal_result(effect, {:ok, bounded_data})
                {:ok, bounded_data}

              :claim_lost ->
                {:error, @ambiguous_outcome}

              {:ambiguous, :persisted} ->
                dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
                {:error, @ambiguous_outcome}

              {:ambiguous, :unpersisted} ->
                {:error, @ambiguous_outcome}
            end

          {:error, :invalid_effect_result} ->
            reason = :invalid_effect_result
            attempts = effect.attempts + 1

            Logger.warning("Effect result rejected before persistence",
              effect_reference: Maraithon.Redaction.fingerprint(effect.id),
              effect_type: effect.effect_type,
              failure_code: "invalid_effect_result"
            )

            case mark_failed(effect, reason, attempts) do
              :ok -> dispatch_terminal_result(effect, {:error, reason})
              :claim_lost -> :ok
              {:error, _reason} -> :ok
            end

            {:error, reason}
        end

      {:error, reason} ->
        reason = classify_claimed_error(effect, reason)
        attempts = next_attempt_count(effect, reason)

        if should_retry?(effect, reason, attempts) do
          mark_pending_retry(effect, reason, attempts)
        else
          case mark_failed(effect, reason, attempts) do
            :ok -> dispatch_terminal_result(effect, {:error, reason})
            :claim_lost -> :ok
            {:error, _reason} -> :ok
          end
        end

        {:error, reason}
    end
  end

  defp execute_with_command(effect) do
    with :ok <- authorize_effect_claim(effect),
         {:ok, command_module} <- CommandFactory.fetch(effect.effect_type) do
      command_module.execute(effect)
    else
      {:error, :unknown_effect_type} -> {:error, :unknown_effect_type}
      {:error, :stale_effect_context} -> {:error, :stale_effect_context}
    end
  end

  defp authorize_effect_claim(%Effect{
         id: effect_id,
         agent_id: agent_id,
         owner_user_id: owner_user_id,
         agent_run_id: nil,
         claimed_by: claimed_by,
         claimed_at: claimed_at
       })
       when is_binary(claimed_by) and not is_nil(claimed_at) do
    authorized? =
      Repo.exists?(
        from(stored in Effect,
          join: agent in Agent,
          on: agent.id == stored.agent_id,
          where: stored.id == ^effect_id,
          where: stored.agent_id == ^agent_id,
          where: stored.status == "claimed",
          where: stored.claimed_by == ^claimed_by,
          where: stored.claimed_at == ^claimed_at,
          where: fragment("? ->> '__maraithon_effect_protocol' = '2'", stored.params),
          where: agent.status in ["running", "degraded"],
          where: agent.install_status == "enabled",
          where: fragment("? IS NOT DISTINCT FROM ?", stored.owner_user_id, ^owner_user_id),
          where: fragment("? IS NOT DISTINCT FROM ?", agent.user_id, ^owner_user_id)
        )
      )

    if authorized?, do: :ok, else: {:error, :stale_effect_context}
  end

  defp authorize_effect_claim(%Effect{
         id: effect_id,
         agent_id: agent_id,
         owner_user_id: owner_user_id,
         agent_run_id: run_id,
         agent_run_step_id: step_id,
         claimed_by: claimed_by,
         claimed_at: claimed_at
       })
       when is_binary(run_id) and is_binary(step_id) and is_binary(claimed_by) and
              not is_nil(claimed_at) do
    if current_continuation?(agent_id, run_id, effect_id) do
      authorized? =
        Repo.exists?(
          from(stored in Effect,
            join: run in AgentRun,
            on: run.id == stored.agent_run_id,
            join: step in AgentRunStep,
            on: step.id == stored.agent_run_step_id and step.agent_run_id == run.id,
            join: agent in Agent,
            on: agent.id == stored.agent_id and agent.id == run.agent_id,
            where: stored.id == ^effect_id,
            where: stored.agent_id == ^agent_id,
            where: stored.status == "claimed",
            where: stored.claimed_by == ^claimed_by,
            where: stored.claimed_at == ^claimed_at,
            where: run.id == ^run_id and run.status == "running",
            where: agent.active_run_id == run.id,
            where: step.id == ^step_id and step.agent_id == ^agent_id,
            where: step.status == "requested",
            where: agent.status in ["running", "degraded"],
            where: agent.install_status == "enabled",
            where: fragment("? IS NOT DISTINCT FROM ?", stored.owner_user_id, ^owner_user_id),
            where: fragment("? IS NOT DISTINCT FROM ?", run.user_id, ^owner_user_id),
            where: fragment("? IS NOT DISTINCT FROM ?", agent.user_id, ^owner_user_id)
          )
        )

      if authorized?, do: :ok, else: {:error, :stale_effect_context}
    else
      {:error, :stale_effect_context}
    end
  end

  defp authorize_effect_claim(_effect), do: {:error, :stale_effect_context}

  defp current_continuation?(agent_id, run_id, effect_id) do
    case :global.whereis_name({:maraithon_agent, agent_id}) do
      pid when is_pid(pid) ->
        case :sys.get_state(pid, @continuation_check_timeout_ms) do
          {:waiting_effect, %{current_run_id: ^run_id, pending_effects: pending_effects}}
          when is_map(pending_effects) ->
            Map.has_key?(pending_effects, effect_id)

          _other_state ->
            false
        end

      :undefined ->
        false
    end
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp persist_completed(
         effect,
         result,
         completion_writer,
         completion_sleeper,
         attempt \\ 0
       ) do
    case safe_completion_write(completion_writer, effect, result) do
      :ok ->
        :ok

      :claim_lost ->
        :claim_lost

      {:error, _reason} when attempt + 1 < @completion_write_attempts ->
        delay_ms =
          DbResilience.backoff_ms(
            @completion_write_backoff_ms,
            attempt,
            @completion_write_backoff_cap_ms
          )

        safe_completion_sleep(completion_sleeper, delay_ms)

        persist_completed(
          effect,
          result,
          completion_writer,
          completion_sleeper,
          attempt + 1
        )

      {:error, _reason} ->
        Logger.warning("Effect completion persistence exhausted",
          effect_reference: Maraithon.Redaction.fingerprint(effect.id),
          failure_code: "effect_outcome_ambiguous"
        )

        case finalize_ambiguous_claim(effect) do
          :ok -> {:ambiguous, :persisted}
          :claim_lost -> :claim_lost
          {:error, _reason} -> {:ambiguous, :unpersisted}
        end
    end
  end

  defp safe_completion_write(writer, effect, result) do
    case writer.(effect, result) do
      outcome when outcome in [:ok, :claim_lost] -> outcome
      {:error, _reason} = error -> error
      _outcome -> {:error, :invalid_completion_write_result}
    end
  rescue
    _error -> {:error, :completion_write_failed}
  catch
    _kind, _reason -> {:error, :completion_write_failed}
  end

  defp safe_completion_sleep(sleeper, delay_ms) do
    sleeper.(delay_ms)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp mark_completed(effect, result) do
    case update_claimed_effect(effect, "mark completed",
           status: "completed",
           result: result,
           result_envelope: TerminalEnvelope.success(),
           error: nil,
           last_failure_code: nil,
           last_failure_attempt: nil,
           retry_after: nil,
           completion_claimed_by: effect.claimed_by,
           completion_claimed_at: effect.claimed_at,
           result_dispatched_at: nil,
           result_dispatch_after: nil,
           result_dispatch_attempts: 0,
           result_acknowledged_at: nil,
           claimed_by: nil,
           claimed_at: nil
         ) do
      :claim_lost -> completion_persisted_for_claim(effect)
      outcome -> outcome
    end
  end

  defp completion_persisted_for_claim(%Effect{} = effect) do
    case DbResilience.with_database("effect runner verify completed claim", fn ->
           Repo.exists?(
             from(completed in Effect,
               where: completed.id == ^effect.id,
               where: completed.status == "completed",
               where: completed.completion_claimed_by == ^effect.claimed_by,
               where: completed.completion_claimed_at == ^effect.claimed_at
             )
           )
         end) do
      {:ok, true} -> :ok
      {:ok, false} -> :claim_lost
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_pending_retry(effect, reason, attempts) do
    backoff_ms = calculate_backoff(attempts, reason)
    retry_after = DateTime.add(DateTime.utc_now(), backoff_ms, :millisecond)

    fields =
      [
        status: "pending",
        claimed_by: nil,
        claimed_at: nil,
        attempts: attempts,
        retry_after: retry_after,
        error: Maraithon.Redaction.error_summary(reason)
      ] ++ counted_failure_provenance(effect, reason, attempts)

    update_claimed_effect(effect, "mark retry", fields)
  end

  defp mark_failed(effect, reason, attempts) do
    fields =
      [
        status: "failed",
        error: Maraithon.Redaction.error_summary(reason),
        result_envelope: TerminalEnvelope.error(reason),
        attempts: attempts,
        retry_after: nil,
        result_dispatched_at: nil,
        result_dispatch_after: nil,
        result_dispatch_attempts: 0,
        result_acknowledged_at: nil,
        claimed_by: nil,
        claimed_at: nil
      ] ++ failure_provenance(reason, attempts)

    update_claimed_effect(effect, "mark failed", fields)
  end

  defp counted_failure_provenance(%Effect{attempts: previous}, reason, attempts)
       when is_integer(previous) and is_integer(attempts) and attempts > previous,
       do: failure_provenance(reason, attempts)

  defp counted_failure_provenance(_effect, _reason, _attempts), do: []

  defp failure_provenance(:timeout, attempts) when is_integer(attempts) and attempts >= 0,
    do: [last_failure_code: "timeout", last_failure_attempt: attempts]

  defp failure_provenance(_reason, _attempts),
    do: [last_failure_code: nil, last_failure_attempt: nil]

  defp finalize_ambiguous_claim(effect) do
    update_claimed_effect(effect, "mark ambiguous outcome",
      status: "failed",
      result: nil,
      error: "effect_outcome_ambiguous",
      last_failure_code: nil,
      last_failure_attempt: nil,
      result_envelope: TerminalEnvelope.error(@ambiguous_outcome),
      retry_after: nil,
      result_dispatched_at: nil,
      result_dispatch_after: nil,
      result_dispatch_attempts: 0,
      result_acknowledged_at: nil,
      claimed_by: nil,
      claimed_at: nil
    )
  end

  # A worker may finish after its claim was cancelled or reclaimed. Fence every
  # terminal/retry write by the exact claim generation so stale work cannot
  # overwrite the newer status or notify an unrelated Agent incarnation.
  defp update_claimed_effect(
         %Effect{claimed_by: claimed_by, claimed_at: claimed_at} = effect,
         operation,
         updates
       )
       when is_binary(claimed_by) and not is_nil(claimed_at) do
    updates = Keyword.put(updates, :updated_at, DateTime.utc_now())

    case DbResilience.with_database("effect runner #{operation}", fn ->
           Repo.update_all(claimed_effect_query(effect), set: updates)
         end) do
      {:ok, {1, _rows}} ->
        :ok

      {:ok, {0, _rows}} ->
        Logger.info("Discarded late effect result after claim ownership changed",
          effect_reference: Maraithon.Redaction.fingerprint(effect.id),
          failure_code: "claim_lost"
        )

        :claim_lost

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_claimed_effect(%Effect{} = effect, _operation, _updates) do
    Logger.warning("Discarded effect result without claim ownership",
      effect_reference: Maraithon.Redaction.fingerprint(effect.id),
      failure_code: "claim_lost"
    )

    :claim_lost
  end

  defp claimed_effect_query(%Effect{} = effect) do
    from(e in Effect,
      where: e.id == ^effect.id,
      where: e.status == "claimed",
      where: e.claimed_by == ^effect.claimed_by,
      where: e.claimed_at == ^effect.claimed_at
    )
  end

  defp classify_claimed_error(_effect, {:effect_exception, _class}),
    do: @ambiguous_outcome

  defp classify_claimed_error(%Effect{effect_type: "tool_call"}, reason) do
    if terminal_effect_error?(reason), do: reason, else: @ambiguous_outcome
  end

  defp classify_claimed_error(_effect, reason), do: reason

  defp next_attempt_count(%Effect{} = effect, reason) do
    if no_attempt_deferrable_effect_error?(effect, reason) do
      effect.attempts
    else
      effect.attempts + 1
    end
  end

  # Tool commands can cross an external side-effect boundary before returning an
  # error. Re-running the durable effect without a provider idempotency proof is
  # unsafe, so a claimed tool call is attempted at most once.
  defp should_retry?(%Effect{effect_type: "tool_call"}, _reason, _attempts), do: false

  defp should_retry?(%Effect{} = effect, reason, attempts) do
    not terminal_effect_error?(reason) and
      (no_attempt_deferrable_effect_error?(effect, reason) or attempts < effect.max_attempts)
  end

  defp terminal_effect_error?(@ambiguous_outcome), do: true
  defp terminal_effect_error?({:insufficient_quota, _message}), do: true
  defp terminal_effect_error?(:insufficient_quota), do: true
  defp terminal_effect_error?({:invalid_request, _summary}), do: true
  defp terminal_effect_error?(:invalid_request), do: true
  defp terminal_effect_error?("invalid_request"), do: true
  defp terminal_effect_error?({:provider_refusal, _summary}), do: true
  defp terminal_effect_error?({:content_filtered, _summary}), do: true
  defp terminal_effect_error?({:incomplete_response, _summary}), do: true
  defp terminal_effect_error?({:invalid_response, _summary}), do: true
  defp terminal_effect_error?(:invalid_json_response), do: true
  defp terminal_effect_error?({:invalid_json_response, _summary}), do: true
  defp terminal_effect_error?({:llm_provider_not_configured, _summary}), do: true

  defp terminal_effect_error?(message)
       when message in [
              "OPENAI_API_KEY not configured",
              "OPENROUTER_API_KEY not configured",
              "ANTHROPIC_API_KEY not configured"
            ],
       do: true

  defp terminal_effect_error?({:api_error, status, _summary})
       when is_integer(status) and status not in [408, 425, 429] and
              status not in 500..599,
       do: true

  defp terminal_effect_error?(:invalid_effect_result), do: true
  defp terminal_effect_error?(:unknown_effect_type), do: true
  defp terminal_effect_error?("unknown_effect_type"), do: true
  defp terminal_effect_error?(:stale_effect_context), do: true
  defp terminal_effect_error?(:unknown_tool), do: true
  defp terminal_effect_error?(:tool_not_allowed), do: true
  defp terminal_effect_error?({:tool_policy_denied, _decision}), do: true
  defp terminal_effect_error?({:tool_policy_needs_confirmation, _decision}), do: true
  defp terminal_effect_error?("unknown_tool:" <> _tool_name), do: true
  defp terminal_effect_error?(_reason), do: false

  defp no_attempt_deferrable_effect_error?(
         %Effect{effect_type: "llm_call"},
         {:llm_busy, _retry_after}
       ),
       do: true

  defp no_attempt_deferrable_effect_error?(_effect, _reason), do: false

  defp dispatch_terminal_result(effect, result \\ nil)

  defp dispatch_terminal_result(%Effect{} = effect, _result) do
    case DbResilience.with_database("effect runner reserve terminal result dispatch", fn ->
           case Repo.get(Effect, effect.id) do
             %Effect{agent_id: agent_id, status: status} = stored
             when agent_id == effect.agent_id and status in ["completed", "failed"] ->
               {stored, Effects.reserve_terminal_result_dispatch(stored)}

             _missing_or_nonterminal ->
               nil
           end
         end) do
      {:ok, {%Effect{} = stored, {:ok, true}}} ->
        notify_agent(stored.agent_id, stored.id, Effects.terminal_result(stored))

      {:ok, _not_reserved} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp notify_agent(agent_id, effect_id, result) do
    :ok = Dispatch.dispatch(agent_id, {:effect_result, effect_id, result})
  end

  defp finalize_stale_effects(claim_timeout_ms) do
    stale_before =
      dynamic(
        [effect],
        is_nil(effect.claimed_at) or
          effect.claimed_at <
            fragment("timezone('UTC', NOW()) - (? * INTERVAL '1 millisecond')", ^claim_timeout_ms)
      )

    stale_ids =
      from(effect in Effect,
        where: effect.status == "claimed",
        where: ^stale_before,
        order_by: [asc_nulls_first: effect.claimed_at, asc: effect.id],
        limit: @max_stale_finalizations,
        select: effect.id
      )

    query =
      from(effect in Effect,
        where: effect.id in subquery(stale_ids),
        where: effect.status == "claimed",
        where: ^stale_before
      )

    {count, _rows} =
      Repo.update_all(query,
        set: [
          status: "cancelling",
          updated_at: DateTime.utc_now()
        ]
      )

    if count > 0 do
      Logger.warning("Fenced stale effects pending exact worker termination",
        failed: count,
        failure_code: "stale_effect_termination_pending"
      )
    end
  end

  defp calculate_backoff(attempt, reason) do
    case retry_after_ms(reason) do
      nil -> calculate_exponential_backoff(attempt)
      retry_after_ms -> add_jitter(retry_after_ms)
    end
  end

  defp calculate_exponential_backoff(attempt) do
    base = 1_000
    max = 60_000
    delay = base * :math.pow(2, attempt)
    jitter = :rand.uniform() * delay * 0.3
    round(min(delay + jitter, max))
  end

  defp retry_after_ms({:rate_limited, value}), do: normalize_retry_after_ms(value)
  defp retry_after_ms({:llm_busy, value}), do: normalize_retry_after_ms(value)

  defp retry_after_ms({:llm_fallbacks_failed, original_reason, fallback_errors}) do
    retry_after_values =
      ([retry_after_ms(original_reason)] ++ Enum.map(fallback_errors, &fallback_retry_after_ms/1))
      |> Enum.reject(&is_nil/1)

    case retry_after_values do
      [] -> nil
      values -> Enum.max(values)
    end
  end

  defp retry_after_ms(_reason), do: nil

  defp fallback_retry_after_ms(%{reason: reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(%{"reason" => reason}), do: retry_after_text_ms(reason)
  defp fallback_retry_after_ms(_reason), do: nil

  defp retry_after_text_ms(reason) when is_binary(reason) do
    case Regex.run(~r/rate_limited[:,]\s*(\d{1,9})/, reason) do
      [_, retry_after] -> normalize_retry_after_ms(retry_after)
      _other -> nil
    end
  end

  defp retry_after_text_ms(_reason), do: nil

  defp normalize_retry_after_ms(value) when is_integer(value) and value > 0 do
    min(value, @max_rate_limit_retry_ms)
  end

  defp normalize_retry_after_ms(value) when is_binary(value) and byte_size(value) <= 9 do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> normalize_retry_after_ms(parsed)
      _other -> @default_rate_limit_retry_ms
    end
  end

  defp normalize_retry_after_ms(_value), do: @default_rate_limit_retry_ms

  defp add_jitter(retry_after_ms) do
    jitter = :rand.uniform(max(1, div(retry_after_ms, 5)))
    retry_after_ms + jitter
  end

  defp registered_effect_tasks_for_agent(agent_id) do
    case registered_effect_tasks() do
      {:ok, tasks} -> {:ok, Enum.filter(tasks, &(&1.agent_id == agent_id))}
      {:error, _reason} = error -> error
    end
  end

  defp registered_effect_tasks do
    tasks =
      Registry.select(Maraithon.Runtime.EffectTaskRegistry, [
        {{{:"$1", :"$2", :"$3"}, :"$4", :"$5"}, [], [{{:"$1", :"$2", :"$3", :"$4", :"$5"}}]}
      ])
      |> Enum.flat_map(fn
        {effect_id, claimed_by, claimed_at, pid, %{agent_id: agent_id}}
        when is_binary(effect_id) and is_binary(agent_id) and is_pid(pid) ->
          [
            %{
              effect_id: effect_id,
              agent_id: agent_id,
              claimed_by: claimed_by,
              claimed_at: claimed_at,
              pid: pid
            }
          ]

        _other ->
          []
      end)

    {:ok, tasks}
  rescue
    _error -> {:error, :effect_task_registry_unavailable}
  catch
    :exit, _reason -> {:error, :effect_task_registry_unavailable}
  end

  defp state_effect_tasks_for_agent(state, agent_id) do
    Enum.flat_map(state.running, fn
      {effect_id, %Effect{agent_id: ^agent_id} = effect} ->
        case Map.get(state.tasks, effect_id) do
          %Task{pid: pid} when is_pid(pid) ->
            [
              %{
                effect_id: effect_id,
                claimed_by: effect.claimed_by,
                claimed_at: effect.claimed_at,
                pid: pid
              }
            ]

          _no_task ->
            []
        end

      {_effect_id, _effect} ->
        []
    end)
  end

  defp terminate_verified_effect_tasks(task_entries, verified_claims) do
    verified_keys =
      verified_claims
      |> Enum.map(&{&1.id, &1.claimed_by, &1.claimed_at})
      |> MapSet.new()

    Enum.reduce(task_entries, {MapSet.new(), 0}, fn task, {terminated, failures} ->
      key = {task.effect_id, task.claimed_by, task.claimed_at}

      if MapSet.member?(verified_keys, key) do
        outcome =
          try do
            Task.Supervisor.terminate_child(Maraithon.Runtime.EffectSupervisor, task.pid)
          catch
            :exit, _reason -> {:error, :supervisor_unavailable}
          end

        case outcome do
          :ok -> {MapSet.put(terminated, task.effect_id), failures}
          {:error, :not_found} -> {terminated, failures}
          _failure -> {terminated, failures + 1}
        end
      else
        {terminated, failures}
      end
    end)
    |> then(fn {terminated, failures} -> {MapSet.to_list(terminated), failures} end)
  end

  defp terminate_cancelled_agent_tasks(agent_id, claims) do
    runtime_nodes = [node() | Node.list(:connected)] |> Enum.uniq()

    if length(runtime_nodes) > @max_runtime_nodes do
      {:error, :effect_task_termination_incomplete}
    else
      nodes_by_name = Map.new(runtime_nodes, &{Atom.to_string(&1), &1})

      claims
      |> Enum.group_by(& &1.claimed_by)
      |> Enum.reduce_while({:ok, []}, fn {owner_name, owner_claims}, {:ok, terminated} ->
        case Map.get(nodes_by_name, owner_name) do
          nil ->
            {:halt, {:error, :effect_task_termination_incomplete}}

          owner_node when owner_node == node() ->
            case terminate_cancelled_agent_tasks_local(agent_id, owner_claims) do
              {:ok, owner_terminated} ->
                {:cont, {:ok, owner_terminated ++ terminated}}

              _error ->
                {:halt, {:error, :effect_task_termination_incomplete}}
            end

          owner_node ->
            case :rpc.call(
                   owner_node,
                   __MODULE__,
                   :terminate_cancelled_agent_tasks_local,
                   [agent_id, owner_claims],
                   @task_termination_rpc_timeout_ms
                 ) do
              {:ok, owner_terminated} when is_list(owner_terminated) ->
                {:cont, {:ok, owner_terminated ++ terminated}}

              _error ->
                {:halt, {:error, :effect_task_termination_incomplete}}
            end
        end
      end)
      |> case do
        {:ok, terminated} ->
          {:ok, Enum.uniq_by(terminated, &{&1.id, &1.claimed_by, &1.claimed_at})}

        {:error, _reason} = error ->
          Logger.warning("Effect task termination was incomplete on claim-owner nodes",
            failure_code: "effect_task_termination_incomplete"
          )

          error
      end
    end
  catch
    _kind, _reason ->
      Logger.warning("Effect task termination orchestration failed",
        failure_code: "effect_task_termination_failed"
      )

      {:error, :effect_task_termination_incomplete}
  end

  defp valid_cancellation_claims?(claims) do
    Enum.all?(claims, fn
      %{id: id, claimed_by: claimed_by, claimed_at: %DateTime{}}
      when is_binary(id) and is_binary(claimed_by) ->
        valid_effect_cancellation_text?(id) and valid_effect_cancellation_text?(claimed_by)

      _other ->
        false
    end)
  end

  defp finalize_and_terminate_running(state, opts) do
    dispatch? = Keyword.get(opts, :dispatch?, false)

    {registered_tasks, registry_failed?} =
      case registered_effect_tasks() do
        {:ok, tasks} -> {tasks, false}
        {:error, _reason} -> {[], true}
      end

    {registered_effects, registered_load_failed?} =
      load_registered_claims(registered_tasks)

    effects =
      (Map.values(state.running) ++ registered_effects)
      |> Enum.uniq_by(&{&1.id, &1.claimed_by, &1.claimed_at})

    failure_count =
      effects
      |> Enum.group_by(& &1.agent_id)
      |> Enum.reduce(0, fn {agent_id, agent_effects}, failures ->
        fenced_claims = Enum.flat_map(agent_effects, &fence_claim_for_termination/1)
        state_tasks = state_effect_tasks_for_agent(state, agent_id)
        registered = Enum.filter(registered_tasks, &(&1.agent_id == agent_id))

        task_entries =
          Enum.uniq_by(state_tasks ++ registered, fn task ->
            {task.effect_id, task.pid}
          end)

        {_terminated_ids, kill_failures} =
          terminate_verified_effect_tasks(task_entries, fenced_claims)

        finalization_failed? =
          cond do
            length(fenced_claims) != length(agent_effects) ->
              true

            registry_failed? or registered_load_failed? ->
              true

            kill_failures > 0 ->
              true

            true ->
              case Effects.finish_cancel_active_for_agent(agent_id, fenced_claims) do
                {:ok, _summary} ->
                  if dispatch? do
                    Enum.each(agent_effects, fn effect ->
                      dispatch_terminal_result(effect, {:error, @ambiguous_outcome})
                    end)
                  end

                  false

                {:error, _reason} ->
                  true
              end
          end

        failures + if(finalization_failed?, do: 1, else: 0)
      end)

    orphan_kill_failures = terminate_registered_tasks(registered_tasks)
    failure_count = failure_count + orphan_kill_failures

    if failure_count > 0 do
      Logger.warning("Effect shutdown finalization was incomplete",
        failed: failure_count,
        failure_code: "effect_shutdown_finalization_incomplete"
      )
    end

    state = terminate_effect_tasks(state, Map.keys(state.tasks))
    %{state | running: %{}, tasks: %{}, monitors: %{}}
  end

  defp load_registered_claims([]), do: {[], false}

  defp load_registered_claims(tasks) do
    tasks
    |> Enum.chunk_every(512)
    |> Enum.reduce_while({[], false}, fn task_chunk, {effects, false} ->
      ids = Enum.map(task_chunk, & &1.effect_id)
      expected = MapSet.new(task_chunk, &{&1.effect_id, &1.claimed_by, &1.claimed_at})

      loaded =
        Repo.all(
          from(effect in Effect,
            where: effect.id in ^ids,
            where: effect.status in ["claimed", "cancelling"]
          )
        )
        |> Enum.filter(fn effect ->
          MapSet.member?(expected, {effect.id, effect.claimed_by, effect.claimed_at})
        end)

      {:cont, {loaded ++ effects, false}}
    end)
  rescue
    _error -> {[], true}
  catch
    :exit, _reason -> {[], true}
  end

  defp terminate_registered_tasks(tasks) do
    Enum.count(tasks, fn task ->
      try do
        case Task.Supervisor.terminate_child(Maraithon.Runtime.EffectSupervisor, task.pid) do
          :ok -> false
          {:error, :not_found} -> false
          _failure -> true
        end
      catch
        :exit, _reason -> true
      end
    end)
  end

  defp fence_claim_for_termination(%Effect{} = effect) do
    query =
      from(stored in Effect,
        where: stored.id == ^effect.id,
        where: stored.agent_id == ^effect.agent_id,
        where: stored.status == "claimed",
        where: stored.claimed_by == ^effect.claimed_by,
        where: stored.claimed_at == ^effect.claimed_at,
        select: %{
          id: stored.id,
          claimed_by: stored.claimed_by,
          claimed_at: stored.claimed_at
        }
      )

    case Repo.update_all(query,
           set: [status: "cancelling", updated_at: DateTime.utc_now()]
         ) do
      {1, [claim]} ->
        [claim]

      _already_fenced_or_lost ->
        case Repo.one(
               from(stored in Effect,
                 where: stored.id == ^effect.id,
                 where: stored.agent_id == ^effect.agent_id,
                 where: stored.status == "cancelling",
                 where: stored.claimed_by == ^effect.claimed_by,
                 where: stored.claimed_at == ^effect.claimed_at,
                 select: %{
                   id: stored.id,
                   claimed_by: stored.claimed_by,
                   claimed_at: stored.claimed_at
                 }
               )
             ) do
          nil -> []
          claim -> [claim]
        end
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp terminate_effect_tasks(state, effect_ids) do
    Enum.reduce(effect_ids, state, fn effect_id, acc ->
      task = Map.get(acc.tasks, effect_id)
      acc = drop_effect_task(acc, effect_id)

      if match?(%Task{}, task) do
        try do
          Task.Supervisor.terminate_child(Maraithon.Runtime.EffectSupervisor, task.pid)
        catch
          :exit, _reason -> :ok
        end
      end

      acc
    end)
  end

  defp drop_effect_task(state, effect_id, opts \\ []) do
    task = Map.get(state.tasks, effect_id)

    ref =
      case task do
        %Task{ref: ref} -> ref
        _task -> find_monitor_ref(state.monitors, effect_id)
      end

    if is_reference(ref) and Keyword.get(opts, :demonitor?, true) do
      Process.demonitor(ref, [:flush])
    end

    %{
      state
      | running: Map.delete(state.running, effect_id),
        tasks: Map.delete(state.tasks, effect_id),
        monitors: if(is_reference(ref), do: Map.delete(state.monitors, ref), else: state.monitors)
    }
  end

  defp find_monitor_ref(monitors, effect_id) do
    Enum.find_value(monitors, fn
      {ref, ^effect_id} -> ref
      {_ref, _other_id} -> nil
    end)
  end

  defp valid_effect_cancellation_text?(value) do
    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
  end

  defp option_function(opts, key, default, arity) do
    value = if is_list(opts), do: Keyword.get(opts, key), else: nil
    if is_function(value, arity), do: value, else: default
  end

  defp schedule_poll(interval_ms) do
    Process.send_after(self(), :poll, interval_ms)
  end
end
