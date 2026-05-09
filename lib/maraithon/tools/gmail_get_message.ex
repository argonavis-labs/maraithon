defmodule Maraithon.Tools.GmailGetMessage do
  @moduledoc """
  Fetches a single Gmail message by message id for a connected Google account.
  """

  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.GmailHelpers

  def execute(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         {:ok, message_id} <- ActionHelpers.required_string(args, "message_id"),
         {:ok, message} <-
           GmailHelpers.get_message(user_id, message_id, provider: google_provider(args)) do
      {:ok,
       %{
         source: "gmail",
         message_id: message_id,
         message: message
       }}
    else
      {:error, message} when is_binary(message) ->
        {:error, message}

      {:error, reason} ->
        GmailHelpers.normalize_error(reason)
    end
  end

  defp google_provider(args) do
    ActionHelpers.optional_string(args, "google_provider") ||
      ActionHelpers.optional_string(args, "provider") ||
      google_provider_for_account(args)
  end

  defp google_provider_for_account(args) do
    case ActionHelpers.optional_string(args, "google_account_email") ||
           ActionHelpers.optional_string(args, "account_email") ||
           ActionHelpers.optional_string(args, "account") do
      nil -> nil
      "google:" <> _ = provider -> provider
      account_email -> "google:#{account_email}"
    end
  end
end
