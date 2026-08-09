# ==============================================================================
# Webhook Controller Integration Tests
# ==============================================================================
#
# WHAT THIS TESTS (Product Perspective):
# --------------------------------------
# Webhooks are the primary way Maraithon connects to the outside world. They
# allow agents to react to real-world events in real-time:
#
# - **GitHub**: PR opened, issue created, code pushed, CI failed
# - **Slack**: New message in channel, user mentioned, emoji reaction
# - **WhatsApp**: Incoming message from customer
# - **Linear**: Issue created, status changed, assignee updated
# - **Telegram**: Bot receives message, callback query
# - **Google Calendar**: Event created, updated, or deleted
#
# From a user's perspective, webhooks are what make agents feel "alive" and
# responsive. Instead of polling APIs every few minutes, agents receive
# instant notifications when something happens.
#
# Example User Journey:
# 1. User connects their GitHub repo to Maraithon
# 2. User creates an agent subscribed to "github:owner/repo"
# 3. Developer opens a PR on that repo
# 4. GitHub sends a webhook to /webhooks/github
# 5. Maraithon validates the signature and publishes to PubSub
# 6. Agent receives the event and responds (e.g., posts a review)
#
# WHY THESE TESTS MATTER:
# -----------------------
# If webhook handling breaks, users experience:
# - Agents that never respond to external events
# - Security vulnerabilities if signature verification fails
# - Silent failures with no visibility into what went wrong
# - Missed business-critical notifications
#
# ==============================================================================
#
# TECHNICAL DETAILS:
# ------------------
# This test module validates the WebhookController, which handles incoming
# webhook requests from external services. Each provider (GitHub, Slack, etc.)
# has its own signature verification scheme and payload format.
#
# Webhook Processing Flow:
# ------------------------
#
#   ┌─────────────────────────────────────────────────────────────────────────┐
#   │                        Webhook Processing                                │
#   │                                                                          │
#   │   External Service                                                       │
#   │   (GitHub, Slack, etc.)                                                 │
#   │          │                                                               │
#   │          ▼                                                               │
#   │   ┌─────────────────┐                                                   │
#   │   │ POST /webhooks/ │  ◄── Raw HTTP request with signature              │
#   │   │    {provider}   │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │    Signature    │  ◄── Verify HMAC-SHA256 (or provider-specific)    │
#   │   │   Verification  │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │     Connector   │  ◄── Parse payload, extract event type            │
#   │   │   (per-provider)│      Build normalized event structure             │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │  Phoenix.PubSub │  ◄── Publish to topic (e.g., "github:owner/repo") │
#   │   │     Broadcast   │                                                   │
#   │   └────────┬────────┘                                                   │
#   │            │                                                             │
#   │            ▼                                                             │
#   │   ┌─────────────────┐                                                   │
#   │   │ Subscribed      │  ◄── Agents receive {:pubsub_event, topic, data}  │
#   │   │    Agents       │                                                   │
#   │   └─────────────────┘                                                   │
#   └─────────────────────────────────────────────────────────────────────────┘
#
# Signature Verification by Provider:
# -----------------------------------
# - GitHub: HMAC-SHA256 in X-Hub-Signature-256 header
# - Slack: HMAC-SHA256 with timestamp in X-Slack-Signature header
# - WhatsApp: HMAC-SHA256 in X-Hub-Signature-256 header (same as GitHub)
# - Linear: HMAC-SHA256 in Linear-Signature header
# - Google: No signature (relies on channel token validation)
#
# Test Categories:
# ----------------
# - Signature Verification: Ensure invalid signatures are rejected
# - Event Parsing: Verify different event types are handled correctly
# - PubSub Publishing: Confirm events are broadcast to correct topics
# - Error Handling: Graceful handling of malformed payloads
# - Challenge/Verification: Provider-specific URL verification flows
#
# Dependencies:
# -------------
# - MaraithonWeb.WebhookController (the controller being tested)
# - Maraithon.Connectors.* (provider-specific connectors)
# - Phoenix.PubSub (for event broadcasting)
# - Application config (webhook secrets, allow_unsigned flags)
#
# Setup Requirements:
# -------------------
# This test uses `async: false` because:
# 1. Application config is modified during tests (allow_unsigned flags)
# 2. Config changes must be isolated between tests
# 3. on_exit callbacks restore original config
#
# ==============================================================================

defmodule MaraithonWeb.WebhookControllerTest.FailingBackgroundJobs do
  @moduledoc false

  def enqueue_telegram_webhook_event(_bot_id, _update_id, _event),
    do: {:error, :database_unavailable}
