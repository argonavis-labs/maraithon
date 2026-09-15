defmodule Maraithon.Delegations.StateMachine do
  @moduledoc "Pure conversation transitions. Commands are executed under runtime authority."
  alias Maraithon.Delegations.Delegation
  @terminal ~w(completed stopped expired)
  @busy ~w(syncing deciding sending reconciling)

  def apply(%Delegation{schema_version: version}, _event) when version != 1,
    do: {:error, :unsupported_delegation_version}

  def apply(%{state: state} = d, _event) when state in @terminal, do: {d, []}

  def apply(d, %{kind: "user_action", data: %{"action" => action}} = event)
      when action in ~w(pause take_over stop) do
    state = if action == "stop", do: "stopped", else: "paused"

    data =
      Map.put(
        d.data,
        "hold_reason",
        if(d.state in ~w(sending reconciling) or d.data["hold_reason"] == "send_may_be_in_flight",
          do: "send_may_be_in_flight",
          else: action
        )
      )

    {%{d | state: state, next_wake_at: nil, data: data}, [{:cancel_unentered, event.data}]}
  end

  def apply(%{state: state} = d, %{kind: "user_action", data: %{"action" => action}})
      when (action == "start" and state == "ready") or
             (action == "resume" and state == "paused") or
             (action == "answer" and state == "needs_user") do
    {%{d | state: "ready", data: Map.drop(d.data, ~w(question hold_reason))}, [:enqueue_sync]}
  end

  def apply(%{state: "paused"} = d, _event), do: {%{d | next_wake_at: nil}, []}

  def apply(d, %{kind: "inbound_message", data: %{"classification" => classification}} = event) do
    case classification do
      "human_send" ->
        {%{
           d
           | state: "paused",
             next_wake_at: nil,
             data: Map.put(d.data, "hold_reason", "human_takeover")
         }, [:cancel_unentered, :notify_user]}

      "stop" ->
        {%{d | state: "stopped", next_wake_at: nil}, [:cancel_unentered, :notify_user]}

      "bounce" ->
        hold(d, "The message could not be delivered.")

      "reply" when d.state in @busy ->
        {%{
           d
           | source_revision: d.source_revision + 1,
             data: Map.put(d.data, "reply_pending", true)
         }, [:supersede_unentered]}

      "reply" ->
        {%{
           d
           | state: "ready",
             source_revision: d.source_revision + 1,
             reminder_count_cycle: 0,
             next_wake_at: event.occurred_at
         }, [:enqueue_sync]}

      _ ->
        {d, []}
    end
  end

  def apply(d, %{kind: "timer_due"} = event) do
    cond do
      d.state == "reconciling" ->
        {%{d | next_wake_at: nil}, [:observe_action]}

      d.state in @busy or d.state == "needs_user" ->
        {%{d | next_wake_at: nil}, []}

      d.next_wake_at == nil or DateTime.compare(event.occurred_at, d.next_wake_at) == :lt ->
        {d, []}

      true ->
        {%{d | state: "ready", next_wake_at: nil}, [:enqueue_sync]}
    end
  end

  def apply(%{state: state} = d, %{kind: "sync_result"}) when state in ~w(ready syncing),
    do: {%{d | state: "deciding"}, [:enqueue_decide]}

  def apply(%{state: "deciding"} = d, %{kind: "decision", data: decision}) do
    case decision["kind"] do
      kind when kind in ~w(send propose_times book) ->
        {%{d | state: "sending"}, [{:prepare_action, decision}]}

      "complete" ->
        {%{d | state: "completed", next_wake_at: nil}, [{:complete_todo, decision}, :notify_user]}

      "needs_user" ->
        hold(d, decision["question"])

      "wait" ->
        {%{d | state: "waiting_reply", next_wake_at: nil}, [:transition_todo]}

      _ ->
        hold(d, "I couldn't verify the next step. Please review this conversation.")
    end
  end

  def apply(d, %{kind: "send_receipt", data: receipt}) do
    cond do
      receipt["action_type"] == "calendar_create_event" ->
        {%{d | state: "completed", next_wake_at: nil}, [{:meeting_booked, receipt}, :notify_user]}

      d.data["reply_pending"] == true ->
        {%{
           d
           | state: "ready",
             data: Map.delete(d.data, "reply_pending")
         }, [:enqueue_sync]}

      true ->
        {%{d | state: "waiting_reply"}, [{:schedule_follow_up, receipt}, :transition_todo]}
    end
  end

  def apply(d, %{kind: "send_unknown"}), do: {%{d | state: "reconciling"}, [:observe_action]}

  def apply(d, %{kind: "capacity_hold", data: data}) do
    {%{d | state: "waiting_capacity", data: Map.put(d.data, "hold_reason", data["reason"])},
     [{:schedule_capacity, data}]}
  end

  def apply(d, %{kind: "source_gap"}), do: hold(d, "The conversation isn't fully synced yet.")

  def apply(d, %{kind: "failure", data: data}),
    do: hold(d, data["question"] || "This conversation needs your attention.")

  def apply(d, _event), do: {d, []}

  defp hold(d, question) do
    {%{d | state: "needs_user", next_wake_at: nil, data: Map.put(d.data, "question", question)},
     [:transition_todo, :notify_user]}
  end
end
