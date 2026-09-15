defmodule Maraithon.AssistantIdentities do
  @moduledoc "User-owned assistant identities, never substitutes for a missing user grant."
  import Ecto.Query
  alias Maraithon.{Repo, OAuth, Accounts.ConnectedAccount}
  alias Maraithon.Delegations.AssistantIdentity
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Tools.GmailApiHelpers

  @fields ~w(display_name gmail_send_as_email slack_username slack_icon_url disclosure_line disclose_ai cc_user_on_first_send signature_text)
  @defaults %{"disclose_ai" => true, "cc_user_on_first_send" => false}

  def get(user_id),
    do: Repo.get_by(AssistantIdentity, user_id: user_id) |> AssistantIdentity.hydrate()

  def assistant_account_ids(user_id) do
    assistant_accounts(user_id)
    |> select([a], a.id)
    |> Repo.all()
  end

  @doc "Exclude dedicated assistant accounts, including previous identities and pending setup."
  def user_accounts(query \\ ConnectedAccount) do
    excluded = assistant_filter()
    included = dynamic([a], not (^excluded))
    from a in query, where: ^included
  end

  defp assistant_filter do
    bound =
      from i in AssistantIdentity,
        where: i.gmail_mode == "account" and not is_nil(i.gmail_connected_account_id),
        select: i.gmail_connected_account_id

    dynamic(
      [a],
      fragment("COALESCE(?->>'assistant_account', 'false') = 'true'", a.metadata) or
        a.id in subquery(bound)
    )
  end

  defp assistant_accounts(user_id) do
    excluded = assistant_filter()
    from a in ConnectedAccount, where: a.user_id == ^user_id, where: ^excluded
  end

  def assistant_providers(user_id) do
    assistant_accounts(user_id) |> select([a], a.provider) |> Repo.all()
  end

  def user_google_providers(providers, user_id) do
    excluded = assistant_providers(user_id)

    # The legacy "google" token lookup can fall back to any account. Resolve it
    # explicitly whenever an assistant account is present so that an empty user
    # account set cannot reopen the assistant's inbox through that fallback.
    if excluded == [] do
      providers
    else
      tokens = Maraithon.OAuth.list_user_tokens(user_id)
      providers = if providers == ["google"], do: Enum.map(tokens, & &1.provider), else: providers

      Enum.filter(providers, fn provider ->
        provider not in excluded and
          (String.starts_with?(provider, "google:") or
             (provider == "google" and Enum.any?(tokens, &(&1.provider == "google"))))
      end)
    end
  end

  def assistant_emails(user_id) do
    assistant_accounts(user_id)
    |> select([a], {a.external_account_id, a.metadata, a.provider})
    |> Repo.all()
    |> Enum.flat_map(fn {external_id, metadata, provider} ->
      [
        external_id,
        metadata["account_email"],
        metadata["email"],
        String.replace_prefix(provider, "google:", "")
      ]
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
  end

  def assistant_account?(%ConnectedAccount{id: id, user_id: user_id}),
    do: id in assistant_account_ids(user_id)

  def assistant_account?(_), do: false

  def connect_google(user_id, provider, tokens, "assistant") do
    metadata = tokens.metadata
    account = Maraithon.ConnectedAccounts.get(user_id, provider)

    if metadata["account_email"] == user_id or (account && not assistant_account?(account)) do
      {:error, :assistant_account_is_personal}
    else
      tokens = Map.put(tokens, :metadata, Map.put(metadata, "assistant_account", true))

      with {:ok, token} <- Maraithon.OAuth.store_tokens(user_id, provider, tokens) do
        Maraithon.UserIdentity.invalidate(user_id)
        account = Maraithon.ConnectedAccounts.get(user_id, provider)
        identity = get(user_id)

        case configure(user_id, %{
               "display_name" =>
                 (identity && identity.data["display_name"]) || metadata["account_name"] ||
                   "Your assistant",
               "gmail_connected_account_id" => account.id,
               "gmail_mode" => "account",
               "gmail_send_as_email" => metadata["account_email"]
             }) do
          {:ok, _} -> {:ok, token}
          {:error, reason} -> {:error, {:assistant_setup_failed, reason}}
        end
      end
    end
  end

  def connect_google(user_id, provider, tokens, _),
    do: Maraithon.OAuth.store_tokens(user_id, provider, tokens)

  def configure(user_id, attrs) do
    with {:ok, aliases} <- send_as(user_id, attrs["gmail_connected_account_id"]),
         %{} = sender <- Enum.find(aliases, &(&1["sendAsEmail"] == attrs["gmail_send_as_email"])),
         true <-
           (attrs["gmail_mode"] == "alias" and sender["isPrimary"] != true) or
             (attrs["gmail_mode"] == "account" and sender["isPrimary"] == true and
                sender["sendAsEmail"] != user_id) do
      put(user_id, attrs)
    else
      {:error, _} = error -> error
      _ -> {:error, :sending_identity_unavailable}
    end
  end

  def put(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    Repo.transaction(fn ->
      Maraithon.DurablePayload.require_current_mutation!()
      WriteFence.lock_user_writable!(user_id)
      row = get(user_id) || %AssistantIdentity{user_id: user_id, data: @defaults}
      data = Map.merge(row.data, Map.take(attrs, @fields))
      account_id = Map.get(attrs, "gmail_connected_account_id", row.gmail_connected_account_id)

      with :ok <- validate(data),
           true <- is_integer(account_id),
           %ConnectedAccount{status: "connected"} <-
             Repo.get_by(ConnectedAccount, id: account_id, user_id: user_id),
           {:ok, changed} <-
             row
             |> AssistantIdentity.changeset(
               Map.take(attrs, ~w(gmail_connected_account_id gmail_mode))
               |> Map.put("data", data)
             )
             |> Repo.insert_or_update() do
        Enum.each([row, changed], &retain_account_purpose!/1)
        changed
      else
        {:error, reason} -> Repo.rollback(reason)
        _ -> Repo.rollback(:google_account_not_connected)
      end
    end)
    |> tap(fn
      {:ok, _} -> Maraithon.UserIdentity.invalidate(user_id)
      _ -> :ok
    end)
  end

  defp retain_account_purpose!(%AssistantIdentity{
         gmail_mode: "account",
         gmail_connected_account_id: id,
         user_id: user_id
       })
       when is_integer(id) do
    account = Repo.get_by!(ConnectedAccount, id: id, user_id: user_id)

    account
    |> Ecto.Changeset.change(
      metadata: Map.put(account.metadata || %{}, "assistant_account", true)
    )
    |> Repo.update!()
  end

  defp retain_account_purpose!(_), do: :ok

  def send_as(user_id, account_id) do
    with true <- is_integer(account_id),
         %ConnectedAccount{status: "connected"} = account <-
           Repo.get_by(ConnectedAccount, id: account_id, user_id: user_id),
         true <- account.provider == "google" or String.starts_with?(account.provider, "google:"),
         {:ok, %{"sendAs" => aliases}} <-
           GmailApiHelpers.get_for_account(user_id, account.id, "/users/me/settings/sendAs") do
      {:ok,
       Enum.filter(aliases, &(&1["isPrimary"] == true or &1["verificationStatus"] == "accepted"))}
    else
      {:error, _} = error -> error
      _ -> {:error, :google_account_not_connected}
    end
  end

  def gmail_snapshot(user_id, actor, source_account_id) when actor in ~w(as_user as_assistant) do
    identity = if actor == "as_assistant", do: get(user_id)
    id = if identity, do: identity.gmail_connected_account_id, else: source_account_id

    with true <- actor == "as_user" or identity != nil,
         true <- is_integer(id),
         %ConnectedAccount{status: "connected"} = account <-
           Repo.get_by(ConnectedAccount, id: id, user_id: user_id),
         false <- actor == "as_user" and assistant_account?(account),
         true <-
           OAuth.gmail_send_scopes?(account.scopes) ||
             {:error, :gmail_sending_permission_required},
         {:ok, aliases} <- send_as(user_id, account.id),
         %{} = sender <- sender_alias(aliases, identity) do
      {:ok,
       %{
         "account_id" => account.id,
         "provider" => account.provider,
         "external_account_id" => account.external_account_id,
         "actor" => actor,
         "email" => sender["sendAsEmail"],
         "display_name" =>
           if(identity,
             do: identity.data["display_name"],
             else: nonempty(sender["displayName"]) || account.metadata["account_name"]
           ),
         "signature" => signature(identity, sender),
         "signature_html" => signature_html(identity, sender),
         "disclose_ai" => not is_nil(identity) and identity.data["disclose_ai"] == true,
         "cc_user_on_first_send" =>
           not is_nil(identity) and identity.data["cc_user_on_first_send"] == true,
         "assistant_identity_id" => identity && identity.id
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :sending_identity_unavailable}
    end
  end

  defp sender_alias(aliases, nil), do: Enum.find(aliases, &(&1["isPrimary"] == true))

  defp sender_alias(aliases, identity),
    do: Enum.find(aliases, &(&1["sendAsEmail"] == identity.data["gmail_send_as_email"]))

  defp signature(nil, sender), do: mailbox_signature(sender)

  defp signature(identity, sender) do
    [
      nonempty(identity.data["signature_text"]) || mailbox_signature(sender),
      if(identity.data["disclose_ai"],
        do:
          identity.data["disclosure_line"] ||
            "I'm an AI assistant handling scheduling and follow-ups."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp mailbox_signature(sender),
    do: Maraithon.Connectors.Gmail.BodyText.signature(sender["signature"] || "")

  defp signature_html(identity, sender) do
    override = identity && nonempty(identity.data["signature_text"])

    footer =
      if override,
        do: Maraithon.Delegations.EmailBody.text_html(override),
        else: sender["signature"] || ""

    disclosure =
      if identity && identity.data["disclose_ai"],
        do:
          identity.data["disclosure_line"] ||
            "I'm an AI assistant handling scheduling and follow-ups."

    footer <>
      if(disclosure,
        do: "<br>" <> Maraithon.Delegations.EmailBody.text_html(disclosure),
        else: ""
      )
  end

  defp nonempty(value) when is_binary(value), do: if(String.trim(value) != "", do: value)
  defp nonempty(_), do: nil

  defp validate(data) do
    cond do
      not is_binary(data["display_name"]) or String.trim(data["display_name"]) == "" ->
        {:error, :assistant_name_required}

      not Enum.all?(@fields -- ~w(disclose_ai cc_user_on_first_send), fn key ->
        is_nil(data[key]) or (is_binary(data[key]) and byte_size(data[key]) <= 2_000)
      end) ->
        {:error, :invalid_identity_text}

      not is_boolean(data["disclose_ai"]) or not is_boolean(data["cc_user_on_first_send"]) ->
        {:error, :invalid_identity_setting}

      Enum.any?(
        ~w(display_name gmail_send_as_email slack_username),
        &(is_binary(data[&1]) and String.contains?(data[&1], ["\r", "\n"]))
      ) ->
        {:error, :invalid_identity_header}

      true ->
        :ok
    end
  end
end
