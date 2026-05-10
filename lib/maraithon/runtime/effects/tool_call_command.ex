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
    args = effect.params["args"] || %{}

    agent =
      case effect.agent_id do
        agent_id when is_binary(agent_id) and agent_id != "" ->
          Agents.get_agent(agent_id, include_removed: true)

        _ ->
          nil
      end

    policy_context = %{
      surface: "runtime",
      agent_id: effect.agent_id,
      user_id: Map.get(args, "user_id") || agent_user_id(agent),
      confirmed?: effect.params["confirmed"] == true,
      confirmation_state: effect.params["confirmation_state"]
    }

    case Tools.execute(tool_name, args, policy_context) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_user_id(%{user_id: user_id}), do: user_id
  defp agent_user_id(_agent), do: nil
end