end

defmodule MaraithonWeb.WebhookControllerTest do
  # Non-async due to application config modification
  use MaraithonWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob

  @telegram_secret "telegram_webhook_secret_token_123456789"

  # ----------------------------------------------------------------------------
  # Test Setup
  # ----------------------------------------------------------------------------
  #
  # Configures all webhook providers to allow unsigned requests for testing.
  # In production, all webhooks require valid signatures for security.
  #
  # The allow_unsigned flag is a development/testing convenience that lets us
  # test webhook handling without computing real HMAC signatures.
  # ----------------------------------------------------------------------------
  setup do
    original_webhook_controller =
      Application.get_env(:maraithon, MaraithonWeb.WebhookController)

    Application.delete_env(:maraithon, MaraithonWeb.WebhookController)

    # Enable unsigned webhooks for testing
    Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
    Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: true)

    Application.put_env(:maraithon, :whatsapp,
      app_secret: "",
      verify_token: "test_verify_token",
      allow_unsigned: true
    )

    Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: true)

    Application.put_env(:maraithon, :telegram,
      bot_token: "123456:ABC-DEF",
      webhook_secret_token: @telegram_secret
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: false)
      Application.put_env(:maraithon, :telegram, webhook_secret_token: "")

      if original_webhook_controller do
        Application.put_env(
          :maraithon,
          MaraithonWeb.WebhookController,
          original_webhook_controller
        )
      else
        Application.delete_env(:maraithon, MaraithonWeb.WebhookController)
      end
    end)

    :ok
  end

  # ============================================================================
  # GITHUB WEBHOOK TESTS
  # ============================================================================
  #
  # GitHub webhooks are triggered by repository events:
  # - push: Code pushed to branch
  # - pull_request: PR opened/closed/merged
  # - issues: Issue opened/closed/commented
  # - ping: Webhook configuration validation
  #
  # GitHub uses HMAC-SHA256 for signature verification.
  # ============================================================================

  describe "POST /webhooks/github" do
    @doc """
    Verifies that push events are processed and published.
    Push events contain commit information and branch references.
    These are published to topic "github:{owner}/{repo}".
    """
    test "handles push event", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/main",
        "repository" => %{"full_name" => "owner/repo"},
        "sender" => %{"login" => "user"},
        "commits" => [%{"id" => "abc123", "message" => "Test commit"}]
      }

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 200)["status"] == "published"
      assert json_response(conn, 200)["event_type"] == "push"
    end

    @doc """
    Verifies that ping events are ignored (not published).
    Ping events are sent by GitHub when configuring a new webhook.
    They're used to verify the endpoint is reachable.
    """
    test "handles ping event", %{conn: conn} do
      payload = %{
        "zen" => "Keep it simple.",
        "hook_id" => 12345
      }

      conn =
        conn
        |> put_req_header("x-github-event", "ping")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    @doc """
    Verifies that invalid signatures are rejected when security is enabled.
    This is critical for preventing spoofed webhooks from malicious actors.
    """
    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      # Temporarily disable allow_unsigned
      Application.put_env(:maraithon, :github,
        webhook_secret: "real_secret",
        allow_unsigned: false
      )

      payload = %{"action" => "test"}

      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :github, webhook_secret: "", allow_unsigned: true)
    end
  end

  # ============================================================================
  # SLACK WEBHOOK TESTS
  # ============================================================================
  #
  # Slack webhooks are triggered by workspace events:
  # - url_verification: Challenge/response for endpoint setup
  # - event_callback: Actual events (messages, reactions, etc.)
  #
  # Slack uses a custom signature scheme with timestamp and HMAC-SHA256.
  # ============================================================================

  describe "POST /webhooks/slack" do
    @doc """
    Verifies URL verification challenge handling.
    When you configure a Slack app, Slack sends a challenge request.
    The server must respond with the challenge value to prove ownership.
    """
    test "handles url_verification challenge", %{conn: conn} do
      payload = %{
        "type" => "url_verification",
        "challenge" => "test_challenge_string"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert response(conn, 200) == "test_challenge_string"
    end

    @doc """
    Verifies that event_callback messages are processed and published.
    These contain actual user events like messages, reactions, etc.
    Published to topic "slack:{team_id}".
    """
    test "handles event_callback", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "team_id" => "T123",
        "event" => %{
          "type" => "message",
          "channel" => "C123",
          "user" => "U123",
          "text" => "Hello world"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  # ============================================================================
  # WHATSAPP WEBHOOK TESTS
  # ============================================================================
  #
  # WhatsApp webhooks are triggered by messaging events:
  # - GET: URL verification (hub.challenge)
  # - POST: Incoming messages, status updates
  #
  # WhatsApp uses the same signature scheme as Facebook (HMAC-SHA256).
  # ============================================================================

  describe "GET /webhooks/whatsapp" do
    @doc """
    Verifies URL verification challenge handling for WhatsApp.
    Meta requires you to verify your webhook endpoint before they send events.
    You must respond with the hub.challenge value.
    """
    test "handles verification challenge", %{conn: conn} do
      conn =
        conn
        |> get("/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "test_verify_token",
          "hub.challenge" => "challenge_response"
        })

      assert response(conn, 200) == "challenge_response"
    end

    @doc """
    Verifies that invalid verify tokens are rejected.
    This prevents unauthorized parties from receiving your webhooks.
    """
    test "rejects invalid verify token", %{conn: conn} do
      conn =
        conn
        |> get("/webhooks/whatsapp", %{
          "hub.mode" => "subscribe",
          "hub.verify_token" => "wrong_token",
          "hub.challenge" => "challenge_response"
        })

      assert response(conn, 403) =~ "Verification failed"
    end
  end

  describe "POST /webhooks/whatsapp" do
    @doc """
    Verifies that incoming WhatsApp messages are processed.
    Messages contain sender info, message content, and metadata.
    Published to topic "whatsapp:{phone_number_id}".
    """
    test "handles text message", %{conn: conn} do
      payload = %{
        "object" => "whatsapp_business_account",
        "entry" => [
          %{
            "changes" => [
              %{
                "field" => "messages",
                "value" => %{
                  "metadata" => %{"phone_number_id" => "12345"},
                  "messages" => [
                    %{
                      "from" => "15551234567",
                      "type" => "text",
                      "text" => %{"body" => "Hello"},
                      "id" => "msg123",
                      "timestamp" => "1234567890"
                    }
                  ]
                }
              }
            ]
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  # ============================================================================
  # LINEAR WEBHOOK TESTS
  # ============================================================================
  #
  # Linear webhooks are triggered by project management events:
  # - Issue created/updated/deleted
  # - Comment added
  # - Status changed
  #
  # Linear uses HMAC-SHA256 with the Linear-Signature header.
  # ============================================================================

  describe "POST /webhooks/linear" do
    @doc """
    Verifies that issue creation events are processed.
    Issue events contain full issue data including title, state, team.
    Published to topic "linear:{team_key}".
    """
    test "handles issue created event", %{conn: conn} do
      payload = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue123",
          "title" => "Test Issue",
          "state" => %{"name" => "Todo"},
          "team" => %{"key" => "ENG"}
        },
        "organizationId" => "org123"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", "test-signature")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 200)["status"] == "published"
    end
  end

  # ============================================================================
  # TELEGRAM WEBHOOK TESTS
  # ============================================================================

  describe "POST /webhooks/telegram" do
    @describetag telegram_ingress: true

    test "requires the static path and exact singleton header before parsing", %{conn: conn} do
      payload = telegram_message_payload(80_001)
      assert response(telegram_post(conn, payload), 204) == ""

      accepted_count = telegram_job_count()

      rejected = [
        post(build_conn(), "/webhooks/telegram", payload),
        build_conn()
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong")
        |> post("/webhooks/telegram", payload),
        build_conn()
        |> put_req_header(
          "x-telegram-bot-api-secret-token",
          String.duplicate("x", byte_size(@telegram_secret))
        )
        |> post("/webhooks/telegram", payload),
        build_conn()
        |> Plug.Conn.prepend_req_headers([
          {"x-telegram-bot-api-secret-token", @telegram_secret},
          {"x-telegram-bot-api-secret-token", @telegram_secret}
        ])
        |> post("/webhooks/telegram", payload),
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/telegram/legacy-secret", "not json"),
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/telegram/legacy-secret/suffix", "not json")
      ]

      for rejected_conn <- rejected do
        assert response(rejected_conn, 404) == ""
      end

      Application.put_env(:maraithon, :telegram,
        bot_token: "123456:ABC-DEF",
        webhook_secret_token: ""
      )

      assert response(
               build_conn()
               |> put_req_header("content-length", "999999999")
               |> telegram_post(payload),
               404
             ) == ""

      assert telegram_job_count() == accepted_count
    end

    test "normalizes, bounds, redacts, and recursively scrubs raw fields before 204", %{
      conn: conn
    } do
      raw_sentinel = "RAW-WEBHOOK-SENTINEL-DO-NOT-STORE"
      token_sentinel = "Bearer abcdefghijklmnopqrstuvwxyz0123456789"

      payload = %{
        "update_id" => 80_002,
        "message" => %{
          "message_id" => 91,
          "date" => 1_700_000_000,
          "chat" => %{"id" => 222, "type" => "private"},
          "from" => %{"id" => 222, "username" => "tester", "is_bot" => false},
          "unsupported" => %{"raw" => raw_sentinel, "authorization" => token_sentinel},
          "sentinel" => raw_sentinel
        }
      }

      log = capture_log(fn -> assert response(telegram_post(conn, payload), 204) == "" end)
      refute log =~ raw_sentinel
      refute log =~ token_sentinel

      job =
        Repo.get_by!(BackgroundJob,
          job_type: "telegram_webhook_event",
          dedupe_key: "telegram-webhook:123456:80002"
        )

      assert job.status == "pending"
      assert job.queue == "ingress"
      assert job.max_attempts == 5
      assert job.payload["event"]["type"] == "unknown"
      assert is_binary(job.payload["event"]["timestamp"])
      refute contains_raw_field?(job.payload)
      refute inspect(job.payload) =~ raw_sentinel
      refute inspect(job.payload) =~ token_sentinel
      refute inspect(job.payload) =~ @telegram_secret
    end

    test "persists ignored valid updates as replay tombstones", %{conn: conn} do
      payload = %{"update_id" => 80_003, "poll_answer" => %{"poll_id" => "ignored"}}
      assert response(telegram_post(conn, payload), 204) == ""

      job =
        Repo.get_by!(BackgroundJob,
          dedupe_key: "telegram-webhook:123456:80003",
          job_type: "telegram_webhook_event"
        )

      assert job.payload["event"] == %{
               "data" => %{},
               "source" => "telegram",
               "timestamp" => job.payload["event"]["timestamp"],
               "type" => "ignored_update"
             }
    end

    test "every replay converges on the permanent receipt", %{conn: conn} do
      payload = telegram_message_payload(80_004)
      assert response(telegram_post(conn, payload), 204) == ""

      first =
        Repo.get_by!(BackgroundJob,
          dedupe_key: "telegram-webhook:123456:80004",
          job_type: "telegram_webhook_event"
        )

      first
      |> Ecto.Changeset.change(%{
        status: "completed",
        completed_at: DateTime.utc_now(),
        payload: %{}
      })
      |> Repo.update!()

      replay = put_in(payload, ["message", "text"], "different replay content")
      assert response(telegram_post(build_conn(), replay), 204) == ""

      assert Repo.aggregate(
               from(job in BackgroundJob,
                 where: job.dedupe_key == "telegram-webhook:123456:80004"
               ),
               :count,
               :id
             ) == 1

      assert Repo.get!(BackgroundJob, first.id).payload == %{}
    end

    test "returns 400 for authenticated malformed JSON and invalid update ids" do
      malformed = "{not-json"

      assert_error_sent 400, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-length", Integer.to_string(byte_size(malformed)))
        |> put_req_header("x-telegram-bot-api-secret-token", @telegram_secret)
        |> post("/webhooks/telegram", malformed)
      end

      for update_id <- [-1, 9_223_372_036_854_775_808, "80005", nil] do
        assert response(telegram_post(build_conn(), telegram_message_payload(update_id)), 400) ==
                 ""
      end

      assert telegram_job_count() == 0
    end

    test "returns 413 for cumulative compressed and gzip-inflated overflow" do
      oversized_identity = String.duplicate("x", 600_001)

      assert response(
               build_conn()
               |> put_req_header("content-type", "application/json")
               |> put_req_header(
                 "content-length",
                 Integer.to_string(byte_size(oversized_identity))
               )
               |> put_req_header("x-telegram-bot-api-secret-token", @telegram_secret)
               |> post("/webhooks/telegram", oversized_identity),
               413
             ) == ""

      inflated_json = Jason.encode!(%{"update_id" => 80_005, "padding" => oversized_identity})
      gzipped = :zlib.gzip(inflated_json)
      assert byte_size(gzipped) < 600_000

      assert_error_sent 413, fn ->
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> put_req_header("content-encoding", "gzip")
        |> put_req_header("content-length", Integer.to_string(byte_size(gzipped)))
        |> put_req_header("x-telegram-bot-api-secret-token", @telegram_secret)
        |> post("/webhooks/telegram", gzipped)
      end

      assert telegram_job_count() == 0
    end

    test "returns 413 when the normalized durable event is out of bounds", %{conn: conn} do
      payload =
        put_in(
          telegram_message_payload(80_006),
          ["message", "text"],
          String.duplicate("x", 64_001)
        )

      assert response(telegram_post(conn, payload), 413) == ""
      assert telegram_job_count() == 0
    end

    test "returns 503 when bot configuration or durable persistence is unavailable", %{conn: conn} do
      Application.put_env(:maraithon, MaraithonWeb.WebhookController,
        background_jobs_module: MaraithonWeb.WebhookControllerTest.FailingBackgroundJobs
      )

      assert response(telegram_post(conn, telegram_message_payload(80_007)), 503) == ""

      Application.put_env(:maraithon, :telegram,
        bot_token: "",
        webhook_secret_token: @telegram_secret
      )

      assert response(telegram_post(build_conn(), telegram_message_payload(80_008)), 503) == ""
    end
  end

  # ============================================================================
  # GOOGLE CALENDAR WEBHOOK TESTS
  # ============================================================================
  #
  # Google Calendar webhooks notify of calendar changes:
  # - sync: Initial synchronization (ignored)
  # - exists: Resource was created/updated
  #
  # Google uses channel tokens for verification (no HMAC signature).
  # ============================================================================

  describe "POST /webhooks/google/calendar" do
    @doc """
    Verifies that sync notifications are ignored.
    Sync notifications are sent when a watch is first created.
    They don't contain actual event data.
    """
    test "handles calendar sync notification", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-goog-channel-id", "channel123")
        |> put_req_header("x-goog-resource-id", "resource123")
        |> put_req_header("x-goog-resource-state", "sync")
        |> put_req_header("x-goog-channel-token", "user_123")
        |> post("/webhooks/google/calendar", %{})

      # Unknown legacy channels reveal no state and are acknowledged empty.
      assert response(conn, 204) == ""
    end

    @doc """
    Verifies that an unregistered exists notification is acknowledged and dropped.
    User-controlled channel tokens are not proof of a stored watch identity.
    """
    test "acknowledges and drops an unregistered calendar exists notification", %{conn: conn} do
      # Even a real user id in the caller-controlled token is not enough. A
      # connected account with the exact stored watch channel is required.
      {:ok, _user} =
        Maraithon.Accounts.get_or_create_user_by_email("webhook-calendar-exists@example.com")

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-goog-channel-id", "channel123")
        |> put_req_header("x-goog-resource-id", "resource123")
        |> put_req_header("x-goog-resource-state", "exists")
        |> put_req_header("x-goog-channel-token", "webhook-calendar-exists@example.com")
        |> post("/webhooks/google/calendar", %{})

      assert response(conn, 204) == ""

      assert Maraithon.Runtime.BackgroundJobs.list(user_id: "webhook-calendar-exists@example.com") ==
               []
    end
  end

  # ============================================================================
  # ERROR HANDLING TESTS - GITHUB
  # ============================================================================
  #
  # These tests verify graceful error handling for malformed payloads.
  # ============================================================================

  describe "POST /webhooks/github - error handling" do
    @doc """
    Verifies error handling when repository info is missing.
    All GitHub events should include repository context.
    """
    test "handles missing repository error", %{conn: conn} do
      payload = %{
        "action" => "opened"
        # No repository key
      }

      conn =
        conn
        |> put_req_header("x-github-event", "issues")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/github", payload)

      assert json_response(conn, 400)["error"] =~ "Failed to process webhook"
    end
  end

  # ============================================================================
  # ERROR HANDLING TESTS - SLACK
  # ============================================================================

  describe "POST /webhooks/slack - error handling" do
    @doc """
    Verifies that bot messages are ignored to prevent loops.
    When a bot posts a message, it shouldn't trigger another bot response.
    """
    test "handles ignored events", %{conn: conn} do
      payload = %{
        "type" => "event_callback",
        "team_id" => "T123",
        "event" => %{
          "type" => "message",
          "channel" => "C123",
          "bot_id" => "B123",
          "text" => "Bot message"
        }
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=test")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    @doc """
    Verifies signature rejection when security is enabled for Slack.
    """
    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      Application.put_env(:maraithon, :slack,
        signing_secret: "real_secret",
        allow_unsigned: false
      )

      payload = %{"type" => "event_callback"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-slack-signature", "v0=invalid")
        |> put_req_header("x-slack-request-timestamp", "1234567890")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/slack", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :slack, signing_secret: "", allow_unsigned: true)
    end
  end

  # ============================================================================
  # ERROR HANDLING TESTS - WHATSAPP
  # ============================================================================

  describe "POST /webhooks/whatsapp - error handling" do
    @doc """
    Verifies that non-WhatsApp Business Account objects are ignored.
    The object field tells us the type of webhook.
    """
    test "handles ignored events", %{conn: conn} do
      payload = %{
        "object" => "other_object"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    @doc """
    Verifies signature rejection when security is enabled for WhatsApp.
    """
    test "rejects invalid signature when not allowing unsigned", %{conn: conn} do
      Application.put_env(:maraithon, :whatsapp, app_secret: "real_secret", allow_unsigned: false)

      payload = %{"object" => "whatsapp_business_account"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-hub-signature-256", "sha256=invalid")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/whatsapp", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :whatsapp, app_secret: "", allow_unsigned: true)
    end
  end

  # ============================================================================
  # ERROR HANDLING TESTS - LINEAR
  # ============================================================================

  describe "POST /webhooks/linear - error handling" do
    @doc """
    Verifies that events without team info are ignored.
    We need team info to determine the topic for publishing.
    """
    test "handles events without team info", %{conn: conn} do
      payload = %{
        "action" => "create",
        "type" => "Issue",
        "data" => %{
          "id" => "issue123",
          "title" => "Test Issue"
          # No team key
        },
        "organizationId" => "org123"
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("linear-signature", "test-signature")
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 200)["status"] == "ignored"
    end

    @doc """
    Verifies signature rejection when secret is configured for Linear.
    """
    test "rejects invalid signature when secret configured", %{conn: conn} do
      Application.put_env(:maraithon, :linear, webhook_secret: "real_secret")

      payload = %{"action" => "create", "type" => "Issue"}

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        # No linear-signature header
        |> assign(:raw_body, Jason.encode!(payload))
        |> post("/webhooks/linear", payload)

      assert json_response(conn, 401)["error"] == "Invalid signature"

      Application.put_env(:maraithon, :linear, webhook_secret: "", allow_unsigned: true)
    end
  end

  # ============================================================================
  # ERROR HANDLING TESTS - TELEGRAM
  # ============================================================================

  # ============================================================================
  # RAW BODY HANDLING TESTS
  # ============================================================================
  #
  # These tests verify that the webhook handler works with or without
  # the raw body being cached in conn.assigns. The raw body is needed
  # for signature verification.
  # ============================================================================

  describe "raw body handling" do
    @doc """
    Verifies fallback when raw_body is not cached in assigns.
    The CacheRawBody plug should cache it, but we have a fallback
    that re-encodes the parsed params if needed.
    """
    test "falls back to re-encoding when raw_body is not cached", %{conn: conn} do
      payload = %{
        "ref" => "refs/heads/main",
        "repository" => %{"full_name" => "owner/repo"},
        "commits" => []
      }

      # Do not assign :raw_body - it will fall back to re-encoding
      conn =
        conn
        |> put_req_header("x-github-event", "push")
        |> put_req_header("x-hub-signature-256", "sha256=test")
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/github", payload)

      # Should still succeed (with allow_unsigned)
      assert json_response(conn, 200)["status"] == "published"
    end
  end

  defp telegram_post(conn, payload) do
    body = Jason.encode!(payload)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> put_req_header("x-telegram-bot-api-secret-token", @telegram_secret)
    |> post("/webhooks/telegram", body)
  end

  defp telegram_job_count do
    Repo.aggregate(
      from(job in BackgroundJob, where: job.job_type == "telegram_webhook_event"),
      :count,
      :id
    )
  end

  defp telegram_message_payload(update_id) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => 90,
        "date" => 1_700_000_000,
        "chat" => %{"id" => 222, "type" => "private"},
        "from" => %{"id" => 222, "username" => "tester", "is_bot" => false},
        "text" => "hello"
      }
    }
  end

  defp contains_raw_field?(value) when is_map(value) do
    Enum.any?(value, fn
      {key, _nested} when key in [:raw, "raw"] -> true
      {_key, nested} -> contains_raw_field?(nested)
    end)
  end

  defp contains_raw_field?(value) when is_list(value),
    do: Enum.any?(value, &contains_raw_field?/1)

  defp contains_raw_field?(_value), do: false
end
