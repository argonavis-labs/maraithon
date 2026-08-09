defmodule MaraithonWeb.Plugs.TelegramWebhookGateTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias MaraithonWeb.Plugs.TelegramWebhookGate

  @token "telegram_webhook_secret_token_123456789"

  setup do
    previous = Application.get_env(:maraithon, :telegram)
    Application.put_env(:maraithon, :telegram, webhook_secret_token: @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:maraithon, :telegram, previous),
        else: Application.delete_env(:maraithon, :telegram)
    end)

    :ok
  end

  test "authenticates exactly one matching header, then deletes it" do
    conn =
      :post
      |> conn("/webhooks/telegram", "{}")
      |> put_req_header("x-telegram-bot-api-secret-token", @token)
      |> TelegramWebhookGate.call([])

    refute conn.halted
    assert conn.private.telegram_webhook_authenticated
    assert get_req_header(conn, "x-telegram-bot-api-secret-token") == []
  end

  test "rejects missing, blank, wrong, different-length, and duplicate headers with empty 404" do
    requests = [
      conn(:post, "/webhooks/telegram", "{}"),
      conn(:post, "/webhooks/telegram", "{}")
      |> put_req_header("x-telegram-bot-api-secret-token", ""),
      conn(:post, "/webhooks/telegram", "{}")
      |> put_req_header(
        "x-telegram-bot-api-secret-token",
        String.duplicate("x", byte_size(@token))
      ),
      conn(:post, "/webhooks/telegram", "{}")
      |> put_req_header("x-telegram-bot-api-secret-token", "wrong"),
      conn(:post, "/webhooks/telegram", "{}")
      |> prepend_req_headers([
        {"x-telegram-bot-api-secret-token", @token},
        {"x-telegram-bot-api-secret-token", @token}
      ])
    ]

    for request <- requests do
      rejected = TelegramWebhookGate.call(request, [])
      assert rejected.halted
      assert rejected.status == 404
      assert rejected.resp_body == ""
    end
  end

  test "checks authentication before an oversized declared body" do
    rejected =
      :post
      |> conn("/webhooks/telegram", "")
      |> put_req_header("content-length", "600001")
      |> put_req_header("x-telegram-bot-api-secret-token", "wrong")
      |> TelegramWebhookGate.call([])

    assert rejected.status == 404
    assert rejected.resp_body == ""

    oversized =
      :post
      |> conn("/webhooks/telegram", "")
      |> put_req_header("content-length", "600001")
      |> put_req_header("x-telegram-bot-api-secret-token", @token)
      |> TelegramWebhookGate.call([])

    assert oversized.status == 413
    assert oversized.resp_body == ""
  end

  test "rejects malformed or duplicate content-length only after authentication" do
    for request <- [
          conn(:post, "/webhooks/telegram", "")
          |> put_req_header("content-length", "12x"),
          conn(:post, "/webhooks/telegram", "")
          |> prepend_req_headers([{"content-length", "1"}, {"content-length", "1"}])
        ] do
      rejected =
        request
        |> put_req_header("x-telegram-bot-api-secret-token", @token)
        |> TelegramWebhookGate.call([])

      assert rejected.status == 413
      assert rejected.resp_body == ""
    end
  end

  test "rejects non-POST, legacy, and suffix paths before parsing" do
    for request <- [
          conn(:get, "/webhooks/telegram"),
          conn(:post, "/webhooks/telegram/old-secret", "not json"),
          conn(:post, "/webhooks/telegram/suffix/more", "not json")
        ] do
      rejected = TelegramWebhookGate.call(request, [])
      assert rejected.halted
      assert rejected.status == 404
      assert rejected.resp_body == ""
    end
  end

  test "blank or invalid configured tokens never authenticate" do
    for token <- ["", "contains spaces", String.duplicate("x", 257)] do
      Application.put_env(:maraithon, :telegram, webhook_secret_token: token)

      rejected =
        :post
        |> conn("/webhooks/telegram", "{}")
        |> put_req_header("x-telegram-bot-api-secret-token", token)
        |> TelegramWebhookGate.call([])

      assert rejected.status == 404
    end
  end
end
