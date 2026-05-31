defmodule Maraithon.InsightNotificationActionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.Repo

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_google = Application.get_env(:maraithon, :gmail, [])
    original_slack = Application.get_env(:maraithon, :slack, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights,
        telegram_module: Maraithon.TestSupport.CapturingTelegram,
        default_sender_name: "Kent"
      )
    )

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime,
        llm_provider: Maraithon.TestSupport.ActionDraftLLM,
        llm_provider_name: "test-action-draft"
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
      Application.put_env(:maraithon, :gmail, original_google)
      Application.put_env(:maraithon, :slack, original_slack)
    end)

    user_id = "telegram-actions@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{agent: agent, user_id: user_id}
  end

  test "drafts and sends a Gmail follow-up directly from Telegram", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "google-access",
        refresh_token: "google-refresh",
        expires_in: 3600
      })

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" =>
            "You said you'd send the deck to Sarah today. No follow-through is recorded yet.",
          "summary" =>
            "The commitment still appears open for Sarah and no completion evidence was found in sent email.",
          "recommended_action" =>
            "Send the promised follow-through now and explicitly confirm delivery in the same thread.",
          "priority" => 96,
          "confidence" => 0.93,
          "source_id" => "msg-in-1",
          "dedupe_key" => "telegram-actions:gmail:1",
          "metadata" => %{
            "account" => "kent@example.com",
            "thread_id" => "thread-1",
            "to" => "Sarah <sarah@example.com>",
            "subject" => "Investor deck",
            "context_brief" => "Explicit promise made to Sarah.",
            "record" => %{
              "person" => "Sarah",
              "commitment" => "Send the deck to Sarah",
              "evidence" => ["No later reply or delivery was found."],
              "next_action" =>
                "Send the promised follow-through now and explicitly confirm delivery in the same thread."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)

    assert sent.text =~ "<b>Needs action</b>"
    assert sent.text =~ "Send the deck to Sarah"
    assert sent.text =~ "<b>Next</b>"
    assert sent.text =~ "tap Draft Email"
    assert sent.text =~ "approval before sending"
    assert sent.text =~ "<b>Context</b>"
    assert sent.text =~ "Explicit promise made to Sarah."
    assert sent.text =~ "<b>Person</b>"
    assert sent.text =~ "Sarah"
    assert sent.text =~ "Gmail"
    assert sent.text =~ "<b>Why now</b>"
    assert sent.text =~ "A named person is waiting on the next step"
    refute sent.text =~ "I'll draft"
    refute sent.text =~ "<b>Open work</b>"
    refute sent.text =~ "<b>Why important</b>"

    assert sent.text =~
             "Send the promised follow-through now and explicitly confirm delivery"

    assert String.length(sent.text) <= 700
    refute sent.text =~ "I think this needs your attention."
    refute sent.text =~ "thread still looks open"
    refute sent.text =~ "still looks unclosed"
    refute sent.text =~ "I found no later reply"
    refute sent.text =~ "<b>What I'd send</b>"
    refute sent.text =~ "<b>Fast actions</b>"
    refute sent.text =~ "Tap Draft Email"
    refute sent.text =~ "<b>What it is:</b>"
    refute sent.text =~ "<b>Suggested reply:</b>"
    refute sent.text =~ "Needed:"
    refute sent.text =~ "Source:"
    refute sent.text =~ "score="
    refute sent.text =~ "threshold="
    refute sent.text =~ "Need from Kent"
    refute sent.text =~ "Draft plan"
    assert button_labels(sent.opts) |> Enum.member?("Draft Email")
    assert button_labels(sent.opts) |> Enum.member?("Mark Done")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-draft",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:draft"
        }
      })

    drafted_delivery = Repo.get!(Delivery, delivery.id)
    assert get_in(drafted_delivery.metadata, ["telegram_action", "status"]) == "drafted"

    drafted = last_telegram_message(:edit)
    assert drafted.text =~ "Email draft ready"
    assert drafted.text =~ "Re: Quick follow-up"
    assert button_labels(drafted.opts) |> Enum.member?("Send Now")

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/msg-in-1", fn conn ->
      assert conn.query_string =~ "format=metadata"
      assert conn.query_string =~ "metadataHeaders=Message-ID"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "msg-in-1",
          "threadId" => "thread-1",
          "snippet" => "Original message",
          "payload" => %{
            "headers" => [
              %{"name" => "Message-ID", "value" => "<source-message@example.com>"},
              %{"name" => "References", "value" => "<older-message@example.com>"}
            ]
          }
        })
      )
    end)

    Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/messages/send", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["threadId"] == "thread-1"

      decoded = Base.url_decode64!(payload["raw"], padding: false)
      assert decoded =~ "To: Sarah <sarah@example.com>"
      assert decoded =~ "Subject: Re: Quick follow-up"
      assert decoded =~ "In-Reply-To: <source-message@example.com>"
      assert decoded =~ "Following up on this now."

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"id":"gmail-sent-1","threadId":"thread-1","labelIds":["SENT"]}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-send",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:send"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    updated_delivery = Repo.get!(Delivery, delivery.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert get_in(updated_delivery.metadata, ["telegram_action", "status"]) == "executed"
    assert completed.text =~ "<b>Sent</b>"
    assert completed.text =~ "Sent via Gmail"
    assert completed.text =~ "Item: You said you'd send the deck to Sarah today."
    refute completed.text =~ "<b>Completed</b>"
    refute completed.text =~ "message gmail-sent-1"
    refute completed.text =~ "message unknown"
    refute completed.text =~ "At:"
    refute completed.text =~ ~r/\d{4}-\d{2}-\d{2}T/
  end

  test "infers the person from a clear insight title when metadata is missing", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send Sarah the deck",
          "summary" => "Explicit promise still appears open.",
          "recommended_action" => "Reply with a clear owner and timing",
          "priority" => 94,
          "confidence" => 0.91,
          "source_id" => "msg-sarah-title",
          "dedupe_key" => "telegram-actions:gmail:person-from-title",
          "metadata" => %{
            "account" => "kent@example.com",
            "thread_id" => "thread-sarah-title",
            "subject" => "Investor deck"
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert sent.text =~ "<b>Person</b>"
    assert sent.text =~ "Sarah"
    assert sent.text =~ "contact on Investor deck thread"
    assert sent.text =~ "confirm what Sarah is waiting on"
    refute sent.text =~ "Person not clearly named"
  end

  test "missing person copy asks the user to confirm the owner before acting", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Reply owed: Vendor update",
          "summary" => "The vendor update still has no recorded closure.",
          "recommended_action" => "Reply with a clear owner and timing.",
          "priority" => 89,
          "confidence" => 0.86,
          "source_id" => "msg-owner-to-confirm",
          "dedupe_key" => "telegram-actions:gmail:owner-to-confirm",
          "metadata" => %{
            "thread_id" => "thread-owner-to-confirm",
            "subject" => "Vendor update"
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert sent.text =~ "<b>Person</b>"
    assert sent.text =~ "Owner to confirm"
    assert sent.text =~ "Vendor update thread"
    assert sent.text =~ "confirm the owner and specific request"
    refute sent.text =~ "Person not clearly named"
    refute sent.text =~ "real ask"
    refute sent.text =~ "what them is waiting on"
  end

  test "action callback failures do not expose raw provider errors", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "google-access",
        refresh_token: "google-refresh",
        expires_in: 3600
      })

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Reply owed: Vendor update",
          "summary" => "The vendor asked for a status update.",
          "recommended_action" => "Reply with the current status.",
          "priority" => 91,
          "confidence" => 0.9,
          "source_id" => "msg-in-error",
          "dedupe_key" => "telegram-actions:gmail:raw-error",
          "metadata" => %{
            "thread_id" => "thread-error",
            "to" => "Vendor <vendor@example.com>",
            "subject" => "Vendor update",
            "record" => %{"person" => "Vendor"}
          }
        }
      ])

    delivery =
      %Delivery{}
      |> Delivery.changeset(%{
        insight_id: insight.id,
        user_id: user_id,
        channel: "telegram",
        destination: "12345",
        score: 0.91,
        threshold: 0.78,
        status: "sent",
        provider_message_id: "321",
        sent_at: DateTime.utc_now(),
        metadata: %{
          "telegram_action" => %{
            "status" => "drafted",
            "spec" => %{
              "kind" => "gmail_reply",
              "to" => "Vendor <vendor@example.com>",
              "subject" => "Re: Vendor update",
              "body" => "Sharing the latest status now.",
              "thread_id" => "thread-error",
              "reply_to_message_id" => "msg-in-error"
            }
          }
        }
      })
      |> Repo.insert!()

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/msg-in-error", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "msg-in-error",
          "threadId" => "thread-error",
          "payload" => %{"headers" => []}
        })
      )
    end)

    Bypass.expect_once(bypass, "POST", "/gmail/v1/users/me/messages/send", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(500, ~s({"error":"Req.TransportError token abc123"}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-gmail-send-error",
          chat_id: 12345,
          message_id: 321,
          data: "insact:#{delivery.id}:send"
        }
      })

    callback = last_telegram_message(:callback)

    assert callback.opts[:text] ==
             "Action did not complete. No change was made; use the latest message before deciding."

    refute callback.opts[:text] =~ "Req.TransportError"
    refute callback.opts[:text] =~ "token"
    refute callback.opts[:text] =~ "abc123"
    refute callback.opts[:text] =~ "gmail_send_failed"
    refute String.contains?(String.downcase(callback.opts[:text]), "try again")
  end

  test "callback failures give recovery copy instead of system labels", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Follow up on investor deck",
          "summary" => "The investor deck thread still needs a clear next step.",
          "recommended_action" => "Reply with the current status and timing.",
          "priority" => 84,
          "confidence" => 0.86,
          "source_id" => "msg-no-quick-action",
          "dedupe_key" => "telegram-actions:no-quick-action:#{System.unique_integer()}",
          "metadata" => %{
            "account" => "kent@example.com",
            "subject" => "Investor deck"
          }
        }
      ])

    assert %{sent: 1} = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-action-not-available",
          chat_id: 12345,
          message_id: 777,
          data: "insact:#{delivery.id}:draft"
        }
      })

    callback = last_telegram_message(:callback)

    assert callback.opts[:text] ==
             "No quick action is available for this item. Use the latest message or handle it in the source app."

    lower_text = String.downcase(callback.opts[:text])
    refute lower_text =~ "unsupported"
    refute lower_text =~ "not available"
    refute lower_text =~ "insight"
    refute lower_text =~ "try again"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-unsupported-action",
          chat_id: 12345,
          message_id: 777,
          data: "insact:#{delivery.id}:archive"
        }
      })

    callback = last_telegram_message(:callback)

    assert callback.opts[:text] ==
             "That button no longer matches this item. Use the latest Maraithon message before deciding."

    lower_text = String.downcase(callback.opts[:text])
    refute lower_text =~ "unsupported"
    refute lower_text =~ "not available"
    refute lower_text =~ "insight"
    refute lower_text =~ "try again"
  end

  test "verifies proactive Telegram copy stays concise and chief-of-staff shaped", %{
    agent: agent,
    user_id: user_id
  } do
    noisy_text = String.duplicate("generic reply plan with too much detail ", 30)

    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Reply owed: Re: Intro launch video",
          "summary" =>
            "Renat is waiting on the intro launch video update and no sent follow-up was found.",
          "recommended_action" =>
            "Reply with the owner, current status, exact artifact, or a concrete ETA.",
          "priority" => 94,
          "confidence" => 0.91,
          "due_at" => ~U[2026-05-20 23:00:00Z],
          "source_id" => "msg-renat-1",
          "dedupe_key" => "telegram-actions:gmail:chief-copy",
          "metadata" => %{
            "account" => "kent@runner.now",
            "thread_id" => "thread-renat-1",
            "from" => "Renat Gabitov <renat@example.com>",
            "subject" => "Re: Intro launch video",
            "context_brief" => "Renat asked for the intro launch video update.",
            "suggested_reply" => noisy_text,
            "draft_plan" => noisy_text,
            "attention" => %{"change_summary" => noisy_text},
            "record" => %{
              "person" => "Renat Gabitov",
              "commitment" => "Reply to Renat about the intro launch video",
              "next_action" =>
                "Reply with the owner, current status, exact artifact, or a concrete ETA."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert in_order?(sent.text, [
             "<b>Needs action</b>",
             "<b>Next</b>",
             "<b>Context</b>",
             "<b>Person</b>",
             "<b>Why now</b>"
           ])

    assert sent.text =~ "Reply to Renat about the intro launch video"
    assert sent.text =~ "Renat asked for the intro launch video update."
    assert sent.text =~ "Renat Gabitov"
    assert sent.text =~ "Suggested:"
    assert sent.text =~ "tap Draft Email"
    assert sent.text =~ "approval before sending"
    refute sent.text =~ "I'll draft"
    assert sent.text =~ "open the Intro launch video thread"
    assert sent.text =~ "confirm what Renat Gabitov is waiting on"
    assert String.length(sent.text) <= 700
    refute sent.text =~ "I think this needs your attention."
    refute sent.text =~ "What I'd send"
    refute sent.text =~ "Fast actions"
    refute sent.text =~ "Tap Draft"
    refute sent.text =~ "generic reply plan with too much detail"
    refute sent.text =~ "Reply with the owner"
  end

  test "renders due copy in the user's local timezone instead of UTC", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the board packet",
          "summary" => "The board packet is still waiting.",
          "recommended_action" => "Send the board packet and confirm the review window.",
          "priority" => 94,
          "confidence" => 0.91,
          "due_at" => ~U[2026-05-30 18:30:00Z],
          "source_id" => "msg-board-packet-local-time",
          "dedupe_key" => "telegram-actions:gmail:local-due-time",
          "metadata" => %{
            "account" => "kent@runner.now",
            "thread_id" => "thread-board-packet",
            "timezone" => "America/Toronto",
            "timezone_offset_hours" => -5,
            "context_brief" => "The board packet is still waiting.",
            "record" => %{"person" => "Board"}
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert sent.text =~ "Due May 30 at 2:30 PM ET."
    refute sent.text =~ "UTC"
  end

  test "renders todo cards with person context and suggested next actions", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Reply to Michael Berlingo on \"Starteryou UGC Campaigns\".",
          "summary" => "No later reply or follow-through was found in the conversation.",
          "recommended_action" =>
            "Reply now with owner, ETA, and the exact artifact or update you committed to.",
          "priority" => 94,
          "confidence" => 0.91,
          "due_at" => ~U[2026-05-24 20:00:00Z],
          "source_id" => "msg-michael-1",
          "dedupe_key" => "telegram-actions:gmail:michael-context",
          "metadata" => %{
            "account" => "kent@runner.now",
            "thread_id" => "thread-michael-1",
            "from" => "Michael Berlingo <michael@example.com>",
            "subject" => "Starteryou UGC Campaigns",
            "context_brief" => "No later reply or follow-through was found in the conversation.",
            "why_now" => "Deadline is today and no sent follow-up found.",
            "record" => %{"person" => "Michael Berlingo"}
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert sent.text =~ "<b>Needs action</b>"
    assert sent.text =~ "Michael Berlingo"
    assert sent.text =~ "Thread: Starteryou UGC Campaigns"
    assert sent.text =~ "Michael Berlingo is tied to this open thread"
    assert sent.text =~ "no later reply or delivery is recorded"
    assert sent.text =~ "contact on Starteryou UGC Campaigns thread"
    assert sent.text =~ "Gmail · kent@runner.now"
    assert sent.text =~ "Suggested:"
    assert sent.text =~ "tap Draft Email"
    assert sent.text =~ "approval before sending"
    assert sent.text =~ "open the Starteryou UGC Campaigns thread"
    assert sent.text =~ "confirm what Michael Berlingo is waiting on"
    assert sent.text =~ "close if done"
    assert String.length(sent.text) <= 700
    refute sent.text =~ "<b>Open work</b>"
    refute sent.text =~ "<b>Why important</b>"
    refute sent.text =~ "dismiss if stale"
    refute sent.text =~ "exact artifact or update"
    refute sent.text =~ "Reply now with owner, ETA"
    refute sent.text =~ "appears to be waiting"
    refute sent.text =~ "still looks open"
    refute sent.text =~ "I found no later reply"
    assert button_labels(sent.opts) |> Enum.member?("Draft Email")
  end

  test "drafts and sends a Slack reply directly from Telegram", %{agent: agent, user_id: user_id} do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:T123", %{
        access_token: "slack-bot-access",
        refresh_token: "slack-refresh",
        expires_in: 3600
      })

    {:ok, _user_token} =
      OAuth.store_tokens(user_id, "slack:T123:user:U999", %{
        access_token: "slack-user-access",
        refresh_token: "slack-user-refresh",
        expires_in: 3600,
        scopes: ["chat:write", "search:read"]
      })

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "slack",
          "category" => "reply_urgent",
          "title" => "Slack reply owed to Sarah",
          "summary" => "You still owe Sarah a Slack response and no reply was detected.",
          "recommended_action" =>
            "Send a Slack reply now with owner, next step, and a concrete timing commitment.",
          "priority" => 91,
          "confidence" => 0.89,
          "source_id" => "slack:T123:C999:171234.000100",
          "dedupe_key" => "telegram-actions:slack:1",
          "metadata" => %{
            "team_id" => "T123",
            "channel_id" => "C999",
            "channel_name" => "customer-thread",
            "thread_ts" => "171234.000100",
            "record" => %{
              "person" => "Sarah",
              "commitment" => "Reply to Sarah in Slack",
              "evidence" => ["No reply from you was found afterward in this conversation."],
              "next_action" =>
                "Send a Slack reply now with owner, next step, and a concrete timing commitment."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert sent.text =~ "tap Draft Slack"
    assert sent.text =~ "approval before posting"
    refute sent.text =~ "I'll draft"
    assert button_labels(sent.opts) |> Enum.member?("Draft Slack")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-slack-draft",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:draft"
        }
      })

    drafted = last_telegram_message(:edit)
    assert drafted.text =~ "Slack draft ready"
    assert drafted.text =~ "Owner is me"

    Bypass.expect_once(bypass, "POST", "/chat.postMessage", fn conn ->
      assert ["Bearer slack-user-access"] == Plug.Conn.get_req_header(conn, "authorization")

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["channel"] == "C999"
      assert payload["thread_ts"] == "171234.000100"
      assert payload["text"] =~ "Owner is me"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, ~s({"ok":true,"ts":"171235.000200"}))
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-slack-send",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:send"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    updated_delivery = Repo.get!(Delivery, delivery.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert get_in(updated_delivery.metadata, ["telegram_action", "status"]) == "executed"
    assert completed.text =~ "<b>Sent</b>"
    assert completed.text =~ "Sent in Slack"
    assert completed.text =~ "Item: Slack reply owed to Sarah"
    refute completed.text =~ "<b>Completed</b>"
    refute completed.text =~ "ts 171235.000200"
    refute completed.text =~ "ts unknown"
    refute completed.text =~ "At:"
    refute completed.text =~ ~r/\d{4}-\d{2}-\d{2}T/
  end

  test "marks an insight complete directly from Telegram", %{agent: agent, user_id: user_id} do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "calendar",
          "category" => "meeting_follow_up",
          "title" => "Post-meeting follow-up owed: Monday planning",
          "summary" => "After the Monday planning meeting, you still owe owners and next steps.",
          "recommended_action" =>
            "Send a short recap covering owners, next steps, and due dates.",
          "priority" => 88,
          "confidence" => 0.84,
          "dedupe_key" => "telegram-actions:calendar:1"
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert button_labels(sent.opts) |> Enum.member?("Mark Done")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-done",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:done"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert completed.text =~ "<b>Marked Done</b>"
    assert completed.text =~ "Marked complete from Telegram"
    assert completed.text =~ "Item: Post-meeting follow-up owed: Monday planning"
    refute completed.text =~ "<b>Completed</b>"
  end

  test "acknowledges important FYI insights directly from Telegram", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "important_fyi",
          "title" => "Platform status: App Store Connect In Review",
          "summary" =>
            "App review status changed. This is important FYI because it affects release timing.",
          "recommended_action" =>
            "Acknowledge the status change and monitor it; step in only if the review stalls or changes again.",
          "priority" => 83,
          "confidence" => 0.88,
          "dedupe_key" => "telegram-actions:fyi:1",
          "metadata" => %{
            "ackable" => true,
            "why_now" => "App review state changed and could affect release planning."
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    sent = last_telegram_message(:send)
    assert button_labels(sent.opts) |> Enum.member?("Ack")
    refute button_labels(sent.opts) |> Enum.member?("Draft Email")

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          callback_id: "cb-ack",
          chat_id: 12345,
          message_id: 123,
          data: "insact:#{delivery.id}:ack"
        }
      })

    updated_insight = Repo.get!(Maraithon.Insights.Insight, insight.id)
    completed = last_telegram_message(:edit)

    assert updated_insight.status == "acknowledged"
    assert completed.text =~ "<b>Acknowledged</b>"
    assert completed.text =~ "Acknowledged from Telegram"
    assert completed.text =~ "Item: Platform status: App Store Connect In Review"
    refute completed.text =~ "<b>Completed</b>"
  end

  test "renders conversation-progress language for heads_up insights in Telegram", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Gmail thread moving with Charlie",
          "summary" =>
            "Charlie has already responded and the conversation is moving. You may still need to handle the remaining follow-through.",
          "recommended_action" =>
            "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours.",
          "priority" => 88,
          "confidence" => 0.9,
          "dedupe_key" => "telegram-actions:gmail:heads-up",
          "metadata" => %{
            "why_now" =>
              "Charlie has already responded and the conversation is moving. The final follow-through may still be yours.",
            "conversation_context" => %{
              "notification_posture" => "heads_up",
              "latest_actor" => "Charlie"
            },
            "record" => %{
              "person" => "David",
              "commitment" => "Reply to David on Cowrie Agora Update",
              "evidence" => ["Charlie replied later in the conversation."],
              "next_action" =>
                "Monitor the thread and handle the remaining follow-through if the owner, artifact, or ETA is still yours."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)
    assert sent.text =~ "Charlie has already responded"
    assert sent.text =~ "conversation is moving"
    assert sent.text =~ "Monitor the thread"
  end

  test "renders monitor insights in Telegram without execution buttons", %{
    agent: agent,
    user_id: user_id
  } do
    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "reply_urgent",
          "title" => "Monitoring investor handoff",
          "summary" => "Breck acknowledged the thread and is checking his side.",
          "recommended_action" =>
            "Watch for a blocker, a direct request back to you, or a stall in progress.",
          "priority" => 87,
          "confidence" => 0.9,
          "attention_mode" => "monitor",
          "dedupe_key" => "telegram-actions:monitor:1",
          "tracking_key" => "telegram-actions:monitor:1",
          "metadata" => %{
            "why_now" => "The thread still matters, but the next step is not on you right now.",
            "attention" => %{
              "change_summary" => "Ownership moved to Breck after acknowledgment.",
              "re_notify_eligible" => true
            },
            "record" => %{
              "person" => "Breck",
              "commitment" => "Monitor investor handoff",
              "evidence" => ["Breck replied and took ownership of the next step."],
              "next_action" =>
                "Watch for a blocker, a direct request back to you, or a stall in progress."
            }
          }
        }
      ])

    result = InsightNotifications.dispatch_telegram_batch(batch_size: 10)
    assert result.sent == 1

    sent = last_telegram_message(:send)

    assert sent.text =~ "<b>Watching</b>"
    assert sent.text =~ "Monitor investor handoff"
    assert sent.text =~ "<b>Context</b>"
    assert sent.text =~ "Ownership moved to Breck after acknowledgment."
    assert sent.text =~ "<b>Person</b>"
    assert sent.text =~ "Breck"
    assert sent.text =~ "<b>Why now</b>"
    assert sent.text =~ "<b>Next</b>"
    refute sent.text =~ "<b>Why important</b>"
    refute sent.text =~ "I'm watching this."
    refute sent.text =~ "<b>What I'm watching</b>"
    refute sent.text =~ "Since the last check:"
    refute sent.text =~ "<b>Watch for:</b>"
    refute sent.text =~ "<b>What changed:</b>"
    refute sent.text =~ "score="
    refute sent.text =~ "threshold="

    refute button_labels(sent.opts) |> Enum.member?("Draft Email")
    refute button_labels(sent.opts) |> Enum.member?("Mark Done")
    refute button_labels(sent.opts) |> Enum.member?("Ack")
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end

  defp button_labels(opts) do
    opts
    |> Keyword.get(:reply_markup, %{})
    |> Map.get("inline_keyboard", [])
    |> List.flatten()
    |> Enum.map(& &1["text"])
  end

  defp in_order?(text, fragments) do
    fragments
    |> Enum.reduce_while(-1, fn fragment, previous_index ->
      case :binary.match(text, fragment) do
        {index, _length} when index > previous_index -> {:cont, index}
        _ -> {:halt, false}
      end
    end)
    |> is_integer()
  end
end
