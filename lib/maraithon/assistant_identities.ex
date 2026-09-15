defmodule Maraithon.AssistantIdentities do
  @moduledoc "User-owned assistant identities, never substitutes for a missing user grant."
  alias Maraithon.{Repo, Accounts.ConnectedAccount}
  alias Maraithon.Delegations.AssistantIdentity
  alias Maraithon.PrivacyErasure.WriteFence
  alias Maraithon.Tools.GmailApiHelpers

  @fields ~w(display_name gmail_send_as_email slack_username slack_icon_url disclosure_line disclose_ai cc_user_on_first_send signature_text)
  @defaults %{"disclose_ai" => true, "cc_user_on_first_send" => false}

  def get(user_id),
    do: Repo.get_by(AssistantIdentity, user_id: user_id) |> AssistantIdentity.hydrate()

  def assistant_account_ids(user_id) do
    case get(user_id) do
      %AssistantIdentity{gmail_mode: "account", gmail_connected_account_id: id}
      when is_integer(id) ->
        [id]

      _ ->
        []
    end
  end

  def assistant_account?(%ConnectedAccount{id: id, user_id: user_id}),
    do: id in assistant_account_ids(user_id)

  def assistant_account?(_), do: false

  def configure(user_id, attrs) do
    with {:ok, aliases} <- send_as(user_id, attrs["gmail_connected_account_id"]),
         %{} = sender <- Enum.find(aliases, &(&1["sendAsEmail"] == attrs["gmail_send_as_email"])),
         true <- attrs["gmail_mode"] == "alias" or sender["isPrimary"] == true do
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

      with :ok <- validate(data),
           {:ok, changed} <-
             row
             |> AssistantIdentity.changeset(
               Map.take(attrs, ~w(gmail_connected_account_id gmail_mode))
               |> Map.put("data", data)
             )
             |> Repo.insert_or_update() do
        changed
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def send_as(user_id, account_id) do
    with true <- is_integer(account_id),
         %ConnectedAccount{status: "connected"} = account <-
           Repo.get_by(ConnectedAccount, id: account_id, user_id: user_id),
         true <- account.provider == "google" or String.starts_with?(account.provider, "google:"),
         {:ok, %{"sendAs" => aliases}} <-
           GmailApiHelpers.request(api_args(account), :get, "/users/me/settings/sendAs") do
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
           if(identity, do: identity.data["display_name"], else: sender["displayName"]),
         "signature" => if(identity, do: signature(identity), else: sender["signature"] || ""),
         "assistant_identity_id" => identity && identity.id
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :sending_identity_unavailable}
    end
  end

  def api_args(%ConnectedAccount{} = account),
    do: %{"user_id" => account.user_id, "provider" => account.provider, "exact_account" => true}

  defp sender_alias(aliases, nil), do: Enum.find(aliases, &(&1["isPrimary"] == true))

  defp sender_alias(aliases, identity),
    do: Enum.find(aliases, &(&1["sendAsEmail"] == identity.data["gmail_send_as_email"]))

  defp signature(identity) do
    [
      identity.data["signature_text"] || identity.data["display_name"],
      if(identity.data["disclose_ai"],
        do:
          identity.data["disclosure_line"] ||
            "I'm an AI assistant handling scheduling and follow-ups."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

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
