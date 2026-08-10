defmodule Maraithon.InsightNotificationActionsTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Actions
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.Todos.Todo

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_google = Application.get_env(:maraithon, :gmail, [])
    original_slack = Application.get_env(:maraithon, :slack, [])
    original_action_execution = Application.get_env(:maraithon, Actions, [])

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
      Application.put_env(:maraithon, Actions, original_action_execution)
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
          "source_id" => "a1b1c1",
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
          data: button_callback(sent.opts, "Draft Email")
        }
      })

    drafted_delivery = Repo.get!(Delivery, delivery.id)
    assert get_in(drafted_delivery.metadata, ["telegram_action", "status"]) == "drafted"

    drafted = last_telegram_message(:edit)
    assert drafted.text =~ "Email draft ready"
    assert drafted.text =~ "Re: Quick follow-up"
    assert button_labels(drafted.opts) |> Enum.member?("Send Now")

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/a1b1c1", fn conn ->
      assert conn.query_string =~ "format=metadata"
      assert conn.query_string =~ "metadataHeaders=Message-ID"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "a1b1c1",
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
          data: button_callback(drafted.opts, "Send Now")
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
          "source_id" => "a1b1c2",
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
              "reply_to_message_id" => "a1b1c2"
            }
          }
        }
      })
      |> Repo.insert!()

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/a1b1c2", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "a1b1c2",
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
          data: Actions.callback_data_for_action(delivery, "send")
        }
      })

    callback = last_telegram_message(:callback)

    assert callback.opts[:text] == "Check Gmail before sending again"

    state =
      Repo.get!(Delivery, delivery.id).metadata
      |> get_in(["telegram_action"])

    assert state["status"] == "outcome_unknown"

    assert state["outcome_evidence"] == %{
             "code" => "provider_call_failed",
             "manual_reconciliation_required" => true
           }

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
          data: Actions.callback_data_for_action(delivery, "draft")
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
          data: Actions.callback_data_for_action(delivery, "archive")
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
          data: button_callback(sent.opts, "Draft Slack")
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
          data: button_callback(drafted.opts, "Send Now")
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
          data: Actions.callback_data_for_action(delivery, "done")
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
          data: Actions.callback_data_for_action(delivery, "ack")
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

  test "provider claims use the database clock after the delivery row lock", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")
    delivery = create_slack_send_delivery(agent, user_id, "database-clock")
    test_pid = self()

    Bypass.stub(bypass, "POST", "/chat.postMessage", fn conn ->
      send(test_pid, {:database_clock_provider_called, self()})

      receive do
        :release_database_clock_provider -> :ok
      after
        2_000 -> raise "timed out waiting to release the database-clock provider"
      end

      slack_success(conn, "database-clock-result")
    end)

    lock_holder =
      Task.async(fn ->
        Repo.transaction(fn ->
          _locked =
            Delivery
            |> where([candidate], candidate.id == ^delivery.id)
            |> lock("FOR UPDATE")
            |> Repo.one!()

          send(test_pid, {:delivery_row_locked, self()})

          receive do
            {:release_delivery_row, recipient} ->
              released_at = database_now()
              send(recipient, {:delivery_row_released_at, released_at})
              :released
          end
        end)
      end)

    assert_receive {:delivery_row_locked, lock_pid}, 1_000
    claimant = Task.async(fn -> Actions.perform_action(delivery, "send") end)
    send(lock_pid, {:release_delivery_row, self()})

    assert_receive {:delivery_row_released_at, lock_released_at}, 1_000
    assert {:ok, :released} = Task.await(lock_holder, 1_000)
    assert_receive {:database_clock_provider_called, provider_pid}, 1_000

    state = execution_state(delivery)
    claimed_at = parse_datetime!(state["execution_claimed_at"])
    lease_expires_at = parse_datetime!(state["execution_lease_expires_at"])

    assert DateTime.compare(claimed_at, lock_released_at) in [:eq, :gt]
    assert DateTime.diff(lease_expires_at, claimed_at, :millisecond) == 300_000
    assert state["execution_phase"] == "provider_started"

    send(provider_pid, :release_database_clock_provider)
    assert {:ok, _completed, "Slack reply sent"} = Task.await(claimant, 2_000)
  end

  test "a live provider execution claim allows only one provider call", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")
    delivery = create_slack_send_delivery(agent, user_id, "live-claim")
    test_pid = self()
    provider_calls = :atomics.new(1, [])

    Bypass.stub(bypass, "POST", "/chat.postMessage", fn conn ->
      call_number = :atomics.add_get(provider_calls, 1, 1)
      send(test_pid, {:slack_provider_called, call_number, self()})

      receive do
        {:release_slack_provider, ^call_number} -> :ok
      after
        2_000 -> raise "timed out waiting to release Slack provider"
      end

      slack_success(conn, "live-owner-result")
    end)

    owner_send = Task.async(fn -> Actions.perform_action(delivery, "send") end)
    assert_receive {:slack_provider_called, 1, provider_pid}, 1_000

    live_state = execution_state(delivery)
    assert live_state["status"] == "executing"
    assert live_state["execution_phase"] == "provider_started"
    assert is_binary(live_state["execution_owner"])
    assert is_binary(live_state["execution_lease_expires_at"])

    assert {:error, :action_in_progress} = Actions.perform_action(delivery, "send")
    assert :atomics.get(provider_calls, 1) == 1
    refute_receive {:slack_provider_called, 2, _provider_pid}, 100

    send(provider_pid, {:release_slack_provider, 1})
    assert {:ok, _completed, "Slack reply sent"} = Task.await(owner_send, 2_000)

    final_state = execution_state(delivery)
    assert final_state["status"] == "executed"
    assert final_state["execution_phase"] == "provider_checkpointed"
    assert final_state["result"]["ts"] == "live-owner-result"
    assert final_state["execution_owner"] == live_state["execution_owner"]
  end

  test "provider execution reaches its natural deadline below the lease and terminates the task",
       %{
         agent: agent,
         user_id: user_id
       } do
    test_pid = self()
    provider_calls = :atomics.new(1, [])

    provider_runner = fn _spec, _insight ->
      call_number = :atomics.add_get(provider_calls, 1, 1)
      send(test_pid, {:deadline_provider_called, call_number, self()})

      receive do
        :unexpected_release -> {:ok, %{ts: "must-not-complete"}}
      end
    end

    Application.put_env(:maraithon, Actions,
      provider_execution_timeout_ms: 500,
      provider_execution_runner: provider_runner
    )

    delivery = create_slack_send_delivery(agent, user_id, "natural-deadline")
    send_task = Task.async(fn -> Actions.perform_action(delivery, "send") end)
    assert_receive {:deadline_provider_called, 1, provider_task_pid}, 1_000

    provider_task_ref = Process.monitor(provider_task_pid)

    assert_receive {:DOWN, ^provider_task_ref, :process, ^provider_task_pid, _reason}, 1_000

    assert {:ok, unknown_delivery, "Check Slack before sending again"} =
             Task.await(send_task, 2_000)

    state = Actions.action_state_for_delivery(unknown_delivery)
    claimed_at = parse_datetime!(state["execution_claimed_at"])
    lease_expires_at = parse_datetime!(state["execution_lease_expires_at"])

    assert state["status"] == "outcome_unknown"
    assert state["provider_timeout_ms"] == 500

    assert state["provider_timeout_ms"] <
             DateTime.diff(lease_expires_at, claimed_at, :millisecond)

    assert state["outcome_evidence"] == %{
             "code" => "provider_deadline_exceeded",
             "manual_reconciliation_required" => true
           }

    assert :atomics.get(provider_calls, 1) == 1
    refute_receive {:deadline_provider_called, 2, _provider_task_pid}, 100
  end

  test "an expired provider-started claim becomes terminal unknown without re-sending", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")
    delivery = create_slack_send_delivery(agent, user_id, "expired-provider-started")
    test_pid = self()
    provider_calls = :atomics.new(1, [])

    Bypass.stub(bypass, "POST", "/chat.postMessage", fn conn ->
      call_number = :atomics.add_get(provider_calls, 1, 1)
      send(test_pid, {:unexpected_expired_provider_call, call_number})
      slack_success(conn, "must-not-send")
    end)

    now = database_now()
    original_spec = execution_state(delivery)["spec"]

    provider_started_state = %{
      "status" => "executing",
      "spec" => original_spec,
      "started_at" => now |> DateTime.add(-301, :second) |> DateTime.to_iso8601(),
      "execution_owner" => Ecto.UUID.generate(),
      "execution_claimed_at" => now |> DateTime.add(-301, :second) |> DateTime.to_iso8601(),
      "execution_lease_expires_at" => now |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
      "execution_phase" => "provider_started",
      "provider_started_at" => now |> DateTime.add(-10, :second) |> DateTime.to_iso8601(),
      "provider_timeout_ms" => 240_000
    }

    put_execution_state(delivery, provider_started_state)

    assert {:ok, unknown_delivery, "Check Slack before sending again"} =
             Actions.perform_action(delivery, "send")

    unknown_state = Actions.action_state_for_delivery(unknown_delivery)
    assert unknown_state["status"] == "outcome_unknown"
    assert unknown_state["spec"] == original_spec
    assert unknown_state["execution_owner"] == provider_started_state["execution_owner"]

    assert unknown_state["outcome_evidence"] == %{
             "code" => "provider_claim_expired",
             "manual_reconciliation_required" => true
           }

    assert Map.keys(unknown_state["outcome_evidence"]) |> Enum.sort() ==
             ["code", "manual_reconciliation_required"]

    refute_receive {:unexpected_expired_provider_call, _call_number}, 100
    assert :atomics.get(provider_calls, 1) == 0

    unknown_at = unknown_state["outcome_unknown_at"]

    assert {:ok, replayed, "Check Slack before sending again"} =
             Actions.perform_action(delivery, "send")

    assert Actions.action_state_for_delivery(replayed)["outcome_unknown_at"] == unknown_at
    refute_receive {:unexpected_expired_provider_call, _call_number}, 100
  end

  test "an expired pre-provider claim with no started marker may be reclaimed", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")
    delivery = create_slack_send_delivery(agent, user_id, "expired-pre-provider")
    test_pid = self()
    provider_calls = :atomics.new(1, [])

    Bypass.stub(bypass, "POST", "/chat.postMessage", fn conn ->
      call_number = :atomics.add_get(provider_calls, 1, 1)
      send(test_pid, {:reclaimed_provider_called, call_number})
      slack_success(conn, "reclaimed-once")
    end)

    now = database_now()
    original_spec = execution_state(delivery)["spec"]
    expired_owner = Ecto.UUID.generate()

    pre_provider_state = %{
      "status" => "executing",
      "spec" => original_spec,
      "started_at" => now |> DateTime.add(-301, :second) |> DateTime.to_iso8601(),
      "execution_owner" => expired_owner,
      "execution_claimed_at" => now |> DateTime.add(-301, :second) |> DateTime.to_iso8601(),
      "execution_lease_expires_at" => now |> DateTime.add(-1, :second) |> DateTime.to_iso8601(),
      "execution_phase" => "pre_provider"
    }

    put_execution_state(delivery, pre_provider_state)

    assert {:ok, completed, "Slack reply sent"} = Actions.perform_action(delivery, "send")
    assert_receive {:reclaimed_provider_called, 1}, 1_000
    refute_receive {:reclaimed_provider_called, 2}, 100

    state = Actions.action_state_for_delivery(completed)
    assert state["status"] == "executed"
    assert state["spec"] == original_spec
    assert state["result"]["ts"] == "reclaimed-once"
    assert state["execution_phase"] == "provider_checkpointed"
    refute state["execution_owner"] == expired_owner
    assert :atomics.get(provider_calls, 1) == 1
  end

  test "a late provider owner cannot checkpoint over a newer terminal generation", %{
    agent: agent,
    user_id: user_id
  } do
    bypass = Bypass.open()
    Application.put_env(:maraithon, :slack, api_base_url: "http://localhost:#{bypass.port}")
    delivery = create_slack_send_delivery(agent, user_id, "late-owner")
    test_pid = self()
    provider_calls = :atomics.new(1, [])

    Bypass.stub(bypass, "POST", "/chat.postMessage", fn conn ->
      call_number = :atomics.add_get(provider_calls, 1, 1)
      send(test_pid, {:late_owner_provider_called, call_number, self()})

      receive do
        :release_late_owner_provider -> :ok
      after
        2_000 -> raise "timed out waiting to release late owner provider"
      end

      slack_success(conn, "late-owner-result")
    end)

    original_send = Task.async(fn -> Actions.perform_action(delivery, "send") end)
    assert_receive {:late_owner_provider_called, 1, provider_pid}, 1_000

    provider_started_state = execution_state(delivery)
    original_owner = provider_started_state["execution_owner"]
    replacement_owner = Ecto.UUID.generate()

    replacement_state =
      provider_started_state
      |> Map.put("status", "outcome_unknown")
      |> Map.put("execution_owner", replacement_owner)
      |> Map.put("outcome_unknown_at", database_now() |> DateTime.to_iso8601())
      |> Map.put("outcome_evidence", %{
        "code" => "provider_claim_expired",
        "manual_reconciliation_required" => true
      })

    put_execution_state(delivery, replacement_state)
    send(provider_pid, :release_late_owner_provider)

    assert {:error, :provider_outcome_unknown} = Task.await(original_send, 2_000)
    assert :atomics.get(provider_calls, 1) == 1

    final_state = execution_state(delivery)
    assert final_state["status"] == "outcome_unknown"
    assert final_state["execution_owner"] == replacement_owner
    refute final_state["execution_owner"] == original_owner
    refute Map.has_key?(final_state, "result")
    refute Map.has_key?(final_state, "executed_at")

    assert {:ok, replayed, "Check Slack before sending again"} =
             Actions.perform_action(delivery, "send")

    assert Actions.action_state_for_delivery(replayed)["execution_owner"] == replacement_owner
    refute_receive {:late_owner_provider_called, 2, _provider_pid}, 100
  end

  test "an executed provider checkpoint resumes acknowledgement and presentation without re-sending",
       %{
         agent: agent,
         user_id: user_id
       } do
    delivery = create_action_delivery(agent, user_id, "executed-resume")

    checkpoint = %{
      "status" => "executed",
      "spec" => %{
        "kind" => "gmail_reply",
        "notice_label" => "Email",
        "to" => "owner@example.com",
        "subject" => "Re: Durable checkpoint",
        "body" => "Already sent"
      },
      "result" => %{"id" => "provider-side-effect-once"},
      "executed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    delivery =
      delivery
      |> Delivery.changeset(%{
        metadata: %{"telegram_action" => checkpoint}
      })
      |> Repo.update!()

    Code.ensure_loaded!(Maraithon.TestSupport.CapturingTelegram)

    event = %{
      type: "callback_query",
      data: %{
        callback_id: "cb-executed-resume",
        chat_id: 12345,
        message_id: 456,
        data: Actions.callback_data_for_action(delivery, "send")
      }
    }

    # No Gmail token or provider endpoint exists in this test. Success proves
    # the retry resumed from the executed checkpoint instead of re-sending.
    assert :ok = InsightNotifications.process_telegram_event_durable(event)

    resumed_delivery = Repo.get!(Delivery, delivery.id)
    resumed_insight = Repo.get!(Maraithon.Insights.Insight, delivery.insight_id)
    state = get_in(resumed_delivery.metadata, ["telegram_action"])

    assert resumed_insight.status == "acknowledged"
    assert state["status"] == "executed"
    assert state["result"] == %{"id" => "provider-side-effect-once"}
    assert is_binary(state["acknowledged_at"])
    assert last_telegram_message(:edit).text =~ "Sent via Gmail"

    edits_before_retry = telegram_message_count(:edit)
    assert :ok = InsightNotifications.process_telegram_event_durable(event)
    assert telegram_message_count(:edit) == edits_before_retry + 1

    retried_state =
      Repo.get!(Delivery, delivery.id).metadata
      |> get_in(["telegram_action"])

    assert retried_state["result"] == %{"id" => "provider-side-effect-once"}
    assert retried_state["acknowledged_at"] == state["acknowledged_at"]
  end

  test "duplicate ack, dismiss, manual completion, and snooze retries are idempotent", %{
    agent: agent,
    user_id: user_id
  } do
    for {action, expected_status, expected_kind} <- [
          {"ack", "acknowledged", "manual_ack"},
          {"dismiss", "dismissed", nil},
          {"done", "acknowledged", "manual_complete"}
        ] do
      delivery = create_action_delivery(agent, user_id, "terminal-#{action}")

      assert {:ok, first_delivery, _notice} = Actions.perform_action(delivery, action)
      assert {:ok, second_delivery, _notice} = Actions.perform_action(first_delivery, action)

      insight = Repo.get!(Maraithon.Insights.Insight, delivery.insight_id)
      assert insight.status == expected_status

      assert Actions.action_state_for_delivery(second_delivery)["status"] in [
               "executed",
               "dismissed"
             ]

      if expected_kind do
        assert Actions.action_state_for_delivery(second_delivery)["kind"] == expected_kind
      end
    end

    snooze_delivery = create_action_delivery(agent, user_id, "terminal-snooze")
    deadline = DateTime.add(DateTime.utc_now(), 4, :hour)

    {:ok, snoozed_insight} =
      Insights.snooze(user_id, snooze_delivery.insight_id, deadline)

    # Simulate a crash after the insight mutation committed but before the
    # delivery metadata checkpoint was written.
    snooze_delivery =
      snooze_delivery
      |> Repo.reload!()
      |> Repo.preload(:insight)

    assert {:ok, first_snooze, _notice} = Actions.perform_action(snooze_delivery, "snooze")
    assert {:ok, second_snooze, _notice} = Actions.perform_action(first_snooze, "snooze")

    expected_until = DateTime.to_iso8601(snoozed_insight.snoozed_until)
    assert Actions.action_state_for_delivery(first_snooze)["until"] == expected_until
    assert Actions.action_state_for_delivery(second_snooze)["until"] == expected_until

    assert Repo.get!(Maraithon.Insights.Insight, snooze_delivery.insight_id).snoozed_until ==
             snoozed_insight.snoozed_until
  end

  test "action callbacks are revision-bound and stale buttons cannot regress state", %{
    agent: agent,
    user_id: user_id
  } do
    delivery = create_action_delivery(agent, user_id, "revision-bound")

    stale_done = Actions.callback_data_for_action(delivery, "done")
    longest_callback = Actions.callback_data_for_action(delivery, "regenerate")

    assert stale_done =~ ~r/^insact:[0-9a-f-]{36}:done:[0-9a-f]{8}$/
    assert byte_size(longest_callback) <= 64

    # Any newer insight revision invalidates the old evidence-bound button.
    delivery.insight
    |> Ecto.Changeset.change(summary: "Newer source evidence changed this insight.")
    |> Repo.update!()

    assert {:noop, :stale_action_revision} =
             Actions.handle_callback(%{
               callback_id: "stale-insight-revision",
               chat_id: 12345,
               message_id: 100,
               data: stale_done
             })

    assert is_nil(Actions.action_state_for_delivery(Repo.get!(Delivery, delivery.id)))

    current = Delivery |> Repo.get!(delivery.id) |> Repo.preload(:insight)
    stale_done = Actions.callback_data_for_action(current, "done")
    dismiss = Actions.callback_data_for_action(current, "dismiss")

    assert :ok =
             Actions.handle_callback(%{
               callback_id: "current-dismiss",
               chat_id: 12345,
               message_id: 100,
               data: dismiss
             })

    assert {:noop, :stale_action_revision} =
             InsightNotifications.process_telegram_event_durable(%{
               type: "callback_query",
               source: "telegram",
               data: %{
                 callback_id: "stale-done-after-dismiss",
                 chat_id: 12345,
                 message_id: 100,
                 data: stale_done
               }
             })

    terminal = Repo.get!(Delivery, delivery.id)
    assert Actions.action_state_for_delivery(terminal)["status"] == "dismissed"
    assert Repo.get!(Maraithon.Insights.Insight, delivery.insight_id).status == "dismissed"

    todo = synced_todo_for(delivery.insight)
    assert todo.status == "dismissed"
    assert todo.metadata["source_insight_status"] == "dismissed"
  end

  test "a replayed regenerate callback preserves the newer draft revision", %{
    agent: agent,
    user_id: user_id
  } do
    delivery = create_action_delivery(agent, user_id, "stale-regenerate")

    original_state = %{
      "status" => "drafted",
      "spec" => %{
        "kind" => "gmail_reply",
        "notice_label" => "Email",
        "to" => "owner@example.com",
        "subject" => "Re: Revision",
        "body" => "Older draft"
      }
    }

    delivery =
      delivery
      |> Delivery.changeset(%{"metadata" => %{"telegram_action" => original_state}})
      |> Repo.update!()
      |> Repo.preload(:insight, force: true)

    stale_regenerate = Actions.callback_data_for_action(delivery, "regenerate")
    newer_state = put_in(original_state, ["spec", "body"], "Newer draft")

    delivery
    |> Delivery.changeset(%{"metadata" => %{"telegram_action" => newer_state}})
    |> Repo.update!()

    assert :ok =
             Actions.handle_callback(%{
               callback_id: "stale-regenerate",
               chat_id: 12345,
               message_id: 100,
               data: stale_regenerate
             })

    final_state = Repo.get!(Delivery, delivery.id).metadata["telegram_action"]
    assert get_in(final_state, ["spec", "body"]) == "Newer draft"
  end

  test "concurrent terminal insight actions choose one monotone result and sync its todo", %{
    agent: agent,
    user_id: user_id
  } do
    delivery = create_action_delivery(agent, user_id, "terminal-race")

    done = Task.async(fn -> Actions.perform_action(delivery, "done") end)
    snooze = Task.async(fn -> Actions.perform_action(delivery, "snooze") end)

    results = [Task.await(done, 2_000), Task.await(snooze, 2_000)]

    assert Enum.count(results, &match?({:ok, %Delivery{}, _notice}, &1)) == 1
    assert Enum.count(results, &match?({:error, :stale_action_revision}, &1)) == 1

    final_delivery = Repo.get!(Delivery, delivery.id)
    final_insight = Repo.get!(Maraithon.Insights.Insight, delivery.insight_id)
    final_todo = synced_todo_for(delivery.insight)
    state = Actions.action_state_for_delivery(final_delivery)

    case state do
      %{"status" => "executed", "kind" => "manual_complete"} ->
        assert final_insight.status == "acknowledged"
        assert final_todo.status == "done"
        assert final_todo.metadata["source_insight_status"] == "acknowledged"

      %{"status" => "snoozed", "until" => until_text} ->
        assert final_insight.status == "snoozed"
        assert final_todo.status == "snoozed"
        assert DateTime.to_iso8601(final_insight.snoozed_until) == until_text
        assert final_todo.snoozed_until == final_insight.snoozed_until
    end
  end

  test "terminal action recovery repairs a legacy insight-to-todo checkpoint gap", %{
    agent: agent,
    user_id: user_id
  } do
    delivery = create_action_delivery(agent, user_id, "todo-recovery")

    logical_key =
      delivery.insight.tracking_key || delivery.insight.dedupe_key || delivery.insight.id

    refute Repo.get_by(Todo,
             user_id: delivery.insight.user_id,
             dedupe_key: "insight:#{logical_key}"
           )

    delivery.insight
    |> Ecto.Changeset.change(status: "acknowledged")
    |> Repo.update!()

    checkpoint = %{
      "status" => "executed",
      "kind" => "manual_ack",
      "result" => %{"status" => "acknowledged_in_telegram"},
      "executed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    delivery =
      delivery
      |> Delivery.changeset(%{"metadata" => %{"telegram_action" => checkpoint}})
      |> Repo.update!()
      |> Repo.preload(:insight, force: true)

    assert {:ok, recovered, "Acknowledged"} = Actions.perform_action(delivery, "ack")
    assert is_binary(Actions.action_state_for_delivery(recovered)["acknowledged_at"])

    repaired = synced_todo_for(delivery.insight)
    assert repaired.status == "done"
    assert repaired.metadata["source_insight_status"] == "acknowledged"
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

  defp execution_state(%Delivery{} = delivery) do
    Repo.get!(Delivery, delivery.id).metadata
    |> get_in(["telegram_action"])
  end

  defp put_execution_state(%Delivery{} = delivery, state) do
    current = Repo.get!(Delivery, delivery.id)

    current
    |> Ecto.Changeset.change(
      metadata: put_in(current.metadata || %{}, ["telegram_action"], state)
    )
    |> Repo.update!()
  end

  defp database_now do
    case Repo.query!("SELECT timezone('UTC', clock_timestamp())", [], log: false).rows do
      [[%NaiveDateTime{} = value]] -> DateTime.from_naive!(value, "Etc/UTC")
      [[%DateTime{} = value]] -> value
    end
  end

  defp parse_datetime!(value) when is_binary(value) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(value)
    datetime
  end

  defp slack_success(conn, timestamp) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "ts" => timestamp}))
  end

  defp create_slack_send_delivery(agent, user_id, suffix) do
    team_id = "TCLAIM"

    {:ok, _token} =
      OAuth.store_tokens(user_id, "slack:#{team_id}:user:UCLAIM", %{
        access_token: "slack-user-access",
        refresh_token: "slack-user-refresh",
        expires_in: 3_600,
        scopes: ["chat:write"]
      })

    state = %{
      "status" => "drafted",
      "spec" => %{
        "kind" => "slack_reply",
        "notice_label" => "Slack",
        "team_id" => team_id,
        "channel" => "CCLAIM",
        "thread_ts" => "171234.000100",
        "text" => "The reviewed Slack reply"
      }
    }

    agent
    |> create_action_delivery(user_id, suffix)
    |> Delivery.changeset(%{metadata: %{"telegram_action" => state}})
    |> Repo.update!()
    |> Repo.preload(:insight, force: true)
  end

  defp create_action_delivery(agent, user_id, suffix) do
    unique = System.unique_integer([:positive])

    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Durable action #{suffix}",
          "summary" => "This action exercises a durable Telegram checkpoint.",
          "recommended_action" => "Resolve it from Telegram.",
          "priority" => 90,
          "confidence" => 0.9,
          "source_id" => "durable-action-#{suffix}-#{unique}",
          "dedupe_key" => "telegram-actions:#{suffix}:#{unique}",
          "metadata" => %{"ackable" => true}
        }
      ])

    %Delivery{}
    |> Delivery.changeset(%{
      insight_id: insight.id,
      user_id: user_id,
      channel: "telegram",
      destination: "12345",
      score: 0.9,
      threshold: 0.78,
      status: "sent",
      provider_message_id: "durable-#{unique}",
      sent_at: DateTime.utc_now(),
      metadata: %{}
    })
    |> Repo.insert!()
    |> Repo.preload(:insight)
  end

  defp synced_todo_for(insight) do
    logical_key = insight.tracking_key || insight.dedupe_key || insight.id
    Repo.get_by!(Todo, user_id: insight.user_id, dedupe_key: "insight:#{logical_key}")
  end

  defp telegram_message_count(type) do
    Agent.get(:capturing_telegram_recorder, fn events ->
      Enum.count(events, &(&1.type == type))
    end)
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end

  defp button_callback(opts, label) do
    opts
    |> Keyword.get(:reply_markup, %{})
    |> Map.get("inline_keyboard", [])
    |> List.flatten()
    |> Enum.find_value(fn button ->
      if button["text"] == label, do: button["callback_data"]
    end)
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
