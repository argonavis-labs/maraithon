defmodule Maraithon.HTTP do
  @moduledoc """
  Shared HTTP client for external API requests.

  Provides a consistent interface over `Req` with proper error handling and
  JSON decoding.

  ## Usage

      # POST with form-encoded body
      HTTP.post_form("https://api.example.com/token", %{code: "abc"})

      # POST with JSON body
      HTTP.post_json("https://api.example.com/data", %{key: "value"}, [{"Authorization", "Bearer token"}])

      # GET request
      HTTP.get("https://api.example.com/data", [{"Authorization", "Bearer token"}])
  """

  alias Req.Response

  require Logger

  @type headers :: [{String.t(), String.t()}]
  @type response :: {:ok, map() | binary()} | {:error, term()}

  @doc """
  Makes a POST request with form-urlencoded body.
  """
  @spec post_form(String.t(), map(), headers()) :: response()
  def post_form(url, params, headers \\ []) when is_map(params) do
    request(:post, url, headers, form: params)
  end

  @doc """
  Makes a POST request with JSON body.
  """
  @spec post_json(String.t(), map(), headers()) :: response()
  def post_json(url, body, headers \\ []) when is_map(body) do
    request(:post, url, headers, json: body)
  end

  @doc """
  Makes a GET request.

  Options:
    * `:receive_timeout` - overrides the default 15s response timeout,
      for large-body fetches like file downloads.
    * `:expected_statuses` - response statuses that should be returned without
      warning-level logging because the caller handles them as ordinary misses.
    * `:expected_error?` - optional two-arity predicate receiving the response
      status and normalized body. Matching errors retain their return value but
      do not emit duplicate warning-level logs. Predicate failures fail closed.
  """
  @spec get(String.t(), headers(), keyword()) :: response()
  def get(url, headers \\ [], opts \\ []) do
    request(:get, url, headers, [], opts)
  end

  @doc """
  Makes a DELETE request.
  """
  @spec delete(String.t(), headers()) :: response()
  def delete(url, headers \\ []) do
    request(:delete, url, headers, [])
  end

  @doc """
  Makes a DELETE request with JSON body.
  """
  @spec delete_json(String.t(), map(), headers()) :: response()
  def delete_json(url, body, headers \\ []) when is_map(body) do
    request(:delete, url, headers, json: body)
  end

  @doc """
  Makes a PUT request with JSON body.
  """
  @spec put_json(String.t(), map(), headers()) :: response()
  def put_json(url, body, headers \\ []) when is_map(body) do
    request(:put, url, headers, json: body)
  end

  @doc """
  Makes a PATCH request with JSON body.
  """
  @spec patch_json(String.t(), map(), headers()) :: response()
  def patch_json(url, body, headers \\ []) when is_map(body) do
    request(:patch, url, headers, json: body)
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp request(method, url, headers, req_opts, opts \\ []) do
    req =
      Req.new(
        method: method,
        url: url,
        headers: normalize_headers(headers),
        retry: false,
        receive_timeout: Keyword.get(opts, :receive_timeout, 15_000)
      )

    case Req.request(req, req_opts) do
      {:ok, %Response{} = response} ->
        handle_response(response, url, opts)

      {:error, reason} ->
        Logger.warning("HTTP request failed", url: url, reason: inspect(reason))
        {:error, {:http_error, reason}}
    end
  end

  defp handle_response(%Response{status: status, body: body}, _url, _opts)
       when status in 200..299,
       do: {:ok, body}

  defp handle_response(%Response{status: 401}, _url, _opts) do
    {:error, :unauthorized}
  end

  defp handle_response(%Response{status: 429} = response, _url, _opts) do
    body_string = response_body_to_string(response.body)

    case retry_after_seconds(response) do
      nil -> {:error, {:rate_limited, body_string}}
      seconds -> {:error, {:rate_limited, seconds, body_string}}
    end
  end

  defp handle_response(%Response{status: status, body: body}, url, opts) do
    body_string = response_body_to_string(body)

    unless status in Keyword.get(opts, :expected_statuses, []) or
             expected_error?(status, body_string, opts) do
      Logger.warning("HTTP request failed", url: url, status: status, body: body_string)
    end

    {:error, {:http_status, status, body_string}}
  end

  defp expected_error?(status, body, opts) do
    case Keyword.get(opts, :expected_error?) do
      matcher when is_function(matcher, 2) -> matcher.(status, body) == true
      _matcher -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  # `Retry-After` is either delta-seconds (what Google/Slack send in practice)
  # or an HTTP-date; we only parse the numeric form and fall back to letting
  # the caller apply its own default backoff.
  defp retry_after_seconds(%Response{} = response) do
    case Response.get_header(response, "retry-after") do
      [value | _] -> parse_retry_after(value)
      _ -> nil
    end
  end

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> nil
    end
  end

  defp parse_retry_after(_value), do: nil

  defp normalize_headers(headers) do
    Enum.map(headers, fn
      {key, value} when is_atom(key) ->
        {Atom.to_string(key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp response_body_to_string(body) when is_binary(body), do: body
  defp response_body_to_string(body) when is_map(body) or is_list(body), do: inspect(body)
  defp response_body_to_string(body), do: to_string(body)
end
