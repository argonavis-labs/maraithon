defmodule Maraithon.Tools.LinearListTeams do
  @moduledoc """
  Lists Linear teams available to the connected user's OAuth token.
  """

  alias Maraithon.Connectors.Linear
  alias Maraithon.OAuth
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.ToolErrorCopy

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, access_token} <- OAuth.get_valid_access_token(user_id, "linear"),
         {:ok, teams} <- Linear.get_teams(access_token) do
      {:ok, %{source: "linear", count: length(teams), teams: teams}}
    else
      {:error, :no_token} ->
        {:error, "linear_not_connected"}

      {:error, :reauth_required} ->
        {:error, "linear_reauth_required"}

      {:error, message} when is_binary(message) ->
        {:error,
         ToolErrorCopy.safe_message(message, ToolErrorCopy.action_failed("Linear", "list teams"))}

      {:error, reason} ->
        {:error,
         ToolErrorCopy.safe_message(reason, ToolErrorCopy.action_failed("Linear", "list teams"))}
    end
  end
end
