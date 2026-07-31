defmodule Maraithon.Runtime.Agent do
  @moduledoc """
  Agent process using gen_statem.
  Manages the lifecycle of a single long-running agent.
  """

  use GenStateMachine, callback_mode: [:state_functions, :state_enter]

  alias Maraithon.Events
  alias Maraithon.AgentSubscriptions
  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.Agents
  alias Maraithon.Behaviors
  alias Maraithon.Insights.Refresh, as: InsightRefresh
  alias Maraithon.Memory
  alias Maraithon.OpenLoops
  alias Maraithon.OperatorEvents
  alias Maraithon.OperatorEvents.OperatorEvent
  alias Maraithon.Runtime.Dispatch
  alias Maraithon.Runtime.Scheduler
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.UserMemory

  require Logger

  @default_effect_timeout_ms 120_000
  @default_llm_effect_timeout_ms 900_000
  @effect_timeout_buffer_ms 10_000
  @global_register_retry_ms 25
  @global_register_retries 80
  @max_deferred_messages 200

  defstruct [
    :agent_id,
    :user_id,
    :project_id,
    :behavior,
    :agent_package_id,
    :agent_package_version_id,
    :behavior_module,
    :behavior_state,
    :config,
    :budget,
    :sequence_num,
    :pending_effects,
    :handled_jobs,
    :last_heartbeat_at,
    :last_checkpoint_at,
    :started_at,
    :subscriptions,
    :current_trigger,
    :current_event,
    :current_message,
    :current_message_metadata,
    :current_message_id,
    :current_run_id,
    :deferred_messages
  ]

  # ==========================================================================
  # Client API
  # ==========================================================================

  def start_link(agent) do
    GenStateMachine.start_link(__MODULE__, agent,
      name: {:via, Registry, {Maraithon.Runtime.AgentRegistry, agent.id}}
    )
  end

  def child_spec(agent) do
    %{
      id: agent.id,
      start: {__MODULE__, :start_link, [agent]},
      # :transient — the supervisor restarts an agent that crashes (abnormal
      # exit) but not one that stops intentionally (:normal / :shutdown).
      restart: :transient,
      type: :worker
    }
  end

  # ==========================================================================
  # Callbacks
  # ==========================================================================

  @impl true
  def init(agent) do
    case register_global_name(agent.id) do
      :ok ->
        Logger.metadata(agent_id: agent.id)
        Logger.info("Agent initializing", behavior: agent.behavior)

        data = %__MODULE__{
          agent_id: agent.id,
          config: agent.config,
          sequence_num: 0,
          pending_effects: %{},
          handled_jobs: MapSet.new(),
          started_at: DateTime.utc_now(),
          deferred_messages: []
        }

        # Start in recovering state to load any existing state
        {:ok, :recovering, data, [{:next_event, :internal, {:init, agent}}]}

      {:error, _reason} ->
        # Another process already owns this agent globally. Return :ignore so a
        # :transient supervisor treats this as "not started" rather than a crash
        # to restart — otherwise a re-register race would loop.
        :ignore
    end
  end

  # ==========================================================================
  # RECOVERING state
  # ==========================================================================

  def recovering(:enter, _old_state, data) do
    Logger.info("Entering recovering state")
    {:keep_state, data}
  end

  def recovering(:internal, {:init, agent}, data) do
    agent_config = enrich_config_with_package_manifest(agent)

    # Load behavior module
    behavior_module = Behaviors.get!(agent.behavior)

    # Restore behavior state and budget from the latest checkpoint snapshot so a
    # restarted agent resumes with context instead of a blank behavior state.
    # The snapshot is the recovery boundary — events between the last checkpoint
    # and a crash are not replayed (replaying behavior handlers would re-run
    # their side effects).
    #
    # SPEC 08 R3: restore MERGES the snapshot onto fresh init/1 defaults (with
    # optional versioned migration and config reconciliation hooks) instead of
    # installing it wholesale — a snapshot predating a newly-read state key
    # must never be able to crash every subsequent wakeup (prod 2026-07-03,
    # :pending_watermarks), and config-derived state must not stay frozen at
    # snapshot time (the LocalPatternReview never-enabled bug).
    {behavior_state, budget} =
      case safe_load_snapshot(agent.id) do
        %{sequence_num: seq} = snapshot ->
          Logger.info("Agent restoring behavior state from snapshot", sequence_num: seq)
          restore_from_snapshot(behavior_module, agent_config, snapshot, agent.id)

        nil ->
          {behavior_module.init(agent_config), init_budget(agent_config["budget"])}
      end

    # Subscribe to internal runtime dispatch topic (cluster-safe routing)
    :ok = Dispatch.subscribe(agent.id)

    # Subscribe to PubSub topics from config
    subscriptions =
      (agent.config["subscribe"] || [])
      |> Kernel.++(AgentSubscriptions.list_topics_for_agent(agent.id))
      |> Enum.uniq()

    Enum.each(subscriptions, fn topic ->
      Phoenix.PubSub.subscribe(Maraithon.PubSub, topic)
      Logger.info("Subscribed to topic", topic: topic)
    end)

    data = %{
      data
      | behavior_module: behavior_module,
        user_id: agent.user_id,
        project_id: agent.project_id,
        behavior: agent.behavior,
        agent_package_id: agent.agent_package_id,
        agent_package_version_id: agent.agent_package_version_id,
        behavior_state: behavior_state,
        config: agent_config,
        budget: budget,
        sequence_num: Events.latest_sequence_num(agent.id),
        subscriptions: subscriptions,
        current_trigger: nil,
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil,
        current_run_id: nil
    }

    # Emit started event (capture updated data with new sequence_num)
    data =
      emit_event(data, "agent_started", %{
        behavior: agent.behavior,
        config: redact_runtime_config(agent_config)
      })

    # Schedule initial heartbeat and checkpoint
    schedule_heartbeat(data)
    schedule_checkpoint(data)

    # Schedule first wakeup based on behavior
    schedule_next_wakeup(data)

    # Messages that arrived during recovery are drained in idle(:enter).
    Logger.info("Agent recovered, transitioning to idle")
    {:next_state, :idle, data}
  end

  def recovering(:info, {:agent_dispatch, msg}, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def recovering(:info, msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  # ==========================================================================
  # IDLE state
  # ==========================================================================

  def idle(:enter, _old_state, data) do
    Logger.debug("Entering idle state")
    {:keep_state, drain_deferred_messages(data)}
  end

  def idle(:info, {:agent_dispatch, msg}, data) do
    idle(:info, msg, data)
  end

  def idle(:info, {:wakeup, job_type, job_id, payload}, data) do
    acknowledge_wakeup(job_id)

    if MapSet.member?(data.handled_jobs, job_id) do
      # Duplicate, ignore
      {:keep_state, data}
    else
      data = %{data | handled_jobs: add_bounded(data.handled_jobs, job_id, 100)}

      case job_type do
        "heartbeat" ->
          data = emit_heartbeat(data)
          schedule_heartbeat(data)
          {:keep_state, data}

        "checkpoint" ->
          data = emit_checkpoint(data)
          schedule_checkpoint(data)
          {:keep_state, data}

        "wakeup" ->
          data = emit_event(data, "wakeup_received", %{job_id: job_id})
          data = maybe_refill_budget(data)

          if has_budget?(data) do
            data = put_wakeup_trigger(data, job_type, job_id, payload)
            {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
          else
            Logger.warning("No budget, staying idle")
            {:keep_state, data}
          end
      end
    end
  end

  def idle(:info, {:control, :stop, reason}, data) do
    stop_agent(reason, data)
  end

  def idle(:info, {:message, message, metadata, message_id}, data) do
    metadata = normalize_message_metadata(metadata)
    data = maybe_reset_open_insights_for_refresh(data, message, metadata)

    data =
      emit_event(data, "message_received", %{
        message: message,
        metadata: metadata,
        message_id: message_id
      })

    data = maybe_refill_budget(data)

    if has_budget?(data) do
      data = put_message_trigger(data, message, metadata, message_id)
      {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
    else
      Logger.warning("No budget, cannot process message")
      {:keep_state, data}
    end
  end

  # Handle PubSub events
  def idle(:info, {:pubsub_event, topic, payload}, data) do
    if topic in (data.subscriptions || []) do
      Logger.info("Received PubSub event", topic: topic)

      data =
        emit_event(data, "pubsub_event_received", %{
          topic: topic,
          payload: payload
        })

      data = maybe_refill_budget(data)

      if has_budget?(data) do
        data = put_pubsub_trigger(data, topic, payload)
        {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
      else
        Logger.warning("No budget, cannot process PubSub event")
        {:keep_state, data}
      end
    else
      {:keep_state, data}
    end
  end

  def idle(:info, msg, data) do
    Logger.debug("Idle received unknown message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ==========================================================================
  # WORKING state
  # ==========================================================================

  def working(:enter, _old_state, data) do
    Logger.debug("Entering working state")
    {:keep_state, data}
  end

  def working(:info, {:agent_dispatch, msg}, data) do
    working(:info, msg, data)
  end

  def working(:internal, :execute_behavior, data) do
    data = ensure_current_run(data)
    context = build_context(data)

    case data.behavior_module.handle_wakeup(data.behavior_state, context) do
      {:effect, effect, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        request_effect(data, effect)

      {:emit, {event_type, payload}, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        data = emit_event(data, to_string(event_type), payload)
        data = complete_current_run(data, event_type, payload)
        data = clear_transient_context(data)
        schedule_next_wakeup(data)
        {:next_state, :idle, data}

      {:continue, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        {:keep_state, data, [{:next_event, :internal, :execute_behavior}]}

      {:idle, new_behavior_state} ->
        data = %{data | behavior_state: new_behavior_state}
        data = complete_current_run(data, :idle, %{})
        data = clear_transient_context(data)
        schedule_next_wakeup(data)
        {:next_state, :idle, data}
    end
  end

  def working(:info, {:wakeup, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:pubsub_event, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:message, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def working(:info, {:control, :stop, reason}, data) do
    stop_agent(reason, data)
  end

  def working(:info, msg, data) do
    Logger.debug("Working received message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ==========================================================================
  # WAITING_EFFECT state
  # ==========================================================================

  def waiting_effect(:enter, _old_state, data) do
    timeout_ms = pending_effect_timeout_ms(data.pending_effects)

    Logger.debug("Entering waiting_effect state", timeout_ms: timeout_ms)
    {:keep_state, data, [{:state_timeout, timeout_ms, :effect_timeout}]}
  end

  def waiting_effect(:info, {:agent_dispatch, msg}, data) do
    waiting_effect(:info, msg, data)
  end

  def waiting_effect(:info, {:effect_result, effect_id, result}, data) do
    case Map.pop(data.pending_effects, effect_id) do
      {nil, _} ->
        Logger.warning("Received result for unknown effect: #{effect_id}")
        {:keep_state, data}

      {effect_info, pending_effects} ->
        data = %{data | pending_effects: pending_effects}
        data = decrement_budget(data, effect_info.type)
        record_effect_step_result(effect_info, result)

        case result do
          {:ok, result_data} ->
            update_current_run_from_effect(data.current_run_id, effect_info, result_data)

            data =
              emit_event(data, "effect_completed", %{
                effect_id: effect_id,
                effect_type: effect_info.type,
                result: result_data
              })

            # Pass result to behavior
            context = build_context(data)

            case data.behavior_module.handle_effect_result(
                   {effect_info.type, result_data},
                   data.behavior_state,
                   context
                 ) do
              {:emit, {event_type, payload}, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                data = emit_event(data, to_string(event_type), payload)
                data = complete_current_run(data, event_type, payload)
                data = clear_transient_context(data)
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:idle, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                data = complete_current_run(data, :idle, %{})
                data = clear_transient_context(data)
                schedule_next_wakeup(data)
                {:next_state, :idle, data}

              {:effect, effect, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                request_effect(data, effect)

              {:continue, new_behavior_state} ->
                data = %{data | behavior_state: new_behavior_state}
                {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
            end

          {:error, reason} ->
            update_current_run_error(data.current_run_id, effect_info, reason)

            data =
              emit_event(data, "effect_failed", %{
                effect_id: effect_id,
                error: inspect(reason)
              })

            context = build_context(data)

            if function_exported?(data.behavior_module, :handle_effect_error, 4) do
              case data.behavior_module.handle_effect_error(
                     effect_info.type,
                     reason,
                     data.behavior_state,
                     context
                   ) do
                {:emit, {event_type, payload}, new_behavior_state} ->
                  data = %{data | behavior_state: new_behavior_state}
                  data = emit_event(data, to_string(event_type), payload)
                  data = complete_current_run(data, event_type, payload)
                  data = clear_transient_context(data)
                  schedule_next_wakeup(data)
                  {:next_state, :idle, data}

                {:idle, new_behavior_state} ->
                  data = %{data | behavior_state: new_behavior_state}
                  data = complete_current_run(data, :idle, %{})
                  data = clear_transient_context(data)
                  schedule_next_wakeup(data)
                  {:next_state, :idle, data}

                {:effect, effect, new_behavior_state} ->
                  data = %{data | behavior_state: new_behavior_state}
                  request_effect(data, effect)

                {:continue, new_behavior_state} ->
                  data = %{data | behavior_state: new_behavior_state}
                  {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
              end
            else
              data = fail_current_run(data, reason)
              data = clear_transient_context(data)
              schedule_next_wakeup(data)
              {:next_state, :idle, data}
            end
        end
    end
  end

  def waiting_effect(:state_timeout, :effect_timeout, data) do
    Logger.warning("Effect timeout")

    # R4 (SPEC 07): waiting_effect only ever holds the single in-flight
    # effect request_effect/2 just registered, and no effect_id is bound in
    # this clause — clear the whole map so the stale entry stops inflating
    # pending_effect_timeout_ms/1's Enum.max for every later effect and
    # leaking across the agent's lifetime.
    effect_info =
      case Map.values(data.pending_effects) do
        [effect_info | _rest] -> effect_info
        [] -> nil
      end

    data = %{data | pending_effects: %{}}

    # R3 (SPEC 07): route the timeout through the behavior exactly like the
    # {:error, reason} effect_result branch above, so the waiting skill gets
    # its handle_effect_error/4 turn and a mid-cycle timeout can resume the
    # rest of the cycle instead of silently dropping the continuation.
    # Timeouts never decrement budget — unchanged by this spec. If
    # pending_effects was unexpectedly empty, fall back to today's behavior.
    if effect_info != nil and function_exported?(data.behavior_module, :handle_effect_error, 4) do
      update_current_run_error(data.current_run_id, effect_info, "effect_timeout")

      data =
        emit_event(data, "effect_failed", %{
          effect_type: effect_info.type,
          error: "effect_timeout"
        })

      context = build_context(data)

      case data.behavior_module.handle_effect_error(
             effect_info.type,
             "effect_timeout",
             data.behavior_state,
             context
           ) do
        {:emit, {event_type, payload}, new_behavior_state} ->
          data = %{data | behavior_state: new_behavior_state}
          data = emit_event(data, to_string(event_type), payload)
          data = complete_current_run(data, event_type, payload)
          data = clear_transient_context(data)
          schedule_next_wakeup(data)
          {:next_state, :idle, data}

        {:idle, new_behavior_state} ->
          data = %{data | behavior_state: new_behavior_state}
          data = complete_current_run(data, :idle, %{})
          data = clear_transient_context(data)
          schedule_next_wakeup(data)
          {:next_state, :idle, data}

        {:effect, effect, new_behavior_state} ->
          data = %{data | behavior_state: new_behavior_state}
          request_effect(data, effect)

        {:continue, new_behavior_state} ->
          data = %{data | behavior_state: new_behavior_state}
          {:next_state, :working, data, [{:next_event, :internal, :execute_behavior}]}
      end
    else
      data = fail_current_run(data, "effect_timeout")
      data = clear_transient_context(data)
      schedule_next_wakeup(data)
      {:next_state, :idle, data}
    end
  end

  def waiting_effect(:info, {:wakeup, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:pubsub_event, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:message, _, _, _} = msg, data) do
    {:keep_state, defer_message(data, msg)}
  end

  def waiting_effect(:info, {:control, :stop, reason}, data) do
    stop_agent(reason, data)
  end

  def waiting_effect(:info, msg, data) do
    Logger.debug("Waiting effect received message: #{inspect(msg)}")
    {:keep_state, data}
  end

  # ==========================================================================
  # Private Functions
  # ==========================================================================

  defp emit_event(data, event_type, payload) do
    sequence_num = data.sequence_num + 1
    Events.append(data.agent_id, event_type, payload, sequence_num: sequence_num)
    Logger.info("Event: #{event_type}", event_type: event_type)
    %{data | sequence_num: sequence_num}
  end

  defp emit_heartbeat(data) do
    now = DateTime.utc_now()
    data = emit_event(data, "heartbeat_emitted", %{timestamp: DateTime.to_iso8601(now)})
    %{data | last_heartbeat_at: now}
  end

  defp emit_checkpoint(data) do
    now = DateTime.utc_now()
    data = emit_event(data, "checkpoint_created", %{timestamp: DateTime.to_iso8601(now)})
    _ = persist_snapshot(data)
    %{data | last_checkpoint_at: now}
  end

  # Best-effort: a snapshot write must never crash the agent loop. Checkpoints
  # are only handled in the :idle state, so that is the captured state name.
  defp persist_snapshot(data) do
    case Snapshot.persist(
           data.agent_id,
           data.sequence_num,
           :idle,
           data.behavior_state,
           data.budget,
           behavior_schema_version(data.behavior_module)
         ) do
      {:ok, _snapshot} ->
        :ok

      {:error, reason} ->
        Logger.warning("Agent checkpoint snapshot failed",
          agent_id: data.agent_id,
          reason: inspect(reason)
        )

        :ok
    end
  rescue
    error ->
      Logger.warning("Agent checkpoint snapshot crashed",
        agent_id: data.agent_id,
        reason: Exception.message(error)
      )

      :ok
  end

  # A corrupt or schema-incompatible snapshot must not wedge agent startup —
  # fall back to a fresh behavior state if loading or decoding fails.
  defp safe_load_snapshot(agent_id) do
    Snapshot.latest(agent_id)
  rescue
    error ->
      Logger.warning("Agent snapshot load failed, starting fresh",
        agent_id: agent_id,
        reason: Exception.message(error)
      )

      nil
  end

  # SPEC 08 R3 — layered snapshot restore. Returns `{behavior_state, budget}`.
  #
  # Three independent rescue boundaries, deliberately NOT collapsed into one:
  # a bug in a behavior's own migrate_state/3 (step 4) or
  # reconcile_restored_state/2 (step 6) degrades to "skip that step, keep
  # restoring" rather than "abandon the entire snapshot and start with zero
  # accumulated context". The outer boundary here mirrors
  # safe_load_snapshot/1's philosophy: anything else unexpected falls all the
  # way back to a fresh init, exactly like the no-snapshot branch.
  #
  # Public (@doc false) so restore semantics are directly testable; production
  # calls it only from recovering/2.
  @doc false
  def restore_from_snapshot(behavior_module, agent_config, snapshot, agent_id) do
    {restore_behavior_state(behavior_module, agent_config, snapshot),
     restore_budget(agent_config, snapshot)}
  rescue
    error ->
      Logger.error("Agent snapshot restore failed, starting with fresh behavior state",
        agent_id: agent_id,
        behavior: inspect(behavior_module),
        reason: Exception.message(error)
      )

      {behavior_module.init(agent_config), init_budget(agent_config["budget"])}
  end

  defp restore_behavior_state(behavior_module, agent_config, snapshot) do
    # Step 1: fresh defaults. Used ONLY as the fallback source for keys absent
    # from the snapshot — every key present in the snapshot overwrites its
    # default in the merge below, so any id/timestamp init/1 happens to mint
    # for a snapshotted key is discarded, never persisted, never observed.
    defaults = behavior_module.init(agent_config)

    current_version = behavior_schema_version(behavior_module)
    # Defensive nil-guard even though the DB default guarantees 0 for legacy
    # rows — a hand-edited row or a map built elsewhere must still restore.
    stored_version = Map.get(snapshot, :schema_version) || 0

    snapshot.behavior_state
    |> maybe_migrate_state(behavior_module, stored_version, current_version, agent_config)
    |> merge_onto_defaults(defaults)
    |> maybe_reconcile_restored_state(behavior_module, agent_config)
  end

  # Step 4: optional versioned migration, own rescue boundary — a broken
  # migration skips migration, not the restore.
  defp maybe_migrate_state(state, behavior_module, stored_version, current_version, agent_config)
       when stored_version < current_version do
    if function_exported?(behavior_module, :migrate_state, 3) do
      try do
        behavior_module.migrate_state(stored_version, state, agent_config)
      rescue
        error ->
          Logger.warning("Behavior migrate_state failed, restoring unmigrated snapshot state",
            behavior: inspect(behavior_module),
            stored_version: stored_version,
            current_version: current_version,
            reason: Exception.message(error)
          )

          state
      end
    else
      state
    end
  end

  defp maybe_migrate_state(state, _behavior_module, _stored, _current, _agent_config), do: state

  # Step 5: shallow, top-level merge — snapshot/migrated value wins for every
  # key present in it; a key absent from it (new in this release) falls back
  # to the fresh init/1 default. Deliberately NOT a deep merge: nested maps
  # are replaced wholesale by the behaviors that own them, and a recursive
  # merge would resurrect stale sub-keys from init/1 placeholders over real
  # accumulated data. Non-map states (Behavior.state() is any()) restore
  # verbatim — there are no defaults to merge onto.
  defp merge_onto_defaults(restored, defaults)
       when is_map(restored) and not is_struct(restored) and
              is_map(defaults) and not is_struct(defaults) do
    Map.merge(defaults, restored)
  end

  defp merge_onto_defaults(restored, _defaults), do: restored

  # Step 6: optional config reconciliation, own rescue boundary — a broken
  # reconciliation skips reconciliation, not the restore.
  defp maybe_reconcile_restored_state(state, behavior_module, agent_config) do
    if function_exported?(behavior_module, :reconcile_restored_state, 2) do
      try do
        behavior_module.reconcile_restored_state(state, agent_config)
      rescue
        error ->
          Logger.warning("Behavior reconcile_restored_state failed, keeping merged state",
            behavior: inspect(behavior_module),
            reason: Exception.message(error)
          )

          state
      end
    else
      state
    end
  end

  # Step 7: budget merges over fresh defaults the same shallow, snapshot-wins
  # way — generalizing the `refilled_at` defensive-read prior art
  # (maybe_refill_budget/1) so any future budget key is tolerant by
  # construction instead of needing another defensive Map.get at its read
  # site.
  defp restore_budget(agent_config, snapshot) do
    snapshot_budget =
      case snapshot.budget do
        budget when is_map(budget) and not is_struct(budget) -> budget
        _other -> %{}
      end

    Map.merge(init_budget(agent_config["budget"]), snapshot_budget)
  end

  defp behavior_schema_version(behavior_module) do
    if function_exported?(behavior_module, :schema_version, 0) do
      behavior_module.schema_version()
    else
      0
    end
  end

  defp schedule_heartbeat(data) do
    interval = get_config(:heartbeat_interval_ms, 900_000)
    Scheduler.schedule_unique_in(data.agent_id, "heartbeat", interval)
  end

  defp schedule_checkpoint(data) do
    interval = get_config(:checkpoint_interval_ms, 600_000)
    Scheduler.schedule_unique_in(data.agent_id, "checkpoint", interval)
  end

  defp schedule_next_wakeup(data) do
    case data.behavior_module.next_wakeup(data.behavior_state) do
      {:relative, ms} ->
        Scheduler.schedule_in(data.agent_id, "wakeup", ms)

      {:absolute, datetime} ->
        Scheduler.schedule_at(data.agent_id, "wakeup", datetime)

      :none ->
        :ok
    end
  end

  defp request_effect(data, {effect_type, params}) do
    request_effect(data, {effect_type, nil, params})
  end

  defp request_effect(data, {effect_type, tool_name, params}) do
    params = maybe_inject_memory_into_effect(data, effect_type, params)
    effect_id = Ecto.UUID.generate()
    idempotency_key = Ecto.UUID.generate()

    effect_info = %{
      type: effect_type,
      tool_name: tool_name,
      params: params,
      requested_at: DateTime.utc_now(),
      run_id: data.current_run_id,
      run_step_id: record_effect_step(data, effect_type, tool_name, params)
    }

    # Write to effect outbox. A failed write must not park the agent in
    # waiting_effect with a phantom pending effect nothing will ever resolve —
    # surface it through the normal effect-error path instead.
    write_result =
      try do
        Maraithon.Effects.request(data.agent_id, effect_type, tool_name, params, %{
          effect_id: effect_id,
          idempotency_key: idempotency_key
        })
      rescue
        exception -> {:error, {:effect_write_failed, Exception.message(exception)}}
      end

    data =
      emit_event(data, "effect_requested", %{
        effect_id: effect_id,
        effect_type: effect_type,
        idempotency_key: idempotency_key
      })

    data = %{data | pending_effects: Map.put(data.pending_effects, effect_id, effect_info)}

    # Re-arm the effect timeout explicitly: a same-state transition
    # (waiting_effect -> waiting_effect on a chained effect) does not run the
    # :enter callback, so without this the whole chain runs on the first
    # effect's deadline.
    actions = [{:state_timeout, pending_effect_timeout_ms(data.pending_effects), :effect_timeout}]

    case write_result do
      {:ok, _effect_id} ->
        {:next_state, :waiting_effect, data, actions}

      {:error, reason} ->
        Logger.error("Effect outbox write failed for agent #{data.agent_id}: #{inspect(reason)}")

        failure = {:error, {:effect_write_failed, reason}}

        {:next_state, :waiting_effect, data,
         actions ++ [{:next_event, :info, {:effect_result, effect_id, failure}}]}
    end
  end

  defp pending_effect_timeout_ms(pending_effects) when is_map(pending_effects) do
    pending_effects
    |> Map.values()
    |> Enum.map(&effect_timeout_ms/1)
    |> Enum.max(fn -> @default_effect_timeout_ms end)
  end

  defp effect_timeout_ms(%{type: type, params: params})
       when type in [:llm_call, "llm_call"] and is_map(params) do
    case read_timeout_ms(params) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms + @effect_timeout_buffer_ms

      _other ->
        @default_llm_effect_timeout_ms
    end
  end

  defp effect_timeout_ms(%{params: params}) when is_map(params) do
    case read_timeout_ms(params) do
      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms + @effect_timeout_buffer_ms

      _other ->
        @default_effect_timeout_ms
    end
  end

  defp effect_timeout_ms(_effect_info), do: @default_effect_timeout_ms

  defp read_timeout_ms(params) do
    Map.get(params, "timeout_ms") || Map.get(params, :timeout_ms)
  end

  defp ensure_current_run(%{current_run_id: run_id} = data) when is_binary(run_id), do: data

  defp ensure_current_run(data) do
    agent = %Maraithon.Agents.Agent{
      id: data.agent_id,
      user_id: data.user_id,
      project_id: data.project_id,
      behavior: data.behavior,
      agent_package_id: data.agent_package_id,
      agent_package_version_id: data.agent_package_version_id
    }

    manifest = data.config["_harness_manifest"] || %{}
    now = DateTime.utc_now()

    attrs = %{
      trigger_type: trigger_type(data.current_trigger),
      trigger: to_jsonable(data.current_trigger || %{}),
      resolved_model: Manifest.get(manifest, :model),
      intelligence: Manifest.get(manifest, :intelligence),
      active_skills: Manifest.active_skill_ids(manifest),
      tool_allowlist: Manifest.get(manifest, :tool_allowlist, []),
      budget_snapshot: %{
        "llm_calls" => data.budget.llm_calls,
        "tool_calls" => data.budget.tool_calls
      },
      metadata: %{
        "package_manifest" => data.agent_package_version_id != nil,
        "started_by_runtime_at" => DateTime.to_iso8601(now)
      },
      started_at: now
    }

    case Agents.start_agent_run(agent, attrs) do
      {:ok, run} ->
        %{data | current_run_id: run.id}

      {:error, reason} ->
        Logger.error("Failed to record agent run",
          agent_id: data.agent_id,
          reason: inspect(reason)
        )

        data
    end
  end

  defp record_effect_step(%{current_run_id: nil}, _effect_type, _tool_name, _params), do: nil

  defp record_effect_step(data, effect_type, tool_name, params) do
    attrs = %{
      step_type: step_type(effect_type),
      effect_type: to_string(effect_type),
      tool_name: tool_name,
      status: "requested",
      resolved_model: model_from_params(params),
      intelligence: intelligence_from_params(params),
      request_payload: to_jsonable(params),
      generation_mode: generation_mode_for_effect(effect_type)
    }

    case Agents.record_agent_run_step(data.current_run_id, data.agent_id, attrs) do
      {:ok, step} ->
        step.id

      {:error, reason} ->
        Logger.error("Failed to record agent run step",
          agent_id: data.agent_id,
          run_id: data.current_run_id,
          reason: inspect(reason)
        )

        nil
    end
  end

  defp record_effect_step_result(%{run_step_id: nil}, _result), do: :ok

  defp record_effect_step_result(effect_info, {:ok, result_data}) do
    attrs = %{
      status: "completed",
      response_payload: to_jsonable(result_data),
      resolved_model: model_from_response(result_data) || model_from_params(effect_info.params),
      intelligence: intelligence_from_params(effect_info.params),
      finish_reason: finish_reason_from_response(result_data),
      generation_mode: generation_mode_for_effect(effect_info.type)
    }

    update_run_step(effect_info.run_step_id, attrs)
  end

  defp record_effect_step_result(effect_info, {:error, reason}) do
    update_run_step(effect_info.run_step_id, %{
      status: "failed",
      error: inspect(reason),
      response_payload: %{"error" => inspect(reason)}
    })
  end

  defp update_current_run_from_effect(nil, _effect_info, _result_data), do: :ok

  defp update_current_run_from_effect(run_id, %{type: :llm_call} = effect_info, result_data) do
    Agents.update_agent_run(run_id, %{
      resolved_model: model_from_response(result_data) || model_from_params(effect_info.params),
      intelligence: intelligence_from_params(effect_info.params),
      finish_reason: finish_reason_from_response(result_data),
      generation_mode: "llm"
    })

    :ok
  end

  defp update_current_run_from_effect(_run_id, _effect_info, _result_data), do: :ok

  defp update_current_run_error(nil, _effect_info, _reason), do: :ok

  defp update_current_run_error(run_id, %{type: :llm_call} = effect_info, reason) do
    Agents.update_agent_run(run_id, %{
      resolved_model: model_from_params(effect_info.params),
      intelligence: intelligence_from_params(effect_info.params),
      finish_reason: "error",
      generation_mode: "error",
      error: inspect(reason)
    })

    :ok
  end

  defp update_current_run_error(_run_id, _effect_info, _reason), do: :ok

  defp complete_current_run(%{current_run_id: nil} = data, _event_type, _payload), do: data

  defp complete_current_run(data, event_type, payload) do
    status = if to_string(event_type) == "agent_error", do: "failed", else: "completed"

    attrs =
      %{
        status: status,
        metadata: %{"terminal_event" => to_string(event_type)}
      }
      |> maybe_put_error(payload)

    case Agents.complete_agent_run(data.current_run_id, attrs) do
      {:ok, _run} ->
        %{data | current_run_id: nil}

      {:error, reason} ->
        Logger.error("Failed to complete agent run",
          agent_id: data.agent_id,
          run_id: data.current_run_id,
          reason: inspect(reason)
        )

        %{data | current_run_id: nil}
    end
  end

  defp fail_current_run(%{current_run_id: nil} = data, _reason), do: data

  defp fail_current_run(data, reason) do
    _ =
      Agents.fail_agent_run(data.current_run_id, %{
        finish_reason: "error",
        generation_mode: "error",
        error: inspect(reason)
      })

    %{data | current_run_id: nil}
  end

  defp update_run_step(nil, _attrs), do: :ok

  defp update_run_step(step_id, attrs) do
    case Agents.update_agent_run_step(step_id, attrs) do
      {:ok, _step} -> :ok
      {:error, reason} -> Logger.error("Failed to update run step", reason: inspect(reason))
    end
  end

  defp build_context(data) do
    %{
      agent_id: data.agent_id,
      user_id: data.user_id,
      project_id: data.project_id,
      agent_package_id: data.agent_package_id,
      agent_package_version_id: data.agent_package_version_id,
      run_id: data.current_run_id,
      harness_manifest: data.config["_harness_manifest"],
      timestamp: DateTime.utc_now(),
      budget: data.budget,
      recent_events: recent_operator_events(data.user_id),
      user_memory: UserMemory.prompt_context(data.user_id),
      deep_memory:
        Memory.prompt_context(data.user_id,
          query: effect_query(data),
          limit: 8
        ),
      memory_tools:
        ~w(write_memory recall_memory list_memories forget_memory record_memory_feedback update_memory_confidence),
      open_loops:
        OpenLoops.snapshot(data.user_id,
          query: data.current_message,
          limit: 8,
          include_memory?: false
        ),
      open_loop_tools:
        ~w(get_open_loops list_todos upsert_todos resolve_todo list_people get_relationship_context learn_relationship_context recall_memory write_memory record_memory_feedback update_memory_confidence),
      last_message: data.current_message,
      last_message_metadata: data.current_message_metadata || %{},
      last_message_id: data.current_message_id,
      trigger: data.current_trigger,
      event: data.current_event
    }
  end

  defp recent_operator_events(user_id) when is_binary(user_id) do
    user_id
    |> OperatorEvents.list_recent_for_user(20)
    |> Enum.map(&serialize_operator_event_for_prompt/1)
  end

  defp recent_operator_events(_user_id), do: []

  defp serialize_operator_event_for_prompt(%OperatorEvent{} = event) do
    %{
      id: event.id,
      source: event.source,
      event_type: event.event_type,
      scope: event.scope,
      source_item_id: event.source_item_id,
      occurred_at: to_jsonable(event.occurred_at),
      payload: compact_prompt_map(event.payload || %{}),
      metadata: compact_prompt_map(event.metadata || %{})
    }
    |> maybe_put(:project_id, event.project_id)
  end

  defp compact_prompt_map(value) when is_map(value) do
    value
    |> Enum.take(12)
    |> Map.new(fn {key, val} -> {to_string(key), compact_prompt_value(val)} end)
  end

  defp compact_prompt_map(_value), do: %{}

  defp compact_prompt_value(value) when is_binary(value), do: String.slice(value, 0, 500)

  defp compact_prompt_value(value) when is_list(value) do
    value
    |> Enum.take(6)
    |> Enum.map(&compact_prompt_value/1)
  end

  defp compact_prompt_value(value) when is_map(value), do: compact_prompt_map(value)
  defp compact_prompt_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp compact_prompt_value(%Date{} = value), do: Date.to_iso8601(value)
  defp compact_prompt_value(value), do: value

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_inject_memory_into_effect(data, effect_type, params)
       when effect_type in [:llm_call, "llm_call"] and is_map(params) do
    query = effect_query(data)

    params
    |> Memory.inject_llm_params(data.user_id, query: query, limit: 8)
    |> OpenLoops.inject_llm_params(data.user_id,
      query: query,
      limit: 8,
      include_memory?: false
    )
  end

  defp maybe_inject_memory_into_effect(_data, _effect_type, params), do: params

  # SPEC 07 R1: `current_message` is nil for effect/skill-triggered runs
  # (wakeup jobs, pubsub events) that never went through
  # `put_message_trigger/4`. Fall back to the trigger's own intent (job type
  # + reason, or the pubsub topic) so those runs still thread a real query
  # into memory recall instead of silently degrading to "no query".
  defp effect_query(%{current_message: message}) when is_binary(message) do
    case String.trim(message) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp effect_query(%{current_trigger: %{type: :wakeup, job_type: job_type}} = data)
       when is_binary(job_type) do
    reason =
      get_in(data.current_trigger, [:payload, "reason"]) ||
        get_in(data.current_trigger, [:payload, :reason])

    [job_type, reason]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp effect_query(%{current_trigger: %{type: :pubsub_event, topic: topic}})
       when is_binary(topic),
       do: topic

  defp effect_query(_data), do: nil

  defp put_wakeup_trigger(data, job_type, job_id, payload) do
    %{
      data
      | current_trigger: %{
          type: :wakeup,
          job_type: job_type,
          job_id: job_id,
          payload: payload
        },
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil
    }
  end

  defp put_message_trigger(data, message, metadata, message_id) do
    %{
      data
      | current_trigger: %{
          type: :message,
          message_id: message_id,
          metadata: metadata
        },
        current_event: nil,
        current_message: message,
        current_message_metadata: metadata,
        current_message_id: message_id
    }
  end

  defp put_pubsub_trigger(data, topic, payload) do
    %{
      data
      | current_trigger: %{
          type: :pubsub_event,
          topic: topic
        },
        current_event: %{topic: topic, payload: payload},
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil
    }
  end

  defp clear_transient_context(data) do
    %{
      data
      | current_trigger: nil,
        current_event: nil,
        current_message: nil,
        current_message_metadata: %{},
        current_message_id: nil
    }
  end

  defp maybe_reset_open_insights_for_refresh(data, message, metadata) do
    if InsightRefresh.refresh_request?(message, metadata) do
      reset_count =
        InsightRefresh.reset_open_insights_for_agent(
          data.user_id,
          data.agent_id,
          data.behavior_module
        )

      if reset_count > 0 do
        Logger.info("Reset open insights before queued refresh",
          agent_id: data.agent_id,
          reset_count: reset_count
        )
      end
    end

    data
  end

  defp trigger_type(%{type: type}), do: to_string(type)
  defp trigger_type(%{"type" => type}), do: to_string(type)
  defp trigger_type(_trigger), do: nil

  defp step_type(:llm_call), do: "llm_call"
  defp step_type(:tool_call), do: "tool_call"
  defp step_type(effect_type), do: to_string(effect_type)

  defp generation_mode_for_effect(:llm_call), do: "llm"
  defp generation_mode_for_effect(:tool_call), do: "tool"
  defp generation_mode_for_effect(effect_type), do: to_string(effect_type)

  defp model_from_params(params) when is_map(params),
    do: params["model"] || params[:model]

  defp model_from_params(_params), do: nil

  defp intelligence_from_params(params) when is_map(params),
    do:
      params["reasoning_effort"] || params[:reasoning_effort] || params["intelligence"] ||
        params[:intelligence]

  defp intelligence_from_params(_params), do: nil

  defp model_from_response(response) when is_map(response),
    do: response[:model] || response["model"]

  defp model_from_response(_response), do: nil

  defp finish_reason_from_response(response) when is_map(response),
    do: response[:finish_reason] || response["finish_reason"]

  defp finish_reason_from_response(_response), do: nil

  defp maybe_put_error(attrs, payload) when is_map(payload) do
    case payload["error"] || payload[:error] do
      error when is_binary(error) -> Map.put(attrs, :error, error)
      nil -> attrs
      error -> Map.put(attrs, :error, inspect(error))
    end
  end

  defp maybe_put_error(attrs, _payload), do: attrs

  defp to_jsonable(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_jsonable(%Date{} = value), do: Date.to_iso8601(value)
  defp to_jsonable(%Time{} = value), do: Time.to_iso8601(value)
  defp to_jsonable(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp to_jsonable(value) when is_map(value) do
    value
    |> maybe_struct_to_map()
    |> Map.new(fn {key, val} -> {to_string(key), to_jsonable(val)} end)
  end

  defp to_jsonable(value) when is_list(value), do: Enum.map(value, &to_jsonable/1)
  defp to_jsonable(value) when is_atom(value), do: to_string(value)
  defp to_jsonable(value), do: value

  defp normalize_message_metadata(nil), do: %{}
  defp normalize_message_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_message_metadata(_metadata), do: %{}

  defp init_budget(nil), do: %{llm_calls: 500, tool_calls: 1000}

  defp init_budget(budget) do
    %{
      llm_calls: budget["llm_calls"] || 500,
      tool_calls: budget["tool_calls"] || 1000
    }
  end

  # The budget is a runaway-work guardrail, but it is snapshotted and
  # restored across restarts/deploys and was never refilled — so it was
  # a LIFETIME allowance: at the 10-minute always-on cadence an agent
  # burned through it in days and then every wakeup/message/pubsub gate
  # became a silent "No budget, staying idle" no-op forever. Refill to
  # the configured allowance once per UTC day, so it acts as the daily
  # spend cap it was meant to be. `refilled_at` rides inside the budget
  # map (snapshot-compatible: old snapshots lack the key and refill on
  # their first post-deploy trigger; has_budget?/decrement_budget only
  # read llm_calls/tool_calls).
  @budget_refill_interval_hours 24

  defp maybe_refill_budget(data) do
    refilled_at = parse_refilled_at(Map.get(data.budget || %{}, :refilled_at))
    now = DateTime.utc_now()

    stale? =
      is_nil(refilled_at) or
        DateTime.diff(now, refilled_at, :hour) >= @budget_refill_interval_hours

    if stale? do
      fresh = init_budget(data.config["budget"])

      Logger.info("Agent budget refilled",
        agent_id: data.agent_id,
        previous_llm_calls: Map.get(data.budget || %{}, :llm_calls),
        previous_tool_calls: Map.get(data.budget || %{}, :tool_calls)
      )

      %{data | budget: Map.put(fresh, :refilled_at, DateTime.to_iso8601(now))}
    else
      data
    end
  end

  defp parse_refilled_at(%DateTime{} = at), do: at

  defp parse_refilled_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_refilled_at(_other), do: nil

  defp has_budget?(data) do
    data.budget.llm_calls > 0 || data.budget.tool_calls > 0
  end

  defp decrement_budget(data, :llm_call) do
    %{data | budget: %{data.budget | llm_calls: max(0, data.budget.llm_calls - 1)}}
  end

  defp decrement_budget(data, :tool_call) do
    %{data | budget: %{data.budget | tool_calls: max(0, data.budget.tool_calls - 1)}}
  end

  defp decrement_budget(data, _), do: data

  defp add_bounded(set, item, max_size) do
    set = MapSet.put(set, item)

    if MapSet.size(set) > max_size do
      # Evict an arbitrary element, but never the one just added — evicting
      # the new id would immediately re-open the dedupe window for it.
      victim = set |> MapSet.delete(item) |> Enum.at(0)
      MapSet.delete(set, victim)
    else
      set
    end
  end

  defp maybe_struct_to_map(%_{} = value), do: Map.from_struct(value)
  defp maybe_struct_to_map(value), do: value

  defp get_config(key, default) do
    Maraithon.Runtime.Config.get(key, default)
  end

  defp enrich_config_with_package_manifest(agent) do
    config = agent.config || %{}

    case package_version_id(agent, config) do
      nil ->
        config

      version_id ->
        case Agents.get_agent_package_version(version_id) do
          nil ->
            Map.put(config, "_harness_manifest_error", {:package_version_not_found, version_id})

          version ->
            case Manifest.build(version) do
              {:ok, manifest} ->
                config
                |> Map.put("_harness_manifest", manifest)
                |> Map.put("agent_package_version_id", version.id)

              {:error, reason} ->
                Map.put(config, "_harness_manifest_error", reason)
            end
        end
    end
  end

  defp package_version_id(%{agent_package_version_id: id}, _config) when is_binary(id), do: id
  defp package_version_id(_agent, %{"agent_package_version_id" => id}) when is_binary(id), do: id
  defp package_version_id(_agent, _config), do: nil

  defp redact_runtime_config(config) when is_map(config) do
    Map.drop(config, ["_harness_manifest"])
  end

  defp acknowledge_wakeup(job_id) do
    case Scheduler.ack_delivered(job_id) do
      {:ok, _status} ->
        :ok

      {:error, :not_found} ->
        :ok

      {:error, :invalid_state} ->
        :ok

      {:error, reason} ->
        Logger.warning("Scheduled wakeup acknowledgement deferred",
          job_id: job_id,
          error: inspect(reason)
        )

        :ok
    end
  end

  # Buffer a message that arrived while the agent was busy (recovering, working,
  # or waiting on an effect) and replay it once the agent is idle again. Without
  # this, connector pubsub events and direct messages were silently dropped in
  # the busy states' catch-all clauses.
  defp defer_message(data, msg) do
    maybe_ack_wakeup(msg)
    buffer = [msg | data.deferred_messages]

    # Bound the buffer: a busy pubsub feed during a long cycle must not grow
    # process state without limit. Oldest messages are dropped first; scans
    # are cycle-based, so the next wakeup re-covers anything dropped here.
    buffer =
      if length(buffer) > @max_deferred_messages do
        Logger.warning("Deferred message buffer full for agent #{data.agent_id}; dropping oldest")
        List.delete_at(buffer, -1)
      else
        buffer
      end

    %{data | deferred_messages: buffer}
  end

  # A wakeup is "delivered" the moment it lands in the agent's mailbox, in any
  # state. Acking on receipt — not only in :idle — stops the Scheduler from
  # reclaiming and re-dispatching the same job every poll while the agent is
  # busy, which was the scheduler-churn leak.
  defp maybe_ack_wakeup({:wakeup, _type, job_id, _payload}) when is_binary(job_id) do
    acknowledge_wakeup(job_id)
  end

  defp maybe_ack_wakeup({:agent_dispatch, inner}), do: maybe_ack_wakeup(inner)
  defp maybe_ack_wakeup(_msg), do: :ok

  defp drain_deferred_messages(%{deferred_messages: []} = data), do: data

  defp drain_deferred_messages(%{deferred_messages: messages} = data) do
    # Replay in arrival order (the buffer is prepended, so reverse first).
    Enum.each(Enum.reverse(messages), &send(self(), &1))
    %{data | deferred_messages: []}
  end

  defp stop_agent(reason, data) do
    data = fail_current_run(data, reason)
    data = emit_event(data, "agent_stopped", %{reason: reason})
    # Cancel this agent's scheduled jobs so they don't churn in the scheduler
    # once the process is gone. Only intentional stops reach here — a crash
    # bypasses stop_agent and is restarted by the :transient supervisor, which
    # re-schedules its own heartbeat/checkpoint jobs on recovery.
    _ = Scheduler.cancel_all(data.agent_id)
    {:stop, :normal, data}
  end

  defp register_global_name(agent_id) do
    name = {:maraithon_agent, agent_id}
    register_global_name(name, @global_register_retries)
  end

  defp register_global_name(name, retries_left) do
    case :global.register_name(name, self()) do
      :yes ->
        :ok

      :no ->
        owner = :global.whereis_name(name)

        if retries_left > 0 and retry_global_register?(owner) do
          Process.sleep(@global_register_retry_ms)
          register_global_name(name, retries_left - 1)
        else
          {:error, {:already_started, owner}}
        end
    end
  end

  defp retry_global_register?(:undefined), do: true

  defp retry_global_register?(pid) when is_pid(pid) do
    node(pid) == node() and not Process.alive?(pid)
  end

  defp retry_global_register?(_owner), do: false
end
