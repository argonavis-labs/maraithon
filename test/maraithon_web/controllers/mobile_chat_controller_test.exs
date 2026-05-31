defmodule MaraithonWeb.MobileChatControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.Repo
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.TestSupport.TelegramAssistantClientStub
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations
  alias Maraithon.TelegramConversations.Turn
  alias Maraithon.Todos

  setup do
    start_supervised!(%{
      id: :capturing_telegram_recorder,
      start: {Agent, :start_link, [fn -> [] end, [name: :capturing_telegram_recorder]]}
    })

    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_insights = Application.get_env(:maraithon, :insights, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_liveness_enabled: false,
        client_module: TelegramAssistantClientStub,
        next_step: fn _payload ->
          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "Production assistant response from Maraithon.",
             "message_class" => "assistant_reply",
             "summary" => "Responded through production assistant runtime."
           }}
        end
      )
    )

    Application.put_env(
      :maraithon,
      :insights,
      Keyword.merge(original_insights, telegram_module: CapturingTelegram)
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :insights, original_insights)
    end)

    :ok
  end

  test "mobile chat answers simple greetings immediately", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn)

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    assert %{"thread" => %{"id" => thread_id, "messages" => []}} = json_response(conn, 201)

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Hey"
        }
      })

    response = json_response(conn, 200)

    assert %{
             "thread" => %{
               "messages" => [
                 %{"role" => "user", "body" => "Hey"},
                 %{
                   "role" => "assistant",
                   "body" => "Ready. What needs attention?",
                   "run_id" => run_id,
                   "structured_data" => assistant_structured_data
                 }
               ]
             },
             "run" => %{
               "status" => "completed",
               "id" => response_run_id,
               "message_class" => "assistant_reply"
             }
           } = response

    assert response_run_id == run_id
    assert assistant_structured_data == %{}

    assert captured_telegram_events() == []
  end

  test "mobile chat sends non-trivial messages through assistant runtime without Telegram delivery",
       %{
         conn: conn
       } do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-runtime-chat@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    assert %{"thread" => %{"id" => thread_id, "messages" => []}} = json_response(conn, 201)

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Please summarize this mobile verification sentence in one line."
        }
      })

    response = json_response(conn, 200)

    assert %{
             "thread" => %{
               "messages" => [
                 %{"role" => "user"},
                 %{
                   "role" => "assistant",
                   "body" => "Production assistant response from Maraithon.",
                   "run_id" => run_id,
                   "structured_data" => assistant_structured_data
                 }
               ]
             },
             "run" => %{"status" => "completed", "id" => response_run_id}
           } = response

    assert response_run_id == run_id
    assert assistant_structured_data == %{}
    assert captured_telegram_events() == []
  end

  test "mobile chat refuses credential disclosure requests before assistant runtime", %{
    conn: conn
  } do
    openrouter_key = "sk-or-v1-mobile-chat-secret-test-value"
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.merge(original_runtime,
        llm_provider_name: "openrouter",
        llm_api_key: openrouter_key,
        openrouter_api_key: openrouter_key
      )
    )

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    test_pid = self()

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        next_step: fn _payload ->
          send(test_pid, :assistant_runtime_called)

          {:ok,
           %{
             "status" => "final",
             "assistant_message" => "This runtime response should not be used.",
             "message_class" => "assistant_reply",
             "summary" => "Unexpected runtime call."
           }}
        end
      )
    )

    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-secret-guard@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "what's our open router API key?"
        }
      })
      |> json_response(200)

    assert %{
             "thread" => %{
               "messages" => [
                 %{"role" => "user"},
                 %{
                   "role" => "assistant",
                   "body" => assistant_body,
                   "message_class" => "assistant_reply",
                   "structured_data" => assistant_structured_data
                 }
               ]
             },
             "run" => %{"status" => "completed", "message_class" => "assistant_reply"}
           } = response

    assert assistant_body =~ "OpenRouter is configured"
    assert assistant_body =~ "won't display API keys, tokens, passwords, or other credentials"
    assert assistant_body =~ "deployment secrets or Settings"
    refute assistant_body =~ openrouter_key
    refute assistant_body =~ "OPENROUTER_API_KEY"
    refute assistant_body =~ "sk-or"

    visible_response = inspect(response)
    refute visible_response =~ openrouter_key
    refute visible_response =~ "OPENROUTER_API_KEY"
    refute visible_response =~ "This runtime response should not be used."

    assert assistant_structured_data == %{}
    assert captured_telegram_events() == []
    refute_received :assistant_runtime_called
  end

  test "mobile chat strips assistant diagnostics while preserving useful answer copy", %{
    conn: conn
  } do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        next_step: fn _payload ->
          {:ok,
           %{
             "status" => "final",
             "assistant_message" => """
             Needs your attention: send Sarah the answer today.
             confidence_score: 0.91
             source_health: {"gmail":"connected"}
             model_name: gpt-test
             Next action: reply before 3 PM.
             """,
             "message_class" => "assistant_reply",
             "summary" => "Responded through production assistant runtime."
           }}
        end
      )
    )

    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-public-answer-copy@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Please check what I should do about Sarah today."
        }
      })
      |> json_response(200)

    assistant_body = get_in(response, ["thread", "messages", Access.at(1), "body"])

    assert assistant_body =~ "Needs your attention: send Sarah the answer today."
    assert assistant_body =~ "Next action: reply before 3 PM."
    refute assistant_body =~ "confidence"
    refute assistant_body =~ "score"
    refute assistant_body =~ "source_health"
    refute assistant_body =~ "model_name"
    refute assistant_body =~ "gpt-test"
  end

  test "mobile chat strips model confidence prose while preserving action copy", %{conn: conn} do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        next_step: fn _payload ->
          {:ok,
           %{
             "status" => "final",
             "assistant_message" => """
             90% confidence this matters.
             Reasoning: model saw an owed reply.
             Model score says this is urgent.
             Why now: Sarah needs the answer before today's cutoff.
             Next action: reply with the approved timing before 3 PM.
             """,
             "message_class" => "assistant_reply",
             "summary" => "Responded through production assistant runtime."
           }}
        end
      )
    )

    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-public-confidence-copy@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Please check what I should do about Sarah today."
        }
      })
      |> json_response(200)

    assistant_body = get_in(response, ["thread", "messages", Access.at(1), "body"])
    lower_body = String.downcase(assistant_body)

    assert assistant_body =~ "Why now: Sarah needs the answer before today's cutoff."
    assert assistant_body =~ "Next action: reply with the approved timing before 3 PM."
    refute lower_body =~ "90%"
    refute lower_body =~ "confidence"
    refute lower_body =~ "reasoning"
    refute lower_body =~ "model"
    refute lower_body =~ "score"
  end

  test "mobile chat exposes assistant work as user-facing summaries", %{conn: conn} do
    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(Application.get_env(:maraithon, :telegram_assistant, []),
        next_step: fn payload ->
          tool_history = Map.get(payload, :tool_history) || Map.get(payload, "tool_history") || []

          if tool_history == [] do
            {:ok,
             %{
               "status" => "tool_calls",
               "tool_calls" => [
                 %{"tool" => "list_todos", "arguments" => %{"limit" => 3}}
               ]
             }}
          else
            {:ok,
             %{
               "status" => "final",
               "assistant_message" => "I checked your open todos.",
               "message_class" => "assistant_reply",
               "summary" => "Checked the current todo list."
             }}
          end
        end
      )
    )

    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-work-summary@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "What should I work on from my todo list?"
        }
      })

    response = json_response(conn, 200)

    assert %{
             "run" => %{
               "status" => "completed",
               "work_summary" =>
                 run_work_summary = %{
                   "headline" => "Checked open work and replied",
                   "tool_calls" => [
                     %{
                       "tool" => "open_work",
                       "label" => "Open work",
                       "status" => "completed",
                       "summary" => "This check surfaced no open work."
                     }
                   ],
                   "steps" => steps
                 }
             },
             "thread" => %{
               "messages" => [
                 %{"role" => "user"},
                 %{
                   "role" => "assistant",
                   "body" => "I checked your open work.",
                   "structured_data" => assistant_structured_data,
                   "work_summary" =>
                     assistant_work_summary = %{
                       "headline" => "Checked open work and replied",
                       "tool_calls" => [
                         %{
                           "tool" => "open_work",
                           "label" => "Open work",
                           "summary" => "This check surfaced no open work."
                         }
                       ]
                     }
                 }
               ]
             }
           } = response

    assert Enum.any?(steps, &(&1["title"] == "Checked open work"))
    assert assistant_structured_data == %{}
    refute get_in(response, ["thread", "messages", Access.at(1), "body"]) =~ "todo"
    assert_no_work_summary_implementation_keys(run_work_summary)
    assert_no_work_summary_implementation_keys(assistant_work_summary)
    assert captured_telegram_events() == []
  end

  test "mobile chat executes explicit todo creation immediately", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-direct-todo@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" =>
            "Create a new todo exactly titled Confirm the app store checklist. Keep it visible."
        }
      })

    response = json_response(conn, 200)

    assert %{
             "run" => %{"status" => "completed", "message_class" => "action_result"},
             "thread" => %{
               "messages" => [
                 %{"role" => "user"},
                 %{
                   "role" => "assistant",
                   "body" => "Added to your open work: Confirm the app store checklist",
                   "linked_todo" => %{
                     "id" => todo_id,
                     "title" => "Confirm the app store checklist",
                     "summary" => "You asked Maraithon to track this as open work."
                   }
                 }
               ]
             }
           } = response

    todo = Todos.get_for_user(user_id, todo_id)

    assert todo.title == "Confirm the app store checklist"
    assert todo.summary == "You asked Maraithon to track this as open work."
    assert todo.next_action == "Confirm the app store checklist"

    visible_todo = inspect(get_in(response, ["thread", "messages", Access.at(1), "linked_todo"]))
    refute visible_todo =~ "Captured"
    refute visible_todo =~ "mobile assistant"
    assert captured_telegram_events() == []
  end

  test "mobile chat linked todo hides prompt and runtime fields", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-linked-todo-clean@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to board follow-up",
          "summary" => "A board member is waiting on the financing packet.",
          "next_action" => "Send the financing packet and confirm the next review window.",
          "source_item_id" => "gmail-thread-private-123",
          "dedupe_key" => "gmail:private-board-thread-123",
          "metadata" => %{
            "subject" => "Financing packet follow-up",
            "source_insight_id" => "insight-private-123",
            "model_rationale" => "Model score says this matters.",
            "token" => "secret-token"
          }
        }
      ])

    {:ok, _thread, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        thread,
        thread.chat_id,
        "Added to your open work: Reply to board follow-up",
        structured_data: %{
          "message_class" => "action_result",
          "linked_todo" => Todos.serialize_for_prompt(todo)
        }
      )

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    linked_todo = get_in(response, ["thread", "messages", Access.at(0), "linked_todo"])

    assert linked_todo["id"] == todo.id
    assert linked_todo["title"] == "Reply to board follow-up"
    assert linked_todo["metadata"] == %{"subject" => "Financing packet follow-up"}

    refute Map.has_key?(linked_todo, "owner_user_id")
    refute Map.has_key?(linked_todo, "source_account_id")
    refute Map.has_key?(linked_todo, "source_item_id")
    refute Map.has_key?(linked_todo, "dedupe_key")
    refute Map.has_key?(linked_todo, "attention_profile")
    refute Map.has_key?(linked_todo, "surface_quality")

    encoded = inspect(response)
    refute encoded =~ "gmail-thread-private-123"
    refute encoded =~ "gmail:private-board-thread-123"
    refute encoded =~ "insight-private-123"
    refute encoded =~ "Model score"
    refute encoded =~ "secret-token"
  end

  test "mobile chat answers safe arithmetic without an LLM", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-direct-math@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "What's 2+2?"
        }
      })

    response = json_response(conn, 200)
    run = response["run"]

    assert %{
             "run" => %{
               "status" => "completed",
               "message_class" => "assistant_reply"
             },
             "thread" => %{
               "messages" => [
                 %{"role" => "user", "body" => "What's 2+2?"},
                 %{
                   "role" => "assistant",
                   "body" => "2+2 = 4.",
                   "structured_data" =>
                     %{
                       "calculation" => %{"expression" => "2+2", "result" => "4"}
                     } = assistant_structured_data
                 }
               ]
             }
           } = response

    assert_no_message_structured_data_implementation_keys(assistant_structured_data)
    refute Map.has_key?(run, "model_tier")
    refute Map.has_key?(run, "model_name")
    refute Map.has_key?(run, "model_reasoning_effort")
    refute Map.has_key?(run, "task_class")
    refute Map.has_key?(run, "route_reason")
    assert captured_telegram_events() == []
  end

  test "mobile chat deduplicates repeated client message ids", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-dedupe@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    client_message_id = Ecto.UUID.generate()

    payload = %{
      "message" => %{
        "client_message_id" => client_message_id,
        "body" => "Please process once"
      }
    }

    build_mobile_conn(user_id)
    |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", payload)
    |> json_response(200)

    build_mobile_conn(user_id)
    |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", payload)
    |> json_response(200)

    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)
    user_turns = Enum.filter(thread.turns, &(&1.role == "user"))

    assert length(user_turns) == 1
    assert hd(user_turns).client_message_id == client_message_id
  end

  test "mobile chat rejects cross-user thread access", %{conn: conn} do
    {conn, _user_id} = authenticated_mobile_conn(conn, "owner@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    {_other_conn, other_user_id} = authenticated_mobile_conn(build_conn(), "other@example.com")

    conn =
      build_mobile_conn(other_user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")

    assert %{
             "error" => "not_found",
             "message" =>
               "That conversation is no longer available. Refresh conversations to see current threads."
           } = json_response(conn, 404)
  end

  test "mobile chat thread titles are display-ready for assistant-only threads", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-assistant-title@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    thread
    |> Ecto.Changeset.change(
      summary:
        "assistant: The customer escalation needs a same-day reply.\n" <>
          "assistant: Draft the reply before 2 PM."
    )
    |> Repo.update!()

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads")
      |> json_response(200)

    thread_json = Enum.find(response["threads"], &(&1["id"] == thread_id))

    assert %{"title" => title} = thread_json
    assert title == "The customer escalation needs a same-day reply. Draft the reply before 2 PM."
    refute title =~ "assistant:"
  end

  test "mobile chat assistant message bodies are display-ready", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-assistant-body@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, _thread, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        thread,
        thread.chat_id,
        "assistant: The customer escalation needs a same-day reply.\n" <>
          "Maraithon: Draft the reply before 2 PM."
      )

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert [%{"role" => "assistant", "body" => body}] = get_in(response, ["thread", "messages"])
    assert body == "The customer escalation needs a same-day reply.\nDraft the reply before 2 PM."
    refute body =~ "assistant:"
    refute body =~ "Maraithon:"

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads")
      |> json_response(200)

    thread_json = Enum.find(response["threads"], &(&1["id"] == thread_id))
    assert get_in(thread_json, ["latest_message", "body"]) == body
  end

  test "mobile chat assistant message bodies hide technical failure details", %{conn: conn} do
    {conn, user_id} =
      authenticated_mobile_conn(conn, "mobile-chat-assistant-body-error@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, _thread, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        thread,
        thread.chat_id,
        "RuntimeError stacktrace http_status: 500 token=secret"
      )

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert [%{"role" => "assistant", "body" => body}] = get_in(response, ["thread", "messages"])

    assert body ==
             "Maraithon saved the request and avoided sending an unverified answer."

    visible_response = inspect(response)
    refute body =~ "Ask for"
    refute visible_response =~ "RuntimeError"
    refute visible_response =~ "stacktrace"
    refute visible_response =~ "http_status"
    refute visible_response =~ "token=secret"
  end

  test "mobile chat assistant message bodies hide briefing generation internals", %{conn: conn} do
    {conn, user_id} =
      authenticated_mobile_conn(conn, "mobile-chat-assistant-briefing-error@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, _thread, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        thread,
        thread.chat_id,
        """
        Morning briefing generation failed.
        The configured model did not produce a valid brief.
        Morning briefing model synthesis failed.
        Try the checked source view instead.
        """
      )

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert [%{"role" => "assistant", "body" => body}] = get_in(response, ["thread", "messages"])

    assert body ==
             "Maraithon saved the request and avoided sending an unverified answer."

    visible_response = inspect(response)
    refute visible_response =~ "generation failed"
    refute visible_response =~ "configured model"
    refute visible_response =~ "model synthesis"
    refute visible_response =~ "checked source view"
  end

  test "mobile chat renames a thread and keeps the manual title", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-rename@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> patch(~p"/api/mobile/chat/threads/#{thread_id}", %{
        "thread" => %{"title" => "  CEO   briefing follow-up  "}
      })
      |> json_response(200)

    assert get_in(response, ["thread", "title"]) == "CEO briefing follow-up"

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Hey"
        }
      })
      |> json_response(200)

    assert get_in(response, ["thread", "title"]) == "CEO briefing follow-up"

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert get_in(response, ["thread", "title"]) == "CEO briefing follow-up"
  end

  test "mobile chat returns display-ready copy for blank thread rename", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-blank-rename@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> patch(~p"/api/mobile/chat/threads/#{thread_id}", %{"thread" => %{"title" => "   "}})
      |> json_response(422)

    assert %{
             "error" => "empty_thread_title",
             "message" => "Enter a chat name before saving."
           } = response
  end

  test "mobile chat validation errors are display-ready", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-validation@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    conn =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => String.duplicate("a", 16_385)
        }
      })

    assert %{
             "error" => "message_too_long",
             "message" => "Message is too long. Send a shorter note."
           } = json_response(conn, 422)
  end

  test "mobile chat deletes messages on the server so refresh does not restore them", %{
    conn: conn
  } do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-delete@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/threads/#{thread_id}/messages", %{
        "message" => %{
          "client_message_id" => Ecto.UUID.generate(),
          "body" => "Hey"
        }
      })
      |> json_response(200)

    [user_message, assistant_message] = get_in(response, ["thread", "messages"])

    response =
      build_mobile_conn(user_id)
      |> delete(~p"/api/mobile/chat/threads/#{thread_id}/messages/#{assistant_message["id"]}")
      |> json_response(200)

    assert get_in(response, ["thread", "messages"]) == [user_message]
    assert Repo.get(Turn, assistant_message["id"]) == nil

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert get_in(response, ["thread", "messages"]) == [user_message]
  end

  test "mobile chat returns display-ready copy for missing message delete", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-delete-missing@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate(), "title" => "New conversation"}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]

    response =
      build_mobile_conn(user_id)
      |> delete(~p"/api/mobile/chat/threads/#{thread_id}/messages/#{Ecto.UUID.generate()}")
      |> json_response(404)

    assert %{
             "error" => "message_not_found",
             "message" =>
               "That message is no longer available. Refresh the conversation before continuing."
           } = response
  end

  test "mobile chat run payload hides raw failure details", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-chat-run-error@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        surface: "mobile",
        trigger_type: "inbound_message",
        status: "failed",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{},
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now(),
        error: "http_status: 500 internal_stacktrace db_timeout token=secret"
      })

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/runs/#{run.id}")
      |> json_response(200)

    assert get_in(response, ["run", "status"]) == "failed"

    public_error = get_in(response, ["run", "error"])

    assert public_error ==
             "Maraithon saved the request and avoided sending an unverified answer."

    encoded = inspect(response)
    refute public_error =~ "refresh"
    refute public_error =~ "500"
    refute encoded =~ "internal_stacktrace"
    refute encoded =~ "db_timeout"
    refute encoded =~ "token=secret"
  end

  test "mobile chat exposes pending prepared actions and hides them after decision", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-actions@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        surface: "mobile",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{"message_class" => "approval_prompt"},
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    {:ok, prepared_action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        run_id: run.id,
        surface: "mobile",
        action_type: "create_todo",
        target_type: "todo",
        payload: %{"title" => "Confirm me"},
        preview_text: "Create todo: Confirm me",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    {:ok, _thread, _turn, _result} =
      Maraithon.AssistantChat.MobileDelivery.deliver_turn(
        thread,
        thread.chat_id,
        "Create todo: Confirm me?",
        turn_kind: "approval_prompt",
        origin_type: "prepared_action",
        origin_id: prepared_action.id,
        structured_data: %{
          "prepared_action_id" => prepared_action.id,
          "message_class" => "approval_prompt",
          "run_id" => run.id
        }
      )

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert [
             %{"decision" => "confirm"},
             %{"decision" => "reject"}
           ] = get_in(response, ["thread", "messages", Access.at(0), "actions"])

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/prepared-actions/#{prepared_action.id}/decision", %{
        "decision" => "reject",
        "client_message_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert get_in(response, ["prepared_action", "status"]) == "rejected"

    response =
      build_mobile_conn(user_id)
      |> get(~p"/api/mobile/chat/threads/#{thread_id}")
      |> json_response(200)

    assert [] = get_in(response, ["thread", "messages", Access.at(0), "actions"])
  end

  test "mobile prepared action failure copy hides internal reason", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-action-failure@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        surface: "mobile",
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
      TelegramAssistant.create_prepared_action(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        run_id: run.id,
        surface: "mobile",
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

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/prepared-actions/#{prepared_action.id}/decision", %{
        "decision" => "confirm",
        "client_message_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert get_in(response, ["prepared_action", "status"]) == "failed"

    message = response |> get_in(["thread", "messages"]) |> List.last()

    assert message["body"] ==
             "Maraithon could not update the project. " <>
               "The project it referenced is no longer available."

    refute message["body"] =~ "I could not"
    refute message["body"] =~ ":project_not_found"
    refute message["body"] =~ "project_not_found"
    assert message["structured_data"] == %{}
  end

  test "mobile Gmail send failure copy names the action accurately", %{conn: conn} do
    {conn, user_id} = authenticated_mobile_conn(conn, "mobile-gmail-action-failure@example.com")

    conn =
      post(conn, ~p"/api/mobile/chat/threads", %{
        "thread" => %{"client_thread_id" => Ecto.UUID.generate()}
      })

    thread_id = json_response(conn, 201)["thread"]["id"]
    thread = TelegramConversations.get_mobile_thread(user_id, thread_id)

    {:ok, run} =
      TelegramAssistant.start_run(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        surface: "mobile",
        trigger_type: "inbound_message",
        status: "completed",
        model_provider: "test",
        model_name: "test",
        prompt_snapshot: %{},
        result_summary: %{"message_class" => "approval_prompt"},
        started_at: DateTime.utc_now(),
        finished_at: DateTime.utc_now()
      })

    {:ok, prepared_action} =
      TelegramAssistant.create_prepared_action(%{
        user_id: user_id,
        chat_id: thread.chat_id,
        conversation_id: thread.id,
        run_id: run.id,
        surface: "mobile",
        action_type: "gmail_send",
        target_type: "gmail_thread",
        target_id: "thread-123",
        payload: %{
          "user_id" => user_id,
          "to" => "ops@example.com",
          "subject" => "Quick update",
          "body" => "Sending the update."
        },
        preview_text: "Send Gmail message to ops@example.com with subject \"Quick update\".",
        status: "awaiting_confirmation",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })

    response =
      build_mobile_conn(user_id)
      |> post(~p"/api/mobile/chat/prepared-actions/#{prepared_action.id}/decision", %{
        "decision" => "confirm",
        "client_message_id" => Ecto.UUID.generate()
      })
      |> json_response(200)

    assert get_in(response, ["prepared_action", "status"]) == "failed"

    message = response |> get_in(["thread", "messages"]) |> List.last()

    assert message["body"] ==
             "Maraithon could not send the Gmail message. Gmail is not connected."

    refute message["body"] =~ "I could not"
    refute message["body"] =~ "Gmail draft"
    refute message["body"] =~ "thread-123"
  end

  defp authenticated_mobile_conn(conn, email \\ "mobile-chat@example.com") do
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")

    {conn, user.id}
  end

  defp build_mobile_conn(user_id) do
    user = Accounts.get_user(user_id)
    {:ok, %{token: token}} = Accounts.create_session_for_user(user)

    build_conn()
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp assert_no_work_summary_implementation_keys(summary) do
    refute Map.has_key?(summary, "model_name")
    refute Map.has_key?(summary, "model_tier")
    refute Map.has_key?(summary, "model_reasoning_effort")
    refute Map.has_key?(summary, "task_class")
    refute Map.has_key?(summary, "route_reason")
    refute Map.has_key?(summary, "llm_turns")
    refute Map.has_key?(summary, "tool_steps")

    visible_payload = inspect(summary)
    refute visible_payload =~ "list_todos"
    refute visible_payload =~ "llm"
    refute visible_payload =~ "model_"
  end

  defp assert_no_message_structured_data_implementation_keys(structured_data) do
    refute Map.has_key?(structured_data, "direct_intent")
    refute Map.has_key?(structured_data, "fast_chat_kind")
    refute Map.has_key?(structured_data, "tool_history")
    refute Map.has_key?(structured_data, "surface")
    refute Map.has_key?(structured_data, "client_message_id")
    refute Map.has_key?(structured_data, "run_id")
    refute Map.has_key?(structured_data, "message_class")
    refute Map.has_key?(structured_data, "prepared_action_id")
  end

  defp captured_telegram_events do
    Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
  end
end
