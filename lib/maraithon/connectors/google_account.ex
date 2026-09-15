defmodule Maraithon.Connectors.GoogleAccount do
  @moduledoc "Resolve an explicit connected Google account without mailbox fallback."
  alias Maraithon.{OAuth, Repo}
  alias Maraithon.Accounts.ConnectedAccount

  def resolve(user_id, id) when is_integer(id) do
    case Repo.get_by(ConnectedAccount, id: id, user_id: user_id, status: "connected") do
      %{provider: provider} = account ->
        if provider == "google" or String.starts_with?(provider, "google:"),
          do: {:ok, account},
          else: {:error, :invalid_google_account}

      _ ->
        {:error, :invalid_google_account}
    end
  end

  def resolve(_, _), do: {:error, :invalid_google_account}

  def access_token(user_id, nil), do: user_access_token(user_id)

  def access_token(user_id, id) do
    with {:ok, account} <- resolve(user_id, id),
         do: OAuth.get_valid_access_token(user_id, account.provider, exact?: true)
  end

  @doc "Personal reads cannot fall back to a dedicated assistant's Google account."
  def user_access_token(user_id, provider \\ "google") do
    case Maraithon.AssistantIdentities.user_google_providers([provider], user_id) do
      [resolved | _] ->
        OAuth.get_valid_access_token(user_id, resolved, exact?: resolved != "google")

      [] ->
        {:error, :assistant_account_excluded}
    end
  end
end
