defmodule Maraithon.Runtime.Effects.ToolCallCommand do
  @moduledoc """
  Command implementation for `tool_call` effects.
  """

  @behaviour Maraithon.Runtime.Effects.Command

  alias Maraithon.Agents
  alias Maraithon.Effects.Effect
  alias Maraithon.Tools

  @impl true
  def execute(%Effect{} = effect) do
    tool_name = effect.params["tool"]

    agent =
      case effect.agent_id do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          Agents.get_agent(agent_id, include_removed: true)

        _ ->
          nil
      end

    user_id = trusted_effect_user_id(effect, agent)
    args = bind_user_id(effect.params["args"], user_id)

    policy_context = %{
      surface: "runtime",
      agent_id: effect.agent_id,
      user_id: user_id,
      confirmed?: effect.params["confirmed"] == true,
      confirmation_state: effect.params["confirmation_state"]
    }

    with :ok <- authorize_package_tool(agent, tool_name) do
      case Tools.execute(tool_name, args, policy_context) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
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
