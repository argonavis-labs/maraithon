defmodule Maraithon.Delegations.Commands do
  @moduledoc "Reduce commands into durable jobs and todo progress, with no provider I/O."
  alias Maraithon.Delegations.{Actions, Gates, Jobs, Outcomes}

  def execution_ready?, do: true

  def apply(delegation, grant, event, commands, now) do
    Enum.reduce(commands, delegation, fn command, current ->
      cond do
        match?({:prepare_action, _}, command) and current.provider in ~w(gmail slack) ->
          Maraithon.Delegations.Execution.prepare!(current, grant, event, now)

        command == :transition_todo ->
          Outcomes.apply(current, grant, event, :progress)

        match?({:complete_todo, _}, command) ->
          Outcomes.apply(current, grant, event, :complete)

        match?({:meeting_booked, _}, command) ->
          Outcomes.apply(current, grant, event, :booked)

        match?({:schedule_follow_up, _}, command) ->
          Outcomes.follow_up(current, grant, now)

        command in [:enqueue_sync, :enqueue_decide] and current.provider in ~w(gmail slack) and
          grant.control_state == "active" and Gates.scope_enabled?(current, grant) ->
          if command == :enqueue_sync,
            do: Jobs.start_sync!(current, grant, event, now),
            else: Jobs.start_decide!(current, event, now)

        true ->
          execute(current, grant, command)
      end
    end)
  end

  defp execute(d, _, command) when command in [:cancel_unentered, :supersede_unentered] do
    entered? = Actions.supersede_unentered!(d)

    if command == :supersede_unentered and not entered? and d.data["reply_pending"] == true,
      do: %{
        d
        | state: "ready",
          next_wake_at: Maraithon.Runtime.DatabaseClock.now!(),
          data: Map.delete(d.data, "reply_pending")
      },
      else: d
  end

  defp execute(d, grant, {:cancel_unentered, _}), do: execute(d, grant, :cancel_unentered)
  defp execute(d, _, :notify_user), do: d

  # Preparation admitted the bounded observer in the same transaction as the
  # send. Unknown delivery must not restart its counter or enqueue a new send.
  defp execute(d, _, :observe_action), do: %{d | next_wake_at: nil}

  defp execute(d, _, {:schedule_capacity, data}) do
    Actions.supersede_unentered!(d)

    delay =
      if data["reason"] in ~w(rate_limited llm_busy) and is_integer(data["retry_after_ms"]),
        do: max(60_000, min(data["retry_after_ms"], 300_000)),
        else: 6 * 60 * 60 * 1_000

    %{d | next_wake_at: DateTime.add(Maraithon.Runtime.DatabaseClock.now!(), delay, :millisecond)}
  end

  # Uninstalled providers and commands remain gated independently.
  defp execute(d, grant, _) do
    cond do
      grant.control_state != "active" -> %{d | next_wake_at: nil}
      not Gates.scope_enabled?(d, grant) -> hold(d, "sends_disabled")
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
