defmodule Maraithon.Tools.SlackPostMessage do
  @moduledoc """
  Posts a message to a Slack workspace/channel connected through OAuth.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.SlackHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         {:ok, channel} <- ActionHelpers.required_string(args, "channel"),
         {:ok, text} <- ActionHelpers.required_string(args, "text"),
         {:ok, token} <- resolve_token(user_id, team_id, args),
         {:ok, response} <-
           Slack.post_message(
             token.access_token,
             channel,
             text,
             thread_ts: ActionHelpers.optional_string(args, "thread_ts")
           ) do
      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         channel: channel,
         token_provider: token.provider,
         ts: response["ts"],
         ok: response["ok"]
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        SlackHelpers.normalize_error(reason)
    end
  end

  defp resolve_token(user_id, team_id, args) do
    SlackHelpers.resolve_access_token(
      user_id,
      team_id,
      token_preference: ActionHelpers.optional_string(args, "token_preference") || "user",
      required_scopes: ["chat:write"],
      slack_user_id: ActionHelpers.optional_string(args, "slack_user_id")
    )
  end
end
