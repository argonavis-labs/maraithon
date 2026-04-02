defmodule Maraithon.TelegramAssistantTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.ConnectedAccounts
  alias Maraithon.InsightNotifications
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights
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
               "Top inbox todos: 1. Billing account past due. 2. OAuth verification reply owed.",
             "message_class" => "assistant_reply",
             "tool_calls" => [],
             "summary" => "Returned the persisted todo list."
           }}

        2 ->
          assert Enum.count(payload.context.todos) == 2

          billing_todo =
            Enum.find(payload.context.todos, fn todo ->
              String.contains?(todo.title, "Billing")
            end)

          assert billing_todo

          {:ok,
           %{
             "status" => "tool_calls",
             "assistant_message" => "",
             "message_class" => "assistant_reply",
             "tool_calls" => [
               %{
                 "tool" => "resolve_todo",
                 "arguments" => %{
                   "todo_id" => billing_todo.id,
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
             "assistant_message" =>
               "Billing is closed. Remaining inbox todo: OAuth verification reply owed.",
             "message_class" => "assistant_reply",
             "tool_calls" => [],
             "summary" => "Returned the remaining todo."
           }}
      end
    end)

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9107, text: "What are the emails to triage today?"}
      })

    first_reply = last_telegram_message(:send)
    assert first_reply.text =~ "Billing account past due"
    assert first_reply.text =~ "OAuth verification reply owed"

    open_todos = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert Enum.count(open_todos) == 2

    :ok =
      InsightNotifications.handle_telegram_event(%{
        type: "message",
        data: %{chat_id: 12345, message_id: 9108, text: "Handled the billing, what else?"}
      })

    second_reply = last_telegram_message(:send)
    assert second_reply.text =~ "Billing is closed"
    assert second_reply.text =~ "OAuth verification"
    refute second_reply.text =~ "Billing account past due."

    [remaining_todo] = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert remaining_todo.title =~ "OAuth verification"
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
