defmodule MaraithonWeb.MobileChatControllerTest do
  use MaraithonWeb.ConnCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.TestSupport.CapturingTelegram
  alias Maraithon.TestSupport.TelegramAssistantClientStub
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramConversations
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
                   "body" => "Hey - I'm here.",
                   "run_id" => run_id,
                   "structured_data" => %{
                     "direct_intent" => "fast_chat_reply",
                     "fast_chat_kind" => "greeting"
                   }
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
                   "run_id" => run_id
                 }
               ]
             },
             "run" => %{"status" => "completed", "id" => response_run_id}
           } = response

    assert response_run_id == run_id
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
                   "body" => "Added: Confirm the app store checklist",
                   "linked_todo" => %{
                     "id" => todo_id,
                     "title" => "Confirm the app store checklist"
                   }
                 }
               ]
             }
           } = response

    assert Todos.get_for_user(user_id, todo_id).title == "Confirm the app store checklist"
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

    assert %{"error" => "not_found"} = json_response(conn, 404)
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

  defp captured_telegram_events do
    Agent.get(:capturing_telegram_recorder, &Enum.reverse/1)
  end
end
