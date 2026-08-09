defmodule MaraithonWeb.Plugs.TelegramWebhookGateBanditTest do
  use ExUnit.Case, async: false

  @token "telegram_webhook_secret_token_123456789"

  setup do
    previous = Application.get_env(:maraithon, :telegram)
    Application.put_env(:maraithon, :telegram, webhook_secret_token: @token)

    server =
      start_supervised!(%{
        id: :telegram_gate_raw_bandit,
        start:
          {Bandit, :start_link,
           [
             [
               plug: MaraithonWeb.Endpoint,
               ip: {127, 0, 0, 1},
               port: 0,
               startup_log: false
             ]
           ]},
        restart: :temporary,
        type: :supervisor
      })

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:maraithon, :telegram, previous),
        else: Application.delete_env(:maraithon, :telegram)
    end)

    %{port: port}
  end

  test "wrong auth returns an empty 404 and closes without draining an incomplete chunked body",
       %{
         port: port
       } do
    response =
      raw_incomplete_chunked_request(
        port,
        "wrong-secret-of-deliberately-different-length"
      )

    assert response =~ "HTTP/1.1 404 Not Found\r\n"
    assert response =~ "connection: close\r\n"
    assert response =~ "content-length: 0\r\n"
    refute response =~ @token
  end

  test "authenticated chunked Telegram body is rejected and closed before body assembly", %{
    port: port
  } do
    response = raw_incomplete_chunked_request(port, @token)

    assert response =~ "HTTP/1.1 413 Request Entity Too Large\r\n"
    assert response =~ "connection: close\r\n"
    assert response =~ "content-length: 0\r\n"
  end

  test "non-Telegram HTTP/1 transfer encoding is rejected before JSON parsers", %{port: port} do
    response =
      raw_incomplete_chunked_request(
        port,
        "irrelevant",
        "/api/v1/companion/notes"
      )

    assert response =~ "HTTP/1.1 400 Bad Request\r\n"
    assert response =~ "connection: close\r\n"
    assert response =~ "content-length: 0\r\n"
  end

  defp raw_incomplete_chunked_request(port, token, path \\ "/webhooks/telegram") do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        port,
        [:binary, active: false, packet: :raw, nodelay: true],
        1_000
      )

    request = [
      "POST #{path} HTTP/1.1\r\n",
      "host: 127.0.0.1\r\n",
      "connection: keep-alive\r\n",
      "transfer-encoding: chunked\r\n",
      "content-type: application/json\r\n",
      "x-telegram-bot-api-secret-token: ",
      token,
      "\r\n\r\n",
      # Announce a chunk but deliberately never finish it. A safe early gate
      # must answer without waiting for the rest or trying to drain it.
      "100000\r\n",
      "{"
    ]

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
    assert_socket_closed(socket)
    response
  end

  defp assert_socket_closed(socket) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:error, :closed} ->
        :ok

      {:ok, _remaining_response} ->
        assert_socket_closed(socket)

      other ->
        flunk("expected Bandit to close the early-rejection socket, got: #{inspect(other)}")
    end
  end
end
