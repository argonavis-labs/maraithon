defmodule Maraithon.Tools.SlackOpenConversation do
  @moduledoc """
  Opens or resumes a Slack DM or MPIM conversation.
  """

  alias Maraithon.Connectors.Slack
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.SlackHelpers

  def execute(args) when is_map(args) do
    user_ids = ActionHelpers.optional_csv(args, "user_ids")

    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, team_id} <- ActionHelpers.required_string(args, "team_id"),
         :ok <- validate_user_ids(user_ids),
         {:ok, token} <- resolve_token(user_id, team_id, args),
         {:ok, response} <-
           Slack.open_conversation(token.access_token, user_ids,
             return_im: resolve_return_im(args)
           ) do
      channel = response["channel"] || %{}

      {:ok,
       %{
         source: "slack",
         team_id: team_id,
         token_provider: token.provider,
         channel: %{
           id: channel["id"],
           is_im: channel["is_im"] || false,
           is_mpim: channel["is_mpim"] || false,
           user: channel["user"]
         },
         ok: response["ok"]
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        SlackHelpers.normalize_error(reason)
    end
  end

  defp validate_user_ids([]), do: {:error, "user_ids is required"}
  defp validate_user_ids(_user_ids), do: :ok

  defp resolve_token(user_id, team_id, args) do
    SlackHelpers.resolve_access_token(
      user_id,
      team_id,
      token_preference: ActionHelpers.optional_string(args, "token_preference"),
      slack_user_id: ActionHelpers.optional_string(args, "slack_user_id")
    )
  end

  defp resolve_return_im(args) do
    case ActionHelpers.optional_string(args, "return_im") do
      value when value in ["true", "TRUE", "1"] -> true
      value when value in ["false", "FALSE", "0"] -> false
      _ -> nil
    end
  end
end
