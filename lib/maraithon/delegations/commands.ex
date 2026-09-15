defmodule Maraithon.Delegations.Commands do
  @moduledoc "Admission for reducer commands. The identity/control slice cannot dispatch external work."
  alias Maraithon.Delegations.{Actions, Gates}

  def apply(delegation, grant, _event, commands, _now) do
    Enum.reduce(commands, delegation, fn command, current ->
      execute(current, grant, command)
    end)
  end

  defp execute(d, _, command) when command in [:cancel_unentered, :supersede_unentered] do
    Actions.supersede_unentered!(d)
    d
  end

  defp execute(d, grant, {:cancel_unentered, _}), do: execute(d, grant, :cancel_unentered)
  defp execute(d, _, :notify_user), do: d
  defp execute(d, _, :transition_todo), do: d

  # Enabled separately from identity/control. Until a provider's grant-aware
  # executor is installed, even an accidentally enabled send gate stays closed.
  defp execute(d, grant, _) do
    cond do
      grant.control_state != "active" -> %{d | next_wake_at: nil}
      not Gates.sends_enabled?(d.user_id, d.provider) -> hold(d, "sends_disabled")
      true -> hold(d, "execution_not_ready")
    end
  end

  defp hold(d, reason),
    do: %{
      d
      | state: "waiting_capacity",
        next_wake_at: nil,
        data: Map.put(d.data, "hold_reason", reason)
    }
end
