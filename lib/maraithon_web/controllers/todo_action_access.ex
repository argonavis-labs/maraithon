defmodule MaraithonWeb.TodoActionAccess do
  @moduledoc "Shows the connected account and missing write consent beside a proposed action."
  alias Maraithon.OAuth

  def enrich(card, user_id, payload \\ %{})

  def enrich(%{"provider" => provider} = card, user_id, payload)
      when provider in ["gmail", "calendar"] do
    account_provider =
      if provider == "calendar",
        do: "google",
        else:
          card["google_provider"] || Maraithon.Tools.GmailApiHelpers.provider_from_args(payload)

    token = OAuth.get_token(user_id, account_provider)
    scopes = if token, do: token.scopes || [], else: []

    email =
      if token,
        do: token.metadata["email"] || String.replace_prefix(token.provider, "google:", "")

    card = if email && email != "google", do: Map.put(card, "from", email), else: card

    if writable?(provider, scopes) or terminal?(card) do
      card
    else
      service = if provider == "gmail", do: "gmail_compose", else: "calendar_write"

      label =
        if provider == "gmail",
          do: "Enable Gmail drafts & sending",
          else: "Enable calendar booking"

      params = %{"user_id" => user_id, "scopes" => service, "return_to" => "/todos"}
      params = if email, do: Map.put(params, "login_hint", email), else: params

      Map.merge(card, %{
        "connection_required" => true,
        "connection_label" => label,
        "connection_notice" =>
          "Google access is read-only. Enable permission for this action to continue.",
        "connection_url" =>
          Maraithon.AppUrl.base_url() <> "/auth/google?" <> URI.encode_query(params)
      })
    end
  end

  def enrich(card, _, _), do: card

  defp writable?("gmail", scopes),
    do:
      Enum.any?(
        scopes,
        &(&1 in [
            "https://mail.google.com/",
            "https://www.googleapis.com/auth/gmail.compose",
            "https://www.googleapis.com/auth/gmail.modify"
          ])
      )

  defp writable?("calendar", scopes),
    do:
      Enum.any?(
        scopes,
        &(&1 in [
            "https://www.googleapis.com/auth/calendar",
            "https://www.googleapis.com/auth/calendar.events",
            "https://www.googleapis.com/auth/calendar.events.owned"
          ])
      )

  defp terminal?(card),
    do: card["status"] in ["Sent", "Saved to calendar", "Cancelled", "Expired"]
end
