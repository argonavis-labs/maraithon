defmodule Maraithon.Tools.GmailSendMessage do
  @moduledoc """
  Sends a Gmail message using the connected user's OAuth grant.
  """

  alias Maraithon.Connectors.Gmail
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.ToolErrorCopy

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, to} <- ActionHelpers.required_string(args, "to"),
         {:ok, subject} <- ActionHelpers.required_string(args, "subject"),
         {:ok, body} <- ActionHelpers.required_string(args, "body"),
         {:ok, result} <-
           Gmail.send_message(user_id, %{
             account: ActionHelpers.optional_string(args, "account"),
             to: to,
             subject: subject,
             body: body,
             thread_id: ActionHelpers.optional_string(args, "thread_id"),
             reply_to_message_id: ActionHelpers.optional_string(args, "reply_to_message_id")
           }) do
      {:ok, Map.put(result, :source, "gmail")}
    else
      {:error, :no_token} ->
        {:error, "google_account_not_connected"}

      {:error, :reauth_required} ->
        {:error, "google_account_reauth_required"}

      {:error, message} when is_binary(message) ->
        {:error,
         ToolErrorCopy.safe_message(
           message,
           ToolErrorCopy.action_failed("Gmail", "send that message")
         )}

      {:error, reason} ->
        {:error, ToolErrorCopy.connected_source(reason, google_error_opts())}
    end
  end

  defp google_error_opts do
    [
      label: "Gmail",
      not_connected: "google_account_not_connected",
      reauth_required: "google_account_reauth_required",
      reconnect_required: "google_account_reconnect_required"
    ]
  end
end
