defmodule Maraithon.TelegramAssistantToolboxTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.Companion.Devices, as: CompanionDevices
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{PreparedAction, Toolbox}
  alias Maraithon.TelegramConversations
  alias Maraithon.Todos

  setup do
    original_gmail = Application.get_env(:maraithon, :gmail, [])
    original_projects = Application.get_env(:maraithon, Maraithon.Projects, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :gmail, original_gmail)
      Application.put_env(:maraithon, Maraithon.Projects, original_projects)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
    end)

    :ok
  end

  test "get_open_work_summary flags stale Gmail insights when live inbox mail is newer" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    user_id = "toolbox-freshness-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "Toolbox freshness agent", "prompt" => "Inspect work."}
      })

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:work@example.com", %{
               access_token: "toolbox-work-token",
               refresh_token: "toolbox-work-refresh",
               metadata: %{"account_email" => "work@example.com"}
             })

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      ["Bearer toolbox-work-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "maxResults=1"
      assert conn.query_string =~ "labelIds=INBOX"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => [%{"id" => "live-1"}]}))
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages/live-1", fn conn ->
      ["Bearer toolbox-work-token"] = Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => "live-1",
          "threadId" => "thread-live-1",
          "snippet" => "Fresh inbox item",
          "labelIds" => ["INBOX"],
          "internalDate" => "1775091600000",
          "payload" => %{
            "headers" => [
              %{"name" => "From", "value" => "founder@example.com"},
              %{"name" => "Subject", "value" => "Fresh thread"}
            ]
          }
        })
      )
    end)

    assert {:ok, [_insight]} =
             Insights.record_many(user_id, agent.id, [
               %{
                 "source" => "gmail",
                 "category" => "reply_urgent",
                 "title" => "Old Gmail insight",
                 "summary" => "This open insight is old.",
                 "recommended_action" => "Reply in the old thread.",
                 "priority" => 90,
                 "confidence" => 0.9,
                 "dedupe_key" => "toolbox-freshness:old",
                 "tracking_key" => "toolbox-freshness:old",
                 "source_occurred_at" => ~U[2026-03-01 12:00:00Z]
               }
             ])

    assert {:ok, result} =
             Toolbox.execute(
               "get_open_work_summary",
               %{"limit" => 5},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert get_in(result, [:source_health, :gmail, :status]) == "ok"
    assert get_in(result, [:source_health, :gmail, :insights_stale]) == true

    assert get_in(result, [:source_health, :gmail, :freshest_visible_email_at]) ==
             "2026-04-02T01:00:00.000Z"

    assert get_in(result, [:source_health, :gmail, :latest_open_insight_at]) ==
             "2026-03-01T12:00:00.000000Z"

    assert get_in(result, [:source_health, :gmail, :recommended_next_step]) =~
             "search Gmail"

    assert result.insight_count == 1
    assert result.todo_count == 0
    assert result.todos == []
    assert result.summary =~ "Open work: 1 priority."
    assert result.summary =~ "Start with Reply in the old thread."
    assert result.summary =~ "Gmail has newer mail than this summary"

    assert result.next_action ==
             "Search Gmail for the latest inbox first; if nothing supersedes it, start with Reply in the old thread."

    refute result.summary =~ "open insights"
    refute result.summary =~ "1 insight"
    refute result.summary =~ "1 insight and 1 work item"
    refute result.summary =~ "gmail_search_messages"
    refute result.summary =~ "Tell the user"
  end

  test "get_open_work_summary treats connected empty Gmail as checked" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    user_id = "toolbox-empty-gmail-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:empty@example.com", %{
               access_token: "toolbox-empty-token",
               refresh_token: "toolbox-empty-refresh",
               metadata: %{"account_email" => "empty@example.com"}
             })

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      ["Bearer toolbox-empty-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "maxResults=1"
      assert conn.query_string =~ "labelIds=INBOX"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => []}))
    end)

    assert {:ok, result} =
             Toolbox.execute(
               "get_open_work_summary",
               %{"limit" => 5},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert get_in(result, [:source_health, :gmail, :status]) == "ok"
    assert get_in(result, [:source_health, :gmail, :recommended_next_step]) == nil

    assert [%{status: "empty", latest_visible_email_at: nil}] =
             get_in(result, [:source_health, :gmail, :accounts])

    assert result.summary == "No open work appeared in the connected sources checked."
    assert result.next_action == "No follow-up is pending in the connected sources checked."

    refute result.summary =~ "I do not"
    refute result.next_action =~ "I checked"
    refute result.summary =~ "Maraithon did not find"
    refute result.summary =~ "reconnection"
    refute result.summary =~ "complete inbox review"
    refute result.summary =~ "needs attention"
    refute result.next_action =~ "No action is waiting"
    refute result.next_action =~ "needs action"
  end

  test "get_open_work_summary caveats stale Mac companion context" do
    bypass = Bypass.open()

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    user_id = "toolbox-stale-companion-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, %{device: device}} =
      CompanionDevices.register(user_id, Ecto.UUID.generate(), device_name: "Executive Mac")

    stale_seen_at = DateTime.add(DateTime.utc_now(), -49 * 60 * 60, :second)

    device
    |> Ecto.Changeset.change(last_seen_at: stale_seen_at)
    |> Repo.update!()

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:empty-local@example.com", %{
               access_token: "toolbox-local-token",
               refresh_token: "toolbox-local-refresh",
               metadata: %{"account_email" => "empty-local@example.com"}
             })

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/messages", fn conn ->
      ["Bearer toolbox-local-token"] = Plug.Conn.get_req_header(conn, "authorization")
      assert conn.query_string =~ "maxResults=1"
      assert conn.query_string =~ "labelIds=INBOX"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"messages" => []}))
    end)

    assert {:ok, result} =
             Toolbox.execute(
               "get_open_work_summary",
               %{"limit" => 5},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert get_in(result, [:source_health, :gmail, :status]) == "ok"
    assert get_in(result, [:source_health, :local_context, :status]) == "stale"
    assert get_in(result, [:source_health, :local_context, :paired_device_count]) == 1
    assert get_in(result, [:source_health, :local_context, :active_device_count]) == 1

    assert get_in(result, [:source_health, :local_context, :recommended_next_step]) =~
             "Open the Mac companion app"

    assert result.summary =~
             "No open work appeared in the sources Maraithon could check, but coverage is incomplete."

    assert result.summary =~ "The Mac companion has not checked in recently"

    assert result.summary =~
             "local iMessage, Notes, Reminders, Files, and Browser History context may be incomplete"

    assert result.next_action ==
             "Open the Mac companion app before treating local iMessage, Notes, reminders, files, and browser context as complete."

    refute result.summary =~ "Maraithon did not find"
    refute result.summary =~ "I do not"
    refute result.summary =~ "companion_devices"
    refute result.summary =~ "last_seen_at"
    refute result.next_action =~ "source_health"
  end

  test "get_open_work_summary returns executive-ready summary when Gmail is missing" do
    user_id = "toolbox-open-work-copy-#{System.unique_integer()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "kind" => "general",
          "title" => "Send investor update",
          "summary" => "Investors need the short weekly update.",
          "next_action" => "Send the concise investor update.",
          "priority" => 91,
          "dedupe_key" => "toolbox-open-work-copy:investor-update"
        }
      ])

    assert {:ok, result} =
             Toolbox.execute(
               "get_open_work_summary",
               %{"limit" => 5},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert result.summary =~ "Open work: 1 work item."
    assert result.summary =~ "Start with Send the concise investor update."

    assert result.summary =~
             "Inbox-backed follow-up is not fully covered because Gmail is not connected."

    assert result.next_action == "Start with Send the concise investor update."

    refute result.summary =~ "Tell the user"
    refute result.summary =~ "Maraithon cannot currently inspect"
    refute result.summary =~ "gmail_search_messages"
  end

  test "list_connected_accounts returns connector status without CRM or todo writes" do
    user_id = "toolbox-connections-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "6114124042",
        metadata: %{
          "chat_id" => "6114124042",
          "username" => "kentfenwick",
          "token" => "secret-token"
        }
      })

    {:ok, _google} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "kent@example.com",
        scopes: ["gmail.readonly"]
      })

    {:ok, _slack} =
      ConnectedAccounts.upsert_manual(user_id, "slack:TSECRET123", %{
        external_account_id: "TSECRET123",
        metadata: %{"team_id" => "TSECRET123", "team_name" => "Executive Ops"}
      })

    assert {:ok, result} =
             Toolbox.execute(
               "list_connected_accounts",
               %{},
               %{user_id: user_id, context: %{}}
             )

    assert result.connected_count == 3
    assert result.status_counts == %{"connected" => 3}

    providers = Enum.map(result.connected_accounts, & &1.provider)
    assert "google" in providers
    assert "slack" in providers
    assert "telegram" in providers

    telegram = Enum.find(result.connected_accounts, &(&1.provider == "telegram"))
    assert telegram.account_label == "Telegram"
    refute Map.has_key?(telegram, :metadata)

    google = Enum.find(result.connected_accounts, &(&1.provider == "google"))
    assert google.account_label == "kent@example.com"
    refute Map.has_key?(google, :scopes)

    slack = Enum.find(result.connected_accounts, &(&1.provider == "slack"))
    assert slack.account_label == "Executive Ops"

    result_text = inspect(result)
    refute result_text =~ "external_account_id"
    refute result_text =~ "6114124042"
    refute result_text =~ "TSECRET123"
    refute result_text =~ "gmail.readonly"
    refute result_text =~ "oauth_scopes"

    assert Enum.any?(result.source_freshness, &(&1.provider == "telegram"))
    assert Enum.any?(result.built_in_resources, &(&1.resource == "todos"))
    assert Enum.any?(result.tool_coverage, &(&1.connector_id == "gmail"))
  end

  test "explain_action_ledger returns redacted why path and source freshness" do
    user_id = "toolbox-explain-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    {:ok, action} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "proactive.sent",
        status: "sent",
        source_evidence: %{"dedupe_key" => "why:123", "authorization" => "Bearer secret12345"},
        model_summary: "The todo was due today.",
        result_object_refs: %{"dedupe_key" => "why:123"}
      })

    assert {:ok, result} =
             Toolbox.execute(
               "explain_action_ledger",
               %{"action_id" => action.id},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert result.explanation.id == action.id
    assert result.explanation.model_summary == "The todo was due today."
    assert result.message =~ "The todo was due today."
    assert result.message =~ "Connected sources looked current for this check."
    assert [%{provider: "telegram", status: "fresh"}] = result.source_freshness
    assert result.explanation.source_evidence["authorization"] == "<redacted>"
    refute result.message =~ "No policy reason"
    refute result.message =~ "Policy reason"
    refute result.message =~ "freshness snapshot"
    refute result.message =~ "marked stale"
  end

  test "explain_action_ledger explains guardrails without raw reason codes" do
    user_id = "toolbox-explain-guardrail-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    {:ok, action} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "tool.needs_confirmation",
        status: "needs_confirmation",
        policy_decision: %{
          "status" => "needs_confirmation",
          "reason_code" => "confirmation_required",
          "message" => "Confirm this action before it runs."
        },
        model_summary: "Maraithon prepared a reply but did not send it."
      })

    assert {:ok, result} =
             Toolbox.execute(
               "explain_action_ledger",
               %{"action_id" => action.id},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert result.message =~ "Maraithon prepared a reply but did not send it."

    assert result.message =~
             "This stopped for your confirmation before anything was sent or changed."

    assert result.message =~ "Connected sources looked current for this check."
    refute result.message =~ "Policy reason"
    refute result.message =~ "confirmation_required"
  end

  test "explain_action_ledger fallback avoids internal ledger language" do
    user_id = "toolbox-explain-fallback-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{external_account_id: "12345"})

    {:ok, action} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "tool.executed",
        status: "completed"
      })

    assert {:ok, result} =
             Toolbox.execute(
               "explain_action_ledger",
               %{"action_id" => action.id},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert result.message =~ "That action is recorded, but it does not include a summary yet."
    refute result.message =~ "I found"
    refute result.message =~ "ledger"
    refute result.message =~ "model summary"
  end

  test "explain_action_ledger describes source health in user language" do
    user_id = "toolbox-explain-source-copy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _account} =
      ConnectedAccounts.upsert_manual(user_id, "google", %{
        external_account_id: "work@example.com",
        metadata: %{"last_successful_sync_at" => "2026-01-01T12:00:00Z"}
      })

    {:ok, action} =
      ActionLedger.record(%{
        user_id: user_id,
        surface: "telegram",
        event_type: "proactive.sent",
        status: "sent",
        model_summary: "The assistant found one item that needed attention."
      })

    assert {:ok, result} =
             Toolbox.execute(
               "explain_action_ledger",
               %{"action_id" => action.id},
               %{user_id: user_id, context: %{projects: []}}
             )

    assert [%{provider: "google", status: "stale"}] = result.source_freshness

    assert result.message =~
             "Source verification was incomplete before that action: work@example.com was out of date."

    refute result.message =~ "I could not"
    refute result.message =~ "Source health issues"
    refute result.message =~ "freshness snapshot"
    refute result.message =~ "stale"
  end

  test "prepare_external_action confirmation previews hide provider ids" do
    user_id = "toolbox-prepared-copy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(config,
        telegram_full_chat_enabled: true,
        telegram_assistant_write_tools_enabled: true
      )
    )

    runtime_context = toolbox_run_context(user_id)

    assert {:ok, slack} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "slack_post",
                 "payload" => %{
                   "channel" => "C012ABCD9",
                   "team_id" => "T012SECRET",
                   "text" => "Shipping the update."
                 }
               },
               runtime_context
             )

    assert slack.preview_text == "Post a Slack message to the selected Slack channel."
    assert slack.message =~ "Post a Slack message to the selected Slack channel."
    refute_prepared_preview_leaks(slack, ["C012ABCD9", "T012SECRET", "workspace T"])

    assert {:ok, linear} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "linear_update_issue_state",
                 "payload" => %{
                   "issue_id" => "lin-internal-issue-id",
                   "state_id" => "lin-internal-state-id"
                 }
               },
               runtime_context
             )

    assert linear.preview_text == "Move the selected Linear issue to the selected state."
    refute_prepared_preview_leaks(linear, ["lin-internal-issue-id", "lin-internal-state-id"])

    assert {:ok, notaui} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "notaui_complete_task",
                 "payload" => %{
                   "task_id" => "notaui-internal-task-id",
                   "task_title" => "Renew contractor NDA"
                 }
               },
               runtime_context
             )

    assert notaui.preview_text == "Complete Notaui task \"Renew contractor NDA\"."
    refute_prepared_preview_leaks(notaui, ["notaui-internal-task-id"])
  end

  test "prepare_external_action previews trim noisy labels and ignore id-like display values" do
    user_id = "toolbox-prepared-labels-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(config,
        telegram_full_chat_enabled: true,
        telegram_assistant_write_tools_enabled: true
      )
    )

    runtime_context = toolbox_run_context(user_id)

    long_subject =
      "Board packet revisions, investor-side questions, and operating review notes for next week"

    assert {:ok, gmail} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "gmail_send",
                 "payload" => %{
                   "to" => "ceo@example.com",
                   "subject" => long_subject
                 }
               },
               runtime_context
             )

    assert gmail.preview_text =~ "Send Gmail message to ceo@example.com with subject"
    assert gmail.preview_text =~ "..."
    refute gmail.preview_text =~ "for next week"
    assert String.length(gmail.preview_text) < 140

    assert {:ok, slack} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "slack_post",
                 "payload" => %{
                   "channel_name" => "C012ABCD9",
                   "workspace_name" => "T012SECRET",
                   "text" => "Shipping the update."
                 }
               },
               runtime_context
             )

    assert slack.preview_text == "Post a Slack message to the selected Slack channel."
    refute_prepared_preview_leaks(slack, ["C012ABCD9", "T012SECRET"])

    assert {:ok, linear} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "linear_update_issue_state",
                 "payload" => %{
                   "identifier" => "OPS-123",
                   "state_name" => "lin-internal-state-id"
                 }
               },
               runtime_context
             )

    assert linear.preview_text == "Move Linear issue OPS-123 to the selected state."
    refute_prepared_preview_leaks(linear, ["lin-internal-state-id"])
  end

  test "tool failures return product-safe copy instead of raw error codes" do
    user_id = "toolbox-safe-errors-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:error, linear_copy} =
             Toolbox.execute(
               "linear_list_or_lookup",
               %{"identifier" => "OPS-123"},
               %{user_id: user_id, context: %{}}
             )

    assert linear_copy =~ "Connect Linear before looking up issues"
    refute linear_copy =~ "linear_not_connected"

    assert {:error, agent_copy} =
             Toolbox.execute(
               "inspect_agent",
               %{"agent_id" => Ecto.UUID.generate()},
               %{user_id: user_id, context: %{}}
             )

    assert agent_copy == "That automation is no longer available. Refresh automations."
    refute agent_copy =~ "agent_not_found"
    refute String.contains?(String.downcase(agent_copy), "try again")

    assert {:error, action_copy} =
             Toolbox.execute(
               "prepare_external_action",
               %{
                 "action_type" => "slack_post",
                 "payload" => %{"channel" => "C012ABCD9", "text" => "Ship it."}
               },
               toolbox_run_context(user_id)
             )

    assert action_copy == "Action drafting is not enabled."
    refute action_copy =~ "write_tools_disabled"

    assert {:error, unknown_copy} =
             Toolbox.execute(
               "unknown_private_tool",
               %{},
               %{user_id: user_id, context: %{}}
             )

    assert unknown_copy ==
             "That action is not available. Refresh the message before asking again."

    refute unknown_copy =~ "unknown_private_tool"
    refute unknown_copy =~ "unknown_tool"
    refute unknown_copy =~ "assistant action"

    assert {:error, confirmation_copy} =
             Toolbox.execute(
               "gmail_drafts",
               %{"action" => "send", "draft_id" => "draft-123"},
               %{user_id: user_id, context: %{}}
             )

    assert confirmation_copy == "Confirm this action before it runs."
    refute confirmation_copy =~ "tool_policy"
  end

  test "prepare_agent_action uses automation copy in confirmations" do
    user_id = "toolbox-automation-copy-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(config,
        telegram_full_chat_enabled: true,
        telegram_agent_control_enabled: true
      )
    )

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "Kent's Gmail agent", "prompt" => "Track replies."}
      })

    {:ok, legacy_followthrough_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{}
      })

    runtime_context = toolbox_run_context(user_id)

    assert {:ok, delete} =
             Toolbox.execute(
               "prepare_agent_action",
               %{"action" => "delete", "agent_id" => agent.id},
               runtime_context
             )

    assert delete.preview_text ==
             "Delete the \"Kent's Gmail agent\" automation. " <>
               "This removes its saved setup and history."

    assert delete.message =~ "Reply `yes` or use the buttons to delete it"
    refute delete.preview_text =~ "runtime"
    refute delete.preview_text =~ "behavior"

    assert {:ok, legacy_delete} =
             Toolbox.execute(
               "prepare_agent_action",
               %{"action" => "delete", "agent_id" => legacy_followthrough_agent.id},
               runtime_context
             )

    assert legacy_delete.preview_text ==
             "Delete the \"Chief of Staff\" automation. " <>
               "This removes its saved setup and history."

    refute legacy_delete.preview_text =~ "Founder"
    refute legacy_delete.preview_text =~ "founder_followthrough_agent"

    assert {:ok, create} =
             Toolbox.execute(
               "prepare_agent_action",
               %{
                 "action" => "create",
                 "launch" => %{
                   "behavior" => "prompt_agent",
                   "name" => "Inbox Follow-Through",
                   "prompt" => "Track replies."
                 }
               },
               runtime_context
             )

    assert create.preview_text == "Create the \"Inbox Follow-Through\" automation."
    refute create.preview_text =~ "agent"
    refute create.preview_text =~ "prompt_agent"
  end

  test "todo tools can persist, search, and resolve durable work" do
    user_id = "toolbox-todos-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, persisted} =
             Toolbox.execute(
               "upsert_todos",
               %{
                 "todos" => [
                   gmail_todo("thread-billing", "Billing account past due", 98),
                   gmail_todo("thread-oauth", "OAuth verification reply owed", 92)
                 ]
               },
               runtime_context
             )

    assert persisted.count == 2
    assert persisted.enrichment == %{errors: [], memories: [], person_links: []}

    assert {:ok, open_loops} =
             Toolbox.execute(
               "get_open_loops",
               %{"query" => "billing", "limit" => 10},
               runtime_context
             )

    assert open_loops.source == "maraithon_open_loops"
    assert open_loops.totals.open_todos == 2

    assert {:ok, billing_search} =
             Toolbox.execute(
               "list_todos",
               %{
                 "query" => "billing",
                 "statuses" => ["open"],
                 "kind" => "gmail_triage"
               },
               runtime_context
             )

    assert billing_search.count == 1
    [billing_todo] = billing_search.todos
    assert billing_todo.title =~ "Billing"

    assert {:ok, updated} =
             Toolbox.execute(
               "update_todo",
               %{
                 "todo_id" => billing_todo.id,
                 "priority" => 88,
                 "next_action" => "Confirm the billing account is current."
               },
               runtime_context
             )

    assert updated.todo.priority == 88
    assert updated.todo.next_action == "Confirm the billing account is current."

    assert {:ok, resolved} =
             Toolbox.execute(
               "resolve_todo",
               %{
                 "todo_id" => billing_todo.id,
                 "status" => "done",
                 "resolution_note" => "Handled in billing console.",
                 "include_remaining" => true,
                 "kind" => "gmail_triage"
               },
               runtime_context
             )

    assert resolved.todo.status == "done"
    assert resolved.remaining_count == 1
    [remaining_todo] = resolved.remaining_todos
    assert remaining_todo.title =~ "OAuth"
    refute remaining_todo.title =~ "Billing"

    assert {:ok, deleted} =
             Toolbox.execute(
               "delete_todo",
               %{
                 "todo_id" => remaining_todo.id,
                 "resolution_note" => "No longer relevant.",
                 "include_remaining" => true,
                 "kind" => "gmail_triage"
               },
               runtime_context
             )

    assert deleted.deleted == true
    assert deleted.todo.status == "dismissed"
    assert deleted.remaining_count == 0
  end

  test "CRM tools can persist people and return relationship context" do
    user_id = "toolbox-people-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, persisted} =
             Toolbox.execute(
               "upsert_person",
               %{
                 "person" => %{
                   "first_name" => "Charlie",
                   "last_name" => "Jones",
                   "slack_id" => "UCHARLIE",
                   "preferred_communication_method" => "slack",
                   "relationship" => "Runner teammate",
                   "communication_frequency" => "weekly"
                 }
               },
               runtime_context
             )

    person = persisted.person
    assert person.display_name == "Charlie Jones"
    assert person.preferred_communication_method == "slack"

    assert {:ok, listed} =
             Toolbox.execute(
               "list_people",
               %{"query" => "Charlie"},
               runtime_context
             )

    assert listed.count == 1

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "slack",
          "title" => "Confirm launch plan with Charlie",
          "summary" => "Charlie needs a launch plan decision.",
          "next_action" => "Reply to Charlie in Slack.",
          "dedupe_key" => "toolbox-people:charlie-launch"
        }
      ])

    assert {:ok, _linked} =
             Toolbox.execute(
               "link_person_data",
               %{
                 "person_id" => person.id,
                 "todo_id" => todo.id,
                 "resource_source" => "slack"
               },
               runtime_context
             )

    assert {:ok, context_result} =
             Toolbox.execute(
               "get_relationship_context",
               %{"query" => "Charlie"},
               runtime_context
             )

    context = context_result.relationship_context
    assert context.person.id == person.id
    assert context.open_todo_count == 1
    assert [%{title: title}] = context.todos
    assert title =~ "Charlie"

    assert {:ok, duplicate} =
             Toolbox.execute(
               "upsert_person",
               %{
                 "person" => %{
                   "first_name" => "Charles",
                   "last_name" => "Jones",
                   "email" => "charles.jones@example.com",
                   "relationship" => "Duplicate CRM record for Charlie"
                 }
               },
               runtime_context
             )

    assert {:ok, merged} =
             Toolbox.execute(
               "merge_people",
               %{
                 "surviving_person_id" => person.id,
                 "merged_person_id" => duplicate.person.id,
                 "evidence" => "Same teammate and manually confirmed duplicate.",
                 "model_rationale" => "Kent asked to merge duplicate Charlie records.",
                 "performed_by" => "telegram_assistant_test"
               },
               runtime_context
             )

    assert merged.merge.surviving_person.id == person.id
    assert merged.merge.merged_person.merged_into_id == person.id
    assert is_binary(merged.merge.merge_audit_id)
  end

  test "briefing schedule tool updates morning briefings in the user's local timezone" do
    user_id = "toolbox-briefings-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, chief_of_staff_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 9,
          "end_of_day_brief_hour_local" => 18,
          "weekly_review_day_local" => 5,
          "weekly_review_hour_local" => 16
        }
      })

    {:ok, followthrough_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "founder_followthrough_agent",
        config: %{
          "name" => "Inbox Followthrough",
          "timezone_offset_hours" => -4,
          "morning_brief_hour_local" => 9,
          "end_of_day_brief_hour_local" => 18,
          "weekly_review_day_local" => 5,
          "weekly_review_hour_local" => 16
        }
      })

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, result} =
             Toolbox.execute(
               "update_briefing_schedule",
               %{"briefing_kind" => "morning", "local_hour" => 10},
               runtime_context
             )

    assert result.status == "updated"
    assert result.local_time == "10:00"
    assert result.display_time_local == "10:00 AM"
    assert result.local_timezone == "UTC-04:00"
    assert result.updated_agent_count == 2
    assert result.current_schedule.morning.hour_local == 10
    assert result.current_schedule.morning.display_time_local == "10:00 AM"

    assert Agents.get_agent!(chief_of_staff_agent.id).config["morning_brief_hour_local"] == 10
    assert Agents.get_agent!(followthrough_agent.id).config["morning_brief_hour_local"] == 10
  end

  test "briefing schedule tool preserves a named timezone from chat" do
    user_id = "toolbox-briefing-zone-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, chief_of_staff_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "timezone_offset_hours" => -5,
          "morning_brief_hour_local" => 9
        }
      })

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, result} =
             Toolbox.execute(
               "update_briefing_schedule",
               %{
                 "briefing_kind" => "morning",
                 "local_hour" => 10,
                 "timezone" => "America/Toronto"
               },
               runtime_context
             )

    updated = Agents.get_agent!(chief_of_staff_agent.id)

    assert result.status == "updated"
    assert result.display_time_local == "10:00 AM"
    assert result.local_timezone == "ET"
    assert result.timezone_name == "America/Toronto"
    assert result.timezone_offset_hours in [-5, -4]
    assert updated.config["timezone"] == "America/Toronto"
    assert updated.config["timezone_name"] == "America/Toronto"
    assert updated.config["timezone_offset_hours"] == -5
    assert updated.config["morning_brief_hour_local"] == 10
  end

  test "project scope tool can update the linked project from reply context" do
    user_id = "toolbox-project-scope-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, project} =
      Projects.create_project(user_id, %{
        "name" => "Garage Renovation",
        "summary" => "Shelving and paint at home."
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "telegram",
          "kind" => "general",
          "title" => "Buy shelves for the garage",
          "summary" => "Need to finish the garage shelving.",
          "next_action" => "Order the remaining shelves.",
          "priority" => 72,
          "dedupe_key" => "project-scope:garage:shelves",
          "metadata" => %{
            "suggested_project_id" => project.id,
            "suggested_project_name" => project.name,
            "suggested_life_domain" => "home"
          }
        }
      ])

    runtime_context = %{
      user_id: user_id,
      context: %{
        linked_item: %{
          project: %{
            id: project.id,
            name: project.name,
            slug: project.slug
          }
        }
      }
    }

    assert {:ok, result} =
             Toolbox.execute(
               "update_project_scope",
               %{
                 "life_domain" => "home",
                 "confidence" => 0.93,
                 "reasoning" => "This is a household renovation project."
               },
               runtime_context
             )

    assert result.status == "updated"
    assert result.life_domain == "home"
    assert result.project.id == project.id
    assert result.aligned_todo_count == 1

    refreshed = Projects.get_project_for_user(project.id, user_id)
    assert refreshed.metadata["life_domain"] == "home"
    assert refreshed.metadata["life_domain_reasoning"] =~ "household renovation"

    refreshed_todo = Todos.get_for_user(user_id, todo.id)
    assert refreshed_todo.metadata["suggested_life_domain"] == "home"
    assert refreshed_todo.metadata["scope_source"] == "project_scope_confirmation"
  end

  test "preference tools can remember, inspect, and forget durable operator memory" do
    user_id = "toolbox-preferences-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, remembered} =
             Toolbox.execute(
               "remember_preferences",
               %{
                 "rules" => [
                   %{
                     "id" => "ignore_receipts",
                     "kind" => "content_filter",
                     "label" => "Ignore routine receipts",
                     "instruction" =>
                       "Downrank routine receipt and transactional confirmation emails unless they imply unresolved follow-up work.",
                     "applies_to" => ["gmail", "telegram"],
                     "confidence" => 0.96,
                     "filters" => %{"topics" => ["receipts", "transactional_receipts"]},
                     "evidence" => ["The user called receipts noise."]
                   }
                 ]
               },
               runtime_context
             )

    assert remembered.status == "saved"
    assert remembered.saved_count == 1
    assert remembered.durable_saved_count == 1
    assert remembered.active_saved_count == 1
    assert remembered.pending_saved_count == 0
    assert remembered.requires_confirmation == false

    assert remembered.message ==
             "Preference saved: Ignore routine receipts. Maraithon will apply it when ranking future work."

    assert remembered.active_count == 1
    assert Enum.any?(remembered.active_rules, &(&1["id"] == "ignore_receipts"))
    assert Enum.any?(PreferenceMemory.active_rules(user_id), &(&1["id"] == "ignore_receipts"))

    assert {:ok, listed} = Toolbox.execute("list_preferences", %{}, runtime_context)
    assert listed.active_count == 1
    assert listed.pending_count == 0
    assert Enum.any?(listed.active_rules, &(&1["label"] == "Ignore routine receipts"))
    assert is_list(listed.operator_memory)
    assert is_map(listed.user_memory)

    assert {:ok, forgotten} =
             Toolbox.execute(
               "forget_preference",
               %{"rule_id" => "ignore_receipts"},
               runtime_context
             )

    assert forgotten.status == "forgotten"
    assert forgotten.active_count == 0
    assert forgotten.pending_count == 0
    assert forgotten.message =~ "Removed preference"
    assert PreferenceMemory.active_rules(user_id) == []
  end

  test "remember_preferences does not claim low confidence rules were saved" do
    user_id = "toolbox-preference-rejected-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    runtime_context = %{user_id: user_id, context: %{projects: []}}

    assert {:ok, remembered} =
             Toolbox.execute(
               "remember_preferences",
               %{
                 "rules" => [
                   %{
                     "id" => "maybe_ignore_updates",
                     "kind" => "content_filter",
                     "label" => "Maybe ignore updates",
                     "instruction" => "Maybe downrank vague project updates.",
                     "applies_to" => ["gmail", "telegram"],
                     "confidence" => 0.42,
                     "filters" => %{"topics" => ["updates"]},
                     "evidence" => ["The signal was ambiguous."]
                   }
                 ]
               },
               runtime_context
             )

    assert remembered.status == "not_saved"
    assert remembered.saved_count == 1
    assert remembered.durable_saved_count == 0
    assert remembered.active_saved_count == 0
    assert remembered.pending_saved_count == 0
    assert remembered.requires_confirmation == false
    assert [%{"status" => "rejected"}] = remembered.saved_rules

    assert remembered.message ==
             "Could not turn that into a clear standing preference yet. Send /prefer with the rule you want remembered."

    assert PreferenceMemory.active_rules(user_id) == []
    assert PreferenceMemory.pending_rules(user_id) == []
  end

  test "deep memory tools write, recall, record feedback, list, and forget memories" do
    user_id = "toolbox-memory-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    runtime_context = %{user_id: user_id, context: %{}}

    assert {:ok, written} =
             Toolbox.execute(
               "write_memory",
               %{
                 "memory" => %{
                   "kind" => "preference",
                   "title" => "School notices matter",
                   "content" =>
                     "School notices are relevant when they mention pickup, forms, or schedule changes.",
                   "tags" => ["school", "relevance"],
                   "importance" => 85
                 }
               },
               runtime_context
             )

    assert written.memory.title == "School notices matter"

    assert {:ok, recalled} =
             Toolbox.execute(
               "recall_memory",
               %{"query" => "school pickup", "limit" => 5},
               runtime_context
             )

    assert recalled.count == 1
    assert hd(recalled.memories).id == written.memory.id

    assert {:ok, feedback} =
             Toolbox.execute(
               "record_memory_feedback",
               %{
                 "subject" => "Generic VC newsletter",
                 "feedback" => "not_relevant",
                 "reason" => "No concrete Runner or customer implication."
               },
               runtime_context
             )

    assert feedback.memory.kind == "relevance_feedback"
    assert feedback.memory.polarity == "negative"

    assert {:ok, confidence} =
             Toolbox.execute(
               "update_memory_confidence",
               %{
                 "memory_id" => written.memory.id,
                 "confidence" => 0.51,
                 "reason" => "Only applies to school notices with logistics."
               },
               runtime_context
             )

    assert confidence.memory.confidence == 0.51

    assert {:ok, listed} = Toolbox.execute("list_memories", %{}, runtime_context)
    assert listed.count == 2

    assert {:ok, forgotten} =
             Toolbox.execute(
               "forget_memory",
               %{"memory_id" => written.memory.id},
               runtime_context
             )

    assert forgotten.forgotten == true
    assert forgotten.memory.status == "archived"
  end

  test "project delivery tools can accept a recommendation, grant access, and start a run" do
    user_id = "toolbox-projects-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    Application.put_env(:maraithon, Maraithon.Projects,
      delivery_launcher: fn _project, _recommendation, _decision, _agent ->
        {:ok,
         %{
           status: "pending_plan",
           result_summary: "Queued with the project repo planner.",
           metadata: %{"launcher" => "stub"}
         }}
      end
    )

    {:ok, project} =
      Projects.create_project(user_id, %{
        "name" => "Maraithon Product",
        "summary" => "Delivery loop"
      })

    {:ok, _repo_planner} =
      Agents.create_agent(%{
        user_id: user_id,
        project_id: project.id,
        behavior: "repo_planner",
        config: %{"name" => "Project Builder", "codebase_path" => File.cwd!()}
      })

    {:ok, planner_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        project_id: project.id,
        behavior: "github_product_planner",
        config: %{"name" => "PM", "repo_full_name" => "kent/bliss/maraithon"}
      })

    {:ok, [recommendation]} =
      Insights.record_many(user_id, planner_agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Delivery loop",
          "summary" => "Make accepted project work durable.",
          "recommended_action" => "Track repo grants and implementation runs.",
          "priority" => 96,
          "confidence" => 0.92,
          "dedupe_key" => "toolbox-project-delivery:1",
          "metadata" => %{"repo_full_name" => "kent/bliss/maraithon"}
        }
      ])

    runtime_context = %{
      user_id: user_id,
      default_project_id: project.id,
      context: %{projects: []}
    }

    assert {:ok, decision_result} =
             Toolbox.execute(
               "decide_project_recommendation",
               %{
                 "project_id" => project.id,
                 "recommendation_id" => recommendation.id,
                 "decision" => "accepted"
               },
               runtime_context
             )

    assert decision_result.decision.decision == "accepted"

    assert {:ok, grant_result} =
             Toolbox.execute(
               "grant_project_repo_access",
               %{
                 "project_id" => project.id,
                 "repo_full_name" => "kent/bliss/maraithon",
                 "scope" => "read_only"
               },
               runtime_context
             )

    assert grant_result.repo_grant.scope == "read_only"

    assert {:ok, run_result} =
             Toolbox.execute(
               "start_implementation_run",
               %{"project_id" => project.id, "recommendation_id" => recommendation.id},
               runtime_context
             )

    assert run_result.implementation_run.status == "pending_plan"
    assert run_result.message =~ "Queued with the project repo planner."

    assert {:ok, updated_run_result} =
             Toolbox.execute(
               "update_implementation_run",
               %{
                 "implementation_run_id" => run_result.implementation_run.id,
                 "status" => "awaiting_review",
                 "branch_name" => "feature/delivery-loop",
                 "pull_request_url" => "https://github.com/kent/bliss/maraithon/pull/44",
                 "result_summary" => "PR is ready for review."
               },
               runtime_context
             )

    assert updated_run_result.implementation_run.status == "awaiting_review"
    assert updated_run_result.implementation_run.branch_name == "feature/delivery-loop"
    assert updated_run_result.implementation_run.pull_request_url =~ "/pull/44"
  end

  defp gmail_todo(thread_id, title, priority) do
    %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This Gmail thread still needs a reply.",
      "next_action" => "Reply in-thread and close the loop.",
      "priority" => priority,
      "source_item_id" => thread_id,
      "source_occurred_at" => "2026-04-02T04:19:00Z",
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{
        "thread_id" => thread_id,
        "subject" => title,
        "from" => "ops@example.com",
        "google_account_email" => "kent@voteagora.com"
      }
    }
  end

  defp toolbox_run_context(user_id) do
    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, "12345", %{
        "root_message_id" => "toolbox-prepared-copy-root"
      })

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        conversation_id: conversation.id,
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "running",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{},
        started_at: DateTime.utc_now()
      })

    %{
      user_id: user_id,
      chat_id: conversation.chat_id,
      conversation_id: conversation.id,
      run_id: run.id,
      surface: "telegram",
      context: %{}
    }
  end

  defp refute_prepared_preview_leaks(result, forbidden_fragments) do
    prepared_action = Repo.get!(PreparedAction, result.prepared_action_id)

    for text <- [result.preview_text, result.message, prepared_action.preview_text],
        fragment <- forbidden_fragments do
      refute text =~ fragment
    end
  end
end
