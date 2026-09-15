defmodule Maraithon.Delegations.SlackIdentity do
  @moduledoc "Exact Slack author and destination preflight, shared by both delegation actors."
  alias Maraithon.{OAuth, AssistantIdentities}
  alias Maraithon.OAuth.Slack, as: SlackAPI
  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.SlackHelpers
  alias Maraithon.Todos.SourceActions

  def preview(todo, account, actor) do
    location = SourceActions.slack_location(todo)
    team = team_id(account.provider)
    installation = OAuth.get_token(todo.user_id, "slack:#{team}")
    member = installation && installation.metadata["authed_user_id"]
    assistant = if actor == "as_assistant", do: AssistantIdentities.get(todo.user_id)
    preference = if actor == "as_assistant", do: "bot", else: "user"

    scopes =
      if actor == "as_assistant", do: ["chat:write", "chat:write.customize"], else: ["chat:write"]

    with true <- is_binary(team) and team == location.team and valid_id?(location.channel),
         true <- actor == "as_user" or assistant != nil,
         {:ok, token} <-
           SlackHelpers.resolve_access_token(todo.user_id, team,
             token_preference: preference,
             slack_user_id: member,
             required_scopes: scopes,
             strict_identity?: true
           ),
         {:ok, auth} <- SlackAPI.api_request(:post, "auth.test", token.access_token),
         true <- auth["team_id"] == team and is_binary(auth["user_id"]),
         true <- valid_author?(auth, actor, member),
         {:ok, %{"channel" => channel}} <-
           Slack.get_channel_info(token.access_token, location.channel),
         true <- channel["is_member"] == true or channel["is_im"] == true,
         true <- channel["is_archived"] != true do
      root = location.timestamp
      counterparty = channel["user"]
      to = if is_binary(counterparty), do: [counterparty], else: [location.channel]

      topic =
        if counterparty,
          do: "slack:#{team}:dm:#{counterparty}",
          else: "slack:#{team}:#{location.channel}"

      identity = %{
        "account_id" => account.id,
        "external_account_id" => account.external_account_id,
        "provider" => token.provider,
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

      source = %{
        "provider" => "slack",
        "source_account_id" => account.id,
        "channel" => location.channel,
        "thread_id" => root,
        "source_thread_id" => root,
        "source_message_id" => root,
        "team_id" => team,
        "topic" => topic,
        "to" => to,
        "cc" => [],
        "evidence" => [
          %{"source" => "slack", "team" => team, "channel" => location.channel, "id" => root}
        ]
      }

      {:ok, source, identity}
    else
      {:error, _} = error -> error
      _ -> {:error, :slack_identity_or_channel_unavailable}
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
