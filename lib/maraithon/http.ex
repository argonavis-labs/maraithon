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

  alias Maraithon.LLM.BoundedResponse
  alias Req.Response

  require Logger

  @max_error_body_bytes 16_000
  @default_max_response_body_bytes 32_000_000
  @max_response_body_bytes 32_000_000
  @default_receive_timeout_ms 15_000
  @max_request_timeout_ms 300_000
  @request_cleanup_margin_ms 500
  @max_response_chunks 2_048

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
    * `:receive_timeout` - overrides the default 15s response receive timeout.
    * `:request_timeout` - bounds total wall-clock request time (capped at 5 minutes).
    * `:max_response_body_bytes` - bounds successful response bytes at the transport
      boundary (capped at 32 MB); error bodies use the smaller fixed error cap.
    * `:expected_statuses` - response statuses that should be returned without
      warning-level logging because the caller handles them as ordinary misses.
    * `:expected_error?` - optional two-arity predicate receiving the response
      status and normalized body. Matching errors retain their return value but
      do not emit duplicate warning-level logs. Predicate failures fail closed.
    * `:log_failures?` - set to `false` when the caller owns an expected fallback
      and will report only the final outcome.
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
    receive_timeout = positive_timeout(opts[:receive_timeout], @default_receive_timeout_ms)

    request_timeout =
      opts[:request_timeout]
      |> positive_timeout(min(receive_timeout + 1_000, @max_request_timeout_ms))
      |> min(@max_request_timeout_ms)

    inner_receive_timeout =
      min(receive_timeout, max(request_timeout - @request_cleanup_margin_ms, 1))

    max_response_body_bytes =
      opts[:max_response_body_bytes]
      |> positive_limit(@default_max_response_body_bytes)
      |> min(@max_response_body_bytes)

    req =
      Req.new(
        method: method,
        url: url,
        headers: normalize_headers(headers),
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: response_collector(max_response_body_bytes),
        receive_timeout: inner_receive_timeout
      )

    result =
      if Process.whereis(Maraithon.Runtime.ToolCallSupervisor) do
        BoundedResponse.run(fn -> Req.request(req, req_opts) end, request_timeout)
      else
        {:error, %{reason: :request_supervisor_unavailable}}
      end

    case result do
      {:ok, %Response{} = response} ->
        handle_collected_response(response, url, opts)

      {:error, reason} ->
        failure_code = Maraithon.Redaction.error_class(reason)

        if log_failures?(opts) do
          Logger.warning("HTTP request failed", failure_code: failure_code)
        end

        {:error, {:http_error, failure_code}}
    end
  rescue
    error ->
      failure_code = Maraithon.Redaction.error_class(error)

      if log_failures?(opts) do
        Logger.warning("HTTP request setup failed", failure_code: failure_code)
      end

      {:error, {:http_error, failure_code}}
  end

  defp handle_collected_response(%Response{} = response, url, opts) do
    if BoundedResponse.overflow?(response) do
      case response.status do
        status when status in [401, 429] ->
          # Authentication and rate-limit semantics are carried by status and
          # bounded headers, never by the provider-controlled diagnostic body.
          handle_response(%{response | body: ""}, url, opts)

        status ->
          if log_failures?(opts) do
            Logger.warning("HTTP response body exceeded limit",
              status: status,
              failure_code: "response_body_too_large"
            )
          end

          {:error, {:http_status, status, "response_body_too_large"}}
      end
    else
      body =
        response
        |> BoundedResponse.body()
        |> decode_response_body(response)

      handle_response(%{response | body: body}, url, opts)
    end
  end

  defp response_collector(success_limit) do
    fn {:data, data}, {req, response} when is_binary(data) ->
      limit = if response.status in 200..299, do: success_limit, else: @max_error_body_bytes
      bytes = Map.get(response.private, :bounded_response_bytes, 0) + byte_size(data)
      chunk_count = Map.get(response.private, :bounded_response_chunk_count, 0) + 1

      if bytes > limit or chunk_count > @max_response_chunks do
        next_response =
          response
          |> Response.put_private(:bounded_response_bytes, bytes)
          |> Response.put_private(:bounded_response_chunk_count, chunk_count)
          |> Response.put_private(:bounded_response_chunks, [])
          |> Response.put_private(:bounded_response_overflow, true)

        {:halt, {req, next_response}}
      else
        chunks = [data | Map.get(response.private, :bounded_response_chunks, [])]

        next_response =
          response
          |> Response.put_private(:bounded_response_bytes, bytes)
          |> Response.put_private(:bounded_response_chunk_count, chunk_count)
          |> Response.put_private(:bounded_response_chunks, chunks)

        {:cont, {req, next_response}}
      end
    end
  end

  defp decode_response_body("", _response), do: ""

  defp decode_response_body(body, response) when is_binary(body) do
    if json_response?(response) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _reason} -> body
      end
    else
      body
    end
  end

  defp json_response?(response) do
    response
    |> Response.get_header("content-type")
    |> Enum.any?(fn
      content_type when is_binary(content_type) and byte_size(content_type) <= 1_024 ->
        if String.valid?(content_type) do
          content_type = String.downcase(content_type)

          String.contains?(content_type, "application/json") or
            String.contains?(content_type, "+json")
        else
          false
        end

      _content_type ->
        false
    end)
  end

  defp positive_timeout(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_timeout(_value, default), do: default

  defp positive_limit(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_limit(_value, default), do: default

  defp handle_response(%Response{status: status, body: body}, _url, _opts)
       when status in 200..299,
       do: {:ok, body}

  defp handle_response(%Response{status: 401}, _url, _opts) do
    {:error, :unauthorized}
  end

  defp handle_response(%Response{status: 429} = response, _url, _opts) do
    case retry_after_seconds(response) do
      nil -> {:error, {:rate_limited, :provider_limited}}
      seconds -> {:error, {:rate_limited, seconds, :provider_limited}}
    end
  end

  defp handle_response(%Response{status: status, body: body}, _url, opts) do
    body_string = response_body_to_string(body)

    unless status in Keyword.get(opts, :expected_statuses, []) or
             expected_error?(status, body_string, opts) do
      if log_failures?(opts) do
        Logger.warning("HTTP request failed",
          response_status: status,
          failure_code: "http_status"
        )
      end
    end

    {:error, {:http_status, status, body_string}}
  end

  defp log_failures?(opts), do: Keyword.get(opts, :log_failures?, true) == true

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

  defp parse_retry_after(value)
       when is_binary(value) and byte_size(value) <= 64 do
    if String.valid?(value) do
      case Integer.parse(String.trim(value)) do
        {seconds, ""} when seconds >= 0 -> seconds
        _ -> nil
      end
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

  defp response_body_to_string(body) when is_binary(body) do
    Maraithon.PromptBudget.truncate_utf8(body, @max_error_body_bytes)
  end

  defp response_body_to_string(body) do
    body
    |> inspect(pretty: false, limit: 50, printable_limit: @max_error_body_bytes)
    |> Maraithon.PromptBudget.truncate_utf8(@max_error_body_bytes)
  end
end
