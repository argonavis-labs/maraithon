defmodule Maraithon.Runtime.WatchRenewerTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Runtime.WatchRenewer

  test "renews a Gmail watch whose expiration falls within the renewal horizon" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :google,
      pubsub_topic: "projects/test/topics/gmail",
      token_url: "http://localhost:#{bypass.port}/token",
      client_id: "test_client",
      client_secret: "test_secret"
    )

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    on_exit(fn -> Application.delete_env(:maraithon, :google) end)

    user_id = "watch-renewer-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "valid_access_token",
        refresh_token: "valid_refresh_token",
        expires_in: 3600,
        scopes: ["gmail.readonly"]
      })

    account = ConnectedAccounts.get(user_id, "google")

    expiring_soon = DateTime.add(DateTime.utc_now(), 3_600, :second)

    SourceCursors.put(account, "gmail_history_id", %{
      "value" => "1000",
      "watch_expires_at" => expiring_soon
    })

    Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/watch", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "historyId" => "2000",
          "expiration" => "#{System.system_time(:millisecond) + 7 * 86_400_000}"
        })
      )
    end)

    start_supervised!(
      {WatchRenewer,
       name: nil,
       observer: self(),
       interval_ms: :timer.minutes(30),
       lookahead_seconds: 24 * 60 * 60,
       batch_size: 10,
       initial_delay_ms: 10}
    )

    assert_receive {:watch_renewal_cycle, %{attempted: 1, renewed: 1, failed: 0}}, 2_000

    cursor = SourceCursors.get(account.id, "gmail_history_id")
    # The renewal must not rewind progress already made (R5: only seed the
    # historyId when the cursor didn't have one).
    assert cursor.value == "1000"
    assert DateTime.compare(cursor.watch_expires_at, expiring_soon) == :gt
  end

  test "does not renew watches outside the renewal horizon" do
    user_id = "watch-renewer-far-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "valid_access_token",
        refresh_token: "valid_refresh_token",
        expires_in: 3600,
        scopes: ["gmail.readonly"]
      })

    account = ConnectedAccounts.get(user_id, "google")
    far_future = DateTime.add(DateTime.utc_now(), 30 * 24 * 60 * 60, :second)

    SourceCursors.put(account, "gmail_history_id", %{
      "value" => "1",
      "watch_expires_at" => far_future
    })

    start_supervised!(
      {WatchRenewer,
       name: nil,
       observer: self(),
       interval_ms: :timer.minutes(30),
       lookahead_seconds: 24 * 60 * 60,
       batch_size: 10,
       initial_delay_ms: 10}
    )

    assert_receive {:watch_renewal_cycle, %{attempted: 0, renewed: 0, failed: 0}}, 2_000
  end
end
