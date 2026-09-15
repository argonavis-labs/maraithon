defmodule Maraithon.Tools.GmailApiHelpers do
  @moduledoc false

  alias Maraithon.OAuth
  alias Maraithon.OAuth.Google
  alias Maraithon.Tools.ActionHelpers
  alias Maraithon.Tools.ToolErrorCopy

  @gmail_api_base "https://gmail.googleapis.com/gmail/v1"
  @people_api_base "https://people.googleapis.com/v1"

  @doc "Read a verified account for identity setup or frozen-action reconciliation. No fallback."
  def get_for_account(user_id, account_id, path) do
    with {:ok, account} <- Maraithon.Connectors.GoogleAccount.resolve(user_id, account_id),
         {:ok, access_token} <-
           OAuth.get_valid_access_token(user_id, account.provider, exact?: true) do
      Google.api_request(:get, "#{gmail_api_base_url()}#{path}", access_token)
    end
  end

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
    with {:ok, user_id} <- ActionHelpers.required_string(args, "user_id"),
         requested = provider_from_args(args),
         candidates =
           Maraithon.AssistantIdentities.user_google_providers(
             [requested],
             user_id
           ),
         [provider | _] <-
           if(args["exact_account"] == true,
             do: Enum.filter(candidates, &(&1 == requested)),
             else: candidates
           ),
         {:ok, access_token} <-
           OAuth.get_valid_access_token(user_id, provider,
             exact?: args["exact_account"] == true or provider != "google"
           ) do
      {:ok, user_id, provider, access_token}
    else
      [] -> {:error, :assistant_account_excluded}
      error -> error
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
      maybe_header("From", named_sender(Keyword.get(opts, :from), Keyword.get(opts, :from_name))),
      maybe_header("Cc", Keyword.get(opts, :cc)),
      maybe_header("Bcc", Keyword.get(opts, :bcc)),
      "Subject: #{subject}",
      "Date: #{Calendar.strftime(DateTime.utc_now(), "%a, %d %b %Y %H:%M:%S +0000")}",
      message_id_header(Keyword.get(opts, :message_id_header)),
      "MIME-Version: 1.0",
      maybe_header("In-Reply-To", Keyword.get(opts, :in_reply_to)),
      maybe_header("References", Keyword.get(opts, :references))
    ]
    |> Enum.reject(&is_nil/1)
    |> Kernel.++(mime_body(body, Keyword.get(opts, :html_body)))
    |> Enum.join("\r\n")
    |> Base.url_encode64(padding: false)
  end

  defp mime_body(body, html) when is_binary(html) and html != "" do
    boundary =
      "maraithon_" <>
        (:crypto.hash(:sha256, body <> html)
         |> Base.encode16(case: :lower)
         |> String.slice(0, 32))

    ["Content-Type: multipart/alternative; boundary=\"#{boundary}\"", ""] ++
      Enum.flat_map([{"plain", body}, {"html", html}], fn {type, content} ->
        [
          "--#{boundary}",
          "Content-Type: text/#{type}; charset=UTF-8",
          "Content-Transfer-Encoding: base64",
          "",
          encode_part(content)
        ]
      end) ++ ["--#{boundary}--"]
  end

  defp mime_body(body, _), do: ["Content-Type: text/plain; charset=UTF-8", "", body]

  defp encode_part(content),
    do:
      content
      |> Base.encode64()
      |> String.codepoints()
      |> Enum.chunk_every(76)
      |> Enum.map_join("\r\n", &Enum.join/1)

  defp named_sender(email, name) when is_binary(email) and is_binary(name) and name != "",
    do: "=?UTF-8?B?#{Base.encode64(name)}?= <#{email}>"

  defp named_sender(email, _), do: email

  @doc false
  def message_id_header(id) when is_binary(id) do
    if byte_size(id) <= 255 and
         Regex.match?(~r/^<[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9.-]+>$/, id),
       do: "Message-ID: " <> id
  end

  def message_id_header(_), do: nil

  def normalize_error(:no_token), do: {:error, "google_account_not_connected"}
  def normalize_error(:reauth_required), do: {:error, "google_account_reauth_required"}
  def normalize_error(:no_refresh_token), do: {:error, "google_account_reconnect_required"}

  def normalize_error({:http_status, status, body} = reason) when status in [401, 403] do
    Maraithon.Tools.provider_error(
      :gmail,
      reason,
      ToolErrorCopy.connected_source({:http_status, status, body}, google_error_opts())
    )
  end

  def normalize_error(reason) do
    Maraithon.Tools.provider_error(
      :gmail,
      reason,
      ToolErrorCopy.connected_source(reason, google_error_opts())
    )
  end

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

  defp google_error_opts do
    [
      label: "Google",
      not_connected: "google_account_not_connected",
      reauth_required: "google_account_reauth_required",
      reconnect_required: "google_account_reconnect_required"
    ]
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
