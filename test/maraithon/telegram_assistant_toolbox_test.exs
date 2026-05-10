defmodule Maraithon.TelegramAssistantToolboxTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ActionLedger
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Insights
  alias Maraithon.OAuth
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.TelegramAssistant.Toolbox
  alias Maraithon.Todos

  setup do
    original_gmail = Application.get_env(:maraithon, :gmail, [])
    original_projects = Application.get_env(:maraithon, Maraithon.Projects, [])

    on_exit(fn ->
      Application.put_env(:maraithon, :gmail, original_gmail)
      Application.put_env(:maraithon, Maraithon.Projects, original_projects)
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
    assert [%{provider: "telegram", status: "fresh"}] = result.source_freshness
    assert result.explanation.source_evidence["authorization"] == "<redacted>"
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
end
