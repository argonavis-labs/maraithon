defmodule Maraithon.Tools.GmailHelpers do
  @moduledoc false

  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.Gmail
  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google

  @default_api_base "https://gmail.googleapis.com/gmail/v1"

  def list_messages(user_id, opts \\ []) when is_binary(user_id) do
    max_results = Keyword.get(opts, :max_results, 10)
    query = Keyword.get(opts, :query)
    label_ids = Keyword.get(opts, :label_ids, ["INBOX"])
    provider = Keyword.get(opts, :provider)

    providers =
      user_id
      |> providers_for_search(provider)
      |> Enum.uniq()

    fetch_messages_from_providers(user_id, providers, max_results, query, label_ids)
  end

  def get_message(user_id, message_id, opts \\ [])
      when is_binary(user_id) and is_binary(message_id) do
    providers = providers_for_search(user_id, Keyword.get(opts, :provider))

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
  def normalize_error(:reauth_required), do: {:error, "google_reauth_required"}

  def normalize_error({:http_status, status, _body}) when status in [401, 403],
    do: {:error, "google_reauth_required"}

  def normalize_error({:http_status, status, body}),
    do: {:error, "gmail_api_failed: #{status} #{body}"}

  def normalize_error(reason), do: {:error, "gmail_tool_failed: #{inspect(reason)}"}

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
    with {:ok, access_token} <- OAuth.get_valid_access_token(user_id, provider),
         {:ok, message_ids} <- fetch_message_ids(access_token, max_results, query, label_ids) do
      messages =
        message_ids
        |> Task.async_stream(
          fn message_id ->
            Gmail.fetch_message_content(access_token, message_id, access_token: true)
          end,
          max_concurrency: message_concurrency(message_ids),
          ordered: true,
          timeout: :infinity
        )
        |> Enum.filter(&match?({:ok, {:ok, _}}, &1))
        |> Enum.map(fn {:ok, {:ok, message}} ->
          message
          |> Map.put(:google_provider, provider)
          |> Map.put(:google_account_email, provider_account_email(provider))
        end)

      {:ok, messages}
    end
  end

  defp provider_concurrency(providers), do: providers |> length() |> max(1) |> min(4)
  defp message_concurrency(message_ids), do: message_ids |> length() |> max(1) |> min(8)

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

  defp message_sort_value(%{internal_date: %DateTime{} = internal_date}),
    do: DateTime.to_unix(internal_date, :microsecond)

  defp message_sort_value(_message), do: 0

  defp fetch_message_ids(access_token, max_results, query, label_ids) do
    params =
      %{}
      |> Map.put(:maxResults, max_results)
      |> maybe_put(:q, query)
      |> maybe_put(:labelIds, encode_label_ids(label_ids))
      |> URI.encode_query()

    url = "#{api_base_url()}/users/me/messages?#{params}"

    case Google.api_request(:get, url, access_token) do
      {:ok, %{"messages" => messages}} when is_list(messages) ->
        message_ids =
          messages
          |> Enum.take(max_results)
          |> Enum.map(fn message -> message["id"] end)
          |> Enum.filter(&is_binary/1)

        {:ok, message_ids}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, ""), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp encode_label_ids([]), do: nil
  defp encode_label_ids(nil), do: nil
  defp encode_label_ids(ids) when is_list(ids), do: Enum.join(ids, ",")

  defp api_base_url do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:api_base_url, @default_api_base)
  end
end
