defmodule Maraithon.Runtime.BackgroundJobHandlerConnectorsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Connectors.SourceCursors
  alias Maraithon.OAuth
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.BackgroundJobHandler

  describe "gmail_incremental_sync" do
    test "reads the stored historyId cursor, ingests, and advances it" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      user_id = "gmail-job-handler-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = ConnectedAccounts.get(user_id, "google")
      SourceCursors.put(account, "gmail_history_id", %{"value" => "500"})

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        assert conn.query_string =~ "startHistoryId=500"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "555"}))
      end)

      job = %BackgroundJob{
        user_id: user_id,
        job_type: "gmail_incremental_sync",
        queue: "connectors",
        payload: %{}
      }

      assert {:ok, result} = BackgroundJobHandler.execute(job)
      assert result.source == "gmail_incremental_sync"
      assert result.history_id == "555"

      cursor = SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "555"
    end

    test "returns an error when no connected account exists for the provider" do
      user_id = "gmail-job-handler-missing-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      job = %BackgroundJob{
        user_id: user_id,
        job_type: "gmail_incremental_sync",
        queue: "connectors",
        payload: %{}
      }

      assert {:error, {:connected_account_not_found, "google"}} = BackgroundJobHandler.execute(job)
    end
  end

  describe "calendar_incremental_sync" do
    test "reads the stored sync token cursor, ingests, and advances it" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      user_id = "calendar-job-handler-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      account = ConnectedAccounts.get(user_id, "google")
      SourceCursors.put(account, "calendar_sync_token", %{"value" => "old-token"})

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        assert conn.query_string == "syncToken=old-token"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"items" => [], "nextSyncToken" => "new-token"}))
      end)

      job = %BackgroundJob{
        user_id: user_id,
        job_type: "calendar_incremental_sync",
        queue: "connectors",
        payload: %{}
      }

      assert {:ok, result} = BackgroundJobHandler.execute(job)
      assert result.source == "calendar_incremental_sync"

      cursor = SourceCursors.get(account.id, "calendar_sync_token")
      assert cursor.value == "new-token"
    end
  end

  describe "rate limit handling" do
    test "translates a 429 rate_limited error into a retry_after tuple" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      user_id = "gmail-job-handler-429-#{System.unique_integer([:positive])}@example.com"
      {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

      {:ok, _token} =
        OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = ConnectedAccounts.get(user_id, "google")
      SourceCursors.put(account, "gmail_history_id", %{"value" => "1"})

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "42")
        |> Plug.Conn.resp(429, "slow down")
      end)

      job = %BackgroundJob{
        user_id: user_id,
        job_type: "gmail_incremental_sync",
        queue: "connectors",
        payload: %{}
      }

      assert {:error, {:retry_after, 42, {:rate_limited, 42, "slow down"}}} =
               BackgroundJobHandler.execute(job)
    end
  end
end
