defmodule Maraithon.TelegramAssistantTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.Briefs
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
  alias Maraithon.PreferenceMemory
  alias Maraithon.Projects
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant.{PreparedAction, PushReceipt, Run, Step}
  alias Maraithon.TelegramConversations.{Conversation, Turn}
  alias Maraithon.Todos
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.TestSupport.TelegramAssistantClientStub
  alias Maraithon.UserMemory.Profile

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    if Process.whereis(:capturing_telegram_watcher) == nil do
      Process.register(self(), :capturing_telegram_watcher)
    end

    original_insights = Application.get_env(:maraithon, :insights, [])
    original_briefs = Application.get_env(:maraithon, :briefs, [])
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_capturing = Application.get_env(:maraithon, :capturing_telegram, [])
    original_user_memory = Application.get_env(:maraithon, :user_memory, [])
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights,
        telegram_module: CapturingTelegram,
        default_sender_name: "Kent"
      )
    )

    Application.put_env(
      :maraithon,
      :briefs,
      Keyword.merge(original_briefs, telegram_module: CapturingTelegram)
    )

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_unified_push_enabled: true,
        telegram_liveness_enabled: true,
        proactive_delivery_planner_enabled: false,
        typing_initial_delay_ms: 10_000,
        typing_refresh_ms: 4_000,
        contextual_progress_delay_ms: 20_000,
        timeout_notice_ms: 35_000,
        hard_timeout_ms: 40_000,
        client_module: TelegramAssistantClientStub
      )
    )

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime,
        llm_provider: Maraithon.TestSupport.ActionDraftLLM,
        llm_provider_name: "test-action-draft",
        llm_model: "test-action-draft",
        llm_intelligence: "medium"
      )
    )

    Application.put_env(:maraithon, :capturing_telegram, original_capturing)

    assert Maraithon.TelegramAssistant.enabled?()
    assert Maraithon.TelegramAssistant.unified_push_enabled?()

    on_exit(fn ->
      Application.put_env(:maraithon, :insights, original_insights)
      Application.put_env(:maraithon, :briefs, original_briefs)
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :capturing_telegram, original_capturing)
      Application.put_env(:maraithon, :user_memory, original_user_memory)
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    user_id = "telegram-assistant@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => "Kent's Gmail agent", "prompt" => "Do things"}
      })

    {:ok, _telegram} =
      ConnectedAccounts.upsert_manual(user_id, "telegram", %{
        external_account_id: "12345",
        metadata: %{"username" => "kent"}
      })

    %{user_id: user_id, agent: agent}
  end

  test "router uses the assistant tool loop and persists the run audit", %{
    user_id: user_id,
    agent: agent
  } do
    Application.put_env(:maraithon, :user_memory,
      llm_complete: fn _prompt ->
        {:ok,
         Jason.encode!(%{
           "summary" => "Operate as a concise inbox chief of staff for this user.",
           "profile" => %{
             "working_style" => "Prefer concrete next steps.",
             "communication_style" => "Keep updates short.",
             "decision_style" => "Bias toward execution.",
             "current_focus" => "Inbox accountability.",
             "important_context" => "Telegram is an active control surface."
           },
           "confidence" => 0.91
         })}
      end
    )

    {:ok, [_insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send the deck to Sarah",
          "summary" => "You still owe Sarah the deck in Gmail.",
          "recommended_action" => "Reply in the thread with the deck.",
          "priority" => 96,
          "confidence" => 0.93,
          "dedupe_key" => "telegram-assistant:open-work:1",
          "metadata" => %{"account" => "kent@example.com"}
        }
      ])

    start_supervised!(%{
      id: :telegram_assistant_sequence,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        assert Enum.any?(payload.tools, &(&1["name"] == "get_open_loops"))
        assert payload.runtime_policy.loop.max_llm_turns == 6
        assert payload.runtime_policy.tool_calls.max_per_step == 3

        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_loops", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need a fresh work summary."
         }}
      else
        [history_entry] = payload.tool_history
        assert history_entry["tool"] == "get_open_loops"

        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "Right now you owe Sarah the deck in Gmail. That is the highest-priority open loop I can see.",
           "message_class" => "assistant_reply",
           "tool_calls" => [],
           "summary" => "Returned the summarized open work."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9101, text: "What do I owe today?"}
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "owe Sarah the deck"

    run =
      Repo.one!(
        from run in Run,
          where: run.user_id == ^user_id,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert run.status == "completed"
    assert run.trigger_type == "inbound_message"
    assert is_map(run.prompt_snapshot["open_loops"] || run.prompt_snapshot[:open_loops])
    assert is_map(run.prompt_snapshot["user_memory"] || run.prompt_snapshot[:user_memory])

    steps =
      Step
      |> where([step], step.run_id == ^run.id)
      |> order_by([step], asc: step.sequence)
      |> Repo.all()

    assert Enum.any?(steps, &(&1.step_type == "context_fetch"))
    assert Enum.any?(steps, &(&1.step_type == "tool_call"))
    assert Enum.any?(steps, &(&1.step_type == "llm_response"))

    turn =
      Repo.one!(
        from turn in Turn,
          join: conversation in assoc(turn, :conversation),
          where: conversation.user_id == ^user_id and turn.turn_kind == "assistant_reply",
          order_by: [desc: turn.inserted_at],
          limit: 1
      )

    assert turn.text =~ "Sarah"
    refute Enum.any?(telegram_events(), &(&1.type == :chat_action))

    assert %Profile{} = Repo.get_by(Profile, user_id: user_id)
  end

  test "assistant can learn a durable preference and confirm it with plain text", %{
    user_id: user_id
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_preferences,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_preferences]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_preferences, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        assert Enum.any?(payload.tools, &(&1["name"] == "remember_preferences"))

        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{
               "tool" => "remember_preferences",
               "arguments" => %{
                 "rules" => [
                   %{
                     "id" => "investors_are_urgent",
                     "kind" => "urgency_boost",
                     "label" => "Treat investors as urgent",
                     "instruction" =>
                       "Treat investor-related loops as urgent across Gmail, Calendar, Slack, and Telegram.",
                     "applies_to" => ["gmail", "calendar", "slack", "telegram"],
                     "confidence" => 0.79,
                     "filters" => %{"topics" => ["investor"], "priority_bias" => "high"},
                     "evidence" => ["The user asked to treat investor threads as urgent."]
                   }
                 ]
               }
             }
           ],
           "summary" => "Persist a durable urgency rule."
         }}
      else
        [history_entry] = payload.tool_history
        assert history_entry["tool"] == "remember_preferences"
        assert get_in(history_entry, ["result", "status"]) == "awaiting_confirmation"

        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "I think this should become durable memory. Reply `yes` to remember it it, or `no` to keep it local only.",
           "message_class" => "approval_prompt",
           "tool_calls" => [],
           "summary" => "Ask for confirmation."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 91011,
          text: "Anything from investors like this should be urgent."
        }
      })

    assert [%{"id" => "investors_are_urgent", "status" => "pending_confirmation"}] =
             PreferenceMemory.pending_rules(user_id)

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.status == "awaiting_confirmation"
    assert conversation.metadata["pending_rule_ids"] != []

    prompt_reply = last_telegram_message(:send)
    assert prompt_reply.opts[:parse_mode] == "HTML"
    assert prompt_reply.text =~ "Remember this for future triage?"
    assert prompt_reply.text =~ "Treat investors as urgent"
    assert prompt_reply.text =~ "Reply <code>yes</code>"
    refute prompt_reply.text =~ "I think"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 91012, text: "Yes"}
      })

    assert [%{"id" => "investors_are_urgent", "status" => "active"}] =
             PreferenceMemory.active_rules(user_id)

    assert PreferenceMemory.pending_rules(user_id) == []
    assert Repo.get!(Conversation, conversation.id).status == "closed"

    confirmation_reply = last_telegram_message(:send)
    assert confirmation_reply.text =~ "Preference saved: Treat investors as urgent."
    assert confirmation_reply.text =~ "Maraithon will apply it when ranking future work."
    refute confirmation_reply.text =~ "saved that as a durable rule"
  end

  test "assistant prepares a destructive agent action and executes it after text confirmation", %{
    user_id: user_id,
    agent: agent
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_delete,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_delete]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_delete, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{
               "tool" => "prepare_agent_action",
               "arguments" => %{"action" => "delete", "agent_id" => agent.id}
             }
           ],
           "summary" => "Prepare deletion."
         }}
      else
        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "Delete the \"Kent's Gmail agent\" automation. This removes its saved setup and history. Reply `yes` or use the buttons to delete it, or `no` to cancel.",
           "message_class" => "approval_prompt",
           "tool_calls" => [],
           "summary" => "Ask for confirmation."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9102, text: "Delete Kent's Gmail agent"}
      })

    approval = last_telegram_message(:send)
    assert approval.text =~ "Delete the \"Kent's Gmail agent\" automation"
    refute approval.text =~ "runtime history"

    prepared_action =
      Repo.one!(
        from prepared_action in PreparedAction,
          where: prepared_action.user_id == ^user_id,
          order_by: [desc: prepared_action.inserted_at],
          limit: 1
      )

    assert prepared_action.status == "awaiting_confirmation"
    assert prepared_action.action_type == "agent_delete"

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert conversation.status == "awaiting_confirmation"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9103, text: "yes"}
      })

    assert Agents.get_agent(agent.id) == nil
    assert Repo.get!(PreparedAction, prepared_action.id).status == "executed"

    result_message = last_telegram_message(:send)
    assert result_message.text == "Deleted the agent."
  end

  test "assistant updates morning briefing time from natural language without a command", %{
    user_id: user_id
  } do
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

    start_supervised!(%{
      id: :telegram_assistant_sequence_briefing_update,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_briefing_update]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_briefing_update, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          assert get_in(payload.context, [:briefing_schedule, :configured]) == true
          assert get_in(payload.context, [:briefing_schedule, :morning, :hour_local]) == 9
          assert get_in(payload.context, [:briefing_schedule, :local_timezone]) == "UTC-04:00"

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "update_briefing_schedule",
                 "arguments" => %{"briefing_kind" => "morning", "local_hour" => 10}
               }
             ],
             "summary" => "Update the morning briefing schedule."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "update_briefing_schedule"
          assert history_entry["result"]["display_time_local"] == "10:00 AM"
          assert history_entry["result"]["local_timezone"] == "UTC-04:00"

          {:ok,
           %{
             "status" => "final",
             "assistant_message" =>
               "Morning briefings now go out at 10:00 AM local time (UTC-04:00).",
             "message_class" => "assistant_reply",
             "tool_calls" => [],
             "summary" => "Confirmed the updated briefing schedule."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9104,
          text: "Can you send my morning briefings at 10 instead of 9?"
        }
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "10:00 AM local time"
    assert reply.text =~ "UTC-04:00"

    assert Agents.get_agent!(chief_of_staff_agent.id).config["morning_brief_hour_local"] == 10
  end

  test "assistant can prepare and create a project through conversational confirmation", %{
    user_id: user_id
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_project_create,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_project_create]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_project_create, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{
               "tool" => "prepare_project_action",
               "arguments" => %{
                 "action" => "create",
                 "attrs" => %{
                   "name" => "Maraithon Product",
                   "summary" => "Core product work and operator follow-through."
                 }
               }
             }
           ],
           "summary" => "Prepare project creation."
         }}
      else
        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "Create project Maraithon Product. Reply `yes` or use the buttons to create it, or `no` to cancel.",
           "message_class" => "approval_prompt",
           "tool_calls" => [],
           "summary" => "Ask for project confirmation."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9104, text: "Create a project for Maraithon Product"}
      })

    approval = last_telegram_message(:send)
    assert approval.text =~ "Create project Maraithon Product"

    prepared_action =
      Repo.one!(
        from prepared_action in PreparedAction,
          where: prepared_action.user_id == ^user_id,
          order_by: [desc: prepared_action.inserted_at],
          limit: 1
      )

    assert prepared_action.status == "awaiting_confirmation"
    assert prepared_action.action_type == "project_create"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9105, text: "yes"}
      })

    project = Projects.get_project_by_slug_for_user("maraithon-product", user_id)
    assert project.name == "Maraithon Product"
    assert project.summary =~ "Core product work"
    assert Repo.get!(PreparedAction, prepared_action.id).status == "executed"

    result_message = last_telegram_message(:send)
    assert result_message.text == "Created the project."
  end

  test "prepared action failure copy hides internal reason in Telegram", %{user_id: user_id} do
    {:ok, conversation} =
      Maraithon.TelegramConversations.start_or_continue(user_id, "12345", %{
        "root_message_id" => "9301"
      })

    {:ok, run} =
      Maraithon.TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        conversation_id: conversation.id,
        surface: "telegram",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{"message_class" => "approval_prompt"},
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    missing_project_id = Ecto.UUID.generate()

    {:ok, prepared_action} =
      Maraithon.TelegramAssistant.create_prepared_action(%{
        user_id: user_id,
        chat_id: conversation.chat_id,
        conversation_id: conversation.id,
        run_id: run.id,
        surface: "telegram",
        action_type: "project_update",
        target_type: "project",
        target_id: missing_project_id,
        payload: %{
          "project_id" => missing_project_id,
          "attrs" => %{"summary" => "Should not apply"}
        },
        preview_text: "Update project",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          "chat_id" => 12345,
          "message_id" => 9301,
          "callback_id" => "project-update-failure-callback",
          "data" => "tgact:#{prepared_action.id}:confirm"
        }
      })

    result_message = last_telegram_message(:send)

    assert result_message.text ==
             "I could not complete the project update yet. " <>
               "The project it referenced is no longer available."

    refute result_message.text =~ ":project_not_found"
    refute result_message.text =~ "project_not_found"
    assert Repo.get!(PreparedAction, prepared_action.id).status == "failed"
  end

  test "assistant can inspect a project by name and return project-manager recommendations", %{
    user_id: user_id
  } do
    {:ok, project} =
      Projects.create_project(user_id, %{
        "name" => "Maraithon Product",
        "summary" => "Roadmap and operator UX"
      })

    {:ok, planner_agent} =
      Agents.create_agent(%{
        user_id: user_id,
        project_id: project.id,
        behavior: "github_product_planner",
        config: %{"name" => "Maraithon PM", "repo_full_name" => "kent/bliss/maraithon"}
      })

    {:ok, _item} =
      Projects.create_project_item(project, %{
        "item_type" => "grant",
        "title" => "Repo scope",
        "content" => "Project manager can inspect kent/bliss/maraithon."
      })

    {:ok, _insights} =
      Insights.record_many(user_id, planner_agent.id, [
        %{
          "source" => "github",
          "category" => "product_opportunity",
          "title" => "Project workspace",
          "summary" => "Ship a real project dashboard with local memory and agent attachment.",
          "recommended_action" => "Start with projects on the dashboard.",
          "priority" => 97,
          "confidence" => 0.92,
          "dedupe_key" => "telegram-assistant:project-inspection:1",
          "metadata" => %{"why_now" => "The app needs a first-class project surface."}
        }
      ])

    start_supervised!(%{
      id: :telegram_assistant_sequence_project_inspect,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_project_inspect]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_project_inspect, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        assert Enum.any?(payload.tools, &(&1["name"] == "inspect_project"))

        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{
               "tool" => "inspect_project",
               "arguments" => %{"project_name" => "Maraithon Product"}
             }
           ],
           "summary" => "Need the project recommendation context."
         }}
      else
        [history_entry] = payload.tool_history
        assert history_entry["tool"] == "inspect_project"

        {:ok,
         %{
           "status" => "final",
           "assistant_message" =>
             "For Maraithon Product, the top next feature is Project workspace. The project manager recommends starting with projects on the dashboard.",
           "message_class" => "assistant_reply",
           "tool_calls" => [],
           "summary" => "Returned the project recommendation."
         }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9106,
          text: "What feature should I work on next for Maraithon Product?"
        }
      })

    reply = last_telegram_message(:send)
    assert reply.text =~ "Project workspace"
    assert reply.text =~ "projects on the dashboard"
  end

  test "assistant can persist inbox work as todos and resolve one conversationally", %{
    user_id: user_id
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_todos,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_todos]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_todos, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "upsert_todos",
                 "arguments" => %{
                   "todos" => [
                     gmail_todo_payload("thread-billing", "Billing account past due", 98),
                     gmail_todo_payload("thread-oauth", "OAuth verification reply owed", 92)
                   ]
                 }
               }
             ],
             "summary" => "Persisted today's actionable inbox work as todos."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "upsert_todos"
          assert Enum.count(history_entry["result"]["todos"]) == 2

          {:ok,
           %{
             "status" => "final",
             "assistant_message" =>
               "I refreshed today's inbox triage. I'm sending the actionable items one by one.",
             "message_class" => "todo_digest",
             "tool_calls" => [],
             "summary" => "Returned the persisted todo list as itemized Telegram todos."
           }}

        2 ->
          assert Enum.count(payload.context.todos) == 2
          assert payload.context.linked_item.todo.title == "Billing account past due"

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "resolve_todo",
                 "arguments" => %{
                   "todo_id" => payload.context.linked_item.todo.id,
                   "status" => "done",
                   "resolution_note" => "Handled by the user.",
                   "include_remaining" => true,
                   "kind" => "gmail_triage"
                 }
               }
             ],
             "summary" => "Resolved the billing todo and fetched the remaining work."
           }}

        3 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "resolve_todo"
          assert history_entry["result"]["remaining_count"] == 1

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Billing is closed. Here's what is still open.",
             "message_class" => "todo_digest",
             "tool_calls" => [],
             "summary" => "Returned the remaining todo as itemized Telegram output."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9107, text: "What are the emails to triage today?"}
      })

    initial_sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert Enum.count(initial_sends) == 3
    assert Enum.at(initial_sends, 0).text =~ "Each item is ready for a decision"
    refute Enum.at(initial_sends, 0).text =~ "ready to clear"
    refute Enum.at(initial_sends, 0).text =~ "sending the actionable items one by one"

    billing_message = Enum.at(initial_sends, 1)
    oauth_message = Enum.at(initial_sends, 2)
    assert billing_message
    assert oauth_message
    assert billing_message.text =~ "Reply in-thread and close the loop."
    assert billing_message.text =~ "This thread still needs a reply from you."
    refute billing_message.text =~ "Billing account past due"
    refute billing_message.text =~ "Maraithon Todo"
    refute billing_message.text =~ "About:"
    assert oauth_message.text =~ "Reply in-thread and close the loop."
    refute oauth_message.text =~ "OAuth verification reply owed"
    refute oauth_message.text =~ "Maraithon Todo"
    refute oauth_message.text =~ "About:"
    assert get_in(Keyword.get(billing_message.opts, :reply_markup), ["inline_keyboard"]) != nil
    assert get_in(Keyword.get(oauth_message.opts, :reply_markup), ["inline_keyboard"]) != nil

    open_todos = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert Enum.count(open_todos) == 2

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9108,
          text: "Handled this, what else?",
          reply_to: %{message_id: billing_message.message_id}
        }
      })

    sends_after_resolution =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert Enum.count(sends_after_resolution) == 5
    assert Enum.at(sends_after_resolution, 3).text =~ "Billing is closed"
    assert List.last(sends_after_resolution).text =~ "Reply in-thread and close the loop."
    refute List.last(sends_after_resolution).text =~ "OAuth verification reply owed"
    refute List.last(sends_after_resolution).text =~ "Billing account past due"

    [remaining_todo] = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert remaining_todo.title =~ "OAuth verification"
  end

  test "assistant can keep a manual todo list and return it as individual todo cards", %{
    user_id: user_id
  } do
    start_supervised!(%{
      id: :telegram_assistant_sequence_manual_todos,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_manual_todos]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_manual_todos, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          assert Enum.any?(payload.tools, &(&1["name"] == "upsert_todos"))

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "upsert_todos",
                 "arguments" => %{
                   "todos" => [
                     %{
                       "source" => "telegram",
                       "kind" => "general",
                       "attention_mode" => "act_now",
                       "title" => "Renew the domain this week",
                       "summary" => "The user wants this tracked as an ongoing todo.",
                       "next_action" => "Renew the domain and confirm it is done.",
                       "priority" => 76,
                       "metadata" => %{
                         "captured_from" => "telegram_message",
                         "request_text" => "Add renew the domain this week to my todo list."
                       }
                     }
                   ]
                 }
               }
             ],
             "summary" => "Persisted a manual todo from the conversation."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "upsert_todos"

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Added that to your todo list.",
             "message_class" => "action_result",
             "tool_calls" => [],
             "summary" => "Confirmed the manual todo was saved."
           }}

        2 ->
          assert Enum.any?(payload.tools, &(&1["name"] == "list_todos"))

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "list_todos",
                 "arguments" => %{
                   "statuses" => ["open"],
                   "limit" => 20
                 }
               }
             ],
             "summary" => "Loaded the full open todo list."
           }}

        3 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "list_todos"
          assert history_entry["result"]["count"] == 1

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Here is the full open todo list.",
             "message_class" => "todo_digest",
             "tool_calls" => [],
             "summary" => "Returned the open todo list as itemized todo cards."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9110,
          text: "Add renew the domain this week to my todo list."
        }
      })

    assert last_telegram_message(:send).text =~ "Added that to your open work"

    [saved_todo] = Todos.list_open_for_user(user_id, kind: "general")
    assert saved_todo.title == "Renew the domain this week"
    assert saved_todo.source == "telegram"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9111, text: "What's on my todo list?"}
      })

    sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert Enum.count(sends) == 3
    assert Enum.at(sends, 1).text =~ "Here is the full open work"
    assert List.last(sends).text =~ "Renew the domain and confirm it is done."
    assert List.last(sends).text =~ "You want this tracked as an ongoing work item."
    refute List.last(sends).text =~ "Renew the domain this week"
    refute List.last(sends).text =~ "Maraithon Todo"
    refute List.last(sends).text =~ "you wants"
    refute List.last(sends).text =~ "You need to:"
    refute List.last(sends).text =~ "About:"
    assert get_in(Keyword.get(List.last(sends).opts, :reply_markup), ["inline_keyboard"]) != nil
  end

  test "review questions return the full open todo list as individual cards", %{user_id: user_id} do
    assert {:ok, [_first, _second]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Reply to Rippling about employment eligibility",
                 "summary" => "Rippling needs a user response before onboarding can continue.",
                 "next_action" => "Reply with the requested eligibility details.",
                 "priority" => 95,
                 "dedupe_key" => "telegram-assistant:review:1"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Resolve Google Ads billing issue",
                 "summary" => "Ads have stopped because billing needs attention.",
                 "next_action" => "Fix the billing issue and confirm campaigns are active again.",
                 "priority" => 93,
                 "dedupe_key" => "telegram-assistant:review:2"
               }
             ])

    start_supervised!(%{
      id: :telegram_assistant_sequence_review_todos,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_review_todos]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_review_todos, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          assert Enum.any?(payload.tools, &(&1["name"] == "list_todos"))

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "list_todos",
                 "arguments" => %{
                   "statuses" => ["open"],
                   "limit" => 20
                 }
               }
             ],
             "summary" => "Loaded the full open todo list for review."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "list_todos"
          assert history_entry["result"]["count"] == 2

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Here is everything open to review right now.",
             "message_class" => "todo_digest",
             "tool_calls" => [],
             "summary" => "Returned the full actionable review list as todo cards."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9112, text: "What should I review?"}
      })

    sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert Enum.count(sends) == 3
    assert Enum.at(sends, 0).text =~ "everything open to review right now"
    assert Enum.at(sends, 1).text =~ "Reply with the requested eligibility details."

    assert Enum.at(sends, 1).text =~
             "Rippling needs a user response before onboarding can continue."

    refute Enum.at(sends, 1).text =~ "Reply to Rippling about employment eligibility"
    refute Enum.at(sends, 1).text =~ "Maraithon Todo"
    refute Enum.at(sends, 1).text =~ "About:"

    assert Enum.at(sends, 2).text =~
             "Fix the billing issue and confirm campaigns are active again."

    assert Enum.at(sends, 2).text =~ "Ads have stopped because billing needs attention."
    refute Enum.at(sends, 2).text =~ "Resolve Google Ads billing issue"
    refute Enum.at(sends, 2).text =~ "Maraithon Todo"
    refute Enum.at(sends, 2).text =~ "About:"
  end

  test "natural one-at-a-time todo request starts review and advances after each action", %{
    user_id: user_id
  } do
    assert {:ok, [first, second]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Reply to Emma's soccer organizer",
                 "summary" => "Emma's organizer needs confirmation for this weekend.",
                 "next_action" => "Confirm the soccer practice timing.",
                 "priority" => 98,
                 "dedupe_key" => "telegram-assistant:one-at-a-time:1"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Reply to Matthew about setup",
                 "summary" => "Matthew is waiting on setup help and pricing.",
                 "next_action" => "Reply with the recommended setup path and pricing owner.",
                 "priority" => 94,
                 "dedupe_key" => "telegram-assistant:one-at-a-time:2"
               }
             ])

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9220,
          text: "Let's go through my todos one at a time"
        }
      })

    sends = Enum.filter(telegram_events(), &(&1.type == :send))
    assert length(sends) == 1
    assert hd(sends).text =~ "Open work 1 of 2"
    assert hd(sends).text =~ "Confirm the soccer practice timing."
    assert hd(sends).text =~ "Emma's organizer needs confirmation"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: "todo-review-1",
          callback_id: "todo-review-done",
          data: "tgtodo:#{first.id}:done"
        }
      })

    assert Todos.get_for_user(user_id, first.id).status == "done"

    sends = Enum.filter(telegram_events(), &(&1.type == :send))
    assert length(sends) == 2
    assert List.last(sends).text =~ "Open work 2 of 2"
    assert List.last(sends).text =~ "Reply with the recommended setup path"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: "todo-review-2",
          callback_id: "todo-review-dismiss",
          data: "tgtodo:#{second.id}:dismiss"
        }
      })

    assert Todos.get_for_user(user_id, second.id).status == "dismissed"

    sends = Enum.filter(telegram_events(), &(&1.type == :send))
    assert List.last(sends).text =~ "Open work review complete"
    assert List.last(sends).text =~ "Done: 1"
    assert List.last(sends).text =~ "Dismissed: 1"
    assert List.last(sends).text =~ "Done and dismissed work will stay out of future briefs"
  end

  test "todo list replies with dense bullets are converted to contextual todo cards", %{
    user_id: user_id
  } do
    assert {:ok, [_first, _second]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Reply to Dan Bourke about Claude Cowork",
                 "summary" =>
                   "Dan is waiting on the Claude Cowork killer project status before he can plan the next project step.",
                 "next_action" =>
                   "Confirm current status and provide a concrete ETA for the Claude Cowork killer project.",
                 "priority" => 96,
                 "dedupe_key" => "telegram-assistant:contextual-bullets:1"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "attention_mode" => "act_now",
                 "title" => "Follow up with Matthew Diakonov",
                 "summary" =>
                   "Matthew is waiting on the promised follow-up before the meeting can be scheduled.",
                 "next_action" => "Send promised follow-up and book the meeting.",
                 "priority" => 94,
                 "dedupe_key" => "telegram-assistant:contextual-bullets:2"
               }
             ])

    start_supervised!(%{
      id: :telegram_assistant_sequence_dense_todo_bullets,
      start:
        {Agent, :start_link,
         [fn -> 0 end, [name: :telegram_assistant_sequence_dense_todo_bullets]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_dense_todo_bullets, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "list_todos",
                 "arguments" => %{"statuses" => ["open"], "limit" => 20}
               }
             ],
             "summary" => "Loaded open todos."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "list_todos"
          assert Enum.count(history_entry["result"]["todos"]) == 2

          {:ok,
           %{
             "status" => "final",
             "assistant_message" =>
               "- Dan Bourke: Confirm current status and provide a concrete ETA for the Claude Cowork killer project.\n- Matthew Diakonov: Send promised follow-up and book the meeting.",
             "message_class" => "assistant_reply",
             "tool_calls" => [],
             "summary" => "Returned open todos as a dense list."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9113, text: "What should I do next?"}
      })

    sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert Enum.count(sends) == 3
    assert Enum.at(sends, 0).text =~ "context needed for a decision"
    refute Enum.at(sends, 0).text =~ "clear it"
    refute Enum.at(sends, 0).text =~ "Dan Bourke:"
    refute Enum.at(sends, 0).text =~ "Matthew Diakonov:"

    assert Enum.at(sends, 1).text =~
             "Confirm current status and provide a concrete ETA"

    assert Enum.at(sends, 1).text =~
             "Dan is waiting on the Claude Cowork killer project status"

    assert Enum.at(sends, 2).text =~ "Send promised follow-up and book the meeting."

    assert Enum.at(sends, 2).text =~
             "Matthew is waiting on the promised follow-up"
  end

  test "todo item callbacks can close an item directly from Telegram", %{user_id: user_id} do
    assert {:ok, [todo]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to the billing owner",
                 "summary" => "Finance needs an owner confirmation for the invoice thread.",
                 "next_action" => "Reply with the owner and the exact billing contact.",
                 "priority" => 89,
                 "dedupe_key" => "telegram-assistant:todo-callback:1",
                 "metadata" => %{
                   "source_ref" => %{"url" => "https://mail.google.com/mail/u/0/#inbox/thread-1"}
                 }
               }
             ])

    {:ok, conversation} =
      Maraithon.TelegramConversations.start_or_continue(user_id, "12345", %{})

    payload = Maraithon.TelegramAssistant.TodoActions.telegram_payload(todo)

    serialized_payload =
      Maraithon.TelegramAssistant.TodoActions.telegram_payload(Todos.serialize_for_prompt(todo))

    keyboard = get_in(payload.reply_markup, ["inline_keyboard"])
    assert keyboard != nil
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Maraithon"))
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Gmail"))
    assert serialized_payload.text =~ "Reply with the owner and the exact billing contact."
    refute payload.text =~ "Maraithon Todo"
    refute payload.text =~ "Reply to the billing owner"
    refute payload.text =~ "You need to:"
    refute payload.text =~ "Status:"
    refute payload.text =~ "About:"
    assert payload.text =~ "Reply with the owner and the exact billing contact."
    assert payload.text =~ "Finance needs an owner confirmation for the invoice thread."

    assert payload.text =~ "Decision: Handle this now, snooze it, or dismiss it."

    assert payload.text =~ "From Gmail."
    refute payload.text =~ "Choose whether this Gmail thread"
    refute payload.text =~ "I found this in"
    refute payload.text =~ "Priority:"
    refute payload.text =~ "From:"
    refute payload.text =~ "Source:"
    refute payload.text =~ "account "

    assert {:ok, _conversation, turn, _telegram_result} =
             Maraithon.TelegramAssistant.send_turn(
               conversation,
               "12345",
               payload.text,
               telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup],
               structured_data: %{"linked_todo" => Todos.serialize_for_prompt(todo)}
             )

    linked_todo = turn.structured_data["linked_todo"]
    assert linked_todo["id"] == todo.id
    assert linked_todo["title"] == "Reply to the billing owner"
    assert linked_todo["metadata"] == %{}
    refute Map.has_key?(linked_todo, "owner_user_id")
    refute Map.has_key?(linked_todo, "source_item_id")
    refute Map.has_key?(linked_todo, "dedupe_key")
    refute Map.has_key?(linked_todo, "attention_profile")
    refute Map.has_key?(linked_todo, "surface_quality")
    refute inspect(linked_todo) =~ "mail.google.com"

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "callback_query",
        data: %{
          chat_id: 12345,
          message_id: turn.telegram_message_id,
          callback_id: "todo-callback-1",
          data: "tgtodo:#{todo.id}:done"
        }
      })

    assert Todos.get_for_user(user_id, todo.id).status == "done"

    assert last_telegram_message(:edit).text =~
             "Reply with the owner and the exact billing contact."

    refute last_telegram_message(:edit).text =~ "Status:"
    assert Keyword.get(last_telegram_message(:callback).opts, :text) == "Marked done"
  end

  test "assistant-origin todo cards speak like a chief of staff without hardcoding the operator name" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "chief_of_staff_morning_briefing",
      "status" => "open",
      "title" => "Agora getdelegates API errors were flagged",
      "summary" =>
        "Datadog and Sentry surfaced elevated getdelegates API errors for Agora, and Kent needs a quick status check on whether the issue is resolved, who owns it, and whether users or customers were affected.\nFrom: Chief_of_staff_morning_briefing",
      "next_action" =>
        "Ask the engineering owner for a one-line status update covering current state, fix window if still open, and any user or customer impact."
    }

    payload = Maraithon.TelegramAssistant.TodoActions.telegram_payload(todo)

    assert payload.text =~
             "Ask the engineering owner: is it resolved, who owns it, and were any users or customers affected?"

    assert payload.text =~ "you need a quick answer"
    refute payload.text =~ "Kent,"
    refute payload.text =~ "covering current state"
    refute payload.text =~ "From:"
    refute payload.text =~ "Chief_of_staff"
    refute payload.text =~ "chief_of_staff"
    refute payload.text =~ "Kent needs"
    refute payload.text =~ "I found this in"
    refute payload.text =~ "Source:"
    refute payload.text =~ "Priority:"
  end

  test "commitment todo cards prefer specific source context over generic summaries" do
    todo = %{
      "id" => Ecto.UUID.generate(),
      "source" => "gmail",
      "status" => "open",
      "title" => "You committed to Dan Bourke and no follow-up has gone out yet.",
      "summary" =>
        "Commitment to Dan Bourke to follow up remains open and overdue with no evidence of completion.",
      "next_action" =>
        "Send the promised follow-through now and explicitly confirm delivery in the same thread.",
      "metadata" => %{
        "record" => %{
          "person" => "Dan Bourke",
          "commitment" =>
            "Thanks for the auto-follow ups. Love A-Team but we are building out our new Claude Cowork killer: https://runner.now/"
        },
        "why_now" =>
          "No later reply or follow-through was found in the conversation and the deadline is passed."
      }
    }

    payload = Maraithon.TelegramAssistant.TodoActions.telegram_payload(todo)

    assert payload.text =~ "Dan Bourke is waiting on this commitment"
    assert payload.text =~ "Claude Cowork killer"
    refute payload.text =~ "Commitment to Dan Bourke to follow up remains open"
    refute payload.text =~ "You need to:"
  end

  test "todo item callbacks are handled when full Telegram chat is disabled", %{
    user_id: user_id
  } do
    config = Application.get_env(:maraithon, :telegram_assistant, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.put(config, :telegram_full_chat_enabled, false)
    )

    refute Maraithon.TelegramAssistant.enabled?()

    assert {:ok, [done_todo, dismissed_todo, helpful_todo, not_helpful_todo]} =
             Todos.upsert_many(user_id, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to the billing owner",
                 "summary" => "Finance needs an owner confirmation for the invoice thread.",
                 "next_action" => "Reply with the owner and the exact billing contact.",
                 "priority" => 89,
                 "dedupe_key" => "telegram-assistant:todo-callback:disabled:done"
               },
               %{
                 "source" => "calendar",
                 "kind" => "calendar_follow_up",
                 "title" => "Skip old calendar follow-up",
                 "summary" => "This calendar follow-up no longer matters.",
                 "next_action" => "Ignore the stale follow-up.",
                 "priority" => 61,
                 "dedupe_key" => "telegram-assistant:todo-callback:disabled:dismiss"
               },
               %{
                 "source" => "slack",
                 "kind" => "relationship_follow_up",
                 "title" => "Ask Charlie for the launch notes",
                 "summary" => "Charlie may have the launch details Kent needs.",
                 "next_action" => "Ask Charlie for the latest launch notes.",
                 "priority" => 76,
                 "dedupe_key" => "telegram-assistant:todo-callback:disabled:helpful"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Review a low-value newsletter",
                 "summary" => "A newsletter was mistakenly promoted as a todo.",
                 "next_action" => "Review whether this newsletter matters.",
                 "priority" => 30,
                 "dedupe_key" => "telegram-assistant:todo-callback:disabled:not-helpful"
               }
             ])

    callbacks = [
      {done_todo, "done", "cb-done"},
      {dismissed_todo, "dismiss", "cb-dismiss"},
      {helpful_todo, "helpful", "cb-helpful"},
      {not_helpful_todo, "not_helpful", "cb-not-helpful"}
    ]

    Enum.each(callbacks, fn {todo, action, callback_id} ->
      :ok =
        InsightNotifications.handle_telegram_event(%{
          type: "callback_query",
          data: %{
            chat_id: 12345,
            message_id: "todo-message-#{action}",
            callback_id: callback_id,
            data: "tgtodo:#{todo.id}:#{action}"
          }
        })
    end)

    assert Todos.get_for_user(user_id, done_todo.id).status == "done"
    assert Todos.get_for_user(user_id, dismissed_todo.id).status == "dismissed"

    assert get_in(Todos.get_for_user(user_id, helpful_todo.id).metadata, [
             "assistant_feedback",
             "value"
           ]) == "helpful"

    assert get_in(Todos.get_for_user(user_id, not_helpful_todo.id).metadata, [
             "assistant_feedback",
             "value"
           ]) == "not_helpful"

    callback_texts =
      telegram_events()
      |> Enum.filter(&(&1.type == :callback))
      |> Enum.map(&Keyword.get(&1.opts, :text))

    assert callback_texts == [
             "Marked done",
             "Dismissed",
             "Saved helpful feedback",
             "Feedback saved"
           ]

    assert Enum.count(Enum.filter(telegram_events(), &(&1.type == :edit))) == 4
  end

  test "assistant can update a linked project scope from a reply thread", %{user_id: user_id} do
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
          "dedupe_key" => "telegram-project-scope:garage:shelves",
          "metadata" => %{
            "suggested_project_id" => project.id,
            "suggested_project_name" => project.name,
            "suggested_life_domain" => "home"
          }
        }
      ])

    {:ok, conversation} =
      Maraithon.TelegramConversations.start_or_continue(user_id, "12345", %{})

    assert {:ok, {_conversation, turn}} =
             Maraithon.TelegramConversations.append_turn(conversation, %{
               "role" => "assistant",
               "telegram_message_id" => "9300",
               "text" =>
                 "Weekend project check: I currently think Garage Renovation is home. Is that right?",
               "turn_kind" => "assistant_push",
               "origin_type" => "brief",
               "origin_id" => Ecto.UUID.generate(),
               "structured_data" => %{
                 "linked_project" => %{
                   "id" => project.id,
                   "name" => project.name,
                   "slug" => project.slug,
                   "summary" => project.summary
                 }
               }
             })

    start_supervised!(%{
      id: :telegram_assistant_sequence_project_scope,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_sequence_project_scope]]}
    })

    set_assistant(fn payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_sequence_project_scope, fn current ->
          {current, current + 1}
        end)

      case sequence do
        0 ->
          assert payload.context.linked_item.project.id == project.id
          assert payload.context.linked_item.project.name == "Garage Renovation"
          assert Enum.any?(payload.tools, &(&1["name"] == "update_project_scope"))

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "update_project_scope",
                 "arguments" => %{
                   "life_domain" => "home",
                   "confidence" => 0.95,
                   "reasoning" => "This is a household renovation project."
                 }
               }
             ],
             "summary" => "Updated the linked project scope."
           }}

        1 ->
          [history_entry] = payload.tool_history
          assert history_entry["tool"] == "update_project_scope"
          assert get_in(history_entry, ["result", "project", "id"]) == project.id

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Marked Garage Renovation as a home project.",
             "message_class" => "action_result",
             "tool_calls" => [],
             "summary" => "Confirmed the project scope update."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{
          chat_id: 12345,
          message_id: 9301,
          text: "It's home.",
          reply_to: %{message_id: turn.telegram_message_id}
        }
      })

    assert last_telegram_message(:send).text =~ "home project"
    assert Projects.get_project_for_user(project.id, user_id).metadata["life_domain"] == "home"

    assert Todos.get_for_user(user_id, todo.id).metadata["scope_source"] ==
             "project_scope_confirmation"
  end

  test "insight dispatch goes through the unified push broker and records receipts", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [insight]} =
      Insights.record_many(user_id, agent.id, [
        %{
          "source" => "gmail",
          "category" => "commitment_unresolved",
          "title" => "Send Sarah the deck",
          "summary" => "Explicit promise still appears open.",
          "recommended_action" => "Reply with the deck today.",
          "priority" => 98,
          "confidence" => 0.94,
          "dedupe_key" => "telegram-assistant:push-broker:1",
          "metadata" => %{"account" => "kent@example.com"}
        }
      ])

    assert %{sent: 1, failed: 0} = InsightNotifications.dispatch_telegram_batch(batch_size: 10)

    delivery =
      Repo.get_by!(Delivery, insight_id: insight.id, user_id: user_id, channel: "telegram")

    assert delivery.status == "sent"
    assert is_binary(delivery.provider_message_id)

    receipt =
      Repo.one!(
        from receipt in PushReceipt,
          where: receipt.user_id == ^user_id,
          order_by: [desc: receipt.inserted_at],
          limit: 1
      )

    assert receipt.origin_type == "insight"
    assert receipt.decision == "sent_now"

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.linked_delivery_id == ^delivery.id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    assert get_in(conversation.metadata, ["mode"]) == "push_thread"

    turn =
      Repo.one!(
        from turn in Turn,
          where: turn.conversation_id == ^conversation.id,
          order_by: [desc: turn.inserted_at],
          limit: 1
      )

    assert turn.turn_kind == "assistant_push"
    assert turn.origin_type == "insight"
    assert turn.origin_id == delivery.id
  end

  test "check-in briefs deliver an intro with a review open work button", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [new_todo, older_todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_payload("thread-check-in:new", "Reply to Charlie about the budget", 92),
        gmail_todo_payload("thread-check-in:old", "Confirm the old shipping ETA", 87)
      ])

    {:ok, older_todo} =
      older_todo
      |> Ecto.Changeset.change(%{source_occurred_at: ~U[2026-03-31 14:00:00.000000Z]})
      |> Repo.update()

    scheduled_for = ~U[2026-04-02 14:30:00Z]

    assert {:ok, brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "check_in",
               "title" => "Check-in: 2 items still need movement",
               "summary" => "Two open communication loops still need movement.",
               "body" => "INTERNAL_PLACEHOLDER_SHOULD_NOT_SEND",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "telegram-assistant:check-in:todo-style",
               "metadata" => %{
                 "linked_todo_ids" => [new_todo.id, older_todo.id],
                 "timezone_offset_hours" => "-4"
               }
             })

    assert :ok = Briefs.send_brief(brief)

    sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert length(sends) == 1
    [intro] = sends

    assert intro.text =~ "<b>Chief of staff check-in</b>"
    assert intro.text =~ "<b>Check-in: 2 items still need movement</b>"
    assert intro.text =~ "here's the open work that needs review today"
    assert intro.text =~ "1 new today"
    assert intro.text =~ "1 carried over from earlier"

    assert intro.text =~ "Best next move: Reply to Charlie about the budget."

    assert intro.text =~ "review the rest one by one"
    assert intro.text =~ "keep what still needs you"
    refute intro.text =~ "not important"
    refute intro.text =~ "INTERNAL_PLACEHOLDER_SHOULD_NOT_SEND"

    keyboard = get_in(intro.opts, [:reply_markup, "inline_keyboard"]) || []
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Review open work"))
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Maraithon"))

    updated_brief = Repo.get!(Maraithon.Briefs.Brief, brief.id)
    assert updated_brief.status == "sent"
    assert updated_brief.provider_message_id == intro.message_id

    conversation =
      Repo.one!(
        from conversation in Conversation,
          where: conversation.user_id == ^user_id,
          order_by: [desc: conversation.inserted_at],
          limit: 1
      )

    turns =
      Repo.all(
        from turn in Turn,
          where: turn.conversation_id == ^conversation.id,
          order_by: [asc: turn.inserted_at]
      )

    assert Enum.map(turns, & &1.turn_kind) == ["assistant_push"]
    assert get_in(hd(turns).structured_data, ["todo_ids"]) == [new_todo.id, older_todo.id]
  end

  test "end-of-day briefs deliver an intro with a review open work button", %{
    user_id: user_id,
    agent: agent
  } do
    {:ok, [today_todo, carryover_todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_payload("thread-end-of-day:new", "Reply to David about the laptop", 96),
        gmail_todo_payload("thread-end-of-day:old", "Close the Cowrie status loop", 91)
      ])

    {:ok, carryover_todo} =
      carryover_todo
      |> Ecto.Changeset.change(%{source_occurred_at: ~U[2026-03-31 14:00:00.000000Z]})
      |> Repo.update()

    scheduled_for = ~U[2026-04-02 22:30:00Z]

    assert {:ok, brief} =
             Briefs.record(user_id, agent.id, %{
               "cadence" => "end_of_day",
               "title" => "End-of-day review: 2 items still open",
               "summary" => "Two items still need movement before the day closes.",
               "body" => "INTERNAL_PLACEHOLDER_SHOULD_NOT_SEND",
               "scheduled_for" => scheduled_for,
               "dedupe_key" => "telegram-assistant:end-of-day:todo-style",
               "metadata" => %{
                 "linked_todo_ids" => [today_todo.id, carryover_todo.id],
                 "timezone_offset_hours" => "-4"
               }
             })

    assert :ok = Briefs.send_brief(brief)

    sends =
      telegram_events()
      |> Enum.filter(&(&1.type == :send))

    assert length(sends) == 1
    [intro] = sends

    assert intro.text =~ "<b>End-of-day review</b>"
    assert intro.text =~ "<b>End-of-day review: 2 items still open</b>"
    refute intro.text =~ "debt"
    assert intro.text =~ "open work still worth a decision before the day closes"
    assert intro.text =~ "1 new today"
    assert intro.text =~ "1 carried over from earlier"

    assert intro.text =~ "Best next move: Reply to David about the laptop."

    assert intro.text =~ "defer anything that can wait"
    refute intro.text =~ "stale"
    refute intro.text =~ "INTERNAL_PLACEHOLDER_SHOULD_NOT_SEND"

    keyboard = get_in(intro.opts, [:reply_markup, "inline_keyboard"]) || []
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Review open work"))
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Maraithon"))
  end

  test "medium runs emit native typing without a progress note" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 400,
      timeout_notice_ms: 1_500,
      hard_timeout_ms: 2_000
    )

    set_assistant(fn _payload ->
      run_pid = self()
      send(parent, {:assistant_waiting, run_pid})

      receive do
        {:release_assistant, ^run_pid} ->
          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Here is the answer.",
             "message_class" => "assistant_reply",
             "tool_calls" => [],
             "summary" => "Returned the answer."
           }}
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9201, text: "What is going on?"}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :chat_action, action: "typing"}}, 1_000
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)

    events = telegram_events()
    assert Enum.any?(events, &(&1.type == :chat_action))
    assert Enum.count(Enum.filter(events, &(&1.type == :send))) == 1
    refute Enum.any?(events, &(&1.type == :edit))

    [run] =
      Repo.all(
        from run in Run,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert get_in(run.result_summary, ["liveness", "typing_started"])
    refute get_in(run.result_summary, ["liveness", "progress_note_sent"])
  end

  test "slow runs send one contextual progress note and edit it into the final answer" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 100,
      timeout_notice_ms: 1_500,
      hard_timeout_ms: 2_000
    )

    start_supervised!(%{
      id: :telegram_assistant_slow_sequence,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_slow_sequence]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_slow_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need open work."
         }}
      else
        run_pid = self()
        send(parent, {:assistant_waiting, run_pid})

        receive do
          {:release_assistant, ^run_pid} ->
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "Open work reviewed.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "Done."
             }}
        end
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9202, text: "Review my work."}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :chat_action, action: "typing"}}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :send, text: progress_text}}, 1_000
    assert progress_text =~ "open work"
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)

    events = telegram_events()
    assert Enum.count(Enum.filter(events, &(&1.type == :send))) == 1
    assert Enum.count(Enum.filter(events, &(&1.type == :edit))) == 1
    assert Enum.any?(events, &(&1.type == :edit and &1.text == "Open work reviewed."))

    [run] =
      Repo.all(
        from run in Run,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert get_in(run.result_summary, ["liveness", "typing_started"])
    assert get_in(run.result_summary, ["liveness", "progress_note_sent"])
    assert get_in(run.result_summary, ["liveness", "final_delivery_mode"]) == "edit_progress"
  end

  test "relationship lookups explain what is being checked while they run" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 100,
      timeout_notice_ms: 1_500,
      hard_timeout_ms: 2_000
    )

    start_supervised!(%{
      id: :telegram_assistant_relationship_sequence,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_relationship_sequence]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_relationship_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_relationship_context", "arguments" => %{"query" => "Charlie"}}
           ],
           "summary" => "Need relationship context."
         }}
      else
        run_pid = self()
        send(parent, {:assistant_waiting, run_pid})

        receive do
          {:release_assistant, ^run_pid} ->
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "I do not have a confident Charlie yet.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "Answered from relationship lookup."
             }}
        end
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9204, text: "Who is Charlie?"}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :send, text: progress_text}}, 1_000
    assert progress_text == "Still checking what I know about Charlie."
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)

    assert Enum.any?(
             telegram_events(),
             &(&1.type == :edit and &1.text == "I do not have a confident Charlie yet.")
           )
  end

  test "relationship lookup timeout copy avoids internal CRM language" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 75,
      timeout_notice_ms: 140,
      hard_timeout_ms: 2_000
    )

    start_supervised!(%{
      id: :telegram_assistant_relationship_timeout_sequence,
      start:
        {Agent, :start_link,
         [fn -> 0 end, [name: :telegram_assistant_relationship_timeout_sequence]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_relationship_timeout_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_relationship_context", "arguments" => %{"query" => "Charlie"}}
           ],
           "summary" => "Need relationship context."
         }}
      else
        run_pid = self()
        send(parent, {:assistant_waiting, run_pid})

        receive do
          {:release_assistant, ^run_pid} ->
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "This late Charlie answer should still be delivered.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "Late relationship answer."
             }}
        end
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9205, text: "Who is Charlie?"}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 3_000
    assert_receive {:capturing_telegram_event, %{type: :send, text: progress_text}}, 1_000
    assert progress_text == "Still checking what I know about Charlie."
    assert_receive {:capturing_telegram_event, %{type: :edit, text: timeout_text}}, 1_000
    assert timeout_text =~ "I saved the question about Charlie"
    assert timeout_text =~ "relationship context plus connected sources"
    refute timeout_text =~ "CRM"
    refute timeout_text =~ "partial evidence"

    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)
  end

  test "timed out runs tell the user and edit the timeout notice into a late final reply" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 75,
      timeout_notice_ms: 140,
      hard_timeout_ms: 2_000
    )

    start_supervised!(%{
      id: :telegram_assistant_timeout_sequence,
      start: {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_timeout_sequence]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_timeout_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need open work."
         }}
      else
        run_pid = self()
        send(parent, {:assistant_waiting, run_pid})

        receive do
          {:release_assistant, ^run_pid} ->
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "This answer should be suppressed.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "Late final."
             }}
        end
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9203, text: "Take your time."}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 3_000
    assert_receive {:capturing_telegram_event, %{type: :send}}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :edit, text: timeout_text}}, 1_000
    assert timeout_text =~ "I saved this request"
    refute timeout_text =~ "taking longer than it should"
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)

    events = telegram_events()
    assert Enum.count(Enum.filter(events, &(&1.type == :edit))) == 2

    assert Enum.any?(
             events,
             &(&1.type == :edit and &1.text == "This answer should be suppressed.")
           )

    [run] =
      Repo.all(
        from run in Run,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert run.status == "completed"
    assert get_in(run.result_summary, ["liveness", "timeout_notice_sent"])

    assert get_in(run.result_summary, ["liveness", "final_delivery_mode"]) ==
             "edit_after_timeout"
  end

  test "final delivery falls back to a fresh send when editing the progress note fails" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 75,
      timeout_notice_ms: 1_500,
      hard_timeout_ms: 2_000
    )

    Application.put_env(:maraithon, :capturing_telegram,
      edit_result: {:error, :forced_edit_failure}
    )

    start_supervised!(%{
      id: :telegram_assistant_edit_fallback_sequence,
      start:
        {Agent, :start_link, [fn -> 0 end, [name: :telegram_assistant_edit_fallback_sequence]]}
    })

    set_assistant(fn _payload ->
      sequence =
        Agent.get_and_update(:telegram_assistant_edit_fallback_sequence, fn current ->
          {current, current + 1}
        end)

      if sequence == 0 do
        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need open work."
         }}
      else
        run_pid = self()
        send(parent, {:assistant_waiting, run_pid})

        receive do
          {:release_assistant, ^run_pid} ->
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "Final answer after edit failure.",
               "message_class" => "assistant_reply",
               "tool_calls" => [],
               "summary" => "Done."
             }}
        end
      end
    end)

    task =
      Task.async(fn ->
        InsightNotifications.handle_telegram_event(%{
          type: "message",
          data: %{chat_id: 12345, message_id: 9204, text: "Need a slow answer."}
        })
      end)

    assert_receive {:assistant_waiting, run_pid}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :send}}, 1_000
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)
    assert_receive {:capturing_telegram_edit_failed, _event, :forced_edit_failure}, 500

    events = telegram_events()
    assert Enum.count(Enum.filter(events, &(&1.type == :send))) == 2

    refute Enum.any?(
             events,
             &(&1.type == :edit and &1.text == "Final answer after edit failure.")
           )

    assert Enum.any?(
             events,
             &(&1.type == :send and &1.text == "Final answer after edit failure.")
           )
  end

  defp set_assistant(fun) when is_function(fun, 1) do
    config = Application.get_env(:maraithon, :telegram_assistant, [])
    Application.put_env(:maraithon, :telegram_assistant, Keyword.put(config, :next_step, fun))
  end

  defp gmail_todo_payload(thread_id, title, priority) do
    %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This thread still needs a reply from the user.",
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

  defp configure_liveness(opts) do
    config = Application.get_env(:maraithon, :telegram_assistant, [])
    Application.put_env(:maraithon, :telegram_assistant, Keyword.merge(config, opts))
  end

  defp telegram_events do
    Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
  end

  defp last_telegram_message(type) do
    :capturing_telegram_recorder
    |> Agent.get(&Enum.reverse/1)
    |> Enum.filter(&(&1.type == type))
    |> List.last()
  end
end
