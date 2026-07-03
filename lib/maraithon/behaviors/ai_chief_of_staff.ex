defmodule Maraithon.Behaviors.AIChiefOfStaff do
  @moduledoc """
  Unified operator-facing assistant that orchestrates internal Chief of Staff skills.

  The first implementation slice composes the existing follow-through, travel,
  and briefing systems behind one behavior and one builder template.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.ChiefOfStaff.{Acquisition, AttentionArbiter, Skills}
  alias Maraithon.Connectors.SourceCursors

  require Logger

  # GOALS.md: the Chief of Staff wakes every 10 minutes, with lean modes
  # allowed to stretch to 15. R1 (SPEC 04): default cadence is 10 minutes;
  # the floor (not a slow-down clamp) is 5 minutes so config can only make
  # cadence *faster*, never forced back up to the old hourly loop.
  @default_wakeup_interval_ms :timer.minutes(10)
  @min_wakeup_interval_ms :timer.minutes(5)

  @impl true
  def init(config) do
    user_id = normalize_string(config["user_id"])
    enabled_skill_ids = Skills.enabled_ids(config)
    skill_configs = build_skill_configs(config, user_id, enabled_skill_ids)

    skill_states =
      Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
        module = Skills.get!(skill_id)
        Map.put(acc, skill_id, module.init(Map.fetch!(skill_configs, skill_id)))
      end)

    %{
      user_id: user_id,
      enabled_skill_ids: enabled_skill_ids,
      skill_configs: skill_configs,
      skill_states: skill_states,
      cycle_skill_ids: nil,
      assistant_cycle_id: nil,
      source_bundle: nil,
      assistant_fetch_telemetry: nil,
      pending_emit: nil,
      pending_emits: [],
      pending_effect_skill_id: nil,
      resume_index: 0,
      pending_watermarks: [],
      last_watermarks: %{},
      last_cycle_stats: %{},
      cycle_memory: %{"memo" => nil, "updated_at" => nil, "cycle_id" => nil},
      cycle_memo_generated: false,
      wakeup_interval_ms:
        config
        |> Map.get("wakeup_interval_ms")
        |> positive_integer(@default_wakeup_interval_ms)
        |> max(@min_wakeup_interval_ms)
    }
  end

  @impl true
  def handle_wakeup(state, context) do
    state =
      case state.user_id do
        nil -> %{state | user_id: normalize_string(context[:user_id])}
        _ -> state
      end
      |> ensure_cycle(context)

    run_from_index(state.resume_index || 0, state, context)
  end

  @impl true
  def handle_effect_result(effect_result, state, context) do
    case state.pending_effect_skill_id do
      nil ->
        {:idle, state}

      :cycle_memo ->
        handle_cycle_memo_effect_result(effect_result, state, context)

      skill_id ->
        module = Skills.get!(skill_id)
        skill_state = Map.fetch!(state.skill_states, skill_id)
        index = skill_index(state, skill_id)
        skill_context = skill_context(state, context, skill_id, index)

        case module.handle_effect_result(effect_result, skill_state, skill_context) do
          {:effect, effect, next_skill_state} ->
            {:effect, effect, put_skill_state(state, skill_id, next_skill_state)}

          {:emit, emit, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)
              |> stash_emit(emit, skill_id, index)

            run_from_index(state.resume_index || 0, state, context)

          {:continue, next_skill_state} ->
            {:continue,
             state
             |> put_skill_state(skill_id, next_skill_state)
             |> Map.put(:pending_effect_skill_id, nil)
             |> Map.put(:resume_index, index)}

          {:idle, next_skill_state} ->
            state =
              state
              |> put_skill_state(skill_id, next_skill_state)
              |> Map.put(:pending_effect_skill_id, nil)

            run_from_index(state.resume_index || 0, state, context)
        end
    end
  end

  @impl true
  def handle_effect_error(effect_type, reason, state, context) do
    case state.pending_effect_skill_id do
      nil ->
        {:idle, state}

      :cycle_memo ->
        Logger.warning("ChiefOfStaff cycle memo generation failed",
          effect_type: inspect(effect_type),
          reason: inspect(reason)
        )

        finalize_cycle(mark_cycle_memo_done(state))

      skill_id ->
        module = Skills.get!(skill_id)
        skill_state = Map.fetch!(state.skill_states, skill_id)
        index = skill_index(state, skill_id)
        skill_context = skill_context(state, context, skill_id, index)

        if function_exported?(module, :handle_effect_error, 4) do
          case module.handle_effect_error(effect_type, reason, skill_state, skill_context) do
            {:effect, effect, next_skill_state} ->
              {:effect, effect, put_skill_state(state, skill_id, next_skill_state)}

            {:emit, emit, next_skill_state} ->
              state =
                state
                |> put_skill_state(skill_id, next_skill_state)
                |> Map.put(:pending_effect_skill_id, nil)
                |> stash_emit(emit, skill_id, index)

              run_from_index(state.resume_index || 0, state, context)

            {:continue, next_skill_state} ->
              {:continue,
               state
               |> put_skill_state(skill_id, next_skill_state)
               |> Map.put(:pending_effect_skill_id, nil)
               |> Map.put(:resume_index, index)}

            {:idle, next_skill_state} ->
              state =
                state
                |> put_skill_state(skill_id, next_skill_state)
                |> Map.put(:pending_effect_skill_id, nil)

              run_from_index(state.resume_index || 0, state, context)
          end
        else
          {:idle, %{state | pending_effect_skill_id: nil}}
        end
    end
  end

  @impl true
  def next_wakeup(state) do
    scan_schedule = {:relative, Map.get(state, :wakeup_interval_ms, @default_wakeup_interval_ms)}

    state.enabled_skill_ids
    |> Enum.reduce(scan_schedule, fn skill_id, schedule ->
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)
      merge_wakeup(schedule, module.next_wakeup(skill_state))
    end)
    |> clamp_relative_scan_floor()
  end

  def default_skill_ids, do: Skills.default_enabled_ids()

  defp run_from_index(index, state, context) when index < 0, do: run_from_index(0, state, context)

  defp run_from_index(index, state, context) do
    skill_ids = cycle_skill_ids(state)

    if index >= length(skill_ids) do
      request_cycle_memo(%{state | resume_index: 0}, context)
    else
      skill_id = Enum.at(skill_ids, index)
      module = Skills.get!(skill_id)
      skill_state = Map.fetch!(state.skill_states, skill_id)
      skill_context = skill_context(state, context, skill_id, index)

      case module.handle_wakeup(skill_state, skill_context) do
        {:effect, effect, next_skill_state} ->
          {:effect, effect,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:pending_effect_skill_id, skill_id)
           |> Map.put(:resume_index, index + 1)}

        {:emit, emit, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)
            |> stash_emit(emit, skill_id, index)

          run_from_index(index + 1, state, context)

        {:continue, next_skill_state} ->
          {:continue,
           state
           |> put_skill_state(skill_id, next_skill_state)
           |> Map.put(:resume_index, index)}

        {:idle, next_skill_state} ->
          state =
            state
            |> put_skill_state(skill_id, next_skill_state)

          run_from_index(index + 1, state, context)
      end
    end
  end

  # R3/R4 (SPEC 04): before finalizing, ask the model for a short cycle memo
  # ("state of the world + what I decided/held this cycle") so the next
  # wakeup reasons over deltas instead of starting from scratch. This is a
  # cheap effect (skipped entirely on a quiet cycle with no deltas/emits —
  # near-zero spend) routed through the same effect/continue machinery
  # skills use, keyed off the `:cycle_memo` sentinel instead of a skill id.
  defp request_cycle_memo(%{cycle_memo_generated: true} = state, _context) do
    finalize_cycle(state)
  end

  defp request_cycle_memo(state, _context) do
    case memo_llm_params(state) do
      {:ok, params} ->
        {:effect, {:llm_call, params}, %{state | pending_effect_skill_id: :cycle_memo}}

      :skip ->
        finalize_cycle(mark_cycle_memo_done(state))
    end
  end

  defp handle_cycle_memo_effect_result({:llm_call, response}, state, context) do
    state =
      state
      |> put_cycle_memo(extract_memo_text(response), context)
      |> mark_cycle_memo_done()

    finalize_cycle(state)
  end

  defp handle_cycle_memo_effect_result(_effect_result, state, _context) do
    finalize_cycle(mark_cycle_memo_done(state))
  end

  defp mark_cycle_memo_done(state) do
    %{state | pending_effect_skill_id: nil, cycle_memo_generated: true}
  end

  defp put_cycle_memo(state, nil, _context), do: state

  defp put_cycle_memo(state, memo_text, context) when is_binary(memo_text) do
    %{
      state
      | cycle_memory: %{
          "memo" => memo_text,
          "updated_at" => DateTime.to_iso8601(context[:timestamp] || DateTime.utc_now()),
          "cycle_id" => state.assistant_cycle_id
        }
    }
  end

  defp finalize_cycle(state) do
    advanced_watermarks = advance_pending_watermarks(state)
    log_cycle_delta_summary(state)

    emit =
      AttentionArbiter.finalize_emit(
        state.pending_emit,
        state.pending_emits,
        state.assistant_cycle_id,
        state.assistant_fetch_telemetry
      )

    state = %{
      state
      | cycle_skill_ids: nil,
        assistant_cycle_id: nil,
        source_bundle: nil,
        # R3 (SPEC 04): keep a compact per-source watermark/stats snapshot in
        # behavior_state (already snapshotted/restored) even though the
        # canonical watermark lives in `source_cursors` — this is what
        # carries "what I last saw per source" forward for the agent's own
        # reasoning, independent of the DB round-trip.
        last_watermarks: Map.merge(state.last_watermarks || %{}, advanced_watermarks),
        last_cycle_stats: (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{}),
        assistant_fetch_telemetry: nil,
        pending_effect_skill_id: nil,
        pending_emits: [],
        pending_watermarks: [],
        cycle_memo_generated: false,
        resume_index: 0
    }

    case emit do
      nil ->
        {:idle, state}

      finalized_emit ->
        {:emit, finalized_emit, %{state | pending_emit: nil}}
    end
  end

  # R4 (SPEC 04): watermarks are only ever advanced here, after every skill's
  # effects for this cycle have completed (durable writes committed) and the
  # cycle memo attempt has resolved. Acquisition defers advancement for the
  # scheduled cycle (`defer_watermark_advance: true`) and instead proposes
  # `%{account:, kind:, value:}` entries; a crash before this point leaves the
  # watermark untouched, so the next wakeup reprocesses the same items rather
  # than silently skipping them. Returns a `%{"provider:kind" => value}`
  # summary for the behavior_state snapshot (R3).
  defp advance_pending_watermarks(%{pending_watermarks: watermarks}) when is_list(watermarks) do
    Enum.reduce(watermarks, %{}, fn entry, acc ->
      advance_pending_watermark(entry)

      case entry do
        %{account: %Maraithon.Accounts.ConnectedAccount{provider: provider}, kind: kind, value: value}
        when is_binary(provider) and is_binary(kind) ->
          Map.put(acc, "#{provider}:#{kind}", value)

        _ ->
          acc
      end
    end)
  end

  defp advance_pending_watermarks(_state), do: %{}

  defp advance_pending_watermark(%{
         account: %Maraithon.Accounts.ConnectedAccount{} = account,
         kind: kind,
         value: value
       })
       when is_binary(kind) and is_binary(value) do
    case SourceCursors.put(account, kind, %{"value" => value}) do
      {:ok, _cursor} ->
        :ok

      {:error, reason} ->
        Logger.warning("ChiefOfStaff failed to advance source watermark",
          provider: account.provider,
          kind: kind,
          reason: inspect(reason)
        )
    end
  end

  defp advance_pending_watermark(_other), do: :ok

  defp log_cycle_delta_summary(state) do
    sources = (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{})

    Logger.info(
      "ChiefOfStaff cycle source deltas: " <> safe_json(sources),
      assistant_cycle_id: state.assistant_cycle_id,
      user_id: state.user_id
    )
  end

  @memo_max_chars 1500

  defp memo_llm_params(state) do
    if cycle_worth_memo?(state) do
      {:ok,
       %{
         "messages" => [%{"role" => "user", "content" => memo_prompt(state)}],
         "max_tokens" => 400,
         "temperature" => 0.2,
         "reasoning_effort" => "low"
       }}
    else
      :skip
    end
  end

  defp cycle_worth_memo?(state) do
    blank?(Map.get(state.cycle_memory || %{}, "memo")) or cycle_has_activity?(state)
  end

  defp cycle_has_activity?(state) do
    has_emits = state.pending_emits != [] or not is_nil(state.pending_emit)
    has_emits or telemetry_delta_count(state.assistant_fetch_telemetry) > 0
  end

  @delta_count_keys ~w(
    message_count event_count count item_count memo_count note_count
    open_due_soon recent_count visit_count chat_count feed_count
  )

  defp telemetry_delta_count(telemetry) when is_map(telemetry) do
    telemetry
    |> Map.get("sources", %{})
    |> Map.values()
    |> Enum.map(&source_item_count/1)
    |> Enum.sum()
  end

  defp telemetry_delta_count(_telemetry), do: 0

  defp source_item_count(summary) when is_map(summary) do
    @delta_count_keys
    |> Enum.map(&Map.get(summary, &1, 0))
    |> Enum.filter(&is_integer/1)
    |> Enum.sum()
  end

  defp source_item_count(_summary), do: 0

  defp memo_prompt(state) do
    previous_memo = Map.get(state.cycle_memory || %{}, "memo")
    skills_ran = state.pending_emits |> Enum.map(& &1.skill_id) |> Enum.uniq()
    deltas = (state.assistant_fetch_telemetry || %{}) |> Map.get("sources", %{})

    """
    You are the Chief of Staff's cross-cycle memory. Write a short memo \
    (max #{@memo_max_chars} characters, plain text, no markdown) capturing \
    the state of the world and what you decided or held this cycle, so \
    your next wakeup can reason over the delta instead of starting from \
    scratch.

    Previous cycle memo:
    #{if blank?(previous_memo), do: "(none yet - this is the first cycle)", else: previous_memo}

    This cycle:
    - Skills that produced output: #{if skills_ran == [], do: "none", else: Enum.join(skills_ran, ", ")}
    - Per-source new-item counts since the last watermark: #{safe_json(deltas)}

    Write the memo now. Be concrete and terse: note open threads, anything \
    you decided to hold or suppress, and anything worth watching next \
    cycle. Do not repeat these instructions.
    """
  end

  defp extract_memo_text(response) do
    content =
      case response do
        %{content: content} when is_binary(content) -> content
        %{"content" => content} when is_binary(content) -> content
        content when is_binary(content) -> content
        _ -> nil
      end

    case content && String.trim(content) do
      text when is_binary(text) and text != "" -> String.slice(text, 0, @memo_max_chars)
      _ -> nil
    end
  end

  defp safe_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(value)
    end
  end

  # R2 (SPEC 04): the scheduled wakeup path defers watermark advancement to
  # `finalize_cycle/1` (R4) and gets a capped no-cursor fallback lookback
  # (see Acquisition's `deep_lookback?`/`defer_watermark_advance`).
  defp ensure_cycle(%{cycle_skill_ids: nil} = state, context) do
    cycle_skill_ids = selected_skill_ids(state, context)
    acquisition_context = Map.put(context, :defer_watermark_advance, true)

    {source_bundle, assistant_fetch_telemetry, proposed_watermarks} =
      acquisition_module().build(
        state.user_id || normalize_string(context[:user_id]),
        cycle_skill_ids,
        state.skill_configs,
        acquisition_context
      )

    %{
      state
      | cycle_skill_ids: cycle_skill_ids,
        assistant_cycle_id: Ecto.UUID.generate(),
        source_bundle: source_bundle,
        assistant_fetch_telemetry: assistant_fetch_telemetry,
        pending_watermarks: proposed_watermarks,
        cycle_memo_generated: false
    }
  end

  defp ensure_cycle(state, _context), do: state

  defp selected_skill_ids(state, context) do
    Enum.filter(state.enabled_skill_ids, fn skill_id ->
      Skills.interested_in?(skill_id, state.skill_configs, context)
    end)
  end

  defp cycle_skill_ids(%{cycle_skill_ids: skill_ids}) when is_list(skill_ids), do: skill_ids
  defp cycle_skill_ids(state), do: state.enabled_skill_ids

  defp skill_index(state, skill_id) do
    state
    |> cycle_skill_ids()
    |> Enum.find_index(&(&1 == skill_id))
    |> case do
      nil -> 0
      index -> index
    end
  end

  defp put_skill_state(state, skill_id, next_skill_state) do
    put_in(state, [:skill_states, skill_id], next_skill_state)
  end

  defp stash_emit(state, emit, skill_id, index) do
    %{
      state
      | pending_emit: merge_emit(state.pending_emit, emit),
        pending_emits:
          state.pending_emits ++
            [
              %{
                skill_id: skill_id,
                event_type: elem(emit, 0),
                rank: index + 1
              }
            ]
    }
  end

  defp skill_context(state, context, skill_id, index) do
    context
    |> Map.put(:source_bundle, state.source_bundle)
    |> Map.put(:assistant_cycle_id, state.assistant_cycle_id)
    |> Map.put(:assistant_fetch_telemetry, state.assistant_fetch_telemetry)
    |> Map.put(:assistant_origin_skill_id, skill_id)
    |> Map.put(:assistant_origin_skill_rank, index + 1)
    |> Map.put(:previous_cycle_memo, Map.get(state.cycle_memory || %{}, "memo"))
  end

  defp build_skill_configs(config, user_id, enabled_skill_ids) do
    skill_config_overrides =
      read_map(config, "skill_configs")

    Enum.reduce(enabled_skill_ids, %{}, fn skill_id, acc ->
      module = Skills.get!(skill_id)

      merged =
        module.default_config()
        |> Map.merge(shared_skill_config(config, user_id))
        |> Map.merge(read_map(skill_config_overrides, skill_id))
        |> maybe_put("assistant_behavior", "ai_chief_of_staff")

      Map.put(acc, skill_id, merged)
    end)
  end

  defp shared_skill_config(config, user_id) do
    %{}
    |> maybe_put("user_id", user_id)
    |> maybe_put("source_policy", read_string(config, "source_policy", nil))
    |> maybe_put("source_scope", read_map(config, "source_scope"))
    |> maybe_put("timezone", read_string(config, "timezone", nil))
    |> maybe_put("timezone_name", read_string(config, "timezone_name", nil))
    |> maybe_put_integer("timezone_offset_hours", read_integer(config, "timezone_offset_hours"))
    |> maybe_put_integer(
      "morning_brief_hour_local",
      read_integer(config, "morning_brief_hour_local")
    )
    |> maybe_put_integer(
      "morning_brief_minute_local",
      read_integer(config, "morning_brief_minute_local")
    )
    |> maybe_put_integer(
      "end_of_day_brief_hour_local",
      read_integer(config, "end_of_day_brief_hour_local")
    )
    |> maybe_put_integer(
      "weekly_review_day_local",
      read_integer(config, "weekly_review_day_local")
    )
    |> maybe_put_integer(
      "weekly_review_hour_local",
      read_integer(config, "weekly_review_hour_local")
    )
    |> maybe_put_integer("brief_max_items", read_integer(config, "brief_max_items"))
  end

  defp merge_emit(nil, emit), do: emit
  defp merge_emit(emit, nil), do: emit

  defp merge_emit({:insights_recorded, left}, {:insights_recorded, right}) do
    {:insights_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       categories: Enum.uniq(payload_list(left, :categories) ++ payload_list(right, :categories))
     }}
  end

  defp merge_emit({:insight_error, left}, {:insight_error, right}) do
    {:insight_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:briefs_recorded, left}, {:briefs_recorded, right}) do
    {:briefs_recorded,
     %{
       count: payload_int(left, :count, 0) + payload_int(right, :count, 0),
       user_id: payload_string(left, :user_id) || payload_string(right, :user_id),
       cadences: Enum.uniq(payload_list(left, :cadences) ++ payload_list(right, :cadences))
     }}
  end

  defp merge_emit({:brief_error, left}, {:brief_error, right}) do
    {:brief_error,
     %{
       reason:
         [payload_string(left, :reason), payload_string(right, :reason)]
         |> Enum.reject(&blank?/1)
         |> Enum.join(" | "),
       attempted_count:
         payload_int(left, :attempted_count, 0) + payload_int(right, :attempted_count, 0)
     }}
  end

  defp merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs}) do
    base = stringify_keys(recorded)
    briefs_key = shaped_key(recorded, :briefs)
    count_key = shaped_key(briefs, :count)
    cadences_key = shaped_key(briefs, :cadences)

    {:insights_recorded,
     Map.put(
       base,
       briefs_key,
       payload_list(recorded, :briefs) ++
         [
           %{
             count_key => payload_int(briefs, :count, 0),
             cadences_key => payload_list(briefs, :cadences)
           }
         ]
     )}
  end

  defp merge_emit({:briefs_recorded, briefs}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:briefs_recorded, briefs})

  defp merge_emit({:insights_recorded, recorded}, {:insight_error, error}) do
    {:insights_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:insight_error, error}, {:insights_recorded, recorded}),
    do: merge_emit({:insights_recorded, recorded}, {:insight_error, error})

  defp merge_emit({:briefs_recorded, recorded}, {:brief_error, error}) do
    {:briefs_recorded,
     recorded
     |> stringify_keys()
     |> Map.put(
       shaped_key(recorded, :errors),
       payload_list(recorded, :errors) ++
         [
           %{
             shaped_key(error, :reason) => payload_string(error, :reason),
             shaped_key(error, :attempted_count) => payload_int(error, :attempted_count, 0)
           }
         ]
     )}
  end

  defp merge_emit({:brief_error, error}, {:briefs_recorded, recorded}),
    do: merge_emit({:briefs_recorded, recorded}, {:brief_error, error})

  defp merge_emit(left, _right), do: left

  defp merge_wakeup(:none, other), do: other
  defp merge_wakeup(other, :none), do: other

  defp merge_wakeup({:relative, left_ms}, {:relative, right_ms}),
    do: {:relative, min(left_ms, right_ms)}

  defp merge_wakeup({:absolute, %DateTime{} = left}, {:absolute, %DateTime{} = right}) do
    if DateTime.compare(left, right) in [:lt, :eq],
      do: {:absolute, left},
      else: {:absolute, right}
  end

  defp merge_wakeup({:absolute, %DateTime{} = absolute}, {:relative, ms}) do
    relative_absolute = DateTime.add(DateTime.utc_now(), ms, :millisecond)

    if DateTime.compare(absolute, relative_absolute) == :gt,
      do: {:relative, ms},
      else: {:absolute, absolute}
  end

  defp merge_wakeup({:relative, ms}, {:absolute, %DateTime{} = absolute}),
    do: merge_wakeup({:absolute, absolute}, {:relative, ms})

  defp merge_wakeup(_left, right), do: right

  defp clamp_relative_scan_floor({:relative, ms}) when is_integer(ms) do
    {:relative, max(ms, @min_wakeup_interval_ms)}
  end

  defp clamp_relative_scan_floor(other), do: other

  defp acquisition_module do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(:acquisition_module, Acquisition)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_integer(map, _key, nil), do: map
  defp maybe_put_integer(map, key, value) when is_integer(value), do: Map.put(map, key, value)

  defp read_map(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      %{} = map -> map
      _ -> %{}
    end
  end

  defp read_string(payload, key, default) when is_map(payload) do
    case map_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      value when is_atom(value) ->
        value
        |> Atom.to_string()
        |> String.trim()
        |> case do
          "" -> default
          trimmed -> trimmed
        end

      _ ->
        default
    end
  end

  defp read_integer(payload, key) when is_map(payload) do
    case map_value(payload, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default

  defp map_value(payload, key) when is_map(payload) and is_binary(key) do
    Map.get(payload, key) || Map.get(payload, existing_atom(key))
  end

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp payload_int(payload, key, default) do
    case payload_value(payload, key) do
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp payload_string(payload, key) do
    case payload_value(payload, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp payload_list(payload, key) do
    case payload_value(payload, key) do
      values when is_list(values) -> values
      _ -> []
    end
  end

  defp shaped_key(payload, key) when is_map(payload) do
    cond do
      Map.has_key?(payload, key) -> key
      Map.has_key?(payload, Atom.to_string(key)) -> Atom.to_string(key)
      true -> Atom.to_string(key)
    end
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp stringify_keys(payload) when is_map(payload) do
    Enum.reduce(payload, %{}, fn {key, value}, acc ->
      Map.put(acc, if(is_atom(key), do: Atom.to_string(key), else: key), value)
    end)
  end

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil
end
