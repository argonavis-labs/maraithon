defmodule Maraithon.TelegramAssistant.Runner do
  @moduledoc """
  Bounded multi-step runner for Telegram assistant chat and prepared actions.
  """

  import Ecto.Query

  alias Maraithon.AssistantHarness
  alias Maraithon.ActionLedger
  alias Maraithon.ActionCards
  alias Maraithon.Calendar.FreeBlocks
  alias Maraithon.ChiefOfStaff.SourceScope
  alias Maraithon.Connectors.GoogleCalendar
  alias Maraithon.ContextEngine
  alias Maraithon.Memory
  alias Maraithon.OperatorEvents
  alias Maraithon.Projects
  alias Maraithon.Projects.Project
  alias Maraithon.PromptBudget
  alias Maraithon.Repo
  alias Maraithon.Runtime
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.ProactiveCandidate

  alias Maraithon.TelegramAssistant.{
    ConnectedContextPreflight,
    ModelRouting,
    PreferenceConfirmationCopy,
    Run,
    TodoActions,
    Toolbox
  }

  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos
  alias Maraithon.Todos.UserFacingCopy
  alias Maraithon.Todos.SurfaceQuality
  alias Maraithon.Tools
  alias Maraithon.Tracing
  alias Maraithon.UserMemory

  require Logger

  @max_retained_tool_result_bytes 32_000
  @legacy_turn_scan_limit 500

  def run_inbound(attrs) when is_map(attrs) do
    Tracing.with_span(
      "telegram_assistant.run_inbound",
      %{
        chat_id: Map.get(attrs, :chat_id),
        trigger_type: trigger_type(attrs)
      },
      fn ->
        case maybe_resume_durable_delivery(attrs) do
          :pass -> do_run_inbound(attrs)
          result -> result
        end
      end
    )
  end

  # SPEC 09 R1: the Run row is minted (with a placeholder prompt_snapshot)
  # and the liveness session started BEFORE the slow context-build +
  # preflight block, so typing/progress feedback covers exactly the turns
  # that feel slowest. The real prompt_snapshot is backfilled once context
  # is built. R0's ChatWorker-level typing ping covers the routing window
  # (profile_for/1, including the bounded classifier call) that still runs
  # ahead of this.
  defp do_run_inbound(attrs) do
    model_profile = ModelRouting.profile_for(attrs)
    context_attrs = attrs_with_model_profile(attrs, model_profile)
    conversation = Map.get(attrs, :conversation)

    with {:ok, run} <- start_run(attrs, %{}, model_profile),
         _ = maybe_start_liveness_session(run, attrs),
         {:ok, context} <- build_context_and_preflight(run, attrs, context_attrs) do
      run = backfill_prompt_snapshot(run, context)
      run_prepared_turn(run, attrs, context, conversation, model_profile)
    else
      {:error, reason} ->
        {:fallback, reason}
    end
  end

  defp maybe_resume_durable_delivery(attrs) do
    conversation = Map.get(attrs, :conversation)
    source_message_id = Map.get(attrs, :source_message_id)

    if durable_processing?(attrs) and match?(%Conversation{}, conversation) and
         is_binary(source_message_id) do
      case TelegramAssistant.resumable_delivery_run(conversation.id, source_message_id) do
        %Run{} = run -> resume_checkpointed_delivery(run, conversation, attrs)
        nil -> :pass
      end
    else
      :pass
    end
  end

  defp resume_checkpointed_delivery(%Run{} = run, %Conversation{} = conversation, attrs) do
    checkpoint = map_value(run.result_summary || %{}, "delivery_checkpoint", %{})

    case map_value(checkpoint, "kind") do
      "todo_digest" -> resume_todo_digest_delivery(run, conversation, attrs)
      "standard" -> resume_standard_delivery(run, conversation, attrs)
      _unknown -> :pass
    end
  end

  defp resume_standard_delivery(%Run{} = run, %Conversation{} = conversation, attrs) do
    checkpoint = map_value(run.result_summary || %{}, "delivery_checkpoint", %{})
    status = map_value(checkpoint, "completion_status", "completed")
    summary = map_value(checkpoint, "completion_summary", %{})

    case drain_standard_delivery(conversation, attrs, run, checkpoint) do
      {:ok, _conversation} ->
        case TelegramAssistant.complete_run(run, %{status: status, result_summary: summary}) do
          {:ok, _completed_run} -> :ok
          {:error, reason} -> {:error, {:run_completion_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_todo_digest_delivery(%Run{} = run, %Conversation{} = conversation, attrs) do
    checkpoint = map_value(run.result_summary || %{}, "delivery_checkpoint", %{})
    prepared_action_id = map_value(checkpoint, "prepared_action_id")
    summary = map_value(checkpoint, "completion_summary", %{})

    case drain_todo_digest_delivery(conversation, attrs, run) do
      {:ok, final_conversation} ->
        case TelegramAssistant.complete_run(run, %{
               status: todo_digest_status(final_conversation, prepared_action_id),
               result_summary: summary
             }) do
          {:ok, _completed_run} -> :ok
          {:error, reason} -> {:error, {:run_completion_failed, reason}}
        end

      {:error, reason} ->
        _ = fail_run_preserving_summary(run, reason)
        {:error, reason}
    end
  end

  # SPEC 09 R2: after the reorder, a crash inside context build/preflight
  # would otherwise leave a Run parked at "running" forever with an orphaned
  # LivenessSession still ticking — the same "stuck durable state, nothing
  # notices" class as the 2026-07-03 incident. Tear both down and fall back
  # exactly like a start_run failure.
  defp build_context_and_preflight(run, attrs, context_attrs) do
    context = ContextEngine.build_context(context_attrs)
    context = ConnectedContextPreflight.apply(context, preflight_attrs(context_attrs, run, attrs))
    {:ok, context}
  rescue
    error ->
      teardown_failed_context_build(run, error)
  catch
    :exit, reason ->
      teardown_failed_context_build(run, {:exit, reason})

    :throw, value ->
      teardown_failed_context_build(run, {:throw, value})
  end

  defp teardown_failed_context_build(run, reason) do
    _ = TelegramAssistant.cancel_liveness_session(run.id)
    {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")

    Logger.warning("Telegram assistant context build failed after run start",
      run_reference: Maraithon.Redaction.fingerprint(run.id),
      reason: Maraithon.Redaction.error_summary(reason)
    )

    {:error, reason}
  end

  # SPEC 09 R4: thread the run id into preflight so the existing
  # "relationships" liveness hint can fire during the up-to-8s synchronous
  # review window. Mobile runs have no liveness session, matching the
  # note_context_loaded(%Run{surface: "mobile"}) skip.
  defp preflight_attrs(context_attrs, run, attrs) do
    if surface(attrs) == "mobile" do
      context_attrs
    else
      Map.put(context_attrs, :liveness_run_id, run.id)
    end
  end

  defp backfill_prompt_snapshot(run, context) do
    case TelegramAssistant.update_run(run, %{
           prompt_snapshot: ContextEngine.prompt_snapshot(context)
         }) do
      {:ok, updated_run} ->
        updated_run

      {:error, reason} ->
        Logger.warning("Telegram assistant prompt snapshot backfill failed",
          run_reference: Maraithon.Redaction.fingerprint(run.id),
          reason: Maraithon.Redaction.error_summary(reason)
        )

        run
    end
  end

  defp run_prepared_turn(run, attrs, context, conversation, model_profile) do
    runtime_context = build_runtime_context(run, attrs, context, model_profile)

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
        |> Map.put(:task_class, Map.get(runtime_context, :task_class))
        |> Map.put(:route_reason, Map.get(runtime_context, :route_reason))

      {:ok, _run} =
        TelegramAssistant.complete_run(run, %{status: status, result_summary: summary})

      :ok
    else
      {:fallback, reason} ->
        _ = TelegramAssistant.cancel_liveness_session(run.id)
        {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")

        Logger.warning("Telegram assistant falling back to legacy interpreter",
          reason: Maraithon.Redaction.error_summary(reason)
        )

        {:fallback, reason}

      {:error, %Run{} = run, {:final_delivery_failed, delivery_reason}, state} ->
        if durable_processing?(attrs) do
          _ = TelegramAssistant.cancel_liveness_session(run.id)
          _ = fail_run_preserving_summary(run, delivery_reason)
          {:error, delivery_reason}
        else
          handle_run_failure(run, delivery_reason, state, attrs)
        end

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
          {:error, _reason} = error -> error
          :pass -> handle_run_failure(run, reason, state, attrs)
        end

      {:error, reason} ->
        _ = TelegramAssistant.cancel_liveness_session(run.id)
        {:ok, _run} = TelegramAssistant.fail_run(run, reason, "degraded")
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
    if escalatable_reason?(reason) and Map.get(model_profile, :tier) in [:chat, :fast] do
      _ = TelegramAssistant.cancel_liveness_session(original_run.id)

      escalated_profile = ModelRouting.escalated_profile_for(model_profile)

      Logger.info("Escalating Telegram assistant turn to reasoning model",
        run_id: original_run.id,
        reason: Maraithon.Redaction.error_summary(reason),
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

        {:error, _reason} = error ->
          error
      end
    else
      :pass
    end
  end

  defp maybe_escalate_and_retry(_run, _reason, _attrs, _context, _conversation, _profile),
    do: :pass

  defp run_escalated_turn(attrs, context, conversation, model_profile, original_run, reason) do
    # The queued run carried in attrs belongs to the original attempt; reusing
    # it here collides on the (run_id, sequence) step index. The escalated
    # turn gets its own run row.
    attrs = Map.delete(attrs, :run)

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
            |> Map.put(:task_class, Map.get(runtime_context, :task_class))
            |> Map.put(:route_reason, Map.get(runtime_context, :route_reason))
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

          {:error, %Run{} = retry_run, {:final_delivery_failed, delivery_reason}, retry_state} ->
            if durable_processing?(attrs) do
              _ = TelegramAssistant.cancel_liveness_session(retry_run.id)
              _ = fail_run_preserving_summary(retry_run, delivery_reason)
              {:error, delivery_reason}
            else
              handle_run_failure(retry_run, delivery_reason, retry_state, attrs)
            end

          {:error, %Run{} = retry_run, retry_reason, retry_state} ->
            handle_run_failure(retry_run, retry_reason, retry_state, attrs)

          {:error, retry_reason} ->
            _ = TelegramAssistant.cancel_liveness_session(run.id)
            {:ok, _run} = TelegramAssistant.fail_run(run, retry_reason, "degraded")
            :pass
        end

      {:error, _reason} ->
        :pass
    end
  end

  defp escalatable_reason?(:deeper_analysis_requested), do: true
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
    frozen_payload = prepared_action.payload || %{}
    payload = external_prepared_action_payload(frozen_payload)

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
        execute_project_create(payload, prepared_action)

      "project_update" ->
        case Projects.get_project(Map.fetch!(payload, "project_id")) do
          nil ->
            {:error, :project_not_found}

          project ->
            Projects.update_project(project, Map.fetch!(payload, "attrs"))
            |> map_project_result("Updated the project.")
        end

      action_type ->
        execute_external_action(action_type, payload, prepared_action, frozen_payload)
    end
  end

  defp start_run(attrs, context, model_profile) do
    run_attrs = %{
      user_id: Map.fetch!(attrs, :user_id),
      chat_id: Map.fetch!(attrs, :chat_id),
      surface: surface(attrs),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      trigger_type: trigger_type(attrs),
      status: "running",
      model_provider: TelegramAssistant.model_provider_name(),
      model_name: Map.get(model_profile, :model) || TelegramAssistant.model_name(),
      prompt_snapshot: ContextEngine.prompt_snapshot(context),
      result_summary: route_summary(model_profile),
      started_at: Map.get(attrs, :started_at) || DateTime.utc_now()
    }

    case Map.get(attrs, :run) do
      %Run{} = run -> TelegramAssistant.update_run(run, run_attrs)
      _ -> TelegramAssistant.start_run(run_attrs)
    end
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
          |> maybe_offer_deeper_analysis(runtime_context)
          |> Map.put(:_stream_target, runtime_context.run_id)
          |> Map.put(
            :_llm_opts,
            loop_llm_opts(runtime_context, started_monotonic_ms, policy_opts)
          )

        now = DateTime.utc_now()

        Tracing.with_span(
          "telegram_assistant.llm_request",
          %{
            run_id: run.id,
            iteration: state.iteration,
            llm_turns: state.llm_turns,
            model: Map.get(runtime_context, :model_name),
            model_tier: Map.get(runtime_context, :model_tier),
            task_class: Map.get(runtime_context, :task_class),
            route_reason: Map.get(runtime_context, :route_reason)
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

  defp loop_llm_opts(runtime_context, started_monotonic_ms, policy_opts) do
    deadline =
      started_monotonic_ms + AssistantHarness.runtime_policy(policy_opts).loop.max_wall_clock_ms

    llm_opts = Map.get(runtime_context, :llm_opts, [])
    llm_opts = if is_list(llm_opts), do: llm_opts, else: []
    Keyword.put(llm_opts, :deadline_monotonic_ms, deadline)
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
      _ = maybe_record_correction(run, runtime_context, response)
      next_state = %{state | llm_turns: state.llm_turns + 1, sequence: state.sequence + 2}
      handle_llm_response(run, runtime_context, response, next_state, started_monotonic_ms)
    else
      {:error, reason} ->
        {:error, run, reason, state}
    end
  end

  # SPEC 07 R6: deterministically writes a `kind: "correction"` memory
  # whenever the model's step contract marks this turn as a correction
  # (`AssistantHarness.normalize/2`'s `"correction"` field), regardless of
  # whether the model also calls the `write_memory` tool. Best-effort — a
  # failure here never fails the turn.
  defp maybe_record_correction(run, runtime_context, response) do
    case Map.get(response, "correction") do
      %{"detected" => true} = correction ->
        user_id = Map.get(runtime_context, :user_id)

        case Memory.record_correction(user_id, correction,
               source: "assistant_correction",
               run_id: run.id
             ) do
          {:ok, item} ->
            Logger.info("Recorded deterministic correction memory",
              run_reference: Maraithon.Redaction.fingerprint(run.id),
              memory_id: item.id,
              kind: Map.get(correction, "kind")
            )

          {:error, reason} ->
            Logger.warning("Failed to record correction memory",
              run_reference: Maraithon.Redaction.fingerprint(run.id),
              reason: Maraithon.Redaction.error_summary(reason)
            )
        end

      _other ->
        :ok
    end

    :ok
  rescue
    error ->
      Logger.warning("Correction memory recording crashed",
        failure_code: Maraithon.Redaction.error_class(error)
      )

      :ok
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

  @deeper_analysis_tool_name "request_deeper_analysis"
  @deeper_analysis_tool %{
    "name" => @deeper_analysis_tool_name,
    "description" =>
      "Hand this request to the deeper reasoning model. Call this instead of attempting a " <>
        "weak answer when the request needs multi-source analysis, planning, prioritization, " <>
        "or careful judgment beyond a quick reply. The turn restarts on the stronger model " <>
        "with full context, so call it before doing other work.",
    "parameters" => %{
      "type" => "object",
      "properties" => %{
        "reason" => %{
          "type" => "string",
          "description" => "One sentence on why deeper analysis is needed."
        }
      }
    }
  }

  # Offered only on the fast/chat tiers (after focus filtering, so every
  # scope can still escalate); the reasoning tier has nowhere to go.
  defp maybe_offer_deeper_analysis(payload, runtime_context) do
    if escalation_capable?(runtime_context) do
      Map.update(payload, :tools, [@deeper_analysis_tool], &(&1 ++ [@deeper_analysis_tool]))
    else
      payload
    end
  end

  defp escalation_capable?(runtime_context) do
    Map.get(runtime_context, :model_tier) in [:chat, :fast]
  end

  defp deeper_analysis_requested?(tool_calls) when is_list(tool_calls) do
    Enum.any?(tool_calls, &(Map.get(&1, "tool") == @deeper_analysis_tool_name))
  end

  defp deeper_analysis_requested?(_tool_calls), do: false

  defp execute_tool_calls(run, runtime_context, tool_calls, state, started_monotonic_ms) do
    cond do
      deeper_analysis_requested?(tool_calls) and escalation_capable?(runtime_context) ->
        {:error, run, :deeper_analysis_requested, state}

      state.tool_steps + length(tool_calls) > max_tool_steps(runtime_context) ->
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

    policy = AssistantHarness.runtime_policy(runner_policy_opts(runtime_context))
    deadline = started_monotonic_ms + policy.loop.max_wall_clock_ms
    remaining_ms = max(deadline - System.monotonic_time(:millisecond), 1)

    # These tasks must stay linked to the Runner owner. Durable ChatWorker
    # timeout/claim-loss kills that owner; linked tool calls then terminate
    # before a retry can overlap the abandoned execution. `*_nolink` would
    # leave independently supervised provider work running after the owner died.
    results =
      Task.Supervisor.async_stream(
        Maraithon.Runtime.ToolCallSupervisor,
        indexed_calls,
        fn {tool_call, sequence} ->
          try do
            run_single_tool_call(run, runtime_context, tool_call, sequence)
          rescue
            exception ->
              {:error, {:tool_task_failed, Maraithon.Redaction.error_class(exception)}}
          catch
            kind, _reason -> {:error, {:tool_task_failed, to_string(kind)}}
          end
        end,
        ordered: true,
        timeout: remaining_ms,
        on_timeout: :kill_task,
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

      case toolbox_module().execute(tool_name, arguments, runtime_context) do
        {:ok, result} ->
          bounded_result = bounded_tool_result(result)

          {:ok, _completed_tool_step} =
            TelegramAssistant.complete_step(tool_step, %{
              response_payload: bounded_result,
              finished_at: DateTime.utc_now()
            })

          {:ok,
           %{
             "tool" => tool_name,
             "arguments" => arguments,
             "result" => bounded_result
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

  @doc false
  def bounded_tool_result(result) do
    required = required_tool_result_fields(result)

    if ProactiveCandidate.safe_json_shape?(result, @max_retained_tool_result_bytes) do
      compacted =
        PromptBudget.bounded(result, 24_000,
          string_bytes: 4_000,
          list_items: 50,
          map_entries: 100,
          max_depth: 6,
          key_bytes: 255
        ) || %{}

      compacted
      |> ensure_result_map()
      |> Map.merge(required)
    else
      Map.put(required, "_truncated", true)
    end
  end

  defp required_tool_result_fields(result) when is_map(result) do
    [
      {"id", :id},
      {"status", :status},
      {"success", :success},
      {"ok", :ok},
      {"message_id", :message_id},
      {"thread_id", :thread_id},
      {"todo_id", :todo_id},
      {"event_id", :event_id},
      {"draft_id", :draft_id},
      {"task_id", :task_id},
      {"project_id", :project_id},
      {"source_id", :source_id},
      {"provider_id", :provider_id},
      {"external_id", :external_id}
    ]
    |> Enum.reduce(%{}, fn {key, atom_key}, acc ->
      value = Map.get(result, key, Map.get(result, atom_key))

      case bounded_required_result_value(value) do
        nil -> acc
        bounded -> Map.put(acc, key, bounded)
      end
    end)
  end

  defp required_tool_result_fields(_result), do: %{}

  defp bounded_required_result_value(value) when is_binary(value),
    do: PromptBudget.truncate_utf8(value, 255)

  defp bounded_required_result_value(value)
       when is_integer(value) and value >= -9_223_372_036_854_775_808 and
              value <= 9_223_372_036_854_775_807,
       do: value

  defp bounded_required_result_value(value) when is_boolean(value), do: value
  defp bounded_required_result_value(_value), do: nil

  defp ensure_result_map(value) when is_map(value), do: value
  defp ensure_result_map(value), do: %{"value" => value}

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

    delivery =
      resolve_effective_delivery(delivery, liveness_summary, run, Map.get(attrs, :chat_id))

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

  defp deliver_final_response(_conversation, run, _response, state, _attrs) do
    {:error, run, :missing_conversation, state}
  end

  defp handle_run_failure(run, reason, state, attrs) do
    _ = Tracing.record_error(reason)

    {:ok, %{delivery: delivery, summary: liveness_summary}} =
      TelegramAssistant.prepare_final_delivery(run.id)

    delivery =
      resolve_effective_delivery(delivery, liveness_summary, run, Map.get(attrs, :chat_id))

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

    case {state.tool_history, Map.get(attrs, :conversation)} do
      {_history, %Conversation{} = conversation} ->
        case TelegramAssistant.send_turn(
               conversation,
               Map.fetch!(attrs, :chat_id),
               AssistantHarness.failure_message(reason),
               reply_to_message_id: Map.get(attrs, :source_message_id),
               send_mode: send_mode_for_delivery(delivery, attrs),
               message_id: delivery[:message_id],
               turn_kind: "system_notice",
               origin_type: "system",
               structured_data: %{
                 "run_id" => run.id,
                 "surface" => surface(attrs),
                 "error" => normalize_error(reason)
               }
             ) do
          {:ok, _conversation, _turn, _result} -> :ok
          {:error, send_reason} -> {:error, {:telegram_send_failed, send_reason}}
          other -> {:error, {:invalid_telegram_send_result, other}}
        end

      _ ->
        {:error, :missing_failure_delivery_conversation}
    end
  end

  # `LivenessSession` never actually hands back `:suppress_after_timeout`
  # today (it always resolves to `:send` or `:edit`), but this guards against
  # any delivery path that would otherwise end a timed-out run with no
  # user-visible message. If the "still working" notice was never actually
  # delivered, force a plain send of the final response/failure message. If
  # it was delivered, prefer editing that message in place over staying
  # silent.
  defp resolve_effective_delivery(
         %{mode: :suppress_after_timeout} = delivery,
         liveness_summary,
         run,
         chat_id
       ) do
    notice_delivered? = Map.get(liveness_summary || %{}, "timeout_notice_sent", false)
    message_id = Map.get(delivery, :message_id)

    effective_delivery =
      if notice_delivered? and is_binary(message_id) do
        %{mode: :edit, message_id: message_id}
      else
        %{mode: :send}
      end

    Logger.warning(
      "[telegram_fallback] Liveness timeout suppression overridden to guarantee delivery",
      run_reference: Maraithon.Redaction.fingerprint(run.id),
      chat_reference: Maraithon.Redaction.fingerprint(chat_id),
      timeout_notice_delivered: notice_delivered?,
      resolved_mode: effective_delivery.mode
    )

    _ =
      record_timeout_suppression_fallback(
        run,
        chat_id,
        notice_delivered?,
        effective_delivery.mode
      )

    effective_delivery
  end

  defp resolve_effective_delivery(delivery, _liveness_summary, _run, _chat_id), do: delivery

  defp record_timeout_suppression_fallback(run, chat_id, notice_delivered?, resolved_mode) do
    OperatorEvents.record(%{
      user_id: run.user_id,
      source: "telegram",
      event_type: "telegram_fallback.timeout_suppression_overridden",
      source_item_id: run.id,
      dedupe_key: "telegram_fallback:timeout_suppression_overridden:#{run.id}",
      payload: %{
        "run_id" => run.id,
        "chat_id" => chat_id,
        "timeout_notice_delivered" => notice_delivered?,
        "resolved_delivery_mode" => to_string(resolved_mode)
      }
    })
  rescue
    error ->
      Logger.warning(
        "[telegram_fallback] failed to record timeout suppression operator event",
        run_reference: Maraithon.Redaction.fingerprint(run.id),
        failure_code: Maraithon.Redaction.error_class(error)
      )

      :ok
  end

  defp maybe_record_loop_failure(
         run,
         {:assistant_harness_tool_loop_detected, tool, count, class, loop},
         state
       ) do
    ActionLedger.record(%{
      user_id: run.user_id,
      surface: run_surface(run),
      event_type: "model.uncertainty",
      status: "failed",
      source_evidence: %{
        tool_history_length: length(state.tool_history || []),
        latest_tool: tool
      },
      model_summary: "Assistant tool loop stopped before repeating work.",
      remediation_hint: "Run a focused source lookup or inspect the latest tool result manually.",
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
      surface: surface(attrs),
      conversation_id: conversation_id(Map.get(attrs, :conversation)),
      context: context,
      model_tier: Map.get(model_profile, :tier),
      model_name: Map.get(model_profile, :model),
      model_reasoning_effort: Map.get(model_profile, :reasoning_effort),
      task_class: Map.get(model_profile, :task_class),
      route_reason: Map.get(model_profile, :route_reason),
      llm_opts: Map.get(model_profile, :llm_opts, []),
      default_project_id:
        Map.get(defaults, :default_project_id) || defaults["default_project_id"],
      default_project_slug:
        Map.get(defaults, :default_project_slug) || defaults["default_project_slug"],
      default_slack_team_id: default_slack_team_id(Map.fetch!(attrs, :user_id))
    }
  end

  defp default_slack_team_id(user_id) when is_binary(user_id) do
    user_id
    |> SourceScope.resolve()
    |> SourceScope.slack_team_ids()
    |> List.first()
  end

  defp default_slack_team_id(_user_id), do: nil

  defp maybe_start_liveness_session(run, attrs) do
    if surface(attrs) == "mobile" do
      :ok
    else
      case TelegramAssistant.start_liveness_session(run, attrs) do
        {:ok, _pid} ->
          :ok

        {:error, :disabled} ->
          :ok

        {:error, reason} ->
          Logger.warning("Telegram assistant liveness session failed to start",
            run_reference: Maraithon.Redaction.fingerprint(run.id),
            reason: Maraithon.Redaction.error_summary(reason)
          )

          :ok
      end
    end
  end

  defp route_summary(model_profile) do
    %{
      model_tier: route_value(Map.get(model_profile, :tier)),
      model_name: Map.get(model_profile, :model),
      model_reasoning_effort: Map.get(model_profile, :reasoning_effort),
      task_class: route_value(Map.get(model_profile, :task_class)),
      route_reason: route_value(Map.get(model_profile, :route_reason))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp route_value(value) when is_atom(value), do: Atom.to_string(value)
  defp route_value(value), do: value

  defp note_context_loaded(%Run{surface: "mobile"}), do: :ok

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

  defp send_mode_for_delivery(%{mode: :edit}, attrs) do
    if surface(attrs) == "mobile", do: :persist, else: :edit
  end

  defp send_mode_for_delivery(_delivery, attrs) do
    if surface(attrs) == "mobile", do: :persist, else: :reply
  end

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

      summary =
        build_result_summary("todo_digest", prepared_action_id, state, liveness_summary)
        |> Map.put(:todo_items_sent, length(todos))
        |> Map.put(:todo_ids, Enum.map(todos, &map_value(&1, "id")))

      with {:ok, checkpointed_run} <-
             checkpoint_todo_digest_delivery(
               run,
               attrs,
               intro_text,
               todos,
               prepared_action_id,
               summary,
               delivery
             ),
           {:ok, final_conversation} <-
             drain_todo_digest_delivery(conversation, attrs, checkpointed_run) do
        _ = maybe_refresh_user_memory(attrs)
        _ = maybe_compact_conversation_async(final_conversation)

        {:ok, todo_digest_status(final_conversation, prepared_action_id), summary}
      else
        {:error, reason} ->
          {:error, run, {:final_delivery_failed, reason}, state}
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
    text = final_text(response, prepared_action_id, state)

    completion_summary =
      build_result_summary(message_class, prepared_action_id, state, liveness_summary)

    completion_status =
      standard_completion_status(conversation, prepared_action_id, message_class)

    turn_opts =
      standard_turn_opts(
        attrs,
        run,
        state,
        message_class,
        prepared_action_id,
        delivery,
        map_value(response, "summary")
      )
      |> Keyword.put(:client_message_id, final_turn_client_message_id(run.id))

    checkpoint =
      standard_delivery_checkpoint(
        run,
        attrs,
        text,
        turn_opts,
        completion_status,
        completion_summary,
        delivery
      )

    with {:ok, checkpointed_run} <- checkpoint_standard_delivery(run, checkpoint),
         {:ok, updated_conversation} <-
           drain_standard_delivery(conversation, attrs, checkpointed_run, checkpoint) do
      _ = maybe_refresh_user_memory(attrs)
      _ = maybe_compact_conversation_async(updated_conversation)

      {:ok, completion_status, completion_summary}
    else
      {:error, reason} ->
        checkpointed_run =
          case TelegramAssistant.resumable_delivery_run(
                 run.conversation_id,
                 Map.get(attrs, :source_message_id)
               ) do
            %Run{id: id} = persisted when id == run.id -> persisted
            _missing -> run
          end

        {:error, checkpointed_run, {:final_delivery_failed, reason}, state}
    end
  end

  defp standard_completion_status(conversation, prepared_action_id, message_class) do
    # This performs the same awaiting-confirmation local transition as the old
    # post-send status helper, but before the delivery checkpoint is drained.
    # Repeating it during a durable retry is idempotent.
    todo_digest_status(conversation, prepared_action_id, message_class)
  end

  defp standard_delivery_checkpoint(
         run,
         attrs,
         text,
         turn_opts,
         completion_status,
         completion_summary,
         delivery
       ) do
    %{
      "kind" => "standard",
      "source_message_id" => Map.get(attrs, :source_message_id),
      "text" => text,
      "client_message_id" => final_turn_client_message_id(run.id),
      "turn_kind" => Keyword.get(turn_opts, :turn_kind, "assistant_reply"),
      "origin_type" => Keyword.get(turn_opts, :origin_type, "chat"),
      "origin_id" => Keyword.get(turn_opts, :origin_id),
      "structured_data" => normalize_payload(Keyword.get(turn_opts, :structured_data, %{})),
      "terminal_response" => Keyword.get(turn_opts, :terminal_response, true),
      "preserve_safe_label_prefixes" =>
        Keyword.get(turn_opts, :preserve_safe_label_prefixes, false),
      "approval_markup" => Keyword.has_key?(turn_opts, :telegram_opts),
      "completion_status" => completion_status,
      "completion_summary" => normalize_payload(completion_summary),
      "delivery_mode" => delivery |> Map.get(:mode, :send) |> to_string(),
      "delivery_message_id" => Map.get(delivery, :message_id),
      "surface" => surface(attrs)
    }
  end

  defp checkpoint_standard_delivery(%Run{} = run, checkpoint) do
    summary = (run.result_summary || %{}) |> Map.put("delivery_checkpoint", checkpoint)
    TelegramAssistant.update_run(run, %{result_summary: summary})
  end

  defp drain_standard_delivery(
         %Conversation{} = conversation,
         attrs,
         %Run{} = run,
         checkpoint
       ) do
    checkpoint =
      checkpoint || map_value(run.result_summary || %{}, "delivery_checkpoint", %{})

    client_message_id =
      map_value(checkpoint, "client_message_id", final_turn_client_message_id(run.id))

    case TelegramConversations.find_turn_by_client_message_id(
           conversation.id,
           client_message_id
         ) do
      %Turn{} ->
        {:ok, conversation}

      nil ->
        opts = standard_checkpoint_turn_opts(checkpoint, attrs)

        case TelegramAssistant.send_turn(
               conversation,
               Map.fetch!(attrs, :chat_id),
               map_value(checkpoint, "text", "I finished that step."),
               opts
             ) do
          {:ok, updated_conversation, _turn, _delivery_result} ->
            {:ok, updated_conversation}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp standard_checkpoint_turn_opts(checkpoint, attrs) do
    opts = [
      reply_to_message_id: map_value(checkpoint, "source_message_id"),
      client_message_id: map_value(checkpoint, "client_message_id"),
      turn_kind: map_value(checkpoint, "turn_kind", "assistant_reply"),
      origin_type: map_value(checkpoint, "origin_type", "chat"),
      origin_id: map_value(checkpoint, "origin_id"),
      terminal_response: map_value(checkpoint, "terminal_response", true),
      preserve_safe_label_prefixes: map_value(checkpoint, "preserve_safe_label_prefixes", false),
      structured_data: map_value(checkpoint, "structured_data", %{})
    ]

    opts =
      if map_value(checkpoint, "approval_markup", false) do
        case map_value(checkpoint, "origin_id") do
          id when is_binary(id) ->
            Keyword.put(opts, :telegram_opts,
              reply_markup: Maraithon.TelegramResponder.action_markup(id)
            )

          _missing ->
            opts
        end
      else
        opts
      end

    opts
    |> apply_delivery_mode(checkpoint_delivery(checkpoint))
    |> apply_mobile_delivery(attrs)
  end

  defp final_turn_client_message_id(run_id), do: "assistant-run-final:#{run_id}"

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
        "surface" => surface(attrs),
        "prepared_action_id" => prepared_action_id,
        "tool_history" =>
          AssistantHarness.execution_evidence(state.tool_history, runner_policy_opts()),
        "summary" => response_summary,
        "message_class" => message_class
      }
    ]
    |> apply_delivery_mode(delivery)
    |> maybe_put_approval_markup(prepared_action_id, message_class)
    |> apply_mobile_delivery(attrs)
  end

  defp checkpoint_todo_digest_delivery(
         %Run{} = run,
         attrs,
         intro_text,
         todos,
         prepared_action_id,
         completion_summary,
         delivery
       ) do
    checkpoint = %{
      "kind" => "todo_digest",
      "source_message_id" => Map.get(attrs, :source_message_id),
      "intro_text" => intro_text,
      "todos" => normalize_payload(todos),
      "prepared_action_id" => prepared_action_id,
      "completion_summary" => normalize_payload(completion_summary),
      "delivery_mode" => delivery |> Map.get(:mode, :send) |> to_string(),
      "delivery_message_id" => Map.get(delivery, :message_id)
    }

    summary =
      (run.result_summary || %{})
      |> Map.put("delivery_checkpoint", checkpoint)

    TelegramAssistant.update_run(run, %{result_summary: summary})
  end

  defp drain_todo_digest_delivery(%Conversation{} = conversation, attrs, %Run{} = run) do
    checkpoint = map_value(run.result_summary || %{}, "delivery_checkpoint", %{})
    todos = map_value(checkpoint, "todos", [])

    with true <- map_value(checkpoint, "kind") == "todo_digest",
         true <- is_list(todos) and todos != [],
         {:ok, conversation} <-
           maybe_send_todo_digest_intro(conversation, attrs, run, checkpoint),
         delivered_todo_ids <- delivered_todo_ids(conversation.id, run.id),
         {:ok, conversation} <-
           send_todo_messages(conversation, attrs, run, todos, delivered_todo_ids) do
      {:ok, conversation}
    else
      false -> {:error, :invalid_todo_digest_delivery_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_send_todo_digest_intro(conversation, attrs, run, checkpoint) do
    if digest_intro_delivered?(conversation.id, run.id) do
      {:ok, conversation}
    else
      turn_opts =
        [
          reply_to_message_id: Map.get(attrs, :source_message_id),
          turn_kind: "assistant_reply",
          origin_type: "chat",
          terminal_response: false,
          structured_data: %{
            "run_id" => run.id,
            "surface" => surface(attrs),
            "message_class" => "todo_digest_intro",
            "summary" => "Open-work digest introduction. Item delivery is still in progress."
          }
        ]
        |> apply_delivery_mode(checkpoint_delivery(checkpoint))
        |> apply_mobile_delivery(attrs)

      case TelegramAssistant.send_turn(
             conversation,
             Map.fetch!(attrs, :chat_id),
             map_value(checkpoint, "intro_text", "Here are the current open items."),
             turn_opts
           ) do
        {:ok, updated_conversation, _turn, _telegram_result} -> {:ok, updated_conversation}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp checkpoint_delivery(checkpoint) do
    case map_value(checkpoint, "delivery_mode") do
      "edit" -> %{mode: :edit, message_id: map_value(checkpoint, "delivery_message_id")}
      _ -> %{mode: :send}
    end
  end

  defp digest_intro_delivered?(conversation_id, run_id) do
    delivered? =
      Turn
      |> where([turn], turn.conversation_id == ^conversation_id)
      |> where([turn], turn.delivery_state == "delivered")
      |> where([turn], turn.assistant_run_id == ^run_id)
      |> where([turn], turn.message_class == "todo_digest_intro")
      |> Repo.exists?()

    delivered? or legacy_digest_intro_delivered?(conversation_id, run_id)
  end

  defp legacy_digest_intro_delivered?(conversation_id, run_id) do
    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> where([turn], turn.delivery_state == "delivered")
    |> where([turn], is_nil(turn.structured_data))
    |> where([turn], is_nil(turn.assistant_run_id) and is_nil(turn.message_class))
    |> order_by([turn], desc: turn.inserted_at)
    |> limit(@legacy_turn_scan_limit)
    |> Repo.all()
    |> Enum.map(&Turn.hydrate/1)
    |> Enum.any?(fn turn ->
      Turn.effective_assistant_run_id(turn) == run_id and
        Turn.effective_message_class(turn) == "todo_digest_intro"
    end)
  end

  defp delivered_todo_ids(conversation_id, run_id) do
    promoted_ids =
      Turn
      |> where([turn], turn.conversation_id == ^conversation_id)
      |> where([turn], turn.delivery_state == "delivered")
      |> where([turn], turn.assistant_run_id == ^run_id)
      |> where([turn], turn.message_class == "todo_item")
      |> where([turn], not is_nil(turn.linked_todo_id))
      |> select([turn], turn.linked_todo_id)
      |> distinct(true)
      |> Repo.all()
      |> MapSet.new()

    Turn
    |> where([turn], turn.conversation_id == ^conversation_id)
    |> where([turn], turn.delivery_state == "delivered")
    |> where([turn], is_nil(turn.structured_data))
    |> where([turn], is_nil(turn.assistant_run_id) and is_nil(turn.message_class))
    |> order_by([turn], desc: turn.inserted_at)
    |> limit(@legacy_turn_scan_limit)
    |> Repo.all()
    |> Enum.map(&Turn.hydrate/1)
    |> Enum.reduce(promoted_ids, fn turn, delivered ->
      if Turn.effective_assistant_run_id(turn) == run_id and
           Turn.effective_message_class(turn) == "todo_item" do
        case Turn.effective_linked_todo_id(turn) do
          id when is_binary(id) -> MapSet.put(delivered, id)
          _missing -> delivered
        end
      else
        delivered
      end
    end)
  end

  defp send_todo_messages(conversation, attrs, run, todos, delivered_todo_ids) do
    final_index = length(todos) - 1

    todos
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, conversation}, fn {todo, index}, {:ok, acc_conversation} ->
      todo_id = map_value(todo, "id")

      if is_binary(todo_id) and MapSet.member?(delivered_todo_ids, todo_id) do
        {:cont, {:ok, acc_conversation}}
      else
        todo_record = hydrate_todo_for_delivery(attrs, todo)
        payload = todo_delivery_payload(attrs, todo_record)

        turn_opts = [
          reply_to_message_id: Map.get(attrs, :source_message_id),
          send_mode: if(surface(attrs) == "mobile", do: :persist, else: :send),
          turn_kind: "assistant_reply",
          origin_type: "chat",
          terminal_response: index == final_index,
          preserve_safe_label_prefixes: true,
          structured_data: %{
            "run_id" => run.id,
            "surface" => surface(attrs),
            "message_class" => "todo_item",
            "summary" => "Delivered one open work item.",
            "linked_todo" => serialize_linked_todo(todo_record),
            "surface_quality" => SurfaceQuality.assess(todo_record)
          },
          telegram_opts: payload.telegram_opts
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
      end
    end)
  end

  defp apply_mobile_delivery(turn_opts, attrs) do
    if surface(attrs) == "mobile" do
      turn_opts
      |> Keyword.put(:send_mode, :persist)
      |> Keyword.delete(:telegram_opts)
    else
      turn_opts
    end
  end

  defp todo_delivery_payload(attrs, todo_record) do
    if surface(attrs) == "mobile" do
      %{
        text: mobile_todo_text(todo_record),
        telegram_opts: []
      }
    else
      telegram_payload = TodoActions.telegram_payload(todo_record)

      %{
        text: telegram_payload.text,
        telegram_opts: [parse_mode: "HTML", reply_markup: telegram_payload.reply_markup]
      }
    end
  end

  defp mobile_todo_text(todo) do
    ActionCards.render_mobile_todo(todo, include_disconnected: false)
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
        polished_todo_digest_intro(value)

      _ ->
        case final_text(response, prepared_action_id) do
          "I finished that step." ->
            "The current work list is refreshed. Each item is ready for a decision."

          value ->
            value
        end
    end
  end

  defp polished_todo_digest_intro(value) when is_binary(value) do
    value = String.trim(value)

    intro =
      cond do
        todo_bullet_list?(value) ->
          "Here are the current open items. Each one has the context needed for a decision."

        process_todo_digest_intro?(value) ->
          value
          |> String.replace(
            ~r/\s*(I'm|I am)\s+sending\s+(the\s+)?actionable\s+items\s+one\s+by\s+one\.?/iu,
            " Each item is ready for a decision."
          )
          |> String.replace(
            ~r/\s*(I'm|I am)\s+sending\s+each\s+with\s+context\.?/iu,
            " Each item has the context needed for a decision."
          )
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        true ->
          value
      end

    UserFacingCopy.open_work_language(intro)
    |> polish_todo_digest_remaining_intro()
    |> polish_todo_digest_first_person_intro()
  end

  defp polish_todo_digest_remaining_intro(value) when is_binary(value) do
    value
    |> String.replace(
      ~r/\bhere(?:'s|\s+is)\s+what\s+is\s+still\s+open\.?/iu,
      "The remaining work is ready for a decision."
    )
    |> String.replace(
      ~r/\bhere(?:'s|\s+is)\s+what(?:'s|\s+is)\s+still\s+open\.?/iu,
      "The remaining work is ready for a decision."
    )
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp polish_todo_digest_remaining_intro(value), do: value

  defp process_todo_digest_intro?(value) when is_binary(value) do
    String.match?(
      value,
      ~r/\b(sending\s+(the\s+)?actionable\s+items\s+one\s+by\s+one|sending\s+each\s+with\s+context)\b/iu
    )
  end

  defp polish_todo_digest_first_person_intro(value) when is_binary(value) do
    value
    |> then(fn copy ->
      Regex.replace(~r/^\s*I refreshed ([^.]+)\.\s*/iu, copy, fn _, subject ->
        "#{capitalize_sentence_start(subject)} is refreshed. "
      end)
    end)
    |> String.replace(
      ~r/^\s*I found the current open work items\.?/iu,
      "Here are the current open work items."
    )
    |> String.trim()
  end

  defp polish_todo_digest_first_person_intro(value), do: value

  defp capitalize_sentence_start(value) when is_binary(value) do
    case String.trim(value) do
      <<first::utf8, rest::binary>> -> String.upcase(<<first::utf8>>) <> rest
      "" -> ""
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
        UserFacingCopy.open_work_language(assistant_message)

      is_binary(prepared_action_id) ->
        case TelegramAssistant.get_prepared_action(prepared_action_id) do
          %{preview_text: preview_text} -> UserFacingCopy.open_work_language(preview_text)
          _ -> UserFacingCopy.open_work_language("I prepared the requested action.")
        end

      true ->
        UserFacingCopy.open_work_language("I finished that step.")
    end
  end

  defp final_text(response, prepared_action_id, state) do
    case pending_preference_confirmation_rules(state.tool_history) do
      [] ->
        response
        |> final_text(prepared_action_id)
        |> maybe_replace_generic_final_text(response, prepared_action_id, state)

      rules ->
        PreferenceConfirmationCopy.text(rules)
    end
  end

  defp maybe_replace_generic_final_text(text, _response, prepared_action_id, _state)
       when is_binary(prepared_action_id),
       do: text

  defp maybe_replace_generic_final_text(text, response, _prepared_action_id, state) do
    if generic_completion_text?(text) do
      response
      |> response_or_tool_result_text(state.tool_history)
      |> case do
        replacement when is_binary(replacement) and replacement != "" -> replacement
        _ -> text
      end
    else
      text
    end
  end

  defp generic_completion_text?(text) when is_binary(text) do
    normalized =
      text
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[.!?]+$/u, "")

    normalized in [
      "done",
      "reviewed",
      "work reviewed",
      "open work reviewed",
      "checked open work",
      "reviewed open work",
      "i checked your open work",
      "i reviewed your open work",
      "completed",
      "completed the check",
      "finished",
      "finished that step",
      "i finished that step",
      "that is done"
    ]
  end

  defp generic_completion_text?(_text), do: false

  defp response_or_tool_result_text(response, tool_history) do
    [
      tool_result_text(tool_history),
      response_summary_text(response)
    ]
    |> Enum.find(&present_string?/1)
  end

  defp response_summary_text(response) when is_map(response) do
    response
    |> map_value("summary")
    |> case do
      value when is_binary(value) and value != "" ->
        if generic_completion_text?(value),
          do: nil,
          else: UserFacingCopy.open_work_language(value)

      _ ->
        nil
    end
  end

  defp response_summary_text(_response), do: nil

  defp tool_result_text(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value(fn entry ->
      tool = map_value(entry, "tool")
      result = map_value(entry, "result")

      if is_map(result) do
        tool_result_summary(tool, result)
      end
    end)
  end

  defp tool_result_text(_tool_history), do: nil

  defp tool_result_summary(tool, result)
       when tool in ["list_todos", "open_work"] and is_map(result) do
    case map_value(result, "todos") do
      [] -> "No saved open work matched this request."
      _ -> tool_result_summary(result)
    end
  end

  defp tool_result_summary(_tool, result), do: tool_result_summary(result)

  defp tool_result_summary(result) when is_map(result) do
    summary = map_value(result, "summary")
    next_action = map_value(result, "next_action")

    cond do
      present_string?(summary) and present_string?(next_action) and
          not same_sentence?(summary, next_action) ->
        UserFacingCopy.open_work_language("#{summary}\n\nNext: #{next_action}")

      present_string?(summary) ->
        UserFacingCopy.open_work_language(summary)

      present_string?(next_action) ->
        UserFacingCopy.open_work_language(next_action)

      true ->
        nil
    end
  end

  defp tool_result_summary(_result), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp same_sentence?(left, right) when is_binary(left) and is_binary(right) do
    normalize_sentence(left) == normalize_sentence(right)
  end

  defp same_sentence?(_left, _right), do: false

  defp normalize_sentence(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/[.!?]+$/u, "")
  end

  defp turn_kind_for_message_class("approval_prompt"), do: "approval_prompt"
  defp turn_kind_for_message_class("action_result"), do: "action_result"
  defp turn_kind_for_message_class("system_notice"), do: "system_notice"
  defp turn_kind_for_message_class(_message_class), do: "assistant_reply"

  defp pending_preference_confirmation_rules(tool_history) when is_list(tool_history) do
    tool_history
    |> Enum.reverse()
    |> Enum.find_value([], fn entry ->
      case {map_value(entry, "tool"), map_value(entry, "result")} do
        {"remember_preferences", result} when is_map(result) ->
          if preference_confirmation_required?(result) do
            result
            |> map_value("saved_rules", [])
            |> pending_rules_from_list()
            |> case do
              [] -> result |> map_value("pending_rules", []) |> pending_rules_from_list()
              rules -> rules
            end
          else
            false
          end

        _ ->
          false
      end
    end)
  end

  defp pending_preference_confirmation_rules(_tool_history), do: []

  defp preference_confirmation_required?(result) do
    map_value(result, "status") == "awaiting_confirmation" or
      map_value(result, "requires_confirmation") == true
  end

  defp pending_rules_from_list(rules) when is_list(rules) do
    Enum.filter(rules, fn
      rule when is_map(rule) -> map_value(rule, "status") in ["pending_confirmation", nil]
      _ -> false
    end)
  end

  defp pending_rules_from_list(_rules), do: []

  defp trigger_type(attrs) do
    cond do
      is_binary(Map.get(attrs, :reply_to_message_id)) -> "reply"
      Map.get(attrs, :linked_delivery) -> "reply"
      true -> "inbound_message"
    end
  end

  defp surface(attrs) when is_map(attrs) do
    case Map.get(attrs, :surface) || Map.get(attrs, "surface") do
      "mobile" -> "mobile"
      :mobile -> "mobile"
      _ -> "telegram"
    end
  end

  defp surface(_attrs), do: "telegram"

  defp run_surface(%Run{surface: surface}) when surface in ["telegram", "mobile"], do: surface
  defp run_surface(_run), do: "telegram"

  defp maybe_compact_conversation_async(%Conversation{} = conversation) do
    if compaction_async_enabled?() do
      Task.start(fn ->
        try do
          TelegramConversations.compact_old_turns(conversation)
        rescue
          error ->
            Logger.warning("Telegram conversation compaction failed",
              conversation_id: conversation.id,
              failure_code: Maraithon.Redaction.error_class(error)
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
                  user_fingerprint: Maraithon.Redaction.fingerprint(user_id),
                  failure_code: Maraithon.Redaction.error_class(error)
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
        user_fingerprint: Maraithon.Redaction.fingerprint(Map.get(attrs, :user_id)),
        failure_code: Maraithon.Redaction.error_class(error)
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

  defp max_tool_steps(runtime_context) do
    AssistantHarness.max_tool_steps(runner_policy_opts(runtime_context))
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

  defp execute_project_create(payload, prepared_action) do
    user_id = Map.fetch!(payload, "user_id")
    attrs = Map.fetch!(payload, "attrs")

    case project_created_for_prepared_action(user_id, prepared_action.id) do
      %Project{} = project ->
        map_project_result({:ok, project}, "Created the project.")

      nil ->
        metadata =
          case Map.get(attrs, "metadata") || Map.get(attrs, :metadata) do
            %{} = metadata -> metadata
            _ -> %{}
          end

        attrs =
          attrs
          |> Map.put(
            "metadata",
            Map.put(metadata, "_maraithon_prepared_action_id", prepared_action.id)
          )

        Projects.create_project(user_id, attrs)
        |> map_project_result("Created the project.")
    end
  end

  defp project_created_for_prepared_action(user_id, prepared_action_id) do
    Project
    |> where(
      [project],
      project.user_id == ^user_id and
        fragment(
          "?->>'_maraithon_prepared_action_id' = ?",
          project.metadata,
          ^prepared_action_id
        )
    )
    |> limit(1)
    |> Repo.one()
  end

  defp execute_external_action(action_type, payload, prepared_action, frozen_payload) do
    case action_type do
      "gmail_send" ->
        execute_tool_action("gmail_send_message", payload, "Sent via Gmail.", prepared_action)

      "gmail_draft_send" ->
        with :ok <-
               maybe_update_frozen_gmail_draft(frozen_payload, payload, prepared_action) do
          payload = Map.put(payload || %{}, "action", "send")
          execute_tool_action("gmail_drafts", payload, "Sent the Gmail draft.", prepared_action)
        end

      "slack_post" ->
        execute_tool_action(
          "slack_post_message",
          payload,
          "Posted the Slack message.",
          prepared_action
        )

      "linear_create_issue" ->
        execute_tool_action(
          "linear_create_issue",
          payload,
          "Created the Linear issue.",
          prepared_action
        )

      "linear_create_comment" ->
        execute_tool_action(
          "linear_create_comment",
          payload,
          "Added the Linear comment.",
          prepared_action
        )

      "linear_update_issue_state" ->
        execute_tool_action(
          "linear_update_issue_state",
          payload,
          "Updated the Linear issue state.",
          prepared_action
        )

      "notaui_complete_task" ->
        execute_tool_action(
          "notaui_complete_task",
          payload,
          "Completed the task in Notaui.",
          prepared_action
        )

      "notaui_update_task" ->
        execute_tool_action(
          "notaui_update_task",
          payload,
          "Updated the task in Notaui.",
          prepared_action
        )

      # SPEC 04 R10: the confirmed action of a PersonMergeSuggestions card
      # invokes the already-existing merge_people assistant tool. This is
      # the only path that reaches Crm.merge_people/4 from a suggestion —
      # and only after explicit human confirmation.
      "merge_people" ->
        execute_tool_action(
          "merge_people",
          payload,
          "Merged the duplicate person records.",
          prepared_action
        )

      # SPEC 12 R4: calendar block creation is NOT routed through the plain
      # `execute_tool_action/4` helper because it needs two extra steps —
      # the fresh double-booking recheck (R10, plus the past-start guard)
      # before the connector call, and the deterministic client event id
      # (R7) derived from this prepared action for idempotent retries.
      "calendar_create_event" ->
        execute_calendar_create_event(payload, prepared_action)

      # SPEC 12 R9: lifecycle actions against the block Maraithon created.
      # Ownership-marker verification (R8) happens inside the tools, before
      # any Google mutation.
      "calendar_update_event" ->
        execute_tool_action(
          "calendar_update_event",
          payload,
          "Updated the calendar block.",
          prepared_action
        )

      "calendar_cancel_event" ->
        execute_tool_action(
          "calendar_cancel_event",
          payload,
          "Cancelled the calendar block.",
          prepared_action
        )

      _ ->
        {:error, "unsupported_prepared_action"}
    end
  end

  defp maybe_update_frozen_gmail_draft(frozen_payload, payload, prepared_action) do
    if Map.get(frozen_payload || %{}, "_maraithon_update_draft_before_send") == true do
      update_payload = Map.put(payload || %{}, "action", "update")

      case execute_tool_action(
             "gmail_drafts",
             update_payload,
             "Updated the frozen Gmail draft.",
             prepared_action
           ) do
        {:ok, _result} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp external_prepared_action_payload(payload) when is_map(payload) do
    Map.reject(payload, fn {key, _value} ->
      is_binary(key) and String.starts_with?(key, "_maraithon_")
    end)
  end

  defp external_prepared_action_payload(_payload), do: %{}

  defp execute_calendar_create_event(payload, prepared_action) do
    payload = payload || %{}
    user_id = Map.get(payload, "user_id") || Map.get(payload, :user_id)
    client_event_id = calendar_client_event_id(prepared_action.id)

    with {:ok, start_at, end_at} <- calendar_block_window(payload),
         :ok <- ensure_calendar_block_in_future(start_at),
         :ok <- ensure_calendar_slot_free(user_id, start_at, end_at, client_event_id) do
      execute_tool_action(
        "calendar_create_event",
        Map.put(payload, "client_event_id", client_event_id),
        "Booked the block on your calendar.",
        prepared_action
      )
    end
  end

  # SPEC 12 R7: deterministic RFC2938 base32hex id (lowercase a-v, 0-9)
  # derived from the prepared action, so a retried confirm or a retried HTTP
  # call inside execute is idempotent at Google's side.
  defp calendar_client_event_id(prepared_action_id) do
    :crypto.hash(:sha256, "calendar_create_event:" <> to_string(prepared_action_id))
    |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp calendar_block_window(payload) do
    with start_raw when is_binary(start_raw) <- Map.get(payload, "start_at"),
         end_raw when is_binary(end_raw) <- Map.get(payload, "end_at"),
         {:ok, start_at, _} <- DateTime.from_iso8601(start_raw),
         {:ok, end_at, _} <- DateTime.from_iso8601(end_raw),
         :lt <- DateTime.compare(start_at, end_at) do
      {:ok, start_at, end_at}
    else
      _ -> {:error, "invalid_calendar_block_window"}
    end
  end

  # SPEC 12 edge case: the confirmation window (default 15 min) can outlive
  # the proposed slot — never create a block in the past.
  defp ensure_calendar_block_in_future(start_at) do
    if DateTime.compare(start_at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, "calendar_block_start_passed"}
    end
  end

  # SPEC 12 R10: a genuinely fresh read immediately before creating — never
  # a cached proposal-time fetch. On conflict, fail honestly instead of
  # silently picking a different time. All-day events don't block timed work
  # (same rule as `FreeBlocks`), and this action's own event (already
  # created by a prior lost-response attempt, R7) is not a conflict.
  defp ensure_calendar_slot_free(user_id, start_at, end_at, client_event_id) do
    case GoogleCalendar.events_in_window(user_id, start_at, end_at) do
      {:ok, events} ->
        conflict? =
          Enum.any?(events, fn event ->
            Map.get(event, :event_id) != client_event_id and
              overlaps_window?(FreeBlocks.event_interval(event), start_at, end_at)
          end)

        if conflict?, do: {:error, "slot_no_longer_free"}, else: :ok

      {:error, reason} ->
        # The recheck read failed (no token, reauth, transient API error):
        # fail honestly rather than creating a block that was never verified
        # free. Reuse the calendar tool's error translation so the failure
        # copy matches the connector-error vocabulary.
        {:error,
         Maraithon.Tools.CalendarCreateEvent.translate_error(reason, "check the calendar")}
    end
  end

  defp overlaps_window?(nil, _start_at, _end_at), do: false

  defp overlaps_window?({event_start, event_end}, start_at, end_at) do
    DateTime.compare(event_start, end_at) == :lt and
      DateTime.compare(event_end, start_at) == :gt
  end

  defp execute_tool_action(tool_name, payload, success_message, prepared_action) do
    policy_context = %{
      surface: Map.get(prepared_action, :surface) || "telegram",
      user_id: Map.get(payload, "user_id") || Map.get(payload, :user_id),
      confirmed?: true,
      confirmation_state: "confirmed",
      preserve_provider_errors: true
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

  defp fail_run_preserving_summary(%Run{} = run, reason) do
    current_run = (Repo.get(Run, run.id) || run) |> Run.hydrate_payloads()

    TelegramAssistant.complete_run(current_run, %{
      status: "degraded",
      error: normalize_error(reason),
      result_summary: current_run.result_summary || %{}
    })
  end

  defp toolbox_module do
    Application.get_env(:maraithon, :telegram_assistant, [])
    |> Keyword.get(:toolbox_module, Toolbox)
  end

  defp durable_processing?(attrs) when is_map(attrs),
    do: Map.get(attrs, :durable_processing, false) == true

  defp durable_processing?(_attrs), do: false

  defp normalize_error(error), do: Maraithon.Redaction.error_summary(error)
end
