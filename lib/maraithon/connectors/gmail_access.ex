defmodule Maraithon.Connectors.GmailAccess do
  @moduledoc "A Gmail credential paired with its stable mailbox admission key."
  alias Maraithon.{AssistantIdentities, OAuth, Repo}
  alias Maraithon.Accounts.ConnectedAccount
  alias Maraithon.Connectors.GoogleAccount

  @derive {Inspect, except: [:token]}
  defstruct [:token, :provider, :mailbox_key]

  def for_account(user_id, account_id) do
    with {:ok, account} <- GoogleAccount.resolve(user_id, account_id),
         {:ok, token} <- OAuth.get_valid_access_token(user_id, account.provider, exact?: true),
         do: {:ok, bind(account, token)}
  end

  def for_user(user_id, provider \\ "google", opts \\ []) do
    with [provider | _] <- AssistantIdentities.user_google_providers([provider], user_id),
         %OAuth.Token{} = token <-
           if(opts[:exact?],
             do: Repo.get_by(OAuth.Token, user_id: user_id, provider: provider),
             else: OAuth.get_token(user_id, provider)
           ),
         {:ok, bearer} <- OAuth.get_valid_access_token(user_id, token.provider, exact?: true),
         %ConnectedAccount{} = account <-
           Repo.get_by(ConnectedAccount,
             user_id: user_id,
             provider: token.provider,
             status: "connected"
           ) do
      {:ok, bind(account, bearer)}
    else
      [] -> {:error, :assistant_account_excluded}
      nil -> {:error, :no_token}
      {:error, _} = error -> error
    end
  end

  # Only call with a token just obtained for this account. The credential is
  # transient; neither the bearer token nor mailbox address enters the bucket.
  def bind(%ConnectedAccount{} = account, token) when is_binary(token) do
    mailbox =
      [account.metadata["account_email"], account.metadata["email"], account.external_account_id]
      |> Enum.find("account:#{account.id}", &(is_binary(&1) and String.trim(&1) != ""))

    key =
      :crypto.hash(:sha256, mailbox |> String.trim() |> String.downcase())
      |> Base.encode16(case: :lower)

    %__MODULE__{token: token, provider: account.provider, mailbox_key: key}
  end

  def request(method, url, access, body \\ nil, headers \\ [], opts \\ [])

  def request(method, url, %__MODULE__{} = access, body, headers, opts) do
    OAuth.Google.api_request(
      method,
      url,
      access.token,
      body,
      headers,
      Keyword.put(opts, :admission, {"gmail", access.mailbox_key})
    )
  end

  def request(_, _, _, _, _, _), do: {:error, :gmail_account_required}
end
