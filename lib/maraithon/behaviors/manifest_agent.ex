defmodule Maraithon.Behaviors.ManifestAgent do
  @moduledoc """
  Generic package-driven behavior backed by an agent manifest and markdown skills.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.AgentHarness.ConnectorCatalog
  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.Runner
  alias Maraithon.Behaviors
  alias Maraithon.Memory
  alias Maraithon.OpenLoops
  alias Maraithon.PromptBudget
  alias Maraithon.Tools.{ActionHelpers, ToolErrorCopy}

  @agent_error_fallback "That automation did not complete. Review the latest event before running it again."

  @impl true
  def init(config) do
    manifest = config["_harness_manifest"] || config["harness_manifest"] || %{}
    source_behavior = source_behavior(config)
    source_module = source_behavior_module(source_behavior)
    source_config = Map.drop(config, ["_harness_manifest", "harness_manifest"])

    %{
      manifest: Manifest.normalize(manifest),
      source_behavior: source_behavior,
      source_module: source_module,
      source_state: init_source_state(source_module, source_config),
      pending_source_effect?: false,
      last_message_id: nil,
      pending_tool_call: nil,
      tool_results: [],
      runs: 0
    }
  end

  @impl true
  def snapshot_state(%{source_module: module, source_state: source_state} = state)
      when is_atom(module) and not is_nil(module) do
    source_state =
      if function_exported?(module, :snapshot_state, 1),
        do: module.snapshot_state(source_state),
        else: source_state

    state
    |> Map.put(:source_state, source_state)
    |> Map.drop([:manifest, "manifest"])
    |> compact_tool_result_state()
    |> Maraithon.Behaviors.SnapshotTrim.trim()
  end

  def snapshot_state(state) when is_map(state) do
    state
    |> Map.drop([:manifest, "manifest"])
    |> compact_tool_result_state()
    |> Maraithon.Behaviors.SnapshotTrim.trim()
  end

  def snapshot_state(state), do: state

  @doc false
  def put_cycle_context(
        %{source_module: module, source_state: source_state} = state,
        cycle_context
      )
      when is_atom(module) and not is_nil(module) do
    if function_exported?(module, :put_cycle_context, 2),
      do: %{state | source_state: module.put_cycle_context(source_state, cycle_context)},
      else: state
  end

  def put_cycle_context(state, _cycle_context), do: state

  @doc false
  def pop_cycle_context(%{source_module: module, source_state: source_state} = state)
      when is_atom(module) and not is_nil(module) do
    if function_exported?(module, :pop_cycle_context, 1) do
      case module.pop_cycle_context(source_state) do
        {durable_source_state, cycle_context} ->
          {%{state | source_state: durable_source_state}, cycle_context}

        durable_source_state ->
          %{state | source_state: durable_source_state}
      end
    else
      state
    end
  end

  def pop_cycle_context(state), do: state

  @doc false
  @impl true
  def reconcile_restored_state(state, config) when is_map(state) do
    tool_results =
      state
      |> Map.get(:tool_results, Map.get(state, "tool_results", []))
      |> List.wrap()
      |> Enum.map(&normalize_restored_tool_result/1)
      |> Enum.take(10)

    state
    |> Map.put(:tool_results, tool_results)
    |> Map.update(:pending_tool_call, nil, &compact_pending_tool_call/1)
    |> reconcile_source_state(config)
  end

  def reconcile_restored_state(state, _config), do: state

  @impl true
  def handle_wakeup(state, context) do
    if state.source_module do
      state.source_module.handle_wakeup(state.source_state, context)
      |> route_source_result(state)
    else
      runtime_context =
        context
        |> compact_context()
        |> Map.put(
          :connector_catalog,
          ConnectorCatalog.for_user(context[:user_id], state.manifest)
        )

      case Runner.build_llm_params(state.manifest, runtime_context) do
        {:ok, params} ->
          {:effect, {:llm_call, params}, state}

        {:error, reason} ->
          emit_error(reason, state, context)
      end
    end
  end

  @impl true
  def handle_effect_result({:llm_call, response}, state, context) do
    if state.pending_source_effect? and state.source_module do
      state.source_module.handle_effect_result({:llm_call, response}, state.source_state, context)
      |> route_source_result(%{state | pending_source_effect?: false})
    else
      content = Map.get(response, :content) || Map.get(response, "content") || ""

      case decode_model_action(content) do
        {:tool_call, tool_name, args} ->
          if allowed_tool?(state.manifest, tool_name) do
            {:effect, {:tool_call, tool_name, args},
             %{state | pending_tool_call: %{tool: tool_name}, runs: state.runs + 1}}
          else
            emit_error("tool_not_allowed: #{tool_name}", %{state | runs: state.runs + 1}, context)
          end

        {:respond, message} ->
          emit_response(message, %{state | runs: state.runs + 1}, context)
      end
    end
  end

  @impl true
  def handle_effect_result({:tool_call, result}, state, context) do
    if state.pending_source_effect? and state.source_module do
      state.source_module.handle_effect_result({:tool_call, result}, state.source_state, context)
      |> route_source_result(%{state | pending_source_effect?: false})
    else
      tool_result = summarize_tool_result(state.pending_tool_call, result, context)

      state = %{
        state
        | pending_tool_call: nil,
          tool_results: Enum.take([tool_result | state.tool_results], 10)
      }

      runtime_context =
        context
        |> compact_context()
        |> Map.put(:tool_results, Enum.reverse(state.tool_results))
        |> Map.put(
          :connector_catalog,
          ConnectorCatalog.for_user(context[:user_id], state.manifest)
        )

      case Runner.build_llm_params(state.manifest, runtime_context) do
        {:ok, params} ->
          {:effect, {:llm_call, params}, state}

        {:error, reason} ->
          emit_error(reason, state, context)
      end
    end
  end

  @impl true
  def handle_effect_error(:llm_call, reason, state, context) do
    if state.pending_source_effect? and is_atom(state.source_module) and
         not is_nil(state.source_module) and
         function_exported?(state.source_module, :handle_effect_error, 4) do
      state.source_module.handle_effect_error(:llm_call, reason, state.source_state, context)
      |> route_source_result(%{state | pending_source_effect?: false})
    else
      emit_error(reason, state, context)
    end
  end

  @impl true
  def handle_effect_error(:tool_call, reason, state, context) do
    if state.pending_source_effect? and is_atom(state.source_module) and
         not is_nil(state.source_module) and
         function_exported?(state.source_module, :handle_effect_error, 4) do
      state.source_module.handle_effect_error(:tool_call, reason, state.source_state, context)
      |> route_source_result(%{state | pending_source_effect?: false})
    else
      emit_error(reason, state, context)
    end
  end

  @impl true
  def next_wakeup(%{source_module: module, source_state: source_state}) when not is_nil(module) do
    module.next_wakeup(source_state)
  end

  def next_wakeup(_state), do: :none

  defp reconcile_source_state(
         %{source_module: module, source_state: source_state} = state,
         config
       )
       when is_atom(module) and not is_nil(module) do
    source_config =
      if is_map(config),
        do: Map.drop(config, ["_harness_manifest", "harness_manifest"]),
        else: %{}

    source_state =
      if module == Maraithon.Behaviors.AIChiefOfStaff and
           function_exported?(module, :migrate_state, 3) do
        module.migrate_state(1, source_state, source_config)
      else
        source_state
      end

    source_state =
      if function_exported?(module, :reconcile_restored_state, 2),
        do: module.reconcile_restored_state(source_state, source_config),
        else: source_state

    %{state | source_state: source_state}
  end

  defp reconcile_source_state(state, _config), do: state

  defp compact_tool_result_state(state) do
    tool_results =
      state
      |> Map.get(:tool_results, [])
      |> List.wrap()
      |> Enum.map(&normalize_restored_tool_result/1)
      |> Enum.take(10)

    state
    |> Map.put(:tool_results, tool_results)
    |> Map.update(:pending_tool_call, nil, &compact_pending_tool_call/1)
  end

  defp summarize_tool_result(pending_tool_call, result, context) do
    %{
      tool: pending_tool_name(pending_tool_call),
      status: tool_result_status(result),
      summary: tool_result_summary(result),
      bytes: external_size(result),
      at: tool_result_timestamp(context)
    }
  end

  defp normalize_restored_tool_result(%{summary: summary} = result) do
    %{
      tool: Map.get(result, :tool),
      status: Map.get(result, :status, :ok),
      summary: bounded_summary(summary),
      bytes: Map.get(result, :bytes, external_size(summary)),
      at: Map.get(result, :at)
    }
  end

  defp normalize_restored_tool_result(%{"summary" => summary} = result) do
    %{
      tool: Map.get(result, "tool"),
      status: Map.get(result, "status", "ok"),
      summary: bounded_summary(summary),
      bytes: Map.get(result, "bytes", external_size(summary)),
      at: Map.get(result, "at")
    }
  end

  defp normalize_restored_tool_result({tool, result}) do
    summarize_tool_result(%{tool: tool}, result, %{})
  end

  defp normalize_restored_tool_result(%{} = result) do
    tool_call = Map.get(result, :tool_call, Map.get(result, "tool_call"))
    raw_result = Map.get(result, :result, Map.get(result, "result", result))
    summarize_tool_result(tool_call || result, raw_result, %{})
  end

  defp normalize_restored_tool_result(result),
    do: summarize_tool_result(nil, result, %{})

  defp compact_pending_tool_call(%{} = pending) do
    case pending_tool_name(pending) do
      nil -> nil
      tool -> %{tool: tool}
    end
  end

  defp compact_pending_tool_call(_pending), do: nil

  defp pending_tool_name(%{tool: tool}) when is_binary(tool), do: tool
  defp pending_tool_name(%{"tool" => tool}) when is_binary(tool), do: tool
  defp pending_tool_name(%{name: tool}) when is_binary(tool), do: tool
  defp pending_tool_name(%{"name" => tool}) when is_binary(tool), do: tool

  defp pending_tool_name(%{tool_call: tool_call}), do: pending_tool_name(tool_call)
  defp pending_tool_name(%{"tool_call" => tool_call}), do: pending_tool_name(tool_call)
  defp pending_tool_name(_pending), do: nil

  defp tool_result_status({:ok, _result}), do: :ok
  defp tool_result_status({:error, _reason}), do: :error
  defp tool_result_status(%{status: status}) when status in [:ok, :error], do: status
  defp tool_result_status(%{"status" => status}) when status in ["ok", "error"], do: status
  defp tool_result_status(_result), do: :ok

  defp tool_result_summary({:ok, result}), do: tool_result_summary(result)

  defp tool_result_summary({:error, reason}) do
    reason
    |> Maraithon.Redaction.error_summary()
    |> bounded_summary()
  end

  defp tool_result_summary(result) when is_binary(result), do: bounded_summary(result)

  defp tool_result_summary(result) do
    result
    |> inspect(pretty: false, limit: 30, printable_limit: 4_096)
    |> bounded_summary()
  end

  defp bounded_summary(value) when is_binary(value),
    do: PromptBudget.truncate_utf8(value, 2_048)

  defp bounded_summary(value), do: value |> inspect(pretty: false, limit: 20) |> bounded_summary()

  defp external_size(result) do
    :erlang.external_size(result)
  rescue
    _error -> 0
  end

  defp tool_result_timestamp(context) do
    case context[:timestamp] do
      %DateTime{} = timestamp -> DateTime.to_iso8601(timestamp)
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp source_behavior(config) when is_map(config) do
    case config["source_behavior"] || config[:source_behavior] do
      value when is_binary(value) and value not in ["", "manifest_agent"] -> value
      _ -> nil
    end
  end

  defp source_behavior(_config), do: nil

  defp source_behavior_module(nil), do: nil

  defp source_behavior_module(behavior) do
    if Behaviors.exists?(behavior), do: Behaviors.get!(behavior)
  end

  defp init_source_state(nil, _config), do: nil
  defp init_source_state(module, config), do: module.init(config)

  defp route_source_result({:effect, effect, source_state}, state) do
    {:effect, effect, %{state | source_state: source_state, pending_source_effect?: true}}
  end

  defp route_source_result({:emit, emit, source_state}, state) do
    {:emit, emit, %{state | source_state: source_state}}
  end

  defp route_source_result({:continue, source_state}, state) do
    {:continue, %{state | source_state: source_state}}
  end

  defp route_source_result({:idle, source_state}, state) do
    {:idle, %{state | source_state: source_state}}
  end

  defp compact_context(context) do
    %{
      agent_id: context[:agent_id],
      user_id: context[:user_id],
      timestamp: context[:timestamp],
      trigger: context[:trigger],
      event: context[:event],
      message: context[:last_message],
      message_metadata: context[:last_message_metadata],
      user_memory: context[:user_memory],
      deep_memory: context[:deep_memory],
      memory_tools: context[:memory_tools],
      open_loops: context[:open_loops],
      open_loop_tools: context[:open_loop_tools],
      tool_results: context[:tool_results] || []
    }
    |> Memory.enrich_context()
    |> OpenLoops.enrich_context()
  end

  defp decode_model_action(content) when is_binary(content) do
    with {:ok, decoded} <- Jason.decode(content),
         {:ok, action} <- decode_structured_action(decoded) do
      action
    else
      _ -> {:respond, content}
    end
  end

  defp decode_model_action(_content), do: {:respond, ""}

  defp decode_structured_action(%{"tool_call" => %{"name" => name, "args" => args}})
       when is_binary(name) and is_map(args) do
    {:ok, {:tool_call, name, args}}
  end

  defp decode_structured_action(%{"tool_call" => %{"tool" => name, "args" => args}})
       when is_binary(name) and is_map(args) do
    {:ok, {:tool_call, name, args}}
  end

  defp decode_structured_action(%{tool_call: %{name: name, args: args}})
       when is_binary(name) and is_map(args) do
    {:ok, {:tool_call, name, args}}
  end

  defp decode_structured_action(%{tool_call: %{tool: name, args: args}})
       when is_binary(name) and is_map(args) do
    {:ok, {:tool_call, name, args}}
  end

  defp decode_structured_action(%{"response" => response}) when is_binary(response) do
    {:ok, {:respond, response}}
  end

  defp decode_structured_action(%{response: response}) when is_binary(response) do
    {:ok, {:respond, response}}
  end

  defp decode_structured_action(_decoded), do: :error

  defp allowed_tool?(manifest, tool_name) do
    tool_name in Manifest.get(manifest, :tool_allowlist, [])
  end

  defp emit_error(reason, state, context) do
    {:emit,
     {:agent_error,
      %{
        error: error_text(reason),
        source: "manifest_agent",
        source_behavior: state.source_behavior,
        message_id: context[:last_message_id],
        correlation_id: get_in(context, [:last_message_metadata, "correlation_id"])
      }}, state}
  end

  defp error_text("model_not_configured") do
    "That automation is missing model configuration."
  end

  defp error_text({:model_not_configured, _details}) do
    "That automation is missing model configuration."
  end

  defp error_text("intelligence_not_configured") do
    "That automation is missing intelligence configuration."
  end

  defp error_text({:intelligence_not_configured, _details}) do
    "That automation is missing intelligence configuration."
  end

  defp error_text("tool_not_allowed:" <> _tool_name) do
    "That automation is not allowed to use that action."
  end

  defp error_text(reason) when is_binary(reason) do
    ToolErrorCopy.safe_message(reason, @agent_error_fallback)
  end

  defp error_text(reason), do: ActionHelpers.safe_error(reason, @agent_error_fallback)

  defp emit_response(message, state, context) do
    {:emit,
     {:agent_response,
      %{
        response: message,
        source: "manifest_agent",
        run_count: state.runs,
        message_id: context[:last_message_id],
        correlation_id: get_in(context, [:last_message_metadata, "correlation_id"])
      }}, %{state | last_message_id: context[:last_message_id]}}
  end
end
