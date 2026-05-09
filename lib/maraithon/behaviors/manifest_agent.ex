defmodule Maraithon.Behaviors.ManifestAgent do
  @moduledoc """
  Generic package-driven behavior backed by an agent manifest and markdown skills.
  """

  @behaviour Maraithon.Behaviors.Behavior

  alias Maraithon.AgentHarness.ConnectorCatalog
  alias Maraithon.AgentHarness.Manifest
  alias Maraithon.AgentHarness.Runner
  alias Maraithon.Behaviors

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
             %{state | pending_tool_call: %{tool: tool_name, args: args}, runs: state.runs + 1}}
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
      tool_result = %{
        tool_call: state.pending_tool_call,
        result: result
      }

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
    if state.pending_source_effect? and state.source_module and
         function_exported?(state.source_module, :handle_effect_error, 4) do
      state.source_module.handle_effect_error(:llm_call, reason, state.source_state, context)
      |> route_source_result(%{state | pending_source_effect?: false})
    else
      emit_error(reason, state, context)
    end
  end

  @impl true
  def handle_effect_error(:tool_call, reason, state, context) do
    if state.pending_source_effect? and state.source_module and
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
      tool_results: context[:tool_results] || []
    }
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

  defp error_text(reason) when is_binary(reason), do: reason
  defp error_text(reason), do: inspect(reason)

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
