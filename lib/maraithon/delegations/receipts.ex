defmodule Maraithon.Delegations.Receipts do
  @moduledoc "Atomic prepared-action outcomes, turn settlement and conversation wake intents."
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Authority, Binding, Delegation, Event, Outbox, Turn}
  alias Maraithon.TelegramAssistant.PreparedAction

  @result "_maraithon_execution_result"
  @hash "_maraithon_confirmed_payload_sha256"
  @receipt "_maraithon_reconciliation_receipt"
  @fields ~w(source message_id thread_id event_id channel ts reconciled)

  def proof_fields, do: @fields

  # The executor already owns the job fence and delegation/turn/run/action locks.
  # This remains writable after revocation: a receipt is evidence, not new authority.
  def record!(%PreparedAction{authorization_kind: "delegation_grant", status: status} = action)
      when status in ~w(executed execution_unknown failed) do
    %{delegation: d, turn: turn} = Authority.lock_action_scope!(action)
    key = "action:#{action.id}:#{status}"

    unless Repo.get_by(Event, delegation_id: d.id, event_key: key) do
      {kind, turn_status} =
        case status do
          "executed" -> {"send_receipt", "settled"}
          "execution_unknown" -> {"send_unknown", "dispatched"}
          "failed" -> {"failure", "failed"}
        end

      receipt = receipt(action)

      if status == "executed" and not proven?(action, receipt),
        do: Repo.rollback(:delegation_receipt_incomplete)

      turn |> Turn.changeset(%{status: turn_status}) |> Repo.update!()
      data = Map.put(d.data, "last_send_status", status)

      data =
        if status != "execution_unknown" and data["hold_reason"] == "send_may_be_in_flight",
          do: Map.delete(data, "hold_reason"),
          else: data

      changes = %{
        last_action_id: action.id,
        revision: d.revision + 1,
        lifetime_sends:
          d.lifetime_sends +
            if(status == "executed" and action.action_type in ~w(gmail_send slack_post),
              do: 1,
              else: 0
            ),
        data: data
      }

      # The first send on the assistant's mailbox establishes its own thread.
      # A stopped conversation retains the evidence without reserving a live thread.
      changes =
        if status == "executed" and is_nil(d.provider_thread_id) and
             action.action_type in ~w(gmail_send slack_post),
           do: Map.put(changes, :provider_thread_id, receipt["thread_id"] || receipt["ts"]),
           else: changes

      d = d |> Delegation.changeset(changes) |> Repo.update!()

      payload = %{
        "turn_id" => turn.id,
        "grant_version" => turn.grant_version,
        "action_id" => action.id,
        "action_type" => action.action_type,
        "confirmed_payload_hash" => action.payload[@hash],
        "receipt" => receipt
      }

      payload =
        if status == "failed",
          do:
            Map.put(
              payload,
              "question",
              "The message could not be sent. Please review the conversation."
            ),
          else: payload

      Outbox.append!(d, kind, key, payload)
    end

    action
  end

  def record!(action), do: action

  def valid_event?(d, event) do
    with {:ok, id} <- Ecto.UUID.cast(event.data["action_id"]),
         %PreparedAction{} = action <- Repo.get_by(PreparedAction, id: id, user_id: d.user_id),
         action = PreparedAction.hydrate_payload(action),
         true <- action.authorization_kind == "delegation_grant" and action.delegation_id == d.id,
         true <-
           action.delegation_turn_id == event.data["turn_id"] and
             action.grant_version == event.data["grant_version"],
         true <- action.payload[@hash] == event.data["confirmed_payload_hash"],
         true <- action.action_type == event.data["action_type"],
         true <- action.payload[Binding.key()]["turn_id"] == action.delegation_turn_id do
      case event.kind do
        "send_receipt" ->
          action.status == "executed" and receipt(action) == event.data["receipt"] and
            proven?(action, receipt(action))

        "send_unknown" ->
          action.status == "execution_unknown"

        "failure" ->
          action.status == "failed"

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp receipt(action),
    do: Map.take(action.payload[@receipt] || action.payload[@result] || %{}, @fields)

  defp proven?(action, receipt) do
    required =
      case action.action_type do
        "gmail_send" -> ~w(message_id thread_id)
        "slack_post" -> ~w(channel ts)
        "calendar_create_event" -> ~w(event_id)
        _ -> []
      end

    required != [] and is_binary(action.payload[@hash]) and byte_size(action.payload[@hash]) == 64 and
      Enum.all?(required, fn key ->
        is_binary(receipt[key]) and byte_size(receipt[key]) in 1..500
      end)
  end
end
