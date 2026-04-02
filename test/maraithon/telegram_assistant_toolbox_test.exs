defmodule Maraithon.TelegramAssistantToolboxTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.PreferenceMemory
  alias Maraithon.TelegramAssistant.Toolbox

  setup do
    original_gmail = Application.get_env(:maraithon, :gmail, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :gmail, original_gmail)
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
             "Use gmail_search_messages"
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
    assert remembered.requires_confirmation == false
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
end
