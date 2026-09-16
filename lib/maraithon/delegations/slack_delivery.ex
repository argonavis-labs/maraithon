defmodule Maraithon.Delegations.SlackDelivery do
  @moduledoc "Frozen Slack author, one provider write, and exact read-only delivery evidence."
  alias Maraithon.{ConnectedAccounts, Repo}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.Slack
  alias Maraithon.Delegations.SlackIdentity

  @key "_maraithon_reconciliation_identity"

  def freeze(action, payload) do
    identity = %{
      "version" => 1,
      "action_id" => action.id,
      "kind" => "slack_post",
      "author" => payload["_maraithon_slack_author"],
      "team_id" => payload["team_id"],
      "channel" => payload["channel"],
      "thread_ts" => payload["thread_ts"],
      "text_sha256" => hash(payload["text"])
    }

    Map.put(payload, @key, identity)
  end

  def valid?(action, %{"version" => 1, "kind" => "slack_post", "author" => author} = identity)
      when is_map(author) do
    identity["action_id"] == action.id and
      author == action.payload["_maraithon_slack_author"] and
      identity["team_id"] == author["team_id"] and
      Enum.all?(~w(team_id channel thread_ts), &(identity[&1] == action.payload[&1])) and
      is_binary(action.payload["text"]) and byte_size(action.payload["text"]) in 1..16_000 and
      identity["text_sha256"] == hash(action.payload["text"]) and
      author["actor"] in ~w(as_user as_assistant) and
      id?(author["user_id"]) and id?(identity["team_id"]) and id?(identity["channel"]) and
      (timestamp?(identity["thread_ts"]) or
         (is_nil(identity["thread_ts"]) and author["actor"] == "as_assistant" and
            String.starts_with?(identity["channel"], "D") and id?(author["dm_user_id"]) and
            id?(author["source_channel"]) and identity["channel"] != author["source_channel"]))
  end

  def valid?(_, _), do: false

  def same_account?(user_id, %{"author" => author}) do
    source = Repo.get_by(ConnectedAccount, id: author["account_id"], user_id: user_id)
    sender = ConnectedAccounts.get(user_id, author["provider"])

    if source && sender && source.provider == author["source_provider"] &&
         source.external_account_id == author["external_account_id"] &&
         sender.id == author["sender_account_id"] &&
         sender.external_account_id == author["sender_external_account_id"],
       do: :ok,
       else: {:pending, :connected_account_changed}
  end

  def send(args, identity) do
    author = identity["author"]

    scopes =
      if author["actor"] == "as_assistant",
        do: ["chat:write", "chat:write.customize"],
        else: ["chat:write"]

    with true <- valid?(%{id: identity["action_id"], payload: args}, identity),
         :ok <- same_account?(args["user_id"], identity),
         {:ok, token} <- SlackIdentity.access_token(args["user_id"], author, scopes),
         {:ok, %{"channel" => channel}} <- Slack.get_channel_info(token, identity["channel"]),
         true <-
           channel["id"] == identity["channel"] and channel["is_archived"] != true and
             (channel["is_member"] == true or channel["is_im"] == true),
         true <-
           is_nil(author["dm_user_id"]) or
             (channel["is_im"] == true and channel["user"] == author["dm_user_id"]) do
      post(token, args, identity)
    else
      {:pending, reason} -> {:error, reason}
      {:error, _} = error -> error
      _ -> {:error, :slack_identity_or_channel_unavailable}
    end
  end

  defp post(token, args, identity) do
    author = identity["author"]

    result =
      Slack.post_message(token, identity["channel"], args["text"],
        thread_ts: identity["thread_ts"],
        client_msg_id: identity["action_id"],
        username: if(author["actor"] == "as_assistant", do: author["display_name"]),
        icon_url: if(author["actor"] == "as_assistant", do: author["icon_url"]),
        reply_broadcast: false,
        link_names: false,
        parse: "none",
        mrkdwn: false,
        unfurl_links: false,
        unfurl_media: false
      )

    case result do
      {:ok, response} ->
        if response["channel"] == identity["channel"] and
             message_matches?(response["message"], identity, response["ts"]),
           do: {:ok, receipt(identity, response["ts"], false)},
           else:
             {:error,
              %{
                class: :ambiguous,
                code: :slack_delivery_not_proven,
                observation: Map.take(response, ~w(channel ts))
              }}

      # Once postMessage is entered, even Slack's internal_error can follow a
      # committed write. The prepared-action executor must retain uncertainty.
      {:error, reason} = result ->
        if Maraithon.HTTP.Admission.local_deferral(reason),
          do: result,
          else: {:error, %{class: :ambiguous, code: :slack_delivery_not_proven, reason: result}}
    end
  end

  @doc "Preserve only an exact provider timestamp through an uncertain-result checkpoint."
  def observation_hint(action, %{observation: observation}) when is_map(observation) do
    if observation["channel"] == action.payload["channel"] and timestamp?(observation["ts"]),
      do: %{"slack_observation" => Map.take(observation, ~w(channel ts))},
      else: %{}
  end

  def observation_hint(action, {:provider_success_checkpoint_failed, _, receipt})
      when is_map(receipt) do
    observation = Map.new(receipt, fn {key, value} -> {to_string(key), value} end)
    observation_hint(action, %{observation: observation})
  end

  def observation_hint(_, _), do: %{}

  # A missing response has no trustworthy server timestamp. Similar text or a
  # client_msg_id alone cannot authorize a resend or claim delivery.
  def observe(action, identity) do
    observation =
      get_in(action.payload, ["_maraithon_execution_result", "slack_observation"]) || %{}

    ts = observation["ts"]
    author = identity["author"]

    with true <- observation["channel"] == identity["channel"] and timestamp?(ts),
         {:ok, token} <-
           SlackIdentity.read_token(action.user_id, author, identity["channel"]),
         {:ok, response} <-
           Slack.get_thread_replies(token, identity["channel"], identity["thread_ts"] || ts,
             oldest: ts,
             latest: ts,
             inclusive: true,
             limit: 2
           ),
         false <- response["has_more"] == true,
         true <- get_in(response, ["response_metadata", "next_cursor"]) in [nil, ""],
         [message] <- response["messages"],
         true <- message_matches?(message, identity, ts) do
      {:ok, receipt(identity, ts, true)}
    else
      {:error, reason} -> {:pending, reason}
      _ -> {:pending, :slack_message_not_proven}
    end
  end

  def message_matches?(message, identity, ts) when is_map(message) do
    author = identity["author"]

    expected_author? =
      if author["actor"] == "as_assistant",
        do: id?(author["bot_id"]) and message["bot_id"] == author["bot_id"],
        else: message["user"] == author["user_id"] and is_nil(message["bot_id"])

    timestamp?(ts) and message["ts"] == ts and expected_author? and
      (message["thread_ts"] || ts) == (identity["thread_ts"] || ts) and
      message["subtype"] in [nil, "bot_message"] and
      is_nil(message["edited"]) and hash(message["text"]) == identity["text_sha256"]
  end

  def message_matches?(_, _, _), do: false

  defp receipt(identity, ts, reconciled),
    do: %{
      source: "slack",
      team_id: identity["team_id"],
      channel: identity["channel"],
      ts: ts,
      thread_id: identity["thread_ts"] || ts,
      user: identity["author"]["user_id"],
      bot_id: identity["author"]["bot_id"],
      text_sha256: identity["text_sha256"],
      reconciled: reconciled
    }

  def text(body),
    do:
      body
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp hash(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp hash(_), do: nil
  defp id?(value), do: is_binary(value) and Regex.match?(~r/^[A-Z][A-Z0-9]+$/, value)
  defp timestamp?(value), do: is_binary(value) and Regex.match?(~r/^\d{10,16}\.\d{6}$/, value)
end
