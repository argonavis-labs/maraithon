defmodule Maraithon.Tools.GmailApiHelpers do
  @moduledoc false

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Tools.ActionHelpers

  @gmail_api_base "https://gmail.googleapis.com/gmail/v1"
  @people_api_base "https://people.googleapis.com/v1"

  def request(args, method, path, body \\ nil, extra_headers \\ [])
      when is_map(args) and method in [:get, :post, :put, :patch, :delete] and is_binary(path) do
    with {:ok, _user_id, _provider, access_token} <- resolve_access(args) do
      Google.api_request(
        method,
        "#{gmail_api_base_url()}#{path}",
        access_token,
        body,
        extra_headers
      )
    end
  end

  def people_request(args, method, path, body \\ nil, extra_headers \\ [])
      when is_map(args) and method in [:get, :post, :put, :patch, :delete] and is_binary(path) do
    with {:ok, _user_id, _provider, access_token} <- resolve_access(args) do
      Google.api_request(
        method,
        "#{people_api_base_url()}#{path}",
        access_token,
        body,
        extra_headers
      )
    end
  end

  def resolve_access(args) when is_map(args) do
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id") do
      provider = provider_from_args(args)

      case OAuth.get_valid_access_token(user_id, provider) do
        {:ok, access_token} ->
          {:ok, user_id, provider, access_token}

        {:error, :no_token} when provider != "google" ->
          case OAuth.get_valid_access_token(user_id, "google") do
            {:ok, access_token} -> {:ok, user_id, "google", access_token}
            other -> other
          end

        other ->
          other
      end
    end
  end

  def list_message_ids(args, query, max_results) do
    with {:ok, _user_id, _provider, access_token} <- resolve_access(args) do
      params =
        %{}
        |> Map.put(:maxResults, max_results)
        |> maybe_put(:q, query)
        |> URI.encode_query()

      case Google.api_request(
             :get,
             "#{gmail_api_base_url()}/users/me/messages?#{params}",
             access_token
           ) do
        {:ok, %{"messages" => messages}} when is_list(messages) ->
          {:ok,
           messages
           |> Enum.map(& &1["id"])
           |> Enum.filter(&is_binary/1)}

        {:ok, _response} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def raw_message(to, subject, body, opts \\ []) do
    [
      "To: #{to}",
      maybe_header("Cc", Keyword.get(opts, :cc)),
      maybe_header("Bcc", Keyword.get(opts, :bcc)),
      "Subject: #{subject}",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8",
      maybe_header("In-Reply-To", Keyword.get(opts, :in_reply_to)),
      maybe_header("References", Keyword.get(opts, :references)),
      "",
      body
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\r\n")
    |> Base.url_encode64(padding: false)
  end

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}
  def normalize_error(:reauth_required), do: {:error, "google_account_reauth_required"}
  def normalize_error(:no_refresh_token), do: {:error, "google_account_reconnect_required"}
  def normalize_error(message) when is_binary(message), do: {:error, message}

  def normalize_error({:http_status, status, body}) when status in [401, 403],
    do: {:error, "google_account_reauth_required: #{body}"}

  def normalize_error({:http_status, status, body}),
    do: {:error, "google_api_failed: #{status} #{body}"}

  def normalize_error(reason), do: {:error, "google_tool_failed: #{inspect(reason)}"}

  def optional_bool(args, key) do
    case ActionHelpers.optional_string(args, key) do
      value when value in ["true", "TRUE", "1"] -> true
      value when value in ["false", "FALSE", "0"] -> false
      _ -> nil
    end
  end

  def compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  def provider_from_args(args) do
    cond do
      provider = ActionHelpers.optional_string(args, "provider") ->
        provider

      account = ActionHelpers.optional_string(args, "account") ->
        "google:#{account}"

      true ->
        "google"
    end
  end

  defp gmail_api_base_url do
    Application.get_env(:maraithon, :gmail, [])
    |> Keyword.get(:api_base_url, @gmail_api_base)
  end

  defp people_api_base_url do
    Application.get_env(:maraithon, :google, [])
    |> Keyword.get(:people_api_base_url, @people_api_base)
  end

  defp maybe_header(_name, nil), do: nil
  defp maybe_header(_name, ""), do: nil
  defp maybe_header(name, value), do: "#{name}: #{value}"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?([]), do: true
  defp blank?(%{}), do: true
  defp blank?(_value), do: false
end
