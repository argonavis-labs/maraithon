defmodule Maraithon.Delegations.Receipts do
  @moduledoc "Atomic prepared-action outcomes, turn settlement and conversation wake intents."
  import Ecto.Query
  alias Maraithon.Repo
  alias Maraithon.Delegations.{Authority, Binding, Delegation, Event, Outbox, Turn}
  alias Maraithon.TelegramAssistant.PreparedAction

  @result "_maraithon_execution_result"
  @hash "_maraithon_confirmed_payload_sha256"
  @receipt "_maraithon_reconciliation_receipt"
  @fields ~w(source message_id thread_id event_id team_id channel ts user bot_id text_sha256 reconciled)

  def proof_fields, do: @fields

  # Called only after the provider worker returned a closed local admission
  # rejection, under the matching execution claim and the normal write fence.
  # Commit this evidence with the restored unentered action, or restore neither.
  def deferred!(action, token, {:rate_limited, seconds, reason}) do
    %{delegation: d, turn: turn} = Authority.lock_action_scope!(action)
    attempt = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
    retry_at = Maraithon.Runtime.DatabaseClock.now!() |> DateTime.add(max(seconds, 30))

    Outbox.append!(d, "send_deferred", "deferred:#{action.id}:#{attempt}", %{
      "turn_id" => turn.id,
      "grant_version" => turn.grant_version,
      "action_id" => action.id,
      "confirmed_payload_hash" => action.payload[@hash],
      "reason" => Atom.to_string(reason),
      "provider_entered" => false,
      "retry_at" => DateTime.to_iso8601(retry_at)
    })
    |> Event.changeset(%{wake_state: "consumed", consumed_by_turn_id: turn.id})
    |> Repo.update!()

    provider = if action.action_type == "gmail_send", do: "Gmail", else: "Slack"

    d
    |> Delegation.changeset(%{
      revision: d.revision + 1,
      data:
        Map.put(d.data, "last_action", "Waiting for #{provider}'s request limit before sending.")
    })
    |> Repo.update!()
  end

  # The executor already owns the job fence and delegation/turn/run/action locks.
  # This remains writable after revocation: a receipt is evidence, not new authority.
  def record!(%PreparedAction{authorization_kind: "delegation_grant", status: status} = action)
      when status in ~w(executed execution_unknown failed) do
    %{delegation: d, turn: turn, run: run} = Authority.lock_action_scope!(action)
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
        if status == "executed" do
          label =
            case get_in(turn.data, ["decision", "kind"]) do
              "propose_times" -> "Sent #{length(turn.data["decision"]["slot_ids"])} time options."
              "book" -> "Booked the agreed meeting."
              _ -> "Sent a message."
            end

          Map.put(data, "last_action", label)
        else
          data
        end

      data =
        if status == "executed" and get_in(turn.data, ["decision", "kind"]) == "propose_times" do
          scheduling = run.prompt_snapshot["scheduling"]
          selected = turn.data["decision"]["slot_ids"]

          slots =
            Enum.map(selected, fn id ->
              Enum.find(scheduling["slots"], &(Maraithon.Delegations.Policy.slot_id(&1) == id))
            end)

          Map.merge(data, %{
            "offered_slots" => slots,
            "offered_calendar_account_ids" => scheduling["coverage"]["account_ids"],
            "slot_reoffers" =>
              (data["slot_reoffers"] || 0) +
                if(Maraithon.Delegations.Policy.reoffer?(%{delegation: d}, turn.data["decision"]),
                  do: 1,
                  else: 0
                )
          })
        else
          data
        end

      data =
        if status != "execution_unknown" and data["hold_reason"] == "send_may_be_in_flight",
          do: Map.delete(data, "hold_reason"),
          else: data

      changes = %{
        last_action_id: action.id,
        revision: d.revision + 1,
        reminder_count_cycle:
          d.reminder_count_cycle +
            if(status == "executed" and turn.data["reminder"] == true, do: 1, else: 0),
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
        if status == "failed" and action.error == "slot_no_longer_free",
          do: Map.put(payload, "failure_code", "slot_no_longer_free"),
          else: payload

      payload =
        if status == "failed",
          do:
            Map.put(
              payload,
              "question",
              "The message could not be sent. Please review the conversation."
            ),
          else: payload

      Outbox.append!(d, kind, key, payload, %{source_ref: receipt["message_id"] || receipt["ts"]})
    end

    action
  end

  def record!(action), do: action

  def needs_review(%PreparedAction{authorization_kind: "delegation_grant"} = action) do
    Maraithon.AssistantChat.Execution.write(fn ->
      %{delegation: d, turn: turn} = Authority.lock_action_scope!(action)

      current =
        Repo.one!(from a in PreparedAction, where: a.id == ^action.id, lock: "FOR UPDATE")
        |> PreparedAction.hydrate_payload()

      if current.status in ~w(confirmed execution_unknown) do
        Outbox.append!(d, "reconciliation_exhausted", "review:#{action.id}", %{
          "turn_id" => turn.id,
          "grant_version" => turn.grant_version,
          "action_id" => action.id,
          "action_type" => action.action_type,
          "confirmed_payload_hash" => current.payload[@hash]
        })
      end

      :ok
    end)
  end

  def needs_review(_), do: :ok

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

        "reconciliation_exhausted" ->
          action.status in ~w(confirmed execution_unknown)

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

    slack_matches?(action, receipt) and required != [] and is_binary(action.payload[@hash]) and
      byte_size(action.payload[@hash]) == 64 and
      Enum.all?(required, fn key ->
        is_binary(receipt[key]) and byte_size(receipt[key]) in 1..500
      end)
  end

  defp slack_matches?(%{action_type: "slack_post"} = action, receipt) do
    identity = action.payload["_maraithon_reconciliation_identity"]

    is_map(identity) and receipt["team_id"] == identity["team_id"] and
      receipt["channel"] == identity["channel"] and
      receipt["thread_id"] == (identity["thread_ts"] || receipt["ts"]) and
      receipt["user"] == identity["author"]["user_id"] and
      receipt["bot_id"] == identity["author"]["bot_id"] and
      receipt["text_sha256"] == identity["text_sha256"]
  end

  defp slack_matches?(_, _), do: true
end
