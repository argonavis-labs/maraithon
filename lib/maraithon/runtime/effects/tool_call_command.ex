defmodule Maraithon.Runtime.Effects.ToolCallCommand do
  @moduledoc """
  Command implementation for `tool_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.ToolPolicy
  alias Maraithon.ToolPolicy.Decision
  alias Maraithon.Tools

  @impl true
  def prepare(%Effect{} = effect) do
    context = execution_context(effect)

    with {:ok, tool_module} <- Tools.fetch(context.tool_name),
         :ok <- authorize_package_tool(context.agent, context.tool_name),
         {:ok, decision} <- authorize_policy(context.policy_context) do
      {:ok,
       %{
         tool_module: tool_module,
         args: context.args,
         policy_context: context.policy_context,
         policy_decision: decision
       }}
    end
  end

  @impl true
  def execute_prepared(
        %Effect{},
        %{
          tool_module: tool_module,
          args: args,
          policy_context: policy_context,
          policy_decision: %Decision{status: :allow} = decision
        }
      )
      when is_atom(tool_module) and is_map(args) and is_map(policy_context) do
    Tools.execute_prepared(tool_module, args, policy_context, decision)
  end

  def execute_prepared(%Effect{}, _prepared), do: {:error, :invalid_tool_preflight}

  @impl true
  def execute(%Effect{} = effect) do
    context = execution_context(effect)

    with :ok <- authorize_package_tool(context.agent, context.tool_name) do
      Tools.execute(context.tool_name, context.args, context.policy_context)
    end
  end

  defp execution_context(%Effect{} = effect) do
    tool_name = if is_map(effect.params), do: effect.params["tool"]

    agent =
      case effect.agent_id do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          Agents.get_agent(agent_id, include_removed: true)

        _ ->
          nil
      end

    user_id = trusted_effect_user_id(effect, agent)
    raw_args = if is_map(effect.params), do: effect.params["args"]
    args = bind_user_id(raw_args, user_id)

    policy_context = %{
      surface: "runtime",
      agent_id: effect.agent_id,
      user_id: user_id,
      confirmed?: is_map(effect.params) and effect.params["confirmed"] == true,
      confirmation_state: if(is_map(effect.params), do: effect.params["confirmation_state"]),
      tool_name: tool_name,
      arguments: args,
      tool_metadata: Tools.policy_metadata_for(tool_name)
    }

    %{agent: agent, tool_name: tool_name, args: args, policy_context: policy_context}
  end

  defp authorize_policy(policy_context) do
    case ToolPolicy.authorize(policy_context) do
      %Decision{status: :allow} = decision ->
        {:ok, decision}

      %Decision{status: :deny} = decision ->
        {:error, {:tool_policy_denied, Decision.to_map(decision)}}

      %Decision{status: :needs_confirmation} = decision ->
        {:error, {:tool_policy_needs_confirmation, Decision.to_map(decision)}}
    end
  end

  defp authorize_package_tool(nil, _tool_name), do: :ok
  defp authorize_package_tool(%{agent_package_version_id: nil}, _tool_name), do: :ok

  defp authorize_package_tool(%{agent_package_version_id: version_id}, tool_name)
       when is_binary(version_id) and is_binary(tool_name) do
    case Agents.get_agent_package_version(version_id) do
      %{tool_allowlist: allowlist} when is_list(allowlist) ->
        if tool_name in allowlist, do: :ok, else: {:error, :tool_not_allowed}

      _missing_or_invalid_version ->
        {:error, :tool_not_allowed}
    end
  end

  defp authorize_package_tool(_agent, _tool_name), do: {:error, :tool_not_allowed}

  # Tool arguments originate with the model. Tenant identity only comes from
  # the persisted agent and is shared by both policy enforcement and execution.
  defp bind_user_id(args, user_id) do
    args = if is_map(args), do: Map.drop(args, ["user_id", :user_id]), else: %{}

    if is_binary(user_id), do: Map.put(args, "user_id", user_id), else: args
  end

  defp trusted_effect_user_id(
         %Effect{owner_user_id: owner_user_id},
         %{user_id: owner_user_id, status: status, install_status: install_status}
       )
       when is_binary(owner_user_id) and byte_size(owner_user_id) in 1..255 and
              status in ["running", "degraded"] and install_status == "enabled" do
    if String.valid?(owner_user_id) and String.trim(owner_user_id) != "", do: owner_user_id
  end

  defp trusted_effect_user_id(_effect, _agent), do: nil
end
