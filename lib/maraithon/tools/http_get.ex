defmodule Maraithon.Tools.HttpGet do
  @moduledoc """
  HTTP GET tool for fetching public URLs.

  Every request resolves and validates the complete A/AAAA answer set, pins one
  deterministic public address, performs exactly one GET, and never follows
  redirects or retries another address.
  """

  require Logger

  alias Maraithon.Tools.HttpGet.AddressPolicy
  alias Maraithon.Tools.HttpGet.Resolver
  alias Maraithon.Tools.HttpGet.Transport

  @max_response_body_chars 5_000
  @max_response_body_bytes @max_response_body_chars * 4
  @max_response_body_chunks 128
  @max_receive_calls 256
  @max_response_events 512
  @max_response_headers 128
  @max_response_header_bytes 32_768
  @max_url_length 2_048
  @fetch_deadline_ms 15_000
  @receive_timeout_ms 10_000
  @connect_timeout_ms 5_000
  @fetch_error "Could not fetch that URL. Check the address and try again."

  def execute(args), do: execute(args, [])

  @doc false
  def execute(args, opts) when is_list(opts) do
    clock = Keyword.get(opts, :clock, &monotonic_milliseconds/0)
    deadline_ms = Keyword.get(opts, :deadline_ms, @fetch_deadline_ms)

    with {:ok, url} <- extract_url(args),
         {:ok, uri} <- validate_url(url),
         {:ok, deadline} <- deadline(clock, deadline_ms) do
      fetch_url(url, uri, deadline, clock, opts)
    end
  end

  defp fetch_url(url, uri, deadline, clock, opts) do
    public_url = redact_url(url)
    host_reference = Maraithon.Redaction.fingerprint(uri.host)
    Logger.info("HTTP GET", host_reference: host_reference)

    result =
      with {:ok, addresses} <- resolve(uri.host, deadline, clock, opts),
           :ok <- validate_addresses(addresses),
           {:ok, address} <- select_address(addresses),
           request = build_request(uri, address),
           {:ok, response} <- request(request, deadline, clock, opts),
           {:ok, status, body, truncated?} <- validate_response(response),
           {:ok, body} <- format_body(body, truncated?) do
        {:ok, %{status: status, body: body, url: public_url}}
      end

    case result do
      {:ok, _response} = success ->
        success

      {:error, _reason} ->
        Logger.debug("HTTP GET failed", host_reference: host_reference)
        {:error, @fetch_error}
    end
  end

  defp resolve(hostname, deadline, clock, opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, Maraithon.Runtime.ToolCallSupervisor)

    resolver =
      Keyword.get(opts, :resolver, fn hostname, deadline, clock ->
        Resolver.resolve(hostname, deadline, clock: clock, task_supervisor: task_supervisor)
      end)

    resolver.(hostname, deadline, clock)
  rescue
    _error -> {:error, :resolver_failed}
  catch
    _kind, _reason -> {:error, :resolver_failed}
  end

  defp request(request, deadline, clock, opts) do
    transport = Keyword.get(opts, :transport, &Transport.get/3)
    task_supervisor = Keyword.get(opts, :task_supervisor, Maraithon.Runtime.ToolCallSupervisor)
    owner = self()
    watcher_observer = Keyword.get(opts, :watcher_observer)

    with remaining when remaining > 0 <- deadline - clock.() do
      task =
        Task.Supervisor.async_nolink(task_supervisor, fn ->
          monitor_transport_owner(owner, watcher_observer)
          safe_transport_request(transport, request, deadline, clock)
        end)

      case deadline - clock.() do
        remaining_after_start when remaining_after_start > 0 ->
          case Task.yield(task, remaining_after_start) do
            {:ok, result} ->
              result

            {:exit, _reason} ->
              {:error, :transport_failed}

            nil ->
              Task.shutdown(task, :brutal_kill)
              {:error, :deadline_exceeded}
          end

        _expired_during_start ->
          Task.shutdown(task, :brutal_kill)
          {:error, :deadline_exceeded}
      end
    else
      _expired -> {:error, :deadline_exceeded}
    end
  rescue
    _error -> {:error, :transport_failed}
  catch
    _kind, _reason -> {:error, :transport_failed}
  end

  defp monitor_transport_owner(owner, observer) when is_pid(owner) do
    worker = self()

    watcher =
      spawn(fn ->
        owner_ref = Process.monitor(owner)
        worker_ref = Process.monitor(worker)

        receive do
          {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
            Process.exit(worker, :kill)

          {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
            :ok
        end
      end)

    if is_pid(observer), do: send(observer, {:transport_watcher_started, watcher})
    :ok
  end

  defp safe_transport_request(transport, request, deadline, clock) do
    transport.(request, deadline, clock)
  rescue
    _error -> {:error, :transport_failed}
  catch
    _kind, _reason -> {:error, :transport_failed}
  end

  defp validate_addresses(addresses) when is_list(addresses) and addresses != [] do
    if Enum.all?(addresses, &AddressPolicy.global?/1) do
      :ok
    else
      {:error, :non_global_address}
    end
  end

  defp validate_addresses(_addresses), do: {:error, :no_addresses}

  defp select_address(addresses) do
    case Enum.sort_by(addresses, &address_sort_key/1) do
      [address | _rest] -> {:ok, address}
      [] -> {:error, :no_addresses}
    end
  end

  defp address_sort_key(address) when tuple_size(address) == 4,
    do: {0, Tuple.to_list(address)}

  defp address_sort_key(address), do: {1, Tuple.to_list(address)}

  defp build_request(uri, address) do
    %{
      scheme: scheme_atom(uri.scheme),
      address: address,
      hostname: uri.host,
      port: uri.port,
      target: request_target(uri),
      connect_timeout_ms: @connect_timeout_ms,
      receive_timeout_ms: @receive_timeout_ms,
      max_body_bytes: @max_response_body_bytes,
      max_body_chunks: @max_response_body_chunks,
      max_receive_calls: @max_receive_calls,
      max_response_events: @max_response_events,
      max_response_headers: @max_response_headers,
      max_response_header_bytes: @max_response_header_bytes
    }
  end

  defp scheme_atom("http"), do: :http
  defp scheme_atom("https"), do: :https

  defp request_target(%URI{path: path, query: query}) do
    path = if path in [nil, ""], do: "/", else: path
    if is_binary(query), do: path <> "?" <> query, else: path
  end

  defp validate_response(%{status: status, body: body} = response)
       when is_integer(status) and is_binary(body) do
    truncated? = Map.get(response, :truncated?, false)

    cond do
      status < 100 or status > 599 -> {:error, :invalid_status}
      byte_size(body) > @max_response_body_bytes -> {:error, :response_body_too_large}
      not is_boolean(truncated?) -> {:error, :invalid_transport_response}
      true -> {:ok, status, body, truncated?}
    end
  end

  defp validate_response(_response), do: {:error, :invalid_transport_response}

  defp format_body(body, truncated?) do
    with {:ok, body} <- validate_utf8(body, truncated?) do
      body =
        body
        |> redact_sensitive_text()
        |> Maraithon.Redaction.redact_string()
        |> truncate_text(@max_response_body_chars, truncated?)

      {:ok, body}
    end
  end

  defp validate_utf8(body, truncated?) do
    case :unicode.characters_to_binary(body, :utf8, :utf8) do
      valid_body when is_binary(valid_body) ->
        {:ok, valid_body}

      {:incomplete, valid_prefix, _remainder} when truncated? and is_binary(valid_prefix) ->
        {:ok, valid_prefix}

      _invalid ->
        {:error, :invalid_utf8_body}
    end
  end

  defp extract_url(%{"url" => url}) when is_binary(url) do
    cond do
      byte_size(url) > @max_url_length ->
        {:error, "url is too long"}

      not String.valid?(url) ->
        {:error, "url must be valid UTF-8"}

      true ->
        case String.trim(url) do
          "" -> {:error, "url is required"}
          trimmed -> {:ok, trimmed}
        end
    end
  end

  defp extract_url(_args), do: {:error, "url is required"}

  defp validate_url(url) do
    cond do
      not safe_url_bytes?(url) ->
        {:error, "url contains invalid characters"}

      not valid_percent_encoding?(url) ->
        {:error, "url is invalid"}

      true ->
        case URI.new(url) do
          {:ok, uri} -> validate_parsed_uri(uri)
          {:error, _reason} -> {:error, "url is invalid"}
        end
    end
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<?%, high, low, rest::binary>>) do
    ascii_hex?(high) and ascii_hex?(low) and valid_percent_encoding?(rest)
  end

  defp valid_percent_encoding?(<<?%, _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp ascii_hex?(byte), do: byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f

  defp safe_url_bytes?(<<>>), do: true

  defp safe_url_bytes?(<<byte, _rest::binary>>)
       when byte < 0x20 or byte == 0x7F or byte == 0x5C,
       do: false

  defp safe_url_bytes?(<<_byte, rest::binary>>), do: safe_url_bytes?(rest)

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
       when not is_integer(port) or port < 1 or port > 65_535 do
    {:error, "url port is invalid"}
  end

  defp validate_parsed_uri(%URI{host: host} = uri) do
    if String.ends_with?(host, "."),
      do: {:error, "url host must not end with a dot"},
      else: {:ok, uri}
  end

  defp deadline(clock, deadline_ms)
       when is_function(clock, 0) and is_integer(deadline_ms) and deadline_ms > 0 do
    {:ok, clock.() + deadline_ms}
  rescue
    _error -> {:error, @fetch_error}
  catch
    _kind, _reason -> {:error, @fetch_error}
  end

  defp deadline(_clock, _deadline_ms), do: {:error, @fetch_error}

  defp truncate_text(body, max_length, already_truncated?) do
    cond do
      String.length(body) > max_length ->
        String.slice(body, 0, max_length) <> "... (truncated)"

      already_truncated? ->
        body <> "... (truncated)"

      true ->
        body
    end
  end

  defp redact_url(url) do
    url
    |> URI.parse()
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> Map.put(:userinfo, nil)
    |> URI.to_string()
  rescue
    _error -> "redacted-url"
  end

  defp redact_sensitive_text(text) do
    Regex.replace(
      ~r/((?:"?(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|apikey|client[_-]?secret|password|secret|signature|sig|token)"?)\s*(?::|=>|=)\s*)(?:"[^"]*"|'[^']*'|[^,\s}\]]+)/i,
      text,
      "\\1[redacted]"
    )
  end

  defp monotonic_milliseconds do
    System.monotonic_time(:millisecond)
  end
end
