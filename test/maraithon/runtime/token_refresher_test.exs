defmodule Maraithon.Runtime.TokenRefresherTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Runtime.TokenRefresher
  alias Maraithon.TestSupport.CapturingEmail
  alias Maraithon.TestSupport.CapturingTelegram

  test "refreshes tokens that are close to expiry" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google,
      token_url: "http://localhost:#{bypass.port}/token",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :google)
    end)

    user_id = "user_#{System.unique_integer()}"
    expires_soon = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring_access_token",
        refresh_token: "valid_refresh_token",
        expires_at: expires_soon
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "access_token" => "new_refreshed_token",
          "expires_in" => 3600,
          "token_type" => "Bearer"
        })
      )
    end)

    summary = TokenRefresher.run_once(lookahead_seconds: 300, batch_size: 10)

    assert summary == %{attempted: 1, refreshed: 1, failed: 0}

    token = OAuth.get_token(user_id, "google")
    assert token.access_token == "new_refreshed_token"
  end

  test "R1: a terminal refresh failure (invalid_grant) sends a reconnect notification at this cycle" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google,
      token_url: "http://localhost:#{bypass.port}/token",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    start_supervised!(%{
      id: :capturing_email_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_email_recorder]]}
    })

    Application.put_env(:maraithon, :connected_accounts,
      telegram_module: CapturingTelegram,
      email_module: CapturingEmail
    )

    on_exit(fn ->
      Application.delete_env(:maraithon, :google)
      Application.delete_env(:maraithon, :connected_accounts)
    end)

    user_id = "token-refresher-revoked-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "778899"})

    expires_soon = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring_access_token",
        refresh_token: "revoked_refresh_token",
        expires_at: expires_soon
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        400,
        Jason.encode!(%{
          "error" => "invalid_grant",
          "error_description" => "Token has been expired or revoked."
        })
      )
    end)

    summary = TokenRefresher.run_once(lookahead_seconds: 300, batch_size: 10)

    assert summary == %{attempted: 1, refreshed: 0, failed: 1}

    account = ConnectedAccounts.get(user_id, "google")
    assert account.status == "error"

    assert get_in(account.metadata, ["reconnect_notification", "reason"]) ==
             "oauth_reauth_required"

    assert [%{to: ^user_id}] = Agent.get(:capturing_email_recorder, &Enum.reverse/1)
  end

  test "R1: a transient refresh failure does not send a reconnect notification" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google,
      token_url: "http://localhost:#{bypass.port}/token",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    Application.put_env(:maraithon, :connected_accounts, telegram_module: CapturingTelegram)

    on_exit(fn ->
      Application.delete_env(:maraithon, :google)
      Application.delete_env(:maraithon, :connected_accounts)
    end)

    user_id = "token-refresher-transient-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "778900"})

    expires_soon = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "expiring_access_token",
        refresh_token: "valid_refresh_token",
        expires_at: expires_soon
      })

    Bypass.expect_once(bypass, "POST", "/token", fn conn ->
      Plug.Conn.resp(conn, 503, "service unavailable")
    end)

    summary = TokenRefresher.run_once(lookahead_seconds: 300, batch_size: 10)

    assert summary == %{attempted: 1, refreshed: 0, failed: 1}

    account = ConnectedAccounts.get(user_id, "google")
    assert account.status == "connected"
    assert Agent.get(:capturing_telegram_recorder, &Enum.reverse/1) == []
  end
end
