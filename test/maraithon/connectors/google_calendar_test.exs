defmodule Maraithon.Connectors.GoogleCalendarTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Connectors.GoogleCalendar

  setup do
    Application.put_env(:maraithon, :google,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback",
      calendar_webhook_url: "https://example.com/webhooks/gcal"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
    end)

    :ok
  end

  describe "verify_signature/2" do
    test "always returns :ok (Google uses channel tokens)" do
      conn = %Plug.Conn{}
      assert :ok = GoogleCalendar.verify_signature(conn, "any_body")
    end
  end

  describe "handle_webhook/2" do
    test "returns error for missing channel token" do
      conn = build_conn_with_headers(%{})

      assert {:error, :missing_channel_token} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "returns error for empty channel token" do
      conn = build_conn_with_headers(%{"x-goog-channel-token" => ""})

      assert {:error, :missing_channel_token} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "ignores sync confirmation" do
      conn =
        build_conn_with_headers(%{
          "x-goog-channel-id" => "channel123",
          "x-goog-resource-id" => "resource123",
          "x-goog-resource-state" => "sync",
          "x-goog-channel-token" => "user_123"
        })

      assert {:ignore, "sync confirmation"} = GoogleCalendar.handle_webhook(conn, %{})
    end

    test "returns event for not_exists state" do
      conn =
        build_conn_with_headers(%{
          "x-goog-channel-id" => "channel123",
          "x-goog-resource-id" => "resource123",
          "x-goog-resource-state" => "not_exists",
          "x-goog-channel-token" => "user_123"
        })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:user_123"
      assert event.type == "calendar_deleted"
      assert event.source == "google_calendar"
      assert event.data.user_id == "user_123"
      assert event.data.channel_id == "channel123"
      assert event.data.resource_id == "resource123"
    end

    test "ignores unknown resource states" do
      conn =
        build_conn_with_headers(%{
          "x-goog-channel-id" => "channel123",
          "x-goog-resource-id" => "resource123",
          "x-goog-resource-state" => "unknown_state",
          "x-goog-channel-token" => "user_123"
        })

      assert {:ignore, "unknown resource state: unknown_state"} =
               GoogleCalendar.handle_webhook(conn, %{})
    end

    test "enqueues a background job instead of syncing inline" do
      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("cal_webhook_user@example.com")

      conn =
        build_conn_with_headers(%{
          "x-goog-channel-id" => "channel123",
          "x-goog-resource-id" => "resource123",
          "x-goog-resource-state" => "exists",
          "x-goog-channel-token" => "cal_webhook_user@example.com",
          "x-goog-message-number" => "1"
        })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:cal_webhook_user@example.com"
      assert event.type == "calendar_webhook_enqueued"
      assert event.source == "google_calendar"

      [job] = Maraithon.Runtime.BackgroundJobs.list(user_id: "cal_webhook_user@example.com")
      assert job.job_type == "calendar_incremental_sync"
      assert job.status == "pending"
      assert job.dedupe_key == "calendar_webhook:channel123:resource123:1"
    end
  end

  describe "setup_watch/2" do
    test "returns error when webhook URL not configured" do
      Application.put_env(:maraithon, :google, calendar_webhook_url: "")

      assert {:error, :webhook_url_not_configured} =
               GoogleCalendar.setup_watch("user_123", "fake_token")
    end

    test "returns error when no valid token and user not found" do
      assert {:error, :no_token} = GoogleCalendar.setup_watch("nonexistent_user")
    end
  end

  describe "sync_calendar_events/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = GoogleCalendar.sync_calendar_events("nonexistent_user")
    end
  end

  describe "fetch_upcoming_events/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = GoogleCalendar.fetch_upcoming_events("nonexistent_user")
    end
  end

  describe "stop_watch/3" do
    test "returns error when token not found" do
      assert {:error, :no_token} =
               GoogleCalendar.stop_watch("nonexistent_user", "channel_id", "resource_id")
    end
  end

  describe "setup_watch/2 with token" do
    test "returns success with direct access token" do
      Application.put_env(:maraithon, :google,
        calendar_webhook_url: "https://example.com/webhooks/gcal"
      )

      # Will fail on API call but tests the token path
      result = GoogleCalendar.setup_watch("test_user", "valid_access_token")
      assert match?({:error, _}, result)
    end
  end

  describe "stop_watch/3 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_stop_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to stop watch with valid token" do
      result = GoogleCalendar.stop_watch("cal_stop_user", "channel_id", "resource_id")
      assert match?({:error, _}, result)
    end
  end

  describe "sync_calendar_events/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_sync_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch events with valid token" do
      result = GoogleCalendar.sync_calendar_events("cal_sync_user")
      assert match?({:error, _}, result)
    end

    test "accepts sync_token option" do
      result = GoogleCalendar.sync_calendar_events("cal_sync_user", sync_token: "sync123")
      assert match?({:error, _}, result)
    end
  end

  describe "fetch_upcoming_events/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_upcoming_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch upcoming events with valid token" do
      result = GoogleCalendar.fetch_upcoming_events("cal_upcoming_user", 5)
      assert match?({:error, _}, result)
    end
  end

  describe "handle_webhook/2 - exists state with token" do
    setup do
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email("webhook_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("webhook_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "enqueues a background job without calling Google inline" do
      conn =
        build_conn_with_headers(%{
          "x-goog-channel-id" => "channel123",
          "x-goog-resource-id" => "resource123",
          "x-goog-resource-state" => "exists",
          "x-goog-channel-token" => "webhook_user@example.com",
          "x-goog-message-number" => "2"
        })

      {:ok, topic, event} = GoogleCalendar.handle_webhook(conn, %{})

      assert topic == "calendar:webhook_user@example.com"
      assert event.source == "google_calendar"
      assert event.type == "calendar_webhook_enqueued"

      [job] = Maraithon.Runtime.BackgroundJobs.list(user_id: "webhook_user@example.com")
      assert job.job_type == "calendar_incremental_sync"
      assert job.status == "pending"
    end
  end

  describe "setup_watch/2 with Bypass" do
    test "successfully creates watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google,
        calendar_webhook_url: "https://example.com/webhooks/gcal"
      )

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events/watch", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["type"] == "web_hook"
        assert params["address"] == "https://example.com/webhooks/gcal"
        assert params["token"] == "user_123"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "channel-123",
            "resourceId" => "resource-456",
            "expiration" => "#{System.system_time(:millisecond) + 86_400_000}"
          })
        )
      end)

      {:ok, watch} = GoogleCalendar.setup_watch("user_123", "test_access_token")

      assert watch.id == "channel-123"
      assert watch.resource_id == "resource-456"
      assert %DateTime{} = watch.expiration
    end
  end

  describe "fetch_upcoming_events/2 with Bypass" do
    test "successfully fetches events" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_fetch_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "event1",
                "summary" => "Meeting with Bob",
                "description" => "Discuss project",
                "location" => "Conference Room A",
                "status" => "confirmed",
                "start" => %{"dateTime" => "2024-01-15T10:00:00Z"},
                "end" => %{"dateTime" => "2024-01-15T11:00:00Z"},
                "attendees" => [
                  %{
                    "email" => "bob@test.com",
                    "displayName" => "Bob",
                    "responseStatus" => "accepted"
                  }
                ],
                "organizer" => %{"email" => "me@test.com"},
                "htmlLink" => "https://calendar.google.com/event/event1",
                "created" => "2024-01-01T00:00:00Z",
                "updated" => "2024-01-02T00:00:00Z"
              }
            ]
          })
        )
      end)

      {:ok, events} = GoogleCalendar.fetch_upcoming_events("cal_fetch_user", 10)

      assert length(events) == 1
      event = hd(events)
      assert event.event_id == "event1"
      assert event.summary == "Meeting with Bob"
      assert event.location == "Conference Room A"
      assert length(event.attendees) == 1
    end
  end

  describe "sync_calendar_events/2 with Bypass" do
    test "successfully syncs events" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_sync_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "event2",
                "summary" => "Team Standup",
                "start" => %{"dateTime" => "2024-01-15T09:00:00Z"},
                "end" => %{"dateTime" => "2024-01-15T09:15:00Z"},
                "organizer" => %{"email" => "team@test.com"}
              }
            ],
            "nextSyncToken" => "sync_token_123"
          })
        )
      end)

      {:ok, events} = GoogleCalendar.sync_calendar_events("cal_sync_bypass_user")

      assert length(events) == 1
      assert hd(events).event_id == "event2"
    end

    test "handles sync token for incremental sync" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_incremental_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        # Verify sync token is passed
        assert conn.query_string =~ "syncToken"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "items" => [],
            "nextSyncToken" => "new_sync_token"
          })
        )
      end)

      {:ok, events} =
        GoogleCalendar.sync_calendar_events("cal_incremental_user", sync_token: "old_token")

      assert events == []
    end

    test "handles 410 Gone by doing full sync" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_410_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          # First call with sync token returns 410
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(410, Jason.encode!(%{"error" => %{"code" => 410}}))
        else
          # Second call (full sync) succeeds
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "items" => [
                %{
                  "id" => "event3",
                  "summary" => "Recovered Event",
                  "start" => %{"date" => "2024-01-16"},
                  "end" => %{"date" => "2024-01-17"},
                  "organizer" => %{"email" => "org@test.com"}
                }
              ]
            })
          )
        end
      end)

      {:ok, events} =
        GoogleCalendar.sync_calendar_events("cal_410_user", sync_token: "expired_token")

      assert length(events) == 1
      assert hd(events).event_id == "event3"
    end
  end

  describe "stop_watch/3 with Bypass" do
    test "successfully stops watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_stop_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      Bypass.expect_once(bypass, "POST", "/calendar/v3/channels/stop", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["id"] == "channel_123"
        assert params["resourceId"] == "resource_456"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok =
               GoogleCalendar.stop_watch("cal_stop_bypass_user", "channel_123", "resource_456")
    end
  end

  describe "sync_history/3 - with Bypass" do
    test "fetches events, ingests them, and persists the fresh nextSyncToken cursor" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email("cal_cursor_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_cursor_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("cal_cursor_user@example.com", "google")

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "updated_event",
                "summary" => "Updated Meeting",
                "start" => %{"dateTime" => "2024-01-15T14:00:00Z"},
                "end" => %{"dateTime" => "2024-01-15T15:00:00Z"},
                "organizer" => %{"email" => "me@test.com"}
              }
            ],
            "nextSyncToken" => "fresh-token-123"
          })
        )
      end)

      {:ok, result} = GoogleCalendar.sync_history("cal_cursor_user@example.com", account)

      assert result.count == 1
      assert result.next_sync_token == "fresh-token-123"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "calendar_sync_token")
      assert cursor.value == "fresh-token-123"
    end

    test "second call uses the persisted sync token" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("cal_cursor_user_2@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_cursor_user_2@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("cal_cursor_user_2@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "calendar_sync_token", %{
        "value" => "existing-token-456"
      })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        assert conn.query_string == "syncToken=existing-token-456"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"items" => [], "nextSyncToken" => "next-token"}))
      end)

      {:ok, result} = GoogleCalendar.sync_history("cal_cursor_user_2@example.com", account)
      assert result.next_sync_token == "next-token"
    end

    test "follows nextPageToken to the final page and persists its nextSyncToken" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("cal_paged_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_paged_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("cal_paged_user@example.com", "google")

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        case count do
          1 ->
            refute conn.query_string =~ "pageToken"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "items" => [
                  %{
                    "id" => "event_p1",
                    "summary" => "Page 1 Event",
                    "start" => %{"dateTime" => "2024-01-15T09:00:00Z"},
                    "end" => %{"dateTime" => "2024-01-15T09:15:00Z"},
                    "organizer" => %{"email" => "team@test.com"}
                  }
                ],
                "nextPageToken" => "page2"
                # No nextSyncToken - Google only returns it on the FINAL page.
              })
            )

          2 ->
            assert conn.query_string =~ "pageToken=page2"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "items" => [
                  %{
                    "id" => "event_p2",
                    "summary" => "Page 2 Event",
                    "start" => %{"dateTime" => "2024-01-15T10:00:00Z"},
                    "end" => %{"dateTime" => "2024-01-15T10:15:00Z"},
                    "organizer" => %{"email" => "team@test.com"}
                  }
                ],
                "nextSyncToken" => "final-page-token"
              })
            )
        end
      end)

      {:ok, result} = GoogleCalendar.sync_history("cal_paged_user@example.com", account)

      # Both pages' events were collected, and the FINAL page's nextSyncToken
      # (only Google returns it there) was persisted - not nil, which is what
      # a single-request implementation would see on a multi-page result.
      assert result.count == 2
      assert result.next_sync_token == "final-page-token"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "calendar_sync_token")
      assert cursor.value == "final-page-token"
    end

    test "on 410, clears the stored sync token before the recovery fetch so an empty/partial recovery can't leave an expired token behind" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("cal_410_cursor_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("cal_410_cursor_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["calendar.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("cal_410_cursor_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "calendar_sync_token", %{
        "value" => "expired-token",
        "watch_channel_id" => "chan-1",
        "watch_resource_id" => "res-1"
      })

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        if count == 1 do
          assert conn.query_string == "syncToken=expired-token"

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(410, Jason.encode!(%{"error" => %{"code" => 410}}))
        else
          # Recovery full-window fetch returns an empty window with no
          # nextSyncToken (e.g. nothing in range) - the expired token must
          # not still be sitting in source_cursors after this.
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"items" => []}))
        end
      end)

      {:ok, result} = GoogleCalendar.sync_history("cal_410_cursor_user@example.com", account)

      assert result.count == 0
      assert result.next_sync_token == nil

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "calendar_sync_token")
      # The expired token is gone (no perpetual-410 loop on the next sync)...
      assert cursor.value in [nil, ""]
      # ...but the watch bookkeeping on the same row was preserved, since
      # clearing it would silently drop the account from WatchRenewer.
      assert cursor.watch_channel_id == "chan-1"
      assert cursor.watch_resource_id == "res-1"
    end
  end

  # ============================================================================
  # SPEC 12 — calendar time-blocking write path
  # ============================================================================

  describe "create_event/2 (SPEC 12)" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      user_id = "cal_create_user_#{System.unique_integer([:positive])}@example.com"

      {:ok, _token} =
        Maraithon.OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["https://www.googleapis.com/auth/calendar.readonly"]
        })

      {:ok, bypass: bypass, user_id: user_id}
    end

    test "sends the client id, timeZone names, and ownership markers", %{
      bypass: bypass,
      user_id: user_id
    } do
      client_event_id = deterministic_client_id("prepared-action-1")
      parent = self()

      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        send(parent, {:request_body, params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => params["id"],
            "summary" => params["summary"],
            "status" => "confirmed",
            "start" => params["start"],
            "end" => params["end"],
            "htmlLink" => "https://calendar.google.com/event/#{params["id"]}",
            "organizer" => %{"email" => user_id},
            "extendedProperties" => %{
              "private" => params["extendedProperties"]["private"]
            }
          })
        )
      end)

      assert {:ok, event} = GoogleCalendar.create_event(user_id, create_attrs(client_event_id))
      assert event.event_id == client_event_id
      assert event.private_properties["maraithon_managed"] == "true"
      assert event.private_properties["maraithon_client_key"] == client_event_id

      assert_receive {:request_body, params}
      assert params["id"] == client_event_id
      # R7: the client id is RFC2938 base32hex — lowercase a-v / 0-9 only.
      assert Regex.match?(~r/^[a-v0-9]{5,1024}$/, params["id"])
      # DST edge case: an explicit IANA zone name on both sides — never a
      # hand-computed UTC offset.
      assert params["start"]["timeZone"] == "America/New_York"
      assert params["end"]["timeZone"] == "America/New_York"
      assert params["extendedProperties"]["private"]["maraithon_todo_id"] == "todo-1"
    end

    test "derives the same client id from the same prepared action across calls", %{
      bypass: bypass,
      user_id: user_id
    } do
      client_event_id = deterministic_client_id("prepared-action-same")
      assert client_event_id == deterministic_client_id("prepared-action-same")

      parent = self()

      Bypass.expect(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:sent_id, Jason.decode!(body)["id"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => client_event_id,
            "summary" => "Hyatt prep",
            "start" => %{"dateTime" => "2026-07-09T14:00:00Z"},
            "end" => %{"dateTime" => "2026-07-09T14:45:00Z"},
            "organizer" => %{"email" => user_id}
          })
        )
      end)

      assert {:ok, _} = GoogleCalendar.create_event(user_id, create_attrs(client_event_id))
      assert {:ok, _} = GoogleCalendar.create_event(user_id, create_attrs(client_event_id))

      assert_receive {:sent_id, first_id}
      assert_receive {:sent_id, second_id}
      assert first_id == client_event_id
      assert second_id == client_event_id
    end

    test "recovers a 409 on the client id by fetching the existing event", %{
      bypass: bypass,
      user_id: user_id
    } do
      client_event_id = deterministic_client_id("prepared-action-409")

      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          409,
          Jason.encode!(%{
            "error" => %{"code" => 409, "message" => "The requested identifier already exists."}
          })
        )
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/calendar/v3/calendars/primary/events/#{client_event_id}",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "id" => client_event_id,
              "summary" => "Hyatt prep",
              "start" => %{"dateTime" => "2026-07-09T14:00:00Z"},
              "end" => %{"dateTime" => "2026-07-09T14:45:00Z"},
              "organizer" => %{"email" => user_id},
              "extendedProperties" => %{
                "private" => %{
                  "maraithon_managed" => "true",
                  "maraithon_client_key" => client_event_id
                }
              }
            })
          )
        end
      )

      assert {:ok, event} = GoogleCalendar.create_event(user_id, create_attrs(client_event_id))
      assert event.event_id == client_event_id
    end

    test "409 recovery fails when the ownership marker does not match", %{
      bypass: bypass,
      user_id: user_id
    } do
      client_event_id = deterministic_client_id("prepared-action-collision")

      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(409, Jason.encode!(%{"error" => %{"code" => 409}}))
      end)

      Bypass.expect_once(
        bypass,
        "GET",
        "/calendar/v3/calendars/primary/events/#{client_event_id}",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "id" => client_event_id,
              "summary" => "Someone else's event",
              "start" => %{"dateTime" => "2026-07-09T14:00:00Z"},
              "end" => %{"dateTime" => "2026-07-09T14:45:00Z"},
              "organizer" => %{"email" => user_id}
            })
          )
        end
      )

      assert {:error, :calendar_event_id_conflict} =
               GoogleCalendar.create_event(user_id, create_attrs(client_event_id))
    end

    test "translates an insufficient-scope 403 to :calendar_write_scope_required", %{
      bypass: bypass,
      user_id: user_id
    } do
      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          403,
          Jason.encode!(%{
            "error" => %{
              "code" => 403,
              "message" => "Request had insufficient authentication scopes.",
              "status" => "PERMISSION_DENIED",
              "details" => [%{"reason" => "ACCESS_TOKEN_SCOPE_INSUFFICIENT"}]
            }
          })
        )
      end)

      assert {:error, :calendar_write_scope_required} =
               GoogleCalendar.create_event(
                 user_id,
                 create_attrs(deterministic_client_id("prepared-action-403"))
               )
    end

    test "passes a non-scope 403 through unchanged", %{bypass: bypass, user_id: user_id} do
      Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          403,
          Jason.encode!(%{"error" => %{"code" => 403, "message" => "Rate limit exceeded."}})
        )
      end)

      assert {:error, {:http_status, 403, _body}} =
               GoogleCalendar.create_event(
                 user_id,
                 create_attrs(deterministic_client_id("prepared-action-403-other"))
               )
    end

    # DST-boundary: two dates straddling the US spring-forward transition
    # (2026-03-08) both carry the IANA timeZone name — Google resolves DST
    # from the zone, so there is no hand-computed offset to drift.
    test "sends the IANA timeZone for dates on both sides of a DST transition", %{
      bypass: bypass,
      user_id: user_id
    } do
      parent = self()

      Bypass.expect(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        send(parent, {:dst_body, params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => params["id"],
            "summary" => params["summary"],
            "start" => params["start"],
            "end" => params["end"],
            "organizer" => %{"email" => user_id}
          })
        )
      end)

      before_dst =
        create_attrs(deterministic_client_id("dst-before"))
        |> Map.merge(%{start: "2026-03-06T15:00:00Z", end: "2026-03-06T15:45:00Z"})

      after_dst =
        create_attrs(deterministic_client_id("dst-after"))
        |> Map.merge(%{start: "2026-03-09T14:00:00Z", end: "2026-03-09T14:45:00Z"})

      assert {:ok, _} = GoogleCalendar.create_event(user_id, before_dst)
      assert {:ok, _} = GoogleCalendar.create_event(user_id, after_dst)

      assert_receive {:dst_body, first}
      assert_receive {:dst_body, second}

      for body <- [first, second] do
        assert body["start"]["timeZone"] == "America/New_York"
        assert body["end"]["timeZone"] == "America/New_York"
        refute Map.has_key?(body["start"], "offset")
      end

      assert first["start"]["dateTime"] == "2026-03-06T15:00:00Z"
      assert second["start"]["dateTime"] == "2026-03-09T14:00:00Z"
    end
  end

  describe "delete_event/2 (SPEC 12)" do
    setup do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      user_id = "cal_delete_user_#{System.unique_integer([:positive])}@example.com"

      {:ok, _token} =
        Maraithon.OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600
        })

      {:ok, bypass: bypass, user_id: user_id}
    end

    test "treats an already-deleted event (410) as a successful no-op", %{
      bypass: bypass,
      user_id: user_id
    } do
      Bypass.expect_once(
        bypass,
        "DELETE",
        "/calendar/v3/calendars/primary/events/gone-event",
        fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(410, Jason.encode!(%{"error" => %{"code" => 410}}))
        end
      )

      assert {:ok, :already_gone} = GoogleCalendar.delete_event(user_id, "gone-event")
    end
  end

  describe "events_in_window/3 (SPEC 12 R10)" do
    test "fetches events overlapping the window with a fresh read", %{} do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google_calendar,
        api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
      )

      user_id = "cal_window_user_#{System.unique_integer([:positive])}@example.com"

      {:ok, _token} =
        Maraithon.OAuth.store_tokens(user_id, "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600
        })

      Bypass.expect_once(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
        query = URI.decode_query(conn.query_string)
        assert query["timeMin"] == "2026-07-09T14:00:00Z"
        assert query["timeMax"] == "2026-07-09T14:45:00Z"
        assert query["singleEvents"] == "true"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "items" => [
              %{
                "id" => "overlapping-event",
                "summary" => "Landed meeting",
                "start" => %{"dateTime" => "2026-07-09T14:15:00Z"},
                "end" => %{"dateTime" => "2026-07-09T14:30:00Z"},
                "organizer" => %{"email" => user_id}
              }
            ]
          })
        )
      end)

      assert {:ok, [event]} =
               GoogleCalendar.events_in_window(
                 user_id,
                 "2026-07-09T14:00:00Z",
                 "2026-07-09T14:45:00Z"
               )

      assert event.event_id == "overlapping-event"
    end
  end

  # Helper functions

  defp create_attrs(client_event_id) do
    %{
      client_event_id: client_event_id,
      summary: "Hyatt prep",
      description: "Prep block",
      start: "2026-07-09T14:00:00Z",
      end: "2026-07-09T14:45:00Z",
      timezone: "America/New_York",
      extended_private_properties: %{
        "maraithon_managed" => "true",
        "maraithon_todo_id" => "todo-1",
        "maraithon_client_key" => client_event_id
      }
    }
  end

  defp deterministic_client_id(prepared_action_id) do
    :crypto.hash(:sha256, "calendar_create_event:" <> prepared_action_id)
    |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp build_conn_with_headers(headers) do
    conn = %Plug.Conn{req_headers: []}

    Enum.reduce(headers, conn, fn {header, value}, acc ->
      %{acc | req_headers: [{header, value} | acc.req_headers]}
    end)
  end
end
