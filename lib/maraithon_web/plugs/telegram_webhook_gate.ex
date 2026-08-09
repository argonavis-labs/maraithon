defmodule MaraithonWeb.Plugs.TelegramWebhookGate do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Maraithon.Connectors.Telegram
  alias MaraithonWeb.Plugs.CacheRawBody

  @telegram_path "/webhooks/telegram"
  @legacy_prefix "/webhooks/telegram/"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: @telegram_path, method: "POST"} = conn, _opts) do
    # Authentication deliberately precedes every request-framing and size check
    # so callers cannot use response differences to probe the configured token.
    case Telegram.verify_signature(conn, "") do
      :ok ->
        conn
        |> delete_req_header("x-telegram-bot-api-secret-token")
        |> put_private(:telegram_webhook_authenticated, true)
        |> enforce_fixed_length_body()

      {:error, _closed_reason} ->
        reject(conn, :not_found)
    end
  end

  def call(%Plug.Conn{request_path: @telegram_path} = conn, _opts),
    do: reject(conn, :not_found)

  def call(%Plug.Conn{request_path: path} = conn, _opts) when is_binary(path) do
    cond do
      String.starts_with?(path, @legacy_prefix) ->
        reject(conn, :not_found)

      http1_transfer_encoded?(conn) ->
        # Bandit 1.10 assembles chunked entities when a body reader is invoked.
        # Refuse HTTP/1 transfer coding before parsers for every endpoint so no
        # JSON or urlencoded route can bypass the configured cumulative limits.
        reject(conn, :bad_request)

      true ->
        conn
    end
  end

  defp enforce_fixed_length_body(conn) do
    cond do
      http1_transfer_encoded?(conn) ->
        reject(conn, :request_entity_too_large)

      true ->
        enforce_singleton_content_length(conn)
    end
  end

  defp enforce_singleton_content_length(conn) do
    maximum = CacheRawBody.webhook_compressed_limit()

    case get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 and length <= maximum ->
            conn

          _invalid_or_oversized ->
            reject(conn, :request_entity_too_large)
        end

      _missing_or_duplicate ->
        reject(conn, :request_entity_too_large)
    end
  end

  defp http1_transfer_encoded?(conn) do
    get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"] and
      get_req_header(conn, "transfer-encoding") != []
  end

  defp reject(conn, status) do
    conn
    |> put_resp_header("connection", "close")
    |> send_resp(status, "")
    |> halt()
  end
end
