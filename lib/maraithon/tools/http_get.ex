defmodule Maraithon.Tools.HttpGet do
  @moduledoc """
  HTTP GET tool for fetching URLs.
  """

  require Logger

  @max_response_body_chars 5_000
  @max_url_length 2_048
  @receive_timeout_ms 10_000
  @connect_timeout_ms 5_000
  @fetch_error "Could not fetch that URL. Check the address and try again."
  @sensitive_query_keys MapSet.new(~w(
    access_token
    api_key
    apikey
    client_secret
    code
    id_token
    key
    password
    refresh_token
    secret
    sig
    signature
    token
  ))

  def execute(args) do
    with {:ok, url} <- extract_url(args),
         :ok <- validate_url(url) do
      fetch_url(url)
    end
  end

  defp fetch_url(url) do
    public_url = redact_url(url)

    Logger.info("HTTP GET", url: public_url)

    case Req.get(url,
           receive_timeout: @receive_timeout_ms,
           connect_options: [timeout: @connect_timeout_ms],
           retry: false
         ) do
      {:ok, %{status: status, body: body}} ->
        {:ok,
         %{
           status: status,
           body: truncate(body, @max_response_body_chars),
           url: public_url
         }}

      {:error, reason} ->
        Logger.debug("HTTP GET failed", url: public_url, reason: inspect(reason))
        {:error, @fetch_error}
    end
  end

  defp extract_url(%{"url" => url}) when is_binary(url) do
    case String.trim(url) do
      "" -> {:error, "url is required"}
      trimmed -> {:ok, trimmed}
    end
  end

  defp extract_url(_args), do: {:error, "url is required"}

  defp validate_url(url) do
    cond do
      byte_size(url) > @max_url_length ->
        {:error, "url is too long"}

      true ->
        validate_parsed_uri(URI.parse(url))
    end
  end

  defp validate_parsed_uri(%URI{userinfo: userinfo}) when is_binary(userinfo) do
    {:error, "url must not include credentials"}
  end

  defp validate_parsed_uri(%URI{scheme: nil}) do
    {:error, "url must include scheme (http or https)"}
  end

  defp validate_parsed_uri(%URI{scheme: scheme}) when scheme not in ["http", "https"] do
    {:error, "url scheme must be http or https"}
  end

  defp validate_parsed_uri(%URI{host: host}) when host in [nil, ""] do
    {:error, "url host is required"}
  end

  defp validate_parsed_uri(%URI{port: port})
       when is_integer(port) and (port < 1 or port > 65_535) do
    {:error, "url port is invalid"}
  end

  defp validate_parsed_uri(%URI{}), do: :ok

  defp truncate(body, max_length) do
    body
    |> body_to_text()
    |> redact_sensitive_text()
    |> truncate_text(max_length)
  end

  defp body_to_text(body) when is_binary(body), do: body
  defp body_to_text(body), do: inspect(body, limit: 50)

  defp truncate_text(body, max_length) do
    if String.length(body) > max_length do
      String.slice(body, 0, max_length) <> "... (truncated)"
    else
      body
    end
  end

  defp redact_url(url) do
    uri = URI.parse(url)
    query = redact_query(uri.query)

    uri
    |> Map.put(:query, query)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  rescue
    _ -> "redacted-url"
  end

  defp redact_query(nil), do: nil
  defp redact_query(""), do: ""

  defp redact_query(query) do
    query
    |> URI.query_decoder()
    |> Enum.map(fn {key, value} ->
      if sensitive_query_key?(key), do: {key, "redacted"}, else: {key, value}
    end)
    |> URI.encode_query()
  end

  defp sensitive_query_key?(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    MapSet.member?(@sensitive_query_keys, normalized) or
      String.ends_with?(normalized, "_token") or
      String.ends_with?(normalized, "_secret") or
      String.ends_with?(normalized, "_key")
  end

  defp redact_sensitive_text(text) do
    Regex.replace(
      ~r/((?:"?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|client[_-]?secret|password|secret|signature|sig|token|key)"?)\s*(?::|=>|=)\s*)(?:"[^"]*"|'[^']*'|[^,\s}\]]+)/i,
      text,
      "\\1[redacted]"
    )
  end
end
