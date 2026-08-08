defmodule Maraithon.Connectors.GmailTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias Maraithon.Connectors.Gmail

  setup do
    Application.put_env(:maraithon, :google,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      redirect_uri: "http://localhost:4000/auth/google/callback",
      pubsub_topic: "projects/test-project/topics/gmail-push"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :google, [])
    end)

    :ok
  end

  describe "verify_signature/2" do
    test "always returns ok" do
      conn = conn(:post, "/webhooks/google/gmail", %{})

      assert :ok = Gmail.verify_signature(conn, ~s({}))
    end
  end

  describe "handle_webhook/2 - invalid payloads" do
    test "returns error for invalid pubsub format" do
      params = %{"invalid" => "format"}
      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_format} = Gmail.handle_webhook(conn, params)
    end

    test "returns error for invalid base64 data" do
      params = %{
        "message" => %{
          "data" => "not-valid-base64!!!",
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_message} = Gmail.handle_webhook(conn, params)
    end

    test "returns error for invalid json in data" do
      # Valid base64 but not valid JSON
      encoded_data = Base.encode64("not json")

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      assert {:error, :invalid_pubsub_message} = Gmail.handle_webhook(conn, params)
    end
  end

  describe "handle_webhook/2 - valid payload" do
    test "enqueues a background job and acks without calling Google" do
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email("user@test.com")
      {:ok, _account} = Maraithon.ConnectedAccounts.upsert_manual("user@test.com", "google")

      # Gmail sends payload: {"emailAddress": "user@example.com", "historyId": "12345"}
      payload_json = ~s({"emailAddress":"user@test.com","historyId":"99999"})
      encoded_data = Base.encode64(payload_json)

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123",
          "publishTime" => "2024-01-01T00:00:00Z"
        },
        "subscription" => "projects/test/subscriptions/gmail-push"
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      {:ok, topic, event} = Gmail.handle_webhook(conn, params)

      assert topic == "email:user@test.com"
      assert event.source == "gmail"
      assert event.type == "email_webhook_enqueued"

      [job] = Maraithon.Runtime.BackgroundJobs.list(user_id: "user@test.com")
      assert job.job_type == "gmail_incremental_sync"
      assert job.status == "pending"
      assert job.dedupe_key == "gmail_webhook:msg123"
    end

    test "dedupes repeated deliveries of the same Pub/Sub messageId" do
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email("dedupe@test.com")
      {:ok, _account} = Maraithon.ConnectedAccounts.upsert_manual("dedupe@test.com", "google")

      payload_json = ~s({"emailAddress":"dedupe@test.com","historyId":"1"})
      encoded_data = Base.encode64(payload_json)

      params = %{
        "message" => %{"data" => encoded_data, "messageId" => "dupe-msg"}
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      {:ok, _topic, _event} = Gmail.handle_webhook(conn, params)
      {:ok, _topic, _event} = Gmail.handle_webhook(conn, params)

      jobs = Maraithon.Runtime.BackgroundJobs.list(user_id: "dedupe@test.com")
      assert length(jobs) == 1
    end
  end

  describe "setup_watch/2" do
    test "returns error when pubsub topic not configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: "")

      assert {:error, :pubsub_topic_not_configured} = Gmail.setup_watch("user_123", "fake_token")
    end

    test "returns error when no valid token and user not found" do
      assert {:error, :no_token} = Gmail.setup_watch("nonexistent_user")
    end
  end

  describe "stop_watch/1" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.stop_watch("nonexistent_user")
    end
  end

  describe "sync_mail_changes/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.sync_mail_changes("nonexistent_user", "12345")
    end
  end

  describe "fetch_recent_emails/2" do
    test "returns error when token not found" do
      assert {:error, :no_token} = Gmail.fetch_recent_emails("nonexistent_user")
    end
  end

  describe "fetch_message/2" do
    test "returns error when token not found for user_id" do
      assert {:error, :no_token} = Gmail.fetch_message("nonexistent_user", "abc123")
    end

    test "rejects malformed ids before token lookup or HTTP" do
      assert Gmail.normalize_id("  A0b1c2  ") == "A0b1c2"
      refute Gmail.valid_id?("gmail:synthetic-id")

      assert {:error, :invalid_gmail_id} =
               Gmail.fetch_message("nonexistent_user", "gmail:synthetic-id")

      assert {:error, :invalid_gmail_id} =
               Gmail.fetch_message_content("nonexistent_user", Ecto.UUID.generate())

      assert {:error, :invalid_gmail_id} =
               Gmail.fetch_thread("nonexistent_user", "thread-with-separators")
    end

    test "handles token directly starting with ya29." do
      # Will fail to connect but tests the branch
      result = Gmail.fetch_message("ya29.fake_token", "abc123")
      assert match?({:error, _}, result)
    end

    test "maps point-lookup 404s to quiet semantic misses" do
      bypass = Bypass.open()
      original_gmail_config = Application.get_env(:maraithon, :gmail, [])

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      on_exit(fn -> Application.put_env(:maraithon, :gmail, original_gmail_config) end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/abc123", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      log =
        capture_log(fn ->
          assert {:error, :not_found} = Gmail.fetch_message("ya29.test-token", "abc123")
        end)

      refute log =~ "HTTP request failed"
    end
  end

  describe "setup_watch/2 - token handling" do
    test "returns error when pubsub topic not configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: nil)

      result = Gmail.setup_watch("test_user", "valid_token")
      assert {:error, :pubsub_topic_not_configured} = result
    end

    test "returns error when pubsub topic is empty" do
      Application.put_env(:maraithon, :google, pubsub_topic: "")

      result = Gmail.setup_watch("test_user", "valid_token")
      assert {:error, :pubsub_topic_not_configured} = result
    end

    test "attempts API call when pubsub topic is configured" do
      Application.put_env(:maraithon, :google, pubsub_topic: "projects/test/topics/gmail")

      # Will fail on actual API call but tests the token path
      result = Gmail.setup_watch("test_user", "valid_token")
      # Will fail because API call to google fails
      assert match?({:error, _}, result)
    end
  end

  describe "stop_watch/1 with token" do
    setup do
      # Create an OAuth token for testing
      {:ok, token} =
        Maraithon.OAuth.store_tokens("gmail_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      {:ok, token: token}
    end

    test "attempts to stop watch with valid token" do
      # Will fail on actual API call but tests the token retrieval path
      result = Gmail.stop_watch("gmail_test_user")
      assert match?({:error, _}, result)
    end
  end

  describe "sync_mail_changes/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch history with valid token" do
      # Will fail on actual API call but tests the token retrieval path
      result = Gmail.sync_mail_changes("sync_test_user", "12345")
      assert match?({:error, _}, result)
    end
  end

  describe "fetch_recent_emails/2 with token" do
    setup do
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("email_test_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "attempts to fetch emails with valid token" do
      result = Gmail.fetch_recent_emails("email_test_user", 5)
      assert match?({:error, _}, result)
    end
  end

  describe "handle_webhook/2 - successful sync" do
    setup do
      {:ok, _user} = Maraithon.Accounts.get_or_create_user_by_email("user@test.com")

      # Create token for user that will be used in webhook
      {:ok, _token} =
        Maraithon.OAuth.store_tokens("user@test.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      on_exit(fn ->
        Maraithon.Repo.delete_all(Maraithon.OAuth.Token)
      end)

      :ok
    end

    test "enqueues the sync job instead of calling Google inline" do
      payload_json = ~s({"emailAddress":"user@test.com","historyId":"99999"})
      encoded_data = Base.encode64(payload_json)

      params = %{
        "message" => %{
          "data" => encoded_data,
          "messageId" => "msg123"
        }
      }

      conn = conn(:post, "/webhooks/google/gmail", params)

      {:ok, topic, event} = Gmail.handle_webhook(conn, params)

      assert topic == "email:user@test.com"
      assert event.source == "gmail"
      assert event.type == "email_webhook_enqueued"

      [job] = Maraithon.Runtime.BackgroundJobs.list(user_id: "user@test.com")
      assert job.job_type == "gmail_incremental_sync"
      assert job.status == "pending"
    end
  end

  describe "setup_watch/2 with Bypass" do
    test "successfully creates watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :google, pubsub_topic: "projects/test/topics/gmail")

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/watch", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)
        assert params["topicName"] == "projects/test/topics/gmail"
        assert params["labelIds"] == ["INBOX"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "historyId" => "12345",
            "expiration" => "#{System.system_time(:millisecond) + 86_400_000}"
          })
        )
      end)

      {:ok, watch} = Gmail.setup_watch("user_123", "test_access_token")

      assert watch.history_id == "12345"
      assert %DateTime{} = watch.expiration
    end
  end

  describe "fetch_recent_emails/2 with Bypass" do
    test "successfully fetches emails" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("fetch_emails_user", "google", %{
          access_token: "ya29.test_access_token",
          refresh_token: "1//test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      # Mock messages list endpoint
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "messages" => [
              %{"id" => "a1", "threadId" => "thread1"},
              %{"id" => "b2", "threadId" => "thread2"}
            ]
          })
        )
      end)

      # Mock individual message fetch
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/a1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "a1",
            "threadId" => "thread1",
            "snippet" => "Test email snippet",
            "labelIds" => ["INBOX", "UNREAD"],
            "internalDate" => "#{System.system_time(:millisecond)}",
            "payload" => %{
              "headers" => [
                %{"name" => "From", "value" => "sender@test.com"},
                %{"name" => "To", "value" => "me@test.com"},
                %{"name" => "Subject", "value" => "Test Subject"},
                %{"name" => "Date", "value" => "Mon, 1 Jan 2024 00:00:00 +0000"}
              ]
            }
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/b2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "b2",
            "threadId" => "thread2",
            "snippet" => "Another email",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      {:ok, emails} = Gmail.fetch_recent_emails("fetch_emails_user", 2)

      assert length(emails) == 2
      assert hd(emails).message_id == "a1"
      assert hd(emails).subject == "Test Subject"
      assert hd(emails).from == "sender@test.com"
    end

    test "metadata mode reports truncation and per-message failures" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      user_id = "fetch-metadata-#{System.unique_integer([:positive])}@example.com"

      {:ok, _token} =
        Maraithon.OAuth.store_tokens(user_id, "google", %{
          access_token: "metadata-access-token",
          refresh_token: "metadata-refresh-token",
          expires_in: 3_600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "messages" => [%{"id" => "d1"}, %{"id" => "e2"}],
            "nextPageToken" => "more"
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/d1", fn conn ->
        assert conn.query_string == "format=metadata"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "d1",
            "threadId" => "f3",
            "snippet" => "Metadata only",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => [%{"name" => "Subject", "value" => "Metadata"}]}
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/e2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"id" => "e2", "payload" => %{"headers" => 123}})
        )
      end)

      assert {:ok, [message], metadata} =
               Gmail.fetch_messages(user_id,
                 max_results: 2,
                 message_format: :metadata,
                 include_fetch_metadata: true,
                 message_fetch_concurrency: 2,
                 message_fetch_timeout_ms: 1_000
               )

      assert message.message_id == "d1"
      assert message.subject == "Metadata"
      assert metadata.listed_count == 2
      assert metadata.requested_count == 2
      assert metadata.detail_success_count == 1
      assert metadata.detail_failure_count == 1
      assert metadata.truncated?
      refute metadata.complete?
    end

    test "returns empty list when no messages" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("fetch_no_emails_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"resultSizeEstimate" => 0}))
      end)

      {:ok, emails} = Gmail.fetch_recent_emails("fetch_no_emails_user")

      assert emails == []
    end
  end

  describe "sync_mail_changes/2 with Bypass - history endpoint" do
    test "successfully syncs mail changes" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      # Mock history endpoint
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "history" => [
              %{
                "messagesAdded" => [
                  %{"message" => %{"id" => "c3"}}
                ]
              }
            ],
            "historyId" => "12346"
          })
        )
      end)

      body = Base.url_encode64("Full body text for the new message.", padding: false)

      # Mock message fetch
      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/c3", fn conn ->
        assert conn.query_string == "format=full"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "c3",
            "threadId" => "thread1",
            "snippet" => "New email",
            "labelIds" => ["INBOX"],
            "payload" => %{
              "headers" => [
                %{"name" => "Subject", "value" => "New Message"}
              ],
              "mimeType" => "text/plain",
              "body" => %{"data" => body}
            }
          })
        )
      end)

      {:ok, messages} = Gmail.sync_mail_changes("sync_bypass_user", "12345")

      assert length(messages) == 1
      assert hd(messages).message_id == "c3"
      assert hd(messages).text_body == "Full body text for the new message."
    end

    test "returns empty list when no history changes" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_empty_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "12346"}))
      end)

      {:ok, messages} = Gmail.sync_mail_changes("sync_empty_user", "12345")

      assert messages == []
    end

    test "returns history_expired error on 404" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("sync_expired_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"code" => 404}}))
      end)

      result = Gmail.sync_mail_changes("sync_expired_user", "12345")

      assert {:error, :history_expired} = result
    end
  end

  describe "sync_history/3 - cursor-aware incremental sync with Bypass" do
    test "uses the stored historyId cursor and advances it to the response max" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("gmail_cursor_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("gmail_cursor_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("gmail_cursor_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "gmail_history_id", %{"value" => "1000"})

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        assert conn.query_string =~ "startHistoryId=1000"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "1050"}))
      end)

      {:ok, result} = Gmail.sync_history("gmail_cursor_user@example.com", account)

      assert result.mode == :incremental
      assert result.history_id == "1050"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "1050"
    end

    test "falls back to a bounded full resync and resets the cursor on history_expired" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("gmail_expired_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("gmail_expired_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("gmail_expired_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "gmail_history_id", %{"value" => "1"})

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"code" => 404}}))
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"resultSizeEstimate" => 0}))
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/profile", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "9999", "emailAddress" => "x"}))
      end)

      {:ok, result} = Gmail.sync_history("gmail_expired_user@example.com", account)

      assert result.mode == :full_resync
      assert result.history_id == "9999"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "9999"
    end

    test "follows nextPageToken across multiple history pages before advancing the cursor" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("gmail_paged_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("gmail_paged_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("gmail_paged_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "gmail_history_id", %{"value" => "1000"})

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
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
                "history" => [
                  %{"messagesAdded" => [%{"message" => %{"id" => "a1"}}]}
                ],
                "nextPageToken" => "page2",
                "historyId" => "1040"
              })
            )

          2 ->
            assert conn.query_string =~ "pageToken=page2"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "history" => [
                  %{"messagesAdded" => [%{"message" => %{"id" => "b2"}}]}
                ],
                "historyId" => "1050"
              })
            )
        end
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/a1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "a1",
            "threadId" => "t1",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/b2", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "b2",
            "threadId" => "t2",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      {:ok, result} = Gmail.sync_history("gmail_paged_user@example.com", account)

      # Both pages' messages were collected, and the cursor advanced to the
      # FINAL page's historyId, not the first page's (the bug this guards
      # against: advancing past page 2+ without ever having fetched them).
      assert result.mode == :incremental
      assert result.count == 2
      assert result.history_id == "1050"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "1050"
    end

    test "treats a middle page with no \"history\" key as empty and keeps paginating" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("gmail_empty_page_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("gmail_empty_page_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("gmail_empty_page_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "gmail_history_id", %{"value" => "1000"})

      call_count = :counters.new(1, [:atomics])

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
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
                "history" => [
                  %{"messagesAdded" => [%{"message" => %{"id" => "a1"}}]}
                ],
                "nextPageToken" => "page2",
                "historyId" => "1040"
              })
            )

          2 ->
            assert conn.query_string =~ "pageToken=page2"

            # Gmail omits "history" entirely when this page's filtered
            # result set is empty. This must NOT discard page 1's
            # accumulated results or stop short of following
            # nextPageToken - that's the bug this test guards against.
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "nextPageToken" => "page3",
                "historyId" => "1045"
              })
            )

          3 ->
            assert conn.query_string =~ "pageToken=page3"

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              200,
              Jason.encode!(%{
                "history" => [
                  %{"messagesAdded" => [%{"message" => %{"id" => "c3"}}]}
                ],
                "historyId" => "1050"
              })
            )
        end
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/a1", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "a1",
            "threadId" => "t1",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/c3", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => "c3",
            "threadId" => "t3",
            "labelIds" => ["INBOX"],
            "payload" => %{"headers" => []}
          })
        )
      end)

      {:ok, result} = Gmail.sync_history("gmail_empty_page_user@example.com", account)

      # Page 1 and page 3 messages both ingested despite page 2 having no
      # "history" key, and the cursor advanced to the FINAL page's
      # historyId.
      assert result.mode == :incremental
      assert result.count == 2
      assert result.history_id == "1050"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "1050"
    end

    test "falls back to full resync when history pagination exceeds the safety cap" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1",
        max_history_pages: 1
      )

      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("gmail_capped_user@example.com")

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("gmail_capped_user@example.com", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      account = Maraithon.ConnectedAccounts.get("gmail_capped_user@example.com", "google")

      Maraithon.Connectors.SourceCursors.put(account, "gmail_history_id", %{"value" => "1000"})

      # Page 1 always claims another page exists, so with a cap of 1 the
      # implementation must give up rather than loop forever or advance the
      # cursor past unseen pages.
      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/history", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "history" => [%{"messagesAdded" => [%{"message" => %{"id" => "m1"}}]}],
            "nextPageToken" => "more",
            "historyId" => "1010"
          })
        )
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"resultSizeEstimate" => 0}))
      end)

      Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/profile", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"historyId" => "9000", "emailAddress" => "x"}))
      end)

      {:ok, result} = Gmail.sync_history("gmail_capped_user@example.com", account)

      assert result.mode == :full_resync
      assert result.history_id == "9000"

      cursor = Maraithon.Connectors.SourceCursors.get(account.id, "gmail_history_id")
      assert cursor.value == "9000"
    end
  end

  describe "stop_watch/1 with Bypass" do
    test "successfully stops watch" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("stop_bypass_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert :ok = Gmail.stop_watch("stop_bypass_user")
    end

    test "returns ok on 404 (not watching)" do
      bypass = Bypass.open()

      Application.put_env(:maraithon, :gmail,
        api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
      )

      {:ok, _token} =
        Maraithon.OAuth.store_tokens("stop_404_user", "google", %{
          access_token: "test_access_token",
          refresh_token: "test_refresh_token",
          expires_in: 3600,
          scopes: ["gmail.readonly"]
        })

      Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/stop", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => %{"code" => 404}}))
      end)

      assert :ok = Gmail.stop_watch("stop_404_user")
    end
  end
end
