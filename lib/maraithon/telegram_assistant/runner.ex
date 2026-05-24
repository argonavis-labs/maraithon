defmodule Maraithon.TelegramAssistant.Runner do
  @moduledoc """
  Bounded multi-step runner for Telegram assistant chat and prepared actions.
  """

  alias Maraithon.AssistantHarness
  alias Maraithon.ActionLedger
  alias Maraithon.ContextEngine
  alias Maraithon.Projects
  alias Maraithon.Runtime
  alias Maraithon.TelegramAssistant

  alias Maraithon.TelegramAssistant.{
    ConnectedContextPreflight,
    ModelRouting,
    Run,
    TodoActions,
    Toolbox
  }

  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Conversation
  alias Maraithon.Todos
  alias Maraithon.Todos.SurfaceQuality
  alias Maraithon.Tools
  alias Maraithon.Tracing
  alias Maraithon.UserMemory

  require Logger

  def run_inbound(attrs) when is_map(attrs) do
    Tracing.with_span(
      "telegram_assistant.run_inbound",
      %{
        chat_id: Map.get(attrs, :chat_id),
        trigger_type: trigger_type(attrs)
      },
      fn -> do_run_inbound(attrs) end
    )
  end

  defp do_run_inbound(attrs) do
    model_profile = ModelRouting.profile_for(attrs)
    context_attrs = attrs_with_model_profile(attrs, model_profile)
    context = ContextEngine.build_context(context_attrs)
    context = ConnectedContextPreflight.apply(context, context_attrs)
    conversation = Map.get(attrs, :conversation)

    case start_run(attrs, context, model_profile) do
      {:ok, run} ->
        runtime_context = build_runtime_context(run, attrs, context, model_profile)
        _ = maybe_start_liveness_session(run, attrs)

        with {:ok, _step_state} <- record_context_fetch(run, context),
             :ok <- note_context_loaded(run),
             {:ok, response, state} <-
               run_loop(
                 run,
                 runtime_context,
                 AssistantHarness.initial_loop_state(),
                 System.monotonic_time(:millisecond)
               ),
             {:ok, status, summary} <-
               deliver_final_response(conversation, run, response, state, attrs) do
          summary =
            summary
            |> Map.put(:model_tier, Map.get(runtime_context, :model_tier))
            |> Map.put(:model_name, Map.get(runtime_context, :model_name))
            |> Map.put(:model_reasoning_effort, Map.get(runtime_context, :model_reasoning_effort))

          {:ok, _run} =
            TelegramAssistant.complete_run(run, %{status: status, result_summary: summary})

          :ok
        else
          {:fallback, reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")

            Logger.warning("Telegram assistant falling back to legacy interpreter",
              reason: inspect(reason)
            )

            {:fallback, reason}

          {:error, %Run{} = run, reason, state} ->
            case maybe_escalate_and_retry(
                   run,
                   reason,
                   attrs,
                   context,
                   conversation,
                   model_profile
                 ) do
              :ok -> :ok
              :pass -> handle_run_failure(run, reason, state, attrs)
            end

          {:error, reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")
            {:fallback, reason}
        end

      {:error, reason} ->
        {:fallback, reason}
    end
  end

  defp maybe_escalate_and_retry(
         %Run{} = original_run,
         reason,
         attrs,
         context,
         %Conversation{} = conversation,
         model_profile
       ) do
    if escalatable_reason?(reason) and Map.get(model_profile, :tier) == :chat do
      _ = TelegramAssistant.cancel_liveness_session(original_run.id)

      escalated_profile = ModelRouting.escalated_profile_for(model_profile)

      Logger.info("Escalating Telegram assistant turn to reasoning model",
        run_id: original_run.id,
        reason: inspect(reason),
        model: Map.get(escalated_profile, :model)
      )

      case run_escalated_turn(
             attrs,
             context,
             conversation,
             escalated_profile,
             original_run,
             reason
           ) do
        {:ok, escalated_run_id} ->
          {:ok, _run} =
            TelegramAssistant.complete_run(original_run, %{
              status: "completed",
              result_summary: %{
                escalated_to_reasoning: true,
                escalated_run_id: escalated_run_id,
                escalated_from_reason: normalize_error(reason)
              }
            })

          :ok

        :ok ->
          {:ok, _run} =
            TelegramAssistant.fail_run(
              original_run,
              {:escalated_to_reasoning, reason},
              "degraded"
            )

          :ok

        :pass ->
          :pass
      end
    else
      :pass
    end
  end

  defp maybe_escalate_and_retry(_run, _reason, _attrs, _context, _conversation, _profile),
    do: :pass

  defp run_escalated_turn(attrs, context, conversation, model_profile, original_run, reason) do
    case start_run(attrs, context, model_profile) do
      {:ok, run} ->
        runtime_context = build_runtime_context(run, attrs, context, model_profile)
        _ = maybe_start_liveness_session(run, attrs)

        with {:ok, _step_state} <- record_context_fetch(run, context),
             :ok <- note_context_loaded(run),
             {:ok, response, state} <-
               run_loop(
                 run,
                 runtime_context,
                 AssistantHarness.initial_loop_state(),
                 System.monotonic_time(:millisecond)
               ),
             {:ok, status, summary} <-
               deliver_final_response(conversation, run, response, state, attrs) do
          summary =
            summary
            |> Map.put(:model_tier, Map.get(runtime_context, :model_tier))
            |> Map.put(:model_name, Map.get(runtime_context, :model_name))
            |> Map.put(:model_reasoning_effort, Map.get(runtime_context, :model_reasoning_effort))
            |> Map.put(:escalated_from_run_id, original_run.id)
            |> Map.put(:escalated_from_reason, normalize_error(reason))

          {:ok, _run} =
            TelegramAssistant.complete_run(run, %{status: status, result_summary: summary})

          {:ok, run.id}
        else
          {:fallback, retry_reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, retry_reason, "degraded")
            :pass

          {:error, %Run{} = retry_run, retry_reason, retry_state} ->
            handle_run_failure(retry_run, retry_reason, retry_state, attrs)
            :ok

          {:error, retry_reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, retry_reason, "degraded")
            :pass
        end

      {:error, _reason} ->
        :pass
    end
  end

  defp escalatable_reason?(:timeout), do: true
  defp escalatable_reason?(:llm_turn_limit), do: true
  defp escalatable_reason?(:tool_step_limit), do: true
  defp escalatable_reason?(:assistant_harness_empty_tool_calls), do: true
  defp escalatable_reason?(:assistant_harness_invalid_status), do: true
  defp escalatable_reason?(:assistant_harness_invalid_tool_calls), do: true
  defp escalatable_reason?(:assistant_harness_invalid_tool_call), do: true
  defp escalatable_reason?(:assistant_harness_invalid_json), do: true
  defp escalatable_reason?(:assistant_harness_missing_content), do: true
  defp escalatable_reason?(:assistant_harness_empty_message), do: true
  defp escalatable_reason?({:llm_busy, _retry_after}), do: true
  defp escalatable_reason?({:rate_limited, _retry_after}), do: true
  defp escalatable_reason?({:network_error, _reason}), do: true

  defp escalatable_reason?({:api_error, status, _body})
       when status in [408, 425, 429, 500, 502, 503, 504],
       do: true

  defp escalatable_reason?(_reason), do: false

  def execute_prepared_action(prepared_action) do
    action_type = prepared_action.action_type
    payload = prepared_action.payload || %{}

    case action_type do
      "agent_create" ->
        Runtime.start_agent(Map.fetch!(payload, "start_params"))
        |> map_agent_result("Created agent.")

      "agent_update" ->
        Runtime.update_agent(
          Map.fetch!(payload, "agent_id"),
          Map.fetch!(payload, "update_params")
        )
        |> map_agent_result("Updated agent.")

      "agent_delete" ->
        case Runtime.delete_agent(Map.fetch!(payload, "agent_id")) do
          :ok -> {:ok, %{message: "Deleted the agent."}}
          {:error, reason} -> {:error, reason}
        end

      "project_create" ->
        Projects.create_project(Map.fetch!(payload, "user_id"), Map.fetch!(payload, "attrs"))
        |> map_project_result("Created the project.")

      "project_update" ->
        case Projects.get_project(Map.fetch!(payload, "project_id")) do
          nil ->
            {:error, :project_not_found}

          project ->
            Projects.update_project(project, Map.fetch!(payload, "attrs"))
            |> map_project_result("Updated the project.")
        end

      action_type ->
        execute_external_action(action_type, payload)
    end
  end

  defp start_run(attrs, context, model_profile) do
    TelegramAssistant.start_run(%{
      user_id: Map.fetch!(attrs, :user_id),
      chat_id: Map.fetch!(attrs, :chat_id),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      trigger_type: trigger_type(attrs),
      status: "running",
      model_provider: TelegramAssistant.model_provider_name(),
      model_name: Map.get(model_profile, :model) || TelegramAssistant.model_name(),
      prompt_snapshot: ContextEngine.prompt_snapshot(context),
      result_summary: %{model_tier: Map.get(model_profile, :tier)},
      started_at: DateTime.utc_now()
    })
  end

  defp record_context_fetch(run, context) do
    now = DateTime.utc_now()

    with {:ok, step} <- build_step(run, "context_fetch", 1, %{context: context}, now),
         {:ok, _completed_step} <-
           TelegramAssistant.complete_step(step, %{
             response_payload: %{context_loaded: true},
             finished_at: now
           }) do
      {:ok, :recorded}
    end
  end

  defp run_loop(run, runtime_context, state, started_monotonic_ms) do
    policy_opts = runner_policy_opts(runtime_context)

    case AssistantHarness.guard_loop(state, started_monotonic_ms, policy_opts) do
      {:error, reason} ->
        {:error, run, reason, state}

      :ok ->
        request_payload =
          runtime_context
          |> Map.put(:tools, ContextEngine.tool_catalog(runtime_context.context))
          |> AssistantHarness.build_loop_request_payload(state, policy_opts)
          |> Map.put(:_stream_target, runtime_context.run_id)
          |> Map.put(:_llm_opts, Map.get(runtime_context, :llm_opts, []))

        now = DateTime.utc_now()

        Tracing.with_span(
          "telegram_assistant.llm_request",
          %{
            run_id: run.id,
            iteration: state.iteration,
            llm_turns: state.llm_turns,
            model: Map.get(runtime_context, :model_name),
            model_tier: Map.get(runtime_context, :model_tier)
          },
          fn ->
            do_run_loop_step(
              run,
              runtime_context,
              state,
              started_monotonic_ms,
              request_payload,
              now
            )
          end
        )
    end
  end

  defp do_run_loop_step(run, runtime_context, state, started_monotonic_ms, request_payload, now) do
    with {:ok, llm_request_step} <-
           build_step(run, "llm_request", state.sequence + 1, request_payload, now),
         {:ok, response} <- TelegramAssistant.client_module().next_step(request_payload),
         {:ok, _completed_request_step} <-
           TelegramAssistant.complete_step(llm_request_step, %{
             response_payload: %{ok: true},
             finished_at: DateTime.utc_now()
           }),
         {:ok, _llm_response_step} <-
           record_llm_response(run, state.sequence + 2, response) do
      next_state = %{state | llm_turns: state.llm_turns + 1, sequence: state.sequence + 2}
      handle_llm_response(run, runtime_context, response, next_state, started_monotonic_ms)
    else
      {:error, reason} ->
        {:error, run, reason, state}
    end
  end

  defp handle_llm_response(run, runtime_context, response, state, started_monotonic_ms) do
    case Map.get(response, "status") do
      "tool_calls" ->
        execute_tool_calls(
          run,
          runtime_context,
          Map.get(response, "tool_calls", []),
          state,
          started_monotonic_ms
        )

      _ ->
        {:ok, response, state}
    end
  end

  defp execute_tool_calls(run, runtime_context, tool_calls, state, started_monotonic_ms) do
    cond do
      state.tool_steps + length(tool_calls) > max_tool_steps() ->
        {:error, run, :tool_step_limit, state}

      tool_calls == [] ->
        run_loop(
          run,
          runtime_context,
          %{state | iteration: state.iteration + 1},
          started_monotonic_ms
        )

      true ->
        run_tool_calls_in_parallel(
          run,
          runtime_context,
          tool_calls,
          state,
          started_monotonic_ms
        )
    end
  end

  defp run_tool_calls_in_parallel(run, runtime_context, tool_calls, state, started_monotonic_ms) do
    base_sequence = state.sequence

    indexed_calls =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {call, index} -> {call, base_sequence + 1 + index} end)

    results =
      indexed_calls
      |> Task.async_stream(
        fn {tool_call, sequence} ->
          run_single_tool_call(run, runtime_context, tool_call, sequence)
        end,
        ordered: true,
        timeout: :infinity,
        max_concurrency: max(length(tool_calls), 1)
      )
      |> Enum.to_list()

    case collect_tool_results(results) do
      {:ok, history_entries} ->
        next_state =
          state
          |> Map.update!(:tool_steps, &(&1 + length(history_entries)))
          |> Map.update!(:sequence, &(&1 + length(history_entries)))
          |> Map.update!(:tool_history, fn history -> history ++ history_entries end)

        case AssistantHarness.guard_tool_history(
               next_state.tool_history,
               runner_policy_opts(runtime_context)
             ) do
          :ok ->
            run_loop(
              run,
              runtime_context,
              %{next_state | iteration: next_state.iteration + 1},
              started_monotonic_ms
            )

          {:error, reason} ->
            {:error, run, reason, next_state}
        end

      {:error, reason} ->
        {:error, run, reason, state}
    end
  end

  defp run_single_tool_call(run, runtime_context, tool_call, sequence) do
    tool_name = Map.get(tool_call, "tool")
    arguments = Map.get(tool_call, "arguments", %{})
    now = DateTime.utc_now()

    Tracing.with_span(
      "telegram_assistant.tool_call",
      %{run_id: run.id, tool: tool_name, sequence: sequence},
      fn ->
        do_run_single_tool_call(run, runtime_context, tool_name, arguments, sequence, now)
      end
    )
  end

  defp do_run_single_tool_call(run, runtime_context, tool_name, arguments, sequence, now) do
    with {:ok, tool_step} <-
           build_step(
             run,
             "tool_call",
             sequence,
             %{"tool" => tool_name, "arguments" => arguments},
             now
           ) do
      _ = TelegramAssistant.note_liveness_tool(run.id, tool_name, arguments)

      case Toolbox.execute(tool_name, arguments, runtime_context) do
        {:ok, result} ->
          {:ok, _completed_tool_step} =
            TelegramAssistant.complete_step(tool_step, %{
              response_payload: stringify_map(result),
              finished_at: DateTime.utc_now()
            })

          {:ok,
           %{
             "tool" => tool_name,
             "arguments" => arguments,
             "result" => stringify_map(result)
           }}

        {:error, reason} ->
          {:ok, _completed_tool_step} =
            TelegramAssistant.complete_step(tool_step, %{
              status: "failed",
              response_payload: %{"error" => normalize_error(reason)},
              error: normalize_error(reason),
              finished_at: DateTime.utc_now()
            })

          {:ok,
           %{
             "tool" => tool_name,
             "arguments" => arguments,
             "error" => normalize_error(reason)
           }}
      end
    end
  end

  defp collect_tool_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, {:ok, entry}}, {:ok, acc} ->
        {:cont, {:ok, acc ++ [entry]}}

      {:ok, {:error, reason}}, _acc ->
        {:halt, {:error, reason}}

      {:exit, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp deliver_final_response(
         %Conversation{} = conversation,
         run,
         response,
         state,
         attrs
       ) do
    message_class =
      response
      |> map_value("message_class", "assistant_reply")
      |> verified_message_class(response, state)

    prepared_action_id = latest_prepared_action_id(state.tool_history)

    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)

    case delivery.mode do
      :suppress_after_timeout ->
        {:ok, "degraded",
         build_result_summary(message_class, prepared_action_id, state, liveness_summary)}

      _ ->
        deliver_response_by_class(
          conversation,
          run,
          response,
          state,
          attrs,
          message_class,
          prepared_action_id,
          delivery,
          liveness_summary
        )
    end
  end

  defp deliver_final_response(_conversation, run, _response, state, _attrs) do
    {:error, run, :missing_conversation, state}
  end

  defp handle_run_failure(run, reason, state, attrs) do
    _ = Tracing.record_error(reason)

    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)

    _ = maybe_record_loop_failure(run, reason, state)

    summary =
      build_result_summary(
        "system_notice",
        latest_prepared_action_id(state.tool_history),
        state,
        liveness_summary
      )

    {:ok, _run} =
      TelegramAssistant.complete_run(run, %{
        status: "degraded",
        error: normalize_error(reason),
        result_summary: summary
      })

    case {state.tool_history, Map.get(attrs, :conversation), delivery.mode} do
      {_history, %Conversation{} = _conversation, :suppress_after_timeout} ->
        :ok

      {_history, %Conversation{} = conversation, _mode} ->
        _ =
          TelegramAssistant.send_turn(
            conversation,
            Map.fetch!(attrs, :chat_id),
            AssistantHarness.failure_message(reason),
            reply_to_message_id: Map.get(attrs, :source_message_id),
            send_mode: send_mode_for_delivery(delivery),
            message_id: delivery[:message_id],
            turn_kind: "system_notice",
            origin_type: "system",
            structured_data: %{"run_id" => run.id, "error" => normalize_error(reason)}
          )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_record_loop_failure(
         run,
         {:assistant_harness_tool_loop_detected, tool, count, class, loop},
         state
       ) do
    ActionLedger.record(%{
      user_id: run.user_id,
      surface: "telegram",
      event_type: "model.uncertainty",
      status: "failed",
      source_evidence: %{
        tool_history_length: length(state.tool_history || []),
        latest_tool: tool
      },
      model_summary: "Assistant tool loop stopped before repeating work.",
      remediation_hint: "Ask a narrower question or inspect the source/tool result manually.",
      metadata: %{
        run_id: run.id,
        tool_name: tool,
        loop_class: class,
        repeat_count: count,
        loop: normalize_payload(loop)
      }
    })
  rescue
    _error -> :ok
  end

  defp maybe_record_loop_failure(_run, _reason, _state), do: :ok

  defp record_llm_response(run, sequence, response) do
    now = DateTime.utc_now()

    with {:ok, step} <- build_step(run, "llm_response", sequence, %{}, now) do
      TelegramAssistant.complete_step(step, %{response_payload: response, finished_at: now})
    end
  end

  defp build_step(run, step_type, sequence, request_payload, started_at) do
    TelegramAssistant.create_step(%{
      run_id: run.id,
      sequence: sequence,
      step_type: step_type,
      status: "running",
      request_payload: stringify_map(request_payload),
      response_payload: %{},
      started_at: started_at
    })
  end

  defp build_runtime_context(run, attrs, context, model_profile) do
    defaults = Map.get(context, :defaults) || Map.get(context, "defaults") || %{}

    %{
      run_id: run.id,
      user_id: Map.fetch!(attrs, :user_id),
      chat_id: Map.fetch!(attrs, :chat_id),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      context: context,
      model_tier: Map.get(model_profile, :tier),
      model_name: Map.get(model_profile, :model),
      model_reasoning_effort: Map.get(model_profile, :reasoning_effort),
      llm_opts: Map.get(model_profile, :llm_opts, []),
      default_project_id:
        Map.get(defaults, :default_project_id) || defaults["default_project_id"],
      default_project_slug:
        Map.get(defaults, :default_project_slug) || defaults["default_project_slug"],
      default_slack_team_id:
        Map.get(defaults, :default_slack_team_id) || defaults["default_slack_team_id"]
    }
  end

  defp maybe_start_liveness_session(run, attrs) do
    case TelegramAssistant.start_liveness_session(run, attrs) do
      {:ok, _pid} ->
        :ok

      {:error, :disabled} ->
        :ok

      {:error, reason} ->
        Logger.warning("Telegram assistant liveness session failed to start",
          run_id: run.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp note_context_loaded(run) do
    _ = TelegramAssistant.note_liveness_context_loaded(run.id)
    :ok
  end

  defp apply_delivery_mode(turn_opts, %{mode: :edit, message_id: message_id})
       when is_binary(message_id) do
    turn_opts
    |> Keyword.put(:send_mode, :edit)
    |> Keyword.put(:message_id, message_id)
  end

  defp apply_delivery_mode(turn_opts, _delivery), do: turn_opts

  defp send_mode_for_delivery(%{mode: :edit}), do: :edit
  defp send_mode_for_delivery(_delivery), do: :reply

  defp build_result_summary(message_class, prepared_action_id, state, liveness_summary) do
    %{
      message_class: message_class,
      prepared_action_id: prepared_action_id,
      tool_steps: state.tool_steps,
      llm_turns: state.llm_turns,
      liveness: liveness_summary
    }
  end

  defp maybe_put_approval_markup(turn_opts, prepared_action_id, "approval_prompt")
       when is_binary(prepared_action_id) do
    Keyword.put(
      turn_opts,
      :telegram_opts,
      reply_markup: Maraithon.TelegramResponder.action_markup(prepared_action_id)
    )
  end

  defp maybe_put_approval_markup(turn_opts, _prepared_action_id, _message_class), do: turn_opts

  defp latest_prepared_action_id(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      case map_value(entry, "result") do
        result when is_map(result) ->
          case map_value(result, "prepared_action_id") do
            id when is_binary(id) -> id
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp latest_prepared_action_id(_tool_history), do: nil

  defp deliver_response_by_class(
         conversation,
         run,
         response,
         state,
         attrs,
         "todo_digest",
         prepared_action_id,
         delivery,
         liveness_summary
       ) do
    todos = latest_todo_items(state.tool_history)

    if todos == [] do
      deliver_standard_response(
        conversation,
        run,
        response,
        state,
        attrs,
        "assistant_reply",
        prepared_action_id,
        delivery,
        liveness_summary
      )
    else
      intro_text = todo_digest_intro_text(response, prepared_action_id)

      with {:ok, updated_conversation, _turn, _telegram_result} <-
             TelegramAssistant.send_turn(
               conversation,
               Map.fetch!(attrs, :chat_id),
               intro_text,
               standard_turn_opts(
                 attrs,
                 run,
                 state,
                 "assistant_reply",
                 prepared_action_id,
                 delivery,
                 map_value(response, "summary")
               )
             ),
           {:ok, final_conversation} <-
             send_todo_messages(updated_conversation, attrs, run, todos) do
        summary =
          build_result_summary("todo_digest", prepared_action_id, state, liveness_summary)
          |> Map.put(:todo_items_sent, length(todos))
          |> Map.put(:todo_ids, Enum.map(todos, &map_value(&1, "id")))

        _ = maybe_refresh_user_memory(attrs)
        _ = maybe_compact_conversation_async(final_conversation)

        {:ok, todo_digest_status(final_conversation, prepared_action_id), summary}
      else
        {:error, reason} ->
          {:error, run, reason, state}
      end
    end
  end

  defp deliver_response_by_class(
         conversation,
         run,
         response,
         state,
         attrs,
         message_class,
         prepared_action_id,
         delivery,
         liveness_summary
       ) do
    if should_force_todo_digest?(message_class, response, state) do
      deliver_response_by_class(
        conversation,
        run,
        response,
        state,
        attrs,
        "todo_digest",
        prepared_action_id,
        delivery,
        liveness_summary
      )
    else
      deliver_standard_response(
        conversation,
        run,
        response,
        state,
        attrs,
        message_class,
        prepared_action_id,
        delivery,
        liveness_summary
      )
    end
  end

  defp deliver_standard_response(
         conversation,
         run,
         response,
         state,
         attrs,
         message_class,
         prepared_action_id,
         delivery,
         liveness_summary
       ) do
    text = final_text(response, prepared_action_id)

    case TelegramAssistant.send_turn(
           conversation,
           Map.fetch!(attrs, :chat_id),
           text,
           standard_turn_opts(
             attrs,
             run,
             state,
             message_class,
             prepared_action_id,
             delivery,
             map_value(response, "summary")
           )
         ) do
      {:ok, updated_conversation, _turn, _telegram_result} ->
        summary = build_result_summary(message_class, prepared_action_id, state, liveness_summary)
        _ = maybe_refresh_user_memory(attrs)
        _ = maybe_compact_conversation_async(updated_conversation)

        {:ok, todo_digest_status(updated_conversation, prepared_action_id, message_class),
         summary}

      {:error, reason} ->
        {:error, run, reason, state}
    end
  end

  defp verified_message_class(message_class, response, state) do
    if should_force_todo_digest?(message_class, response, state) do
      "todo_digest"
    else
      message_class
    end
  end

  defp should_force_todo_digest?("todo_digest", _response, _state), do: false
  defp should_force_todo_digest?("approval_prompt", _response, _state), do: false

  defp should_force_todo_digest?(_message_class, response, state) do
    todos = latest_todo_items(state.tool_history)
    latest_todo_tool? = latest_todo_list_tool?(state.tool_history)
    bullet_list? = todo_bullet_list?(map_value(response, "assistant_message", ""))

    case {todos, latest_todo_tool?, bullet_list?} do
      {[], _latest_todo_tool?, _bullet_list?} -> false
      {_todos, true, _bullet_list?} -> true
      {_todos, _latest_todo_tool?, true} -> true
      _ -> false
    end
  end

  defp latest_todo_list_tool?(tool_history) when is_list(tool_history) do
    Enum.reverse(tool_history)
    |> Enum.any?(fn entry ->
      tool = map_value(entry, "tool")
      result = map_value(entry, "result")

      tool in ["list_todos", "resolve_todo"] and is_map(result) and has_todo_result?(result)
    end)
  end

  defp latest_todo_list_tool?(_tool_history), do: false

  defp has_todo_result?(result) when is_map(result) do
    case {map_value(result, "todos"), map_value(result, "remaining_todos")} do
      {todos, _remaining_todos} when is_list(todos) and todos != [] -> true
      {_todos, remaining_todos} when is_list(remaining_todos) and remaining_todos != [] -> true
      _ -> false
    end
  end

  defp has_todo_result?(_result), do: false

  defp todo_bullet_list?(text) when is_binary(text) do
    text
    |> String.split("\n")
    |> Enum.count(&Regex.match?(~r/^\s*(?:[-*•]|\d+[.)])\s+\S+/, &1))
    |> Kernel.>=(2)
  end

  defp todo_bullet_list?(_text), do: false

  defp standard_turn_opts(
         attrs,
         run,
         state,
         message_class,
         prepared_action_id,
         delivery,
         response_summary
       ) do
    [
      reply_to_message_id: Map.get(attrs, :source_message_id),
      turn_kind: turn_kind_for_message_class(message_class),
      origin_type: if(prepared_action_id, do: "prepared_action", else: "chat"),
      origin_id: prepared_action_id,
      structured_data: %{
        "run_id" => run.id,
        "tool_history" =>
          AssistantHarness.execution_evidence(state.tool_history, runner_policy_opts()),
        "summary" => response_summary,
        "message_class" => message_class
      }
    ]
    |> apply_delivery_mode(delivery)
    |> maybe_put_approval_markup(prepared_action_id, message_class)
  end

  defp send_todo_messages(conversation, attrs, run, todos) do
    Enum.reduce_while(todos, {:ok, conversation}, fn todo, {:ok, acc_conversation} ->
      todo_record = hydrate_todo_for_delivery(attrs, todo)
      payload = TodoActions.telegram_payload(todo_record)

      turn_opts = [
        send_mode: :send,
        turn_kind: "assistant_reply",
        origin_type: "chat",
        structured_data: %{
          "run_id" => run.id,
          "message_class" => "todo_item",
          "summary" => "Delivered one actionable todo item.",
          "linked_todo" => serialize_linked_todo(todo_record),
          "surface_quality" => SurfaceQuality.assess(todo_record)
        },
        telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup]
      ]

      case TelegramAssistant.send_turn(
             acc_conversation,
             Map.fetch!(attrs, :chat_id),
             payload.text,
             turn_opts
           ) do
        {:ok, updated_conversation, _turn, _telegram_result} ->
          {:cont, {:ok, updated_conversation}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp latest_todo_items(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value([], fn entry ->
      tool = map_value(entry, "tool")
      result = map_value(entry, "result")

      cond do
        tool == "resolve_todo" and is_map(result) ->
          case map_value(result, "remaining_todos") do
            todos when is_list(todos) -> todos
            _ -> nil
          end

        tool in ["upsert_todos", "list_todos"] and is_map(result) ->
          case map_value(result, "todos") do
            todos when is_list(todos) and todos != [] -> todos
            _ -> nil
          end

        true ->
          nil
      end
    end)
  end

  defp latest_todo_items(_tool_history), do: []

  defp hydrate_todo_for_delivery(attrs, %{"id" => todo_id} = todo) when is_binary(todo_id) do
    case Todos.get_for_user(Map.fetch!(attrs, :user_id), todo_id) do
      nil -> todo
      record -> record
    end
  end

  defp hydrate_todo_for_delivery(attrs, %{id: todo_id} = todo) when is_binary(todo_id) do
    case Todos.get_for_user(Map.fetch!(attrs, :user_id), todo_id) do
      nil -> todo
      record -> record
    end
  end

  defp hydrate_todo_for_delivery(_attrs, todo), do: todo

  defp serialize_linked_todo(%{"id" => _id} = todo), do: todo

  defp serialize_linked_todo(todo) when is_map(todo) do
    case map_value(todo, "id") do
      id when is_binary(id) -> Todos.serialize_for_prompt(todo)
      _ -> %{}
    end
  end

  defp serialize_linked_todo(_todo), do: %{}

  defp todo_digest_intro_text(response, prepared_action_id) do
    case map_value(response, "assistant_message", "") do
      value when is_binary(value) and value != "" ->
        if todo_bullet_list?(value) do
          "I found the current open items. I'm sending each with context."
        else
          value
        end

      _ ->
        case final_text(response, prepared_action_id) do
          "I finished that step." ->
            "I refreshed the current work list. I'm sending the actionable items one by one."

          value ->
            value
        end
    end
  end

  defp todo_digest_status(
         updated_conversation,
         prepared_action_id,
         message_class \\ "assistant_reply"
       ) do
    if message_class == "approval_prompt" and is_binary(prepared_action_id) do
      prepared_action = TelegramAssistant.get_prepared_action(prepared_action_id)

      {:ok, _conversation} =
        TelegramAssistant.mark_conversation_awaiting_action(
          updated_conversation,
          prepared_action
        )

      "waiting_confirmation"
    else
      "completed"
    end
  end

  defp final_text(response, prepared_action_id) do
    assistant_message = map_value(response, "assistant_message", "")

    cond do
      assistant_message != "" ->
        assistant_message

      is_binary(prepared_action_id) ->
        case TelegramAssistant.get_prepared_action(prepared_action_id) do
          %{preview_text: preview_text} -> preview_text
          _ -> "I prepared the requested action."
        end

      true ->
        "I finished that step."
    end
  end

  defp turn_kind_for_message_class("approval_prompt"), do: "approval_prompt"
  defp turn_kind_for_message_class("action_result"), do: "action_result"
  defp turn_kind_for_message_class("system_notice"), do: "system_notice"
  defp turn_kind_for_message_class(_message_class), do: "assistant_reply"

  defp trigger_type(attrs) do
    cond do
      is_binary(Map.get(attrs, :reply_to_message_id)) -> "reply"
      Map.get(attrs, :linked_delivery) -> "reply"
      true -> "inbound_message"
    end
  end

  defp maybe_compact_conversation_async(%Conversation{} = conversation) do
    if compaction_async_enabled?() do
      Task.start(fn ->
        try do
          TelegramConversations.compact_old_turns(conversation)
        rescue
          error ->
            Logger.warning("Telegram conversation compaction failed",
              conversation_id: conversation.id,
              reason: Exception.message(error)
            )
        end
      end)
    end

    :ok
  end

  defp maybe_compact_conversation_async(_conversation), do: :ok

  defp compaction_async_enabled? do
    case Application.get_env(:maraithon, __MODULE__, []) do
      keyword when is_list(keyword) ->
        Keyword.get(keyword, :compaction_async_enabled, true)

      _other ->
        true
    end
  end

  defp maybe_refresh_user_memory(attrs) do
    case Map.get(attrs, :user_id) do
      user_id when is_binary(user_id) ->
        if user_memory_async_enabled?() do
          Task.start(fn ->
            try do
              UserMemory.refresh_if_stale(user_id)
            rescue
              error ->
                Logger.warning("Telegram assistant user-memory refresh failed",
                  user_id: user_id,
                  reason: Exception.message(error)
                )
            end
          end)
        else
          UserMemory.refresh_if_stale(user_id)
        end

      _ ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("Telegram assistant user-memory refresh failed",
        user_id: inspect(Map.get(attrs, :user_id)),
        reason: Exception.message(error)
      )

      :ok
  end

  defp user_memory_async_enabled? do
    case Application.get_env(:maraithon, __MODULE__, []) do
      keyword when is_list(keyword) ->
        Keyword.get(keyword, :user_memory_async_enabled, true)

      _other ->
        true
    end
  end

  defp max_tool_steps do
    AssistantHarness.max_tool_steps(runner_policy_opts())
  end

  defp runner_policy_opts(runtime_context \\ %{}) do
    [max_wall_clock_ms: TelegramAssistant.hard_timeout_ms()]
    |> Keyword.merge(Map.get(runtime_context, :llm_opts, []))
  end

  defp attrs_with_model_profile(attrs, model_profile)
       when is_map(attrs) and is_map(model_profile) do
    attrs
    |> Map.put(:model_profile, model_profile)
    |> Map.put(:request_focus, Map.get(model_profile, :request_focus))
  end

  defp conversation_id(%Conversation{id: id}), do: id
  defp conversation_id(_conversation), do: nil

  defp execute_external_action(action_type, payload) do
    case action_type do
      "gmail_send" ->
        execute_tool_action("gmail_send_message", payload, "Sent via Gmail.")

      "slack_post" ->
        execute_tool_action("slack_post_message", payload, "Posted the Slack message.")

      "linear_create_issue" ->
        execute_tool_action("linear_create_issue", payload, "Created the Linear issue.")

      "linear_create_comment" ->
        execute_tool_action("linear_create_comment", payload, "Added the Linear comment.")

      "linear_update_issue_state" ->
        execute_tool_action(
          "linear_update_issue_state",
          payload,
          "Updated the Linear issue state."
        )

      "notaui_complete_task" ->
        execute_tool_action("notaui_complete_task", payload, "Completed the task in Notaui.")

      "notaui_update_task" ->
        execute_tool_action("notaui_update_task", payload, "Updated the task in Notaui.")

      _ ->
        {:error, "unsupported_prepared_action"}
    end
  end

  defp execute_tool_action(tool_name, payload, success_message) do
    policy_context = %{
      surface: "telegram",
      user_id: Map.get(payload, "user_id") || Map.get(payload, :user_id),
      confirmed?: true,
      confirmation_state: "confirmed"
    }

    case Tools.execute(tool_name, payload, policy_context) do
      {:ok, result} ->
        {:ok,
         result |> normalize_payload() |> ensure_map() |> Map.put("message", success_message)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp map_agent_result({:ok, result}, success_message) do
    {:ok, result |> normalize_payload() |> ensure_map() |> Map.put("message", success_message)}
  end

  defp map_agent_result({:error, reason}, _success_message), do: {:error, reason}

  defp map_project_result({:ok, result}, success_message) do
    {:ok, result |> normalize_payload() |> ensure_map() |> Map.put("message", success_message)}
  end

  defp map_project_result({:error, reason}, _success_message), do: {:error, reason}

  defp stringify_map(value), do: value |> normalize_payload() |> ensure_map()

  defp normalize_payload(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp normalize_payload(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp normalize_payload(%Date{} = value), do: Date.to_iso8601(value)
  defp normalize_payload(%Time{} = value), do: Time.to_iso8601(value)

  defp normalize_payload(value) when is_struct(value),
    do: value |> Map.from_struct() |> normalize_payload()

  defp normalize_payload(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {to_string(key), normalize_payload(nested_value)}
    end)
  end

  defp normalize_payload(value) when is_list(value), do: Enum.map(value, &normalize_payload/1)

  defp normalize_payload(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&normalize_payload/1)

  defp normalize_payload(value) when is_pid(value), do: inspect(value)
  defp normalize_payload(value) when is_reference(value), do: inspect(value)
  defp normalize_payload(value) when is_function(value), do: inspect(value)
  defp normalize_payload(value), do: value

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(value), do: %{"value" => value}

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Map.fetch(map, existing_atom_key(key)) do
          {:ok, value} -> value
          :error -> default
        end
    end
  end

  defp map_value(_map, _key, default), do: default

  defp existing_atom_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom_key(key), do: key

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)
end
