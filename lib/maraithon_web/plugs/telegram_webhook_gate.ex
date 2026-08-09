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
    # Authentication deliberately precedes every request-size check so callers
    # cannot use response differences to probe the configured token.
    case Telegram.verify_signature(conn, "") do
      :ok ->
        conn
        |> delete_req_header("x-telegram-bot-api-secret-token")
        |> put_private(:telegram_webhook_authenticated, true)
        |> enforce_content_length()

      {:error, _closed_reason} ->
        reject(conn, :not_found)
    end
  end

  def call(%Plug.Conn{request_path: @telegram_path} = conn, _opts),
    do: reject(conn, :not_found)

  def call(%Plug.Conn{request_path: path} = conn, _opts) when is_binary(path) do
    if String.starts_with?(path, @legacy_prefix),
      do: reject(conn, :not_found),
      else: conn
  end

  defp enforce_content_length(conn) do
    case get_req_header(conn, "content-length") do
      [] ->
        conn

      [value] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 ->
            if length <= CacheRawBody.webhook_compressed_limit(),
              do: conn,
              else: reject(conn, :request_entity_too_large)

          _invalid_or_oversized ->
            reject(conn, :request_entity_too_large)
        end

      _duplicate ->
        reject(conn, :request_entity_too_large)
    end
  end

  defp reject(conn, status) do
    conn
    |> send_resp(status, "")
    |> halt()
  end
end
