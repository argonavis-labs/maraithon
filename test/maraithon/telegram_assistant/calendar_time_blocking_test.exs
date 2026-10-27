defmodule Maraithon.TelegramAssistant.CalendarTimeBlockingTest do
  @moduledoc """
  SPEC 12 execute-path coverage: confirm -> execute of
  calendar_create_event / calendar_cancel_event prepared actions, including
  the double-booking recheck (R10), the ownership markers + todo metadata
  stamp (R8/R9), and the scope-required failure that must NOT corrupt the
  connected account's read-side health (R6).
  """

  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.OAuth
  alias Maraithon.Repo
  alias Maraithon.TelegramAssistant
  alias Maraithon.TelegramAssistant.{PreparedAction, Toolbox}
  alias Maraithon.TelegramConversations
  alias Maraithon.Todos

  setup do
    original_assistant = Application.get_env(:maraithon, :telegram_assistant, [])
    original_calendar = Application.get_env(:maraithon, :google_calendar, [])

    Application.put_env(
      :maraithon,
      :telegram_assistant,
      Keyword.merge(original_assistant,
        telegram_full_chat_enabled: true,
        telegram_assistant_write_tools_enabled: true
      )
    )

    bypass = Bypass.open()

    Application.put_env(:maraithon, :google_calendar,
      api_base_url: "http://localhost:#{bypass.port}/calendar/v3"
    )

    on_exit(fn ->
      Application.put_env(:maraithon, :telegram_assistant, original_assistant)
      Application.put_env(:maraithon, :google_calendar, original_calendar)
    end)

    user_id = "calendar-blocking-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, _token} =
      OAuth.store_tokens(user_id, "google", %{
        access_token: "test_access_token",
        refresh_token: "test_refresh_token",
        expires_in: 3600,
        scopes: ["https://www.googleapis.com/auth/calendar.readonly"]
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "telegram",
          "title" => "Hyatt prep before Thursday",
          "summary" => "Prepare the Hyatt materials before the Thursday meeting.",
          "next_action" => "Assemble the Hyatt prep packet.",
          "due_at" => DateTime.add(DateTime.utc_now(), 3, :day),
          "dedupe_key" => "calendar-blocking:hyatt-#{System.unique_integer([:positive])}"
        }
      ])

    {:ok, bypass: bypass, user_id: user_id, todo: todo}
  end

  defp run_context(user_id) do
    {:ok, conversation} =
      TelegramConversations.start_or_continue(user_id, "12345", %{
        "root_message_id" => "calendar-blocking-root"
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

  defp prepare_create_action(user_id, payload) do
    {:ok, result} =
      Toolbox.execute(
        "prepare_external_action",
        %{"action_type" => "calendar_create_event", "payload" => payload},
        run_context(user_id)
      )

    Repo.get!(PreparedAction, result.prepared_action_id)
  end

  defp prepare_cancel_action(user_id, payload) do
    {:ok, result} =
      Toolbox.execute(
        "prepare_external_action",
        %{"action_type" => "calendar_cancel_event", "payload" => payload},
        run_context(user_id)
      )

    Repo.get!(PreparedAction, result.prepared_action_id)
  end

  defp future_window do
    start_at =
      DateTime.utc_now()
      |> DateTime.add(2, :day)
      |> DateTime.truncate(:second)

    {DateTime.to_iso8601(start_at), DateTime.to_iso8601(DateTime.add(start_at, 45, :minute))}
  end

  defp expected_client_id(prepared_action_id) do
    :crypto.hash(:sha256, "calendar_create_event:" <> prepared_action_id)
    |> Base.hex_encode32(case: :lower, padding: false)
  end

  defp expect_free_slot_read(bypass) do
    Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"items" => []}))
    end)
  end

  test "confirmed create books the event with ownership markers and stamps the todo", %{
    bypass: bypass,
    user_id: user_id,
    todo: todo
  } do
    {start_at, end_at} = future_window()

    prepared_action =
      prepare_create_action(user_id, %{
        "title" => "Hyatt prep",
        "start_at" => start_at,
        "end_at" => end_at,
        "timezone" => "America/New_York",
        "todo_id" => todo.id
      })

    client_event_id = expected_client_id(prepared_action.id)
    expect_free_slot_read(bypass)
    parent = self()

    Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)
      send(parent, {:create_body, params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => params["id"],
          "summary" => params["summary"],
          "status" => "confirmed",
          "start" => params["start"],
          "end" => params["end"],
          "htmlLink" => "https://calendar.google.com/event/#{params["id"]}",
          "organizer" => %{"email" => user_id}
        })
      )
    end)

    assert {:ok, executed_action, result} = TelegramAssistant.confirm_and_execute(prepared_action)
    assert executed_action.status == "executed"
    assert result["message"] == "Booked the block on your calendar."

    # R7/R8: the outgoing request carried the deterministic client id and
    # the ownership markers.
    assert_receive {:create_body, params}
    assert params["id"] == client_event_id
    assert params["start"]["timeZone"] == "America/New_York"

    assert params["extendedProperties"]["private"] == %{
             "maraithon_managed" => "true",
             "maraithon_todo_id" => todo.id,
             "maraithon_client_key" => client_event_id
           }

    # R9: the linked todo now points at the created event.
    refreshed = Todos.get_for_user(user_id, todo.id)
    block = refreshed.metadata["calendar_block"]
    assert block["event_id"] == client_event_id
    assert block["calendar_id"] == "primary"
    assert block["start_at"] == params["start"]["dateTime"]
    assert is_binary(block["created_at"])
  end

  test "a slot that filled during the confirmation window fails honestly without creating", %{
    bypass: bypass,
    user_id: user_id,
    todo: todo
  } do
    {start_at, end_at} = future_window()

    prepared_action =
      prepare_create_action(user_id, %{
        "title" => "Hyatt prep",
        "start_at" => start_at,
        "end_at" => end_at,
        "timezone" => "America/New_York",
        "todo_id" => todo.id
      })

    # R10: the fresh recheck finds a newly landed overlapping event. No POST
    # expectation exists — creating anyway would fail this test.
    Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "items" => [
            %{
              "id" => "landed-meeting",
              "summary" => "Landed meeting",
              "start" => %{"dateTime" => start_at},
              "end" => %{"dateTime" => end_at},
              "organizer" => %{"email" => user_id}
            }
          ]
        })
      )
    end)

    assert {:error, failed_action, "slot_no_longer_free", :permanent_failure} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert failed_action.status == "failed"
    assert failed_action.error == "slot_no_longer_free"

    # No phantom pointer on the todo.
    refreshed = Todos.get_for_user(user_id, todo.id)
    assert Map.get(refreshed.metadata || %{}, "calendar_block") == nil
  end

  test "an all-day event does not block the slot", %{
    bypass: bypass,
    user_id: user_id,
    todo: todo
  } do
    {start_at, end_at} = future_window()

    prepared_action =
      prepare_create_action(user_id, %{
        "title" => "Hyatt prep",
        "start_at" => start_at,
        "end_at" => end_at,
        "timezone" => "America/New_York",
        "todo_id" => todo.id
      })

    Bypass.expect(bypass, "GET", "/calendar/v3/calendars/primary/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "items" => [
            %{
              "id" => "all-day-holiday",
              "summary" => "Company holiday",
              "start" => %{"date" => String.slice(start_at, 0, 10)},
              "end" => %{"date" => String.slice(end_at, 0, 10)},
              "organizer" => %{"email" => user_id}
            }
          ]
        })
      )
    end)

    Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = Jason.decode!(body)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => params["id"],
          "summary" => params["summary"],
          "start" => params["start"],
          "end" => params["end"],
          "organizer" => %{"email" => user_id}
        })
      )
    end)

    assert {:ok, executed_action, _result} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert executed_action.status == "executed"
  end

  test "a start time that already passed fails without any calendar call", %{
    user_id: user_id,
    todo: todo
  } do
    past_start = DateTime.utc_now() |> DateTime.add(-30, :minute)
    past_end = DateTime.add(past_start, 45, :minute)

    prepared_action =
      prepare_create_action(user_id, %{
        "title" => "Hyatt prep",
        "start_at" => DateTime.to_iso8601(past_start),
        "end_at" => DateTime.to_iso8601(past_end),
        "timezone" => "America/New_York",
        "todo_id" => todo.id
      })

    # No Bypass expectations: any HTTP call would fail the test.
    assert {:error, failed_action, "calendar_block_start_passed", :permanent_failure} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert failed_action.status == "failed"
  end

  test "an insufficient-scope 403 fails the action with reconnect copy and never flips account health",
       %{bypass: bypass, user_id: user_id, todo: todo} do
    account_before = ConnectedAccounts.get(user_id, "google")
    assert account_before.status == "connected"

    {start_at, end_at} = future_window()

    prepared_action =
      prepare_create_action(user_id, %{
        "title" => "Hyatt prep",
        "start_at" => start_at,
        "end_at" => end_at,
        "timezone" => "America/New_York",
        "todo_id" => todo.id
      })

    expect_free_slot_read(bypass)

    Bypass.expect_once(bypass, "POST", "/calendar/v3/calendars/primary/events", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        403,
        Jason.encode!(%{
          "error" => %{
            "code" => 403,
            "message" => "Request had insufficient authentication scopes.",
            "status" => "PERMISSION_DENIED"
          }
        })
      )
    end)

    assert {:error, failed_action, "calendar_write_scope_required", :permanent_failure} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert failed_action.status == "failed"
    assert failed_action.error == "calendar_write_scope_required"

    # R6: the user-facing failure copy carries the reconnect link.
    copy =
      Maraithon.TelegramAssistant.ActionFailureCopy.calendar_action(
        "calendar_write_scope_required"
      )

    assert copy =~ ConnectedAccounts.reconnect_url("google")

    # The sharpest trap in SPEC 12: a missing WRITE scope must not mark the
    # whole account broken — reads/sync/watch still work with readonly.
    account_after = ConnectedAccounts.get(user_id, "google")
    assert account_after.status == "connected"
    refute get_in(account_after.metadata || %{}, ["last_error"])
  end

  test "cancelling a Maraithon-managed block deletes it and clears the todo pointer", %{
    bypass: bypass,
    user_id: user_id,
    todo: todo
  } do
    event_id = "abc123maraithonblock"

    {:ok, _todo} =
      Todos.record_calendar_block(user_id, todo.id, %{
        "event_id" => event_id,
        "calendar_id" => "primary",
        "start_at" => "2026-07-09T14:00:00Z",
        "end_at" => "2026-07-09T14:45:00Z",
        "created_at" => "2026-07-04T00:00:00Z"
      })

    prepared_action =
      prepare_cancel_action(user_id, %{
        "event_id" => event_id,
        "todo_id" => todo.id,
        "title" => "Hyatt prep"
      })

    # R8: ownership verification GET happens before the DELETE.
    Bypass.expect_once(
      bypass,
      "GET",
      "/calendar/v3/calendars/primary/events/#{event_id}",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => event_id,
            "summary" => "Hyatt prep",
            "start" => %{"dateTime" => "2026-07-09T14:00:00Z"},
            "end" => %{"dateTime" => "2026-07-09T14:45:00Z"},
            "organizer" => %{"email" => user_id},
            "extendedProperties" => %{
              "private" => %{
                "maraithon_managed" => "true",
                "maraithon_todo_id" => todo.id,
                "maraithon_client_key" => event_id
              }
            }
          })
        )
      end
    )

    Bypass.expect_once(
      bypass,
      "DELETE",
      "/calendar/v3/calendars/primary/events/#{event_id}",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end
    )

    assert {:ok, executed_action, _result} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert executed_action.status == "executed"

    refreshed = Todos.get_for_user(user_id, todo.id)
    assert Map.get(refreshed.metadata || %{}, "calendar_block") == nil
  end

  test "cancelling an already-deleted block is a successful no-op", %{
    bypass: bypass,
    user_id: user_id,
    todo: todo
  } do
    event_id = "gonemaraithonblock1"

    prepared_action =
      prepare_cancel_action(user_id, %{"event_id" => event_id, "todo_id" => todo.id})

    Bypass.expect_once(
      bypass,
      "GET",
      "/calendar/v3/calendars/primary/events/#{event_id}",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(410, Jason.encode!(%{"error" => %{"code" => 410}}))
      end
    )

    assert {:ok, executed_action, result} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert executed_action.status == "executed"
    assert result["already_gone"] == true
  end

  test "cancel refuses to touch an event without Maraithon's ownership marker", %{
    bypass: bypass,
    user_id: user_id
  } do
    event_id = "someoneelsesevent99"

    prepared_action = prepare_cancel_action(user_id, %{"event_id" => event_id})

    # R8/R11: the GET shows no maraithon_managed marker; no DELETE
    # expectation exists — deleting anyway would fail this test.
    Bypass.expect_once(
      bypass,
      "GET",
      "/calendar/v3/calendars/primary/events/#{event_id}",
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "id" => event_id,
            "summary" => "User's own dentist appointment",
            "start" => %{"dateTime" => "2026-07-09T14:00:00Z"},
            "end" => %{"dateTime" => "2026-07-09T14:45:00Z"},
            "organizer" => %{"email" => user_id}
          })
        )
      end
    )

    assert {:error, failed_action, "calendar_event_not_managed", :permanent_failure} =
             TelegramAssistant.confirm_and_execute(prepared_action)

    assert failed_action.status == "failed"
  end
end
