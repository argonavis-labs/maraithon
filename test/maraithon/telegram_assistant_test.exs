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
        typing_initial_delay_ms: 10_000,
        typing_refresh_ms: 4_000,
        contextual_progress_delay_ms: 20_000,
        timeout_notice_ms: 35_000,
        hard_timeout_ms: 40_000,
        client_module: TelegramAssistantClientStub
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
        assert Enum.any?(payload.tools, &(&1["name"] == "get_open_work_summary"))

        {:ok,
         %{
           "status" => "tool_calls",
           "assistant_message" => "",
           "message_class" => "assistant_reply",
           "tool_calls" => [
             %{"tool" => "get_open_work_summary", "arguments" => %{"limit" => 3}}
           ],
           "summary" => "Need a fresh work summary."
         }}
      else
        [history_entry] = payload.tool_history
        assert history_entry["tool"] == "get_open_work_summary"

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
    assert get_in(run.prompt_snapshot, ["open_insights"]) != []
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
             "I think this should become durable memory. Reply `yes` to save it, or `no` to keep it local only.",
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
    assert prompt_reply.text =~ "Reply `yes`"

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
    assert confirmation_reply.text =~ "saved that as a durable rule"
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
             "Delete agent Kent's Gmail agent. This removes its saved definition and runtime history dependencies. Reply `yes` or use the buttons to delete it, or `no` to cancel.",
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
    assert approval.text =~ "Delete agent Kent's Gmail agent"

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
    assert Enum.at(initial_sends, 0).text =~ "sending the actionable items one by one"

    billing_message =
      Enum.find(initial_sends, fn message ->
        String.contains?(message.text, "Billing account past due")
      end)

    oauth_message =
      Enum.find(initial_sends, fn message ->
        String.contains?(message.text, "OAuth verification reply owed")
      end)

    assert billing_message
    assert oauth_message
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
    assert List.last(sends_after_resolution).text =~ "OAuth verification"
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

    assert last_telegram_message(:send).text =~ "Added that to your todo list"

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
    assert Enum.at(sends, 1).text =~ "Here is the full open todo list"
    assert List.last(sends).text =~ "Renew the domain this week"
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
    assert Enum.at(sends, 1).text =~ "Reply to Rippling about employment eligibility"
    assert Enum.at(sends, 2).text =~ "Resolve Google Ads billing issue"
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
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Dashboard"))
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Open Source"))
    assert serialized_payload.text =~ "Reply to the billing owner"

    assert {:ok, _conversation, turn, _telegram_result} =
             Maraithon.TelegramAssistant.send_turn(
               conversation,
               "12345",
               payload.text,
               telegram_opts: [parse_mode: "HTML", reply_markup: payload.reply_markup],
               structured_data: %{"linked_todo" => Todos.serialize_for_prompt(todo)}
             )

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
    assert last_telegram_message(:edit).text =~ "Done"
    assert Keyword.get(last_telegram_message(:callback).opts, :text) == "Marked done"
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

  test "check-in briefs deliver an intro plus one push card per todo", %{
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
               "body" => "Superseded by todo delivery.",
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

    assert length(sends) == 3
    [intro, first_todo_message, second_todo_message] = sends

    assert intro.text ==
             "Hey Kent, checking on these today.\n\n1 new today. 1 still open from earlier.\nI'm sending them one by one so you can mark them done or say not interested."

    assert first_todo_message.text =~ "New Today"
    assert first_todo_message.text =~ "Reply to Charlie about the budget"
    assert second_todo_message.text =~ "Still Open"
    assert second_todo_message.text =~ "Confirm the old shipping ETA"

    keyboard = get_in(first_todo_message.opts, [:reply_markup, "inline_keyboard"]) || []
    assert Enum.any?(List.flatten(keyboard), &(&1["text"] == "Not Interested"))

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

    assert Enum.map(turns, & &1.turn_kind) == [
             "assistant_push",
             "assistant_push",
             "assistant_push"
           ]

    assert get_in(Enum.at(turns, 1).structured_data, ["linked_todo", "id"]) == new_todo.id
    assert get_in(Enum.at(turns, 2).structured_data, ["linked_todo", "id"]) == older_todo.id
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

  test "timed out runs tell the user and suppress the late final reply" do
    parent = self()

    configure_liveness(
      typing_initial_delay_ms: 25,
      typing_refresh_ms: 50,
      contextual_progress_delay_ms: 75,
      timeout_notice_ms: 140,
      hard_timeout_ms: 200
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

    assert_receive {:assistant_waiting, run_pid}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :send}}, 1_000
    assert_receive {:capturing_telegram_event, %{type: :edit, text: timeout_text}}, 1_000
    assert timeout_text =~ "didn't finish that in time"
    send(run_pid, {:release_assistant, run_pid})
    assert :ok = Task.await(task, 2_000)

    events = telegram_events()
    assert Enum.count(Enum.filter(events, &(&1.type == :edit))) == 1

    refute Enum.any?(
             events,
             &(&1.type == :edit and &1.text == "This answer should be suppressed.")
           )

    refute Enum.any?(
             events,
             &(&1.type == :send and &1.text == "This answer should be suppressed.")
           )

    [run] =
      Repo.all(
        from run in Run,
          order_by: [desc: run.inserted_at],
          limit: 1
      )

    assert run.status == "degraded"
    assert get_in(run.result_summary, ["liveness", "timeout_notice_sent"])

    assert get_in(run.result_summary, ["liveness", "final_delivery_mode"]) ==
             "suppressed_after_timeout"
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
