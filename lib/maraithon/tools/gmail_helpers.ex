defmodule Maraithon.Tools.GmailHelpers do
  @moduledoc false

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth
  alias Maraithon.Tools.ToolErrorCopy

  def list_messages(user_id, opts \\ []) when is_binary(user_id) do
    max_results = Keyword.get(opts, :max_results, 10)
    query = Keyword.get(opts, :query)
    label_ids = Keyword.get(opts, :label_ids, ["INBOX"])
    provider = Keyword.get(opts, :provider)

    providers =
      user_id
      |> providers_for_search(provider)
      |> Maraithon.AssistantIdentities.user_google_providers(user_id)
      |> Enum.uniq()

    fetch_messages_from_providers(user_id, providers, max_results, query, label_ids)
  end

  def get_message(user_id, message_id, opts \\ [])
      when is_binary(user_id) and is_binary(message_id) do
    providers =
      providers_for_search(user_id, Keyword.get(opts, :provider))
      |> Maraithon.AssistantIdentities.user_google_providers(user_id)

    providers
    |> Enum.reduce_while({:error, :no_token}, fn provider, _acc ->
      case Gmail.fetch_message_content(user_id, message_id, provider: provider) do
        {:ok, message} ->
          {:halt,
           {:ok,
            message
            |> Map.put(:google_provider, provider)
            |> Map.put(:google_account_email, provider_account_email(provider))}}

        {:error, reason} ->
          ConnectedAccounts.report_access_issue(user_id, provider, reason)
          {:cont, {:error, reason}}
      end
    end)
  end

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}
  def normalize_error(:reauth_required), do: {:error, "google_account_reauth_required"}

  def normalize_error({:http_status, status, _body}) when status in [401, 403],
    do: {:error, "google_account_reauth_required"}

  def normalize_error(reason),
    do: {:error, ToolErrorCopy.connected_source(reason, google_error_opts("Gmail"))}

  defp fetch_messages_from_providers(_user_id, [], _max_results, _query, _label_ids),
    do: {:error, :no_token}

  defp fetch_messages_from_providers(user_id, providers, max_results, query, label_ids) do
    {messages, errors} =
      providers
      |> Task.async_stream(
        fn provider ->
          {provider,
           fetch_messages_from_provider(user_id, provider, max_results, query, label_ids)}
        end,
        max_concurrency: provider_concurrency(providers),
        ordered: true,
        timeout: :infinity
      )
      |> Enum.reduce({[], []}, fn
        {:ok, {_provider, {:ok, provider_messages}}}, {message_acc, error_acc} ->
          {provider_messages ++ message_acc, error_acc}

        {:ok, {provider, {:error, reason}}}, {message_acc, error_acc} ->
          ConnectedAccounts.report_access_issue(user_id, provider, reason)
          {message_acc, [{provider, reason} | error_acc]}

        {:exit, reason}, {message_acc, error_acc} ->
          {message_acc, [{nil, reason} | error_acc]}
      end)

    case Enum.sort_by(messages, &message_sort_value/1, :desc) |> Enum.take(max_results) do
      [] ->
        case List.first(errors) do
          {_provider, reason} -> {:error, reason}
          nil -> {:ok, []}
        end

      sorted_messages ->
        {:ok, sorted_messages}
    end
  end

  defp fetch_messages_from_provider(user_id, provider, max_results, query, label_ids)
       when is_binary(user_id) and is_binary(provider) do
    with {:ok, messages} <-
           Gmail.fetch_messages(user_id,
             provider: provider,
             max_results: max_results,
             query: query,
             label_ids: label_ids,
             message_format: :full
           ) do
      {:ok,
       Enum.map(messages, fn message ->
         message
         |> Map.put(:google_provider, provider)
         |> Map.put(:google_account_email, provider_account_email(provider))
       end)}
    end
  end

  defp provider_concurrency(providers), do: providers |> length() |> max(1) |> min(4)

  defp providers_for_search(user_id, provider) when provider in [nil, "", "google"] do
    connected_google_providers(user_id)
    |> case do
      [] -> ["google"]
      providers -> providers
    end
  end

  defp providers_for_search(_user_id, provider) when is_binary(provider), do: [provider]
  defp providers_for_search(_user_id, _provider), do: ["google"]

  defp connected_google_providers(user_id) when is_binary(user_id) do
    account_providers =
      user_id
      |> ConnectedAccounts.list_for_user()
      |> Enum.filter(fn account ->
        account.status == "connected" and String.starts_with?(account.provider, "google:")
      end)
      |> Enum.map(& &1.provider)

    token_providers =
      user_id
      |> OAuth.list_user_tokens()
      |> Enum.map(& &1.provider)
      |> Enum.filter(&String.starts_with?(&1, "google:"))

    (account_providers ++ token_providers)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp connected_google_providers(_user_id), do: []

  defp provider_account_email("google:" <> account_email), do: account_email
  defp provider_account_email(_provider), do: nil

  defp google_error_opts(label) do
    [
      label: label,
      not_connected: "google_account_not_connected",
      reauth_required: "google_account_reauth_required",
      reconnect_required: "google_account_reconnect_required"
    ]
  end

  defp message_sort_value(%{internal_date: %DateTime{} = internal_date}),
    do: DateTime.to_unix(internal_date, :microsecond)

  defp message_sort_value(_message), do: 0
end
