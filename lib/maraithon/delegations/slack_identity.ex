defmodule Maraithon.Delegations.SlackIdentity do
  @moduledoc "Exact Slack author and destination preflight, shared by both delegation actors."
  alias Maraithon.{OAuth, AssistantIdentities, ConnectedAccounts}
  alias Maraithon.OAuth.Slack, as: SlackAPI
  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.SlackHelpers
  alias Maraithon.Todos.SourceActions

  def preview(todo, account, actor, opts \\ []) do
    location = SourceActions.slack_location(todo)
    team = team_id(account.provider)
    installation = OAuth.get_token(todo.user_id, "slack:#{team}")

    member =
      source_member(account.provider) || (installation && installation.metadata["authed_user_id"])

    assistant = if actor == "as_assistant", do: AssistantIdentities.get(todo.user_id)
    preference = if actor == "as_assistant", do: "bot", else: "user"

    scopes =
      if actor == "as_assistant", do: ["chat:write", "chat:write.customize"], else: ["chat:write"]

    scopes =
      if actor == "as_assistant" and String.starts_with?(location.channel || "", "D"),
        do: ["im:write" | scopes],
        else: scopes

    with true <- is_binary(team) and team == location.team and valid_id?(location.channel),
         true <- actor == "as_user" or assistant != nil,
         {:ok, token} <-
           SlackHelpers.resolve_access_token(todo.user_id, team,
             token_preference: preference,
             slack_user_id: member,
             required_scopes: scopes,
             strict_identity?: true
           ),
         {:ok, auth} <- SlackAPI.api_request(:post, "auth.test", token),
         true <- auth["team_id"] == team and is_binary(auth["user_id"]),
         true <- valid_author?(auth, actor, member),
         sender when not is_nil(sender) <- ConnectedAccounts.get(todo.user_id, token.provider) do
      root = location.timestamp

      identity = %{
        "account_id" => account.id,
        "external_account_id" => account.external_account_id,
        "source_provider" => account.provider,
        "source_channel" => location.channel,
        "provider" => token.provider,
        "sender_account_id" => sender.id,
        "sender_external_account_id" => sender.external_account_id,
        "operator_user_id" => member,
        "actor" => actor,
        "team_id" => team,
        "user_id" => auth["user_id"],
        "bot_id" => auth["bot_id"],
        "display_name" =>
          if(assistant,
            do: assistant.data["slack_username"] || assistant.data["display_name"],
            else: auth["user"]
          ),
        "icon_url" => assistant && assistant.data["slack_icon_url"],
        "assistant_identity_id" => assistant && assistant.id,
        "token_preference" => preference
      }

      with {:ok, reader} <- read_token(todo.user_id, identity, location.channel),
           {:ok, %{"channel" => channel}} <- Slack.get_channel_info(reader, location.channel),
           true <- available?(channel, location.channel),
           {:ok, snapshot} <-
             Maraithon.Delegations.SlackSource.fetch(
               todo.user_id,
               identity,
               location.channel,
               root,
               opts
             ),
           participants =
             if(channel["is_im"] == true,
               do: [channel["user"]],
               else: Maraithon.Delegations.SlackSource.participants(snapshot, identity)
             ),
           true <- participants != [] and Enum.all?(participants, &valid_id?/1),
           true <- Enum.all?(participants, &(&1 not in [member, auth["user_id"]])),
           {:ok, destination} <- destination(token, channel, identity) do
        counterparty = if channel["is_im"] == true, do: channel["user"]
        identity = Map.put(identity, "dm_user_id", counterparty)

        source = %{
          "provider" => "slack",
          "source_account_id" => account.id,
          "source_channel_id" => location.channel,
          "channel" => destination,
          "thread_id" => if(destination == location.channel, do: root),
          "source_thread_id" => root,
          "source_message_id" => root,
          "team_id" => team,
          "topic" =>
            if(counterparty,
              do: "slack:#{team}:dm:#{counterparty}",
              else: "slack:#{team}:#{destination}"
            ),
          "to" => if(counterparty, do: [counterparty], else: [destination]),
          "cc" => [],
          "evidence" => [
            %{"source" => "slack", "team" => team, "channel" => location.channel, "id" => root}
          ]
        }

        {:ok, Map.put(source, "counterparty_user_ids", participants), identity}
      else
        {:error, _} = error -> error
        {:pending, _} = pending -> pending
        _ -> {:error, :slack_counterparty_unavailable}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :slack_identity_or_channel_unavailable}
    end
  end

  # Opening a DM resolves its destination, but never posts a message. Slack
  # returns the same channel for the same participants on subsequent previews.
  defp destination(token, %{"is_im" => true, "user" => member} = source, %{
         "actor" => "as_assistant"
       }) do
    with {:ok, %{"channel" => channel}} <-
           Slack.open_conversation(token, [member], return_im: true),
         true <- available?(channel, channel["id"]) and channel["is_im"] == true,
         true <- channel["user"] == member and channel["id"] != source["id"] do
      {:ok, channel["id"]}
    else
      false -> {:error, :slack_assistant_dm_unavailable}
      {:error, _} = error -> error
      _ -> {:error, :slack_assistant_dm_unavailable}
    end
  end

  defp destination(token, source, _identity) do
    with {:ok, %{"channel" => channel}} <-
           Slack.get_channel_info(token, source["id"]),
         true <- available?(channel, source["id"]) do
      {:ok, channel["id"]}
    else
      {:error, _} = error -> error
      _ -> {:error, :slack_identity_or_channel_unavailable}
    end
  end

  defp available?(channel, id),
    do:
      valid_id?(id) and channel["id"] == id and channel["is_archived"] != true and
        (channel["is_member"] == true or
           (channel["is_im"] == true and String.starts_with?(id, "D")))

  @doc "Resolve only the frozen author, then verify the credential's live Slack identity."
  def access_token(user_id, identity, scopes) do
    with {:ok, token} <-
           SlackHelpers.resolve_access_token(user_id, identity["team_id"],
             token_preference: identity["token_preference"],
             slack_user_id: identity["user_id"],
             required_scopes: scopes,
             strict_identity?: true
           ),
         true <- token.provider == identity["provider"],
         {:ok, auth} <- SlackAPI.api_request(:post, "auth.test", token),
         true <-
           auth["team_id"] == identity["team_id"] and auth["user_id"] == identity["user_id"],
         true <- auth["bot_id"] == identity["bot_id"],
         true <- valid_author?(auth, identity["actor"], identity["user_id"]) do
      {:ok, token}
    else
      {:error, _} = error -> error
      _ -> {:error, :slack_identity_changed}
    end
  end

  @doc "Read the frozen conversation with its actor in a DM or its source member in a channel."
  def read_token(user_id, identity, channel) do
    reader =
      if String.starts_with?(channel, "D") and
           not (identity["actor"] == "as_assistant" and channel == identity["source_channel"]) do
        identity
      else
        member = identity["operator_user_id"]

        Map.merge(identity, %{
          "actor" => "as_user",
          "user_id" => member,
          "bot_id" => nil,
          "token_preference" => "user",
          "provider" => "slack:#{identity["team_id"]}:user:#{member}"
        })
      end

    access_token(user_id, reader, [])
  end

  defp source_member(provider) do
    case String.split(provider, ":") do
      ["slack", _, "user", member] -> member
      _ -> nil
    end
  end

  defp valid_author?(auth, "as_user", member),
    do: auth["user_id"] == member and is_nil(auth["bot_id"])

  defp valid_author?(auth, "as_assistant", _), do: is_binary(auth["bot_id"])
  defp valid_author?(_, _, _), do: false

  defp team_id(provider) do
    case String.split(provider, ":") do
      ["slack", team | _] -> team
      _ -> nil
    end
  end

  defp valid_id?(id), do: is_binary(id) and Regex.match?(~r/^[A-Z0-9]+$/, id)
end
