defmodule Maraithon.Tools.HttpGet.Transport do
  @moduledoc false

  @base_request_headers [
    {"accept-encoding", "identity"},
    {"connection", "close"}
  ]

  @type request :: %{
          required(:scheme) => :http | :https,
          required(:address) => :inet.ip_address(),
          required(:hostname) => String.t(),
          required(:port) => :inet.port_number(),
          required(:target) => String.t(),
          required(:connect_timeout_ms) => pos_integer(),
          required(:receive_timeout_ms) => pos_integer(),
          required(:max_body_bytes) => pos_integer(),
          required(:max_body_chunks) => pos_integer(),
          required(:max_receive_calls) => pos_integer(),
          required(:max_response_events) => pos_integer(),
          required(:max_response_headers) => pos_integer(),
          required(:max_response_header_bytes) => pos_integer()
        }

  @type clock :: (-> integer())

  @spec get(request(), integer(), clock()) ::
          {:ok, %{status: non_neg_integer(), body: binary(), truncated?: boolean()}}
          | {:error, term()}
  def get(request, deadline, clock), do: get(request, deadline, clock, [])

  @doc false
  @spec get(request(), integer(), clock(), keyword()) ::
          {:ok, %{status: non_neg_integer(), body: binary(), truncated?: boolean()}}
          | {:error, term()}
  def get(request, deadline, clock, opts)
      when is_map(request) and is_integer(deadline) and is_function(clock, 0) and is_list(opts) do
    connect = Keyword.get(opts, :connect, &Mint.HTTP.connect/4)
    request_fun = Keyword.get(opts, :request, &Mint.HTTP.request/5)
    recv = Keyword.get(opts, :recv, &Mint.HTTP.recv/3)
    close = Keyword.get(opts, :close, &Mint.HTTP.close/1)

    with :ok <- validate_request(request),
         {:ok, connect_timeout} <-
           bounded_timeout(deadline, clock, request.connect_timeout_ms),
         connection_opts = connection_options(request, connect_timeout),
         {:ok, connection} <-
           connect.(request.scheme, request.address, request.port, connection_opts) do
      try do
        perform_request(connection, request, deadline, clock, request_fun, recv)
      after
        safe_close(close, connection)
      end
    end
  rescue
    _error -> {:error, :transport_failed}
  catch
    _kind, _reason -> {:error, :transport_failed}
  end

  def get(_request, _deadline, _clock, _opts), do: {:error, :invalid_transport_request}

  defp perform_request(connection, request, deadline, clock, request_fun, recv) do
    with {:ok, _timeout} <- remaining_timeout(deadline, clock),
         {:ok, connection, request_ref} <-
           request_fun.(connection, "GET", request.target, request_headers(request), nil) do
      state = %{
        body: [],
        body_bytes: 0,
        body_chunks: 0,
        receive_calls: 0,
        response_events: 0,
        response_headers: 0,
        response_header_bytes: 0,
        status: nil
      }

      receive_response(connection, request_ref, request, deadline, clock, recv, state)
    end
  end

  defp receive_response(connection, request_ref, request, deadline, clock, recv, state) do
    cond do
      state.receive_calls >= request.max_receive_calls ->
        {:error, :too_many_receive_calls}

      true ->
        with {:ok, timeout} <- bounded_timeout(deadline, clock, request.receive_timeout_ms) do
          case recv.(connection, 0, timeout) do
            {:ok, next_connection, responses} when is_list(responses) ->
              next_state = %{state | receive_calls: state.receive_calls + 1}

              case consume_responses(responses, request_ref, request, next_state) do
                {:continue, next_state} ->
                  receive_response(
                    next_connection,
                    request_ref,
                    request,
                    deadline,
                    clock,
                    recv,
                    next_state
                  )

                {:done, next_state} ->
                  build_response(next_state, false)

                {:truncated, next_state} ->
                  build_response(next_state, true)

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, _next_connection, reason, responses} when is_list(responses) ->
              next_state = %{state | receive_calls: state.receive_calls + 1}

              case consume_responses(responses, request_ref, request, next_state) do
                {:done, next_state} -> build_response(next_state, false)
                {:truncated, next_state} -> build_response(next_state, true)
                _other -> {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}

            _unexpected ->
              {:error, :invalid_transport_response}
          end
        end
    end
  end

  defp consume_responses(responses, request_ref, request, state) do
    Enum.reduce_while(responses, {:continue, state}, fn response, {:continue, state} ->
      if state.response_events >= request.max_response_events do
        {:halt, {:error, :too_many_response_events}}
      else
        state = %{state | response_events: state.response_events + 1}
        consume_response(response, request_ref, request, state)
      end
    end)
  end

  defp consume_response({:status, request_ref, status}, request_ref, _request, state)
       when is_integer(status) do
    {:cont, {:continue, %{state | status: status}}}
  end

  defp consume_response({:headers, request_ref, headers}, request_ref, request, state)
       when is_list(headers) do
    case consume_headers(headers, request, state) do
      {:ok, next_state} -> {:cont, {:continue, next_state}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp consume_response({:data, request_ref, data}, request_ref, request, state)
       when is_binary(data) do
    cond do
      state.body_chunks >= request.max_body_chunks ->
        {:halt, {:truncated, state}}

      byte_size(data) > request.max_body_bytes - state.body_bytes ->
        allowed_bytes = request.max_body_bytes - state.body_bytes
        data = binary_part(data, 0, allowed_bytes)

        state = %{
          state
          | body: [data | state.body],
            body_bytes: state.body_bytes + allowed_bytes,
            body_chunks: state.body_chunks + 1
        }

        {:halt, {:truncated, state}}

      true ->
        state = %{
          state
          | body: [data | state.body],
            body_bytes: state.body_bytes + byte_size(data),
            body_chunks: state.body_chunks + 1
        }

        {:cont, {:continue, state}}
    end
  end

  defp consume_response({:done, request_ref}, request_ref, _request, state) do
    {:halt, {:done, state}}
  end

  defp consume_response({:error, request_ref, reason}, request_ref, _request, _state) do
    {:halt, {:error, reason}}
  end

  defp consume_response(_response, _request_ref, _request, _state) do
    {:halt, {:error, :unexpected_response}}
  end

  defp consume_headers(headers, request, state) do
    Enum.reduce_while(headers, {:ok, state}, fn
      {name, value}, {:ok, current} when is_binary(name) and is_binary(value) ->
        next_count = current.response_headers + 1
        next_bytes = current.response_header_bytes + byte_size(name) + byte_size(value)

        cond do
          next_count > request.max_response_headers ->
            {:halt, {:error, :too_many_response_headers}}

          next_bytes > request.max_response_header_bytes ->
            {:halt, {:error, :response_headers_too_large}}

          true ->
            {:cont,
             {:ok,
              %{
                current
                | response_headers: next_count,
                  response_header_bytes: next_bytes
              }}}
        end

      _invalid_header, {:ok, _current} ->
        {:halt, {:error, :invalid_response_header}}
    end)
  end

  defp build_response(%{status: status} = state, truncated?) when is_integer(status) do
    {:ok,
     %{
       status: status,
       body: state.body |> Enum.reverse() |> IO.iodata_to_binary(),
       truncated?: truncated?
     }}
  end

  defp build_response(_state, _truncated?), do: {:error, :missing_status}

  defp request_headers(request) do
    [{"host", host_header(request)} | @base_request_headers]
  end

  defp host_header(request) do
    hostname =
      case :inet.parse_address(String.to_charlist(request.hostname)) do
        {:ok, address} when tuple_size(address) == 8 -> "[" <> request.hostname <> "]"
        _result -> request.hostname
      end

    if default_port(request.scheme) == request.port do
      hostname
    else
      hostname <> ":" <> Integer.to_string(request.port)
    end
  end

  defp default_port(:http), do: 80
  defp default_port(:https), do: 443

  defp connection_options(request, timeout) do
    ipv6? = tuple_size(request.address) == 8

    [
      hostname: request.hostname,
      mode: :passive,
      protocols: [:http1],
      max_header_list_size: request.max_response_header_bytes,
      transport_opts: [
        timeout: timeout,
        send_timeout: timeout,
        send_timeout_close: true,
        inet6: ipv6?,
        inet4: not ipv6?
      ]
    ]
  end

  defp validate_request(request) do
    required_positive_integers = [
      request[:connect_timeout_ms],
      request[:receive_timeout_ms],
      request[:max_body_bytes],
      request[:max_body_chunks],
      request[:max_receive_calls],
      request[:max_response_events],
      request[:max_response_headers],
      request[:max_response_header_bytes]
    ]

    cond do
      request[:scheme] not in [:http, :https] ->
        {:error, :invalid_scheme}

      not valid_address?(request[:address]) ->
        {:error, :invalid_address}

      not is_binary(request[:hostname]) or request[:hostname] == "" ->
        {:error, :invalid_hostname}

      not String.valid?(request[:hostname]) ->
        {:error, :invalid_hostname}

      not is_integer(request[:port]) or request[:port] < 1 or request[:port] > 65_535 ->
        {:error, :invalid_port}

      not is_binary(request[:target]) or not String.valid?(request[:target]) ->
        {:error, :invalid_target}

      not Enum.all?(required_positive_integers, &(is_integer(&1) and &1 > 0)) ->
        {:error, :invalid_limits}

      true ->
        :ok
    end
  end

  defp valid_address?(address) when is_tuple(address) and tuple_size(address) in [4, 8],
    do: :inet.is_ip_address(address)

  defp valid_address?(_address), do: false

  defp bounded_timeout(deadline, clock, maximum) do
    with {:ok, remaining} <- remaining_timeout(deadline, clock) do
      {:ok, min(remaining, maximum)}
    end
  end

  defp remaining_timeout(deadline, clock) do
    case deadline - clock.() do
      timeout when timeout > 0 -> {:ok, timeout}
      _timeout -> {:error, :deadline_exceeded}
    end
  end

  defp safe_close(close, connection) do
    close.(connection)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
