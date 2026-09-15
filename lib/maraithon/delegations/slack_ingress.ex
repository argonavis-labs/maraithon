defmodule Maraithon.Delegations.SlackIngress do
  @moduledoc "Durable Slack reply routing before acknowledgement, independent of a live Agent."
  import Ecto.Query
  alias Maraithon.{Delegations, Repo}
  alias Maraithon.Delegations.{Delegation, Event, Outbox, SlackDelivery, SlackSource}
  alias Maraithon.TelegramAssistant.PreparedAction

  def accept!(user_id, team, event) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "source routing needs a transaction")
    channel = event["channel"]

    root =
      event["thread_ts"] || event["thread_id"] || event["target_ts"] || event["message_id"] ||
        event["ts"]

    if is_binary(channel) and is_binary(root) do
      unthreaded_dm? =
        String.starts_with?(channel, "D") and
          is_nil(event["thread_ts"]) and is_nil(event["thread_id"]) and is_nil(event["target_ts"])

      live = if unthreaded_dm?, do: List.wrap(only_live_id(user_id, channel)), else: []

      seen =
        from e in Event,
          where: e.user_id == ^user_id and e.source_ref == ^root,
          select: e.delegation_id

      # The single-DM check is separate from the bounded historical lookup.
      # A truncated result must never make an ambiguous DM look unambiguous.
      candidates =
        Repo.all(
          from d in Delegation,
            where:
              d.user_id == ^user_id and d.provider == "slack" and d.slack_channel == ^channel and
                (d.provider_thread_id == ^root or d.id in ^live or d.id in subquery(seen)),
            order_by: d.id,
            lock: "FOR UPDATE",
            limit: 100
        )
        |> Enum.map(&Delegation.hydrate/1)

      for d <- candidates do
        scope = Delegations.current_grant(d).data["scope"]

        if scope["team_id"] == team do
          record!(d, scope, event)
        end
      end
    end

    :ok
  end

  def only_live_id(user_id, channel) do
    case Repo.all(
           from d in Delegation,
             where:
               d.user_id == ^user_id and d.provider == "slack" and
                 d.slack_channel == ^channel and d.state not in ^Delegation.terminal_states(),
             select: d.id,
             limit: 2
         ) do
      [id] -> id
      _ -> nil
    end
  end

  defp record!(d, scope, raw) do
    message = SlackSource.normalize(raw, d.slack_channel, d.provider_thread_id)

    key =
      "slack:#{scope["team_id"]}:#{d.slack_channel}:#{message["message_id"]}:#{message["revision"]}"

    event_id = raw["provider_event_id"]
    prior = from e in Event, where: e.delegation_id == ^d.id

    duplicate? =
      Repo.exists?(from e in prior, where: e.event_key == ^key) or
        (is_binary(event_id) and
           Repo.exists?(from e in prior, where: e.source_revision == ^event_id))

    unless duplicate? do
      occurred =
        SlackSource.time(message["revision_at"]) || Maraithon.Runtime.DatabaseClock.now!()

      classification =
        if DateTime.compare(occurred, d.inserted_at) == :lt,
          do: "historical",
          else: SlackSource.classify(message, scope, own_action?(d, scope, message))

      classification =
        if message["revision_at"] != message["message_id"] and
             classification in ~w(own_send auto_reply),
           do: "source_changed",
           else: classification

      d =
        if Delegation.live?(d) and
             classification in ~w(reply source_changed human_send stop scope_change source_gap),
           do:
             d
             |> Delegation.changeset(%{source_revision: d.source_revision + 1})
             |> Repo.update!(),
           else: d

      Outbox.append!(
        d,
        "inbound_message",
        key,
        %{
          "classification" => classification,
          "source_revision" => d.source_revision,
          "message_id" => message["message_id"],
          "message_revision" => message["revision"],
          "thread_id" => d.provider_thread_id,
          "provider_event_id" => event_id
        },
        %{source_ref: message["message_id"], source_revision: event_id, occurred_at: occurred}
      )
    end
  end

  defp own_action?(d, scope, message) do
    if SlackSource.valid?(message) and
         (message["from"] == scope["identity"]["user_id"] or
            (is_binary(message["bot_id"]) and message["bot_id"] == scope["identity"]["bot_id"])) do
      matches_action?(d, message)
    else
      false
    end
  end

  defp matches_action?(d, message) do
    action_id =
      case Ecto.UUID.cast(message["client_msg_id"]) do
        {:ok, id} -> id
        _ -> nil
      end

    action_id = action_id || receipt_action_id(d, message["message_id"])

    with id when is_binary(id) <- action_id,
         %PreparedAction{} = action <-
           Repo.get_by(PreparedAction,
             id: id,
             user_id: d.user_id,
             delegation_id: d.id,
             authorization_kind: "delegation_grant",
             action_type: "slack_post"
           ),
         action = PreparedAction.hydrate_payload(action),
         true <- (action.payload["_maraithon_execution_attempts"] || 0) > 0,
         identity when is_map(identity) <- action.payload["_maraithon_reconciliation_identity"] do
      SlackDelivery.message_matches?(
        %{
          "ts" => message["message_id"],
          "thread_ts" => message["thread_id"],
          "user" => message["from"],
          "bot_id" => message["bot_id"],
          "text" => message["text_body"],
          "edited" => if(message["revision_at"] != message["message_id"], do: %{})
        },
        identity,
        message["message_id"]
      )
    else
      _ -> false
    end
  end

  defp receipt_action_id(d, message_id) do
    case Repo.one(
           from e in Event,
             where:
               e.delegation_id == ^d.id and
                 e.kind == "send_receipt" and e.source_ref == ^message_id,
             limit: 1
         ) do
      nil -> nil
      event -> Event.hydrate(event).data["action_id"]
    end
  end
end
