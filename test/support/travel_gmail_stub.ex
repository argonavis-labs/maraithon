defmodule Maraithon.TestSupport.TravelGmailStub do
  @moduledoc false

  def configure(opts) when is_list(opts) do
    Application.put_env(:maraithon, __MODULE__, opts)
  end

  def fetch_messages(_user_id, opts \\ []) do
    Application.put_env(:maraithon, :travel_gmail_stub_last_fetch_opts, opts)

    if config(:fetch_messages_hang, false) do
      receive do
        :never -> :ok
      end
    end

    provider = Keyword.get(opts, :provider)
    query = Keyword.get(opts, :query, "")

    error =
      config(:fetch_errors_by_provider, %{})
      |> Map.get(provider, config(:fetch_error, nil))

    if error do
      {:error, error}
    else
      messages =
        case messages_for_query(provider, query) do
          {:matched, messages} ->
            messages

          :no_match ->
            config(:messages_by_provider, %{})
            |> Map.get(provider, config(:messages, []))
        end

      metadata =
        config(:fetch_metadata_by_provider, %{})
        |> Map.get(provider, config(:fetch_metadata, nil))

      if is_map(metadata) and Keyword.get(opts, :include_fetch_metadata, false) do
        {:ok, messages, metadata}
      else
        {:ok, messages}
      end
    end
  end

  def last_fetch_opts do
    Application.get_env(:maraithon, :travel_gmail_stub_last_fetch_opts, [])
  end

  def fetch_message_content(_user_id, message_id) when is_binary(message_id) do
    if message_id in config(:content_hang_ids, []) do
      receive do
        :never -> :ok
      end
    end

    case config(:contents, %{}) do
      %{^message_id => content} -> {:ok, content}
      _ -> {:error, :not_found}
    end
  end

  def fetch_message_content(user_id, message_id, _opts)
      when is_binary(user_id) and is_binary(message_id) do
    fetch_message_content(user_id, message_id)
  end

  def fetch_thread_content(_user_id, thread_id, opts \\ []) when is_binary(thread_id) do
    provider = Keyword.get(opts, :provider)

    case config(:thread_fetch_errors_by_thread, %{}) |> Map.get(thread_id) do
      nil ->
        configured =
          config(:threads_by_provider, %{})
          |> Map.get(provider, %{})
          |> Map.get(thread_id)

        messages =
          if is_list(configured) do
            configured
          else
            provider
            |> configured_messages()
            |> Enum.filter(fn message ->
              field(message, :thread_id) == thread_id
            end)
          end

        {:ok, messages}

      reason ->
        {:error, reason}
    end
  end

  defp messages_for_query(provider, query) when is_binary(query) do
    config(:messages_by_query_match, [])
    |> Enum.find_value(:no_match, fn
      {needle, messages_by_provider} when is_binary(needle) and is_map(messages_by_provider) ->
        if String.contains?(query, needle) do
          {:matched, Map.get(messages_by_provider, provider, [])}
        end

      {needle, messages} when is_binary(needle) and is_list(messages) ->
        if String.contains?(query, needle), do: {:matched, messages}

      _other ->
        nil
    end)
  end

  defp messages_for_query(_provider, _query), do: :no_match

  defp configured_messages(provider) do
    provider_messages =
      config(:messages_by_provider, %{})
      |> Map.get(provider, [])

    query_messages =
      config(:messages_by_query_match, [])
      |> Enum.flat_map(fn
        {_needle, messages_by_provider} when is_map(messages_by_provider) ->
          Map.get(messages_by_provider, provider, [])

        {_needle, messages} when is_list(messages) ->
          messages

        _other ->
          []
      end)

    (provider_messages ++ config(:messages, []) ++ query_messages)
    |> Enum.uniq_by(&(field(&1, :message_id) || field(&1, :id)))
  end

  defp field(message, key) when is_map(message) do
    Map.get(message, key, Map.get(message, Atom.to_string(key)))
  end

  defp config(key, default) do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
