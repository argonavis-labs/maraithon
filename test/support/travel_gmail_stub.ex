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

    error =
      config(:fetch_errors_by_provider, %{})
      |> Map.get(provider, config(:fetch_error, nil))

    if error do
      {:error, error}
    else
      messages =
        config(:messages_by_provider, %{})
        |> Map.get(provider, config(:messages, []))

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

  defp config(key, default) do
    Application.get_env(:maraithon, __MODULE__, [])
    |> Keyword.get(key, default)
  end
end
