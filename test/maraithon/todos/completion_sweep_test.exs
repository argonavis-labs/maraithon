defmodule Maraithon.Todos.CompletionSweepTest do
  use Maraithon.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maraithon.Accounts
  alias Maraithon.LocalMessages
  alias Maraithon.LocalReminders
  alias Maraithon.OAuth
  alias Maraithon.Todos
  alias Maraithon.Todos.CompletionSweep

  defp unique_user! do
    user_id = "completion-sweep-#{Ecto.UUID.generate()}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    user_id
  end

  defp iso(%DateTime{} = datetime), do: DateTime.to_iso8601(DateTime.truncate(datetime, :second))

  defp todo_attrs(source, source_item_id, title, source_occurred_at, overrides) do
    metadata = Keyword.get(overrides, :metadata, %{})

    %{
      "source" => source,
      "kind" => "general",
      "title" => title,
      "summary" => "This open item still needs a source-backed resolution.",
      "next_action" => "Review the source and close the loop.",
      "source_item_id" => source_item_id,
      "source_occurred_at" => iso(source_occurred_at),
      "dedupe_key" => "#{source}:#{source_item_id}:#{System.unique_integer([:positive])}",
      "metadata" => metadata
    }
  end

  test "marks a Gmail todo done when the same thread has a later self-sent reply" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)
    reply_at = DateTime.add(now, -900, :second)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "thread-1", "Reply owed: launch follow-up", source_at,
          metadata: %{
            "thread_id" => "thread-1",
            "google_account_email" => user_id
          }
        )
      ])

    gmail_fetcher = fn ^user_id, fetched_todo ->
      assert fetched_todo.id == todo.id

      {:ok, "google:#{user_id}", "thread-1",
       [
         %{
           message_id: "incoming-1",
           from: "Customer <customer@example.com>",
           internal_date: source_at,
           subject: "Launch follow-up"
         },
         %{
           message_id: "reply-1",
           from: "Kent <#{user_id}>",
           internal_date: reply_at,
           subject: "Re: Launch follow-up"
         }
       ]}
    end

    summary =
      CompletionSweep.run_for_user(user_id,
        now: now,
        gmail_fetcher: gmail_fetcher,
        self_emails: [user_id]
      )

    assert summary.completed == 1
    assert summary.completed_by_source == %{"gmail" => 1}
    assert summary.completed_by_reason == %{"gmail_self_reply" => 1}

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "done"
    assert updated.closed_at
    assert updated.metadata["resolution_note"] =~ "Scheduled completion sweep"
    assert updated.metadata["resolution_note"] =~ "Sent Gmail reply reply-1"
  end

  test "leaves Gmail todos open when self-sent messages predate the source" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)
    earlier_reply_at = DateTime.add(now, -7_200, :second)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "thread-2", "Reply owed: pricing follow-up", source_at,
          metadata: %{"thread_id" => "thread-2", "google_account_email" => user_id}
        )
      ])

    gmail_fetcher = fn ^user_id, _todo ->
      {:ok, "google:#{user_id}", "thread-2",
       [
         %{
           message_id: "old-reply",
           from: "Kent <#{user_id}>",
           internal_date: earlier_reply_at,
           subject: "Re: Pricing"
         }
       ]}
    end

    summary =
      CompletionSweep.run_for_user(user_id,
        now: now,
        gmail_fetcher: gmail_fetcher,
        self_emails: [user_id]
      )

    assert summary.completed == 0
    assert Todos.get_for_user(user_id, todo.id).status == "open"
  end

  test "scopes Gmail misses to the known account and skips malformed legacy ids" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)
    bypass = Bypass.open()
    original_gmail_config = Application.get_env(:maraithon, :gmail, [])

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    on_exit(fn -> Application.put_env(:maraithon, :gmail, original_gmail_config) end)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:a-personal@example.com", %{
               access_token: "personal-token",
               refresh_token: "personal-refresh",
               expires_in: 3_600,
               scopes: ["gmail.readonly"]
             })

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google:z-work@example.com", %{
               access_token: "work-token",
               refresh_token: "work-refresh",
               expires_in: 3_600,
               scopes: ["gmail.readonly"]
             })

    {:ok, [_scoped, _malformed]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "abc123", "Scoped Gmail miss", source_at,
          metadata: %{
            "thread_id" => "abc123",
            "google_account_email" => "z-work@example.com"
          }
        ),
        todo_attrs("gmail", "gmail:synthetic-reference", "Malformed Gmail reference", source_at,
          metadata: %{}
        )
      ])

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/threads/abc123", fn conn ->
      assert ["Bearer work-token"] == Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.resp(conn, 404, "Not Found")
    end)

    log =
      capture_log(fn ->
        summary = CompletionSweep.run_for_user(user_id, now: now)
        assert summary.checked == 2
        assert summary.completed == 0
        assert summary.fetch_errors == 0
      end)

    refute log =~ "HTTP request failed"
  end

  test "continues unscoped Gmail fan-out after one mailbox has an operational error" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)
    reply_at = DateTime.add(now, -900, :second)
    bypass = Bypass.open()
    original_gmail_config = Application.get_env(:maraithon, :gmail, [])

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    on_exit(fn -> Application.put_env(:maraithon, :gmail, original_gmail_config) end)

    for {provider, token} <- [
          {"google:a-first@example.com", "first-token"},
          {"google:z-second@example.com", "second-token"}
        ] do
      assert {:ok, _token} =
               OAuth.store_tokens(user_id, provider, %{
                 access_token: token,
                 refresh_token: "#{token}-refresh",
                 expires_in: 3_600,
                 scopes: ["gmail.readonly"]
               })
    end

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "abc123", "Unscoped Gmail item", source_at,
          metadata: %{"gmail_message_id" => "abc123"}
        )
      ])

    Bypass.expect(bypass, "GET", "/gmail/v1/users/me/messages/abc123", fn conn ->
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer first-token"] ->
          Plug.Conn.resp(conn, 401, "Reauthorization required")

        ["Bearer second-token"] ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{
              "id" => "abc123",
              "threadId" => "def456",
              "internalDate" => Integer.to_string(DateTime.to_unix(source_at, :millisecond)),
              "payload" => %{"headers" => []}
            })
          )
      end
    end)

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/threads/def456", fn conn ->
      assert ["Bearer second-token"] == Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "messages" => [
            %{
              "id" => "fed654",
              "threadId" => "def456",
              "internalDate" => Integer.to_string(DateTime.to_unix(reply_at, :millisecond)),
              "payload" => %{
                "headers" => [
                  %{"name" => "From", "value" => "Kent <#{user_id}>"},
                  %{"name" => "Subject", "value" => "Re: Unscoped Gmail item"}
                ]
              }
            }
          ]
        })
      )
    end)

    summary = CompletionSweep.run_for_user(user_id, now: now)

    assert summary.checked == 1
    assert summary.completed == 1
    assert summary.fetch_errors == 0
  end

  test "treats generic google provenance as a family hint when an account email is present" do
    user_id = unique_user!()
    account_email = "legacy-mailbox@example.com"
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)
    reply_at = DateTime.add(now, -900, :second)
    bypass = Bypass.open()
    original_gmail_config = Application.get_env(:maraithon, :gmail, [])

    Application.put_env(:maraithon, :gmail,
      api_base_url: "http://localhost:#{bypass.port}/gmail/v1"
    )

    on_exit(fn -> Application.put_env(:maraithon, :gmail, original_gmail_config) end)

    assert {:ok, _token} =
             OAuth.store_tokens(user_id, "google", %{
               access_token: "legacy-token",
               refresh_token: "legacy-refresh",
               expires_in: 3_600,
               scopes: ["gmail.readonly"],
               metadata: %{"account_email" => account_email}
             })

    {:ok, [_todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "abc123", "Legacy generic Gmail item", source_at,
          metadata: %{
            "thread_id" => "abc123",
            "google_provider" => "google",
            "google_account_email" => account_email
          }
        )
      ])

    Bypass.expect_once(bypass, "GET", "/gmail/v1/users/me/threads/abc123", fn conn ->
      assert ["Bearer legacy-token"] == Plug.Conn.get_req_header(conn, "authorization")

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "messages" => [
            %{
              "id" => "def456",
              "threadId" => "abc123",
              "internalDate" => Integer.to_string(DateTime.to_unix(reply_at, :millisecond)),
              "payload" => %{
                "headers" => [
                  %{"name" => "From", "value" => "Legacy <#{account_email}>"},
                  %{"name" => "Subject", "value" => "Re: Legacy generic Gmail item"}
                ]
              }
            }
          ]
        })
      )
    end)

    summary = CompletionSweep.run_for_user(user_id, now: now)
    assert summary.checked == 1
    assert summary.completed == 1
    assert summary.fetch_errors == 0
  end

  test "aggregates unavailable-provider failures once per user" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    source_at = DateTime.add(now, -3_600, :second)

    {:ok, [_first, _second]} =
      Todos.upsert_many(user_id, [
        todo_attrs("gmail", "aa11", "First unavailable Gmail item", source_at,
          metadata: %{"gmail_message_id" => "aa11"}
        ),
        todo_attrs("gmail", "bb22", "Second unavailable Gmail item", source_at,
          metadata: %{"gmail_message_id" => "bb22"}
        )
      ])

    log =
      capture_log(fn ->
        summary = CompletionSweep.run_for_user(user_id, now: now)
        assert summary.fetch_errors == 2
        assert summary.completed == 0
      end)

    assert length(Regex.scan(~r/Todo completion sweep could not verify Gmail items/, log)) == 1
    assert log =~ "(2 todos)"
  end

  test "marks a cold-thread todo done when there is a newer outgoing local message" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    device_id = Ecto.UUID.generate()
    chat_key = "any;+;chat123"
    source_at = DateTime.add(now, -4 * 3_600, :second)
    reply_at = DateTime.add(now, -3_600, :second)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("local_patterns", chat_key, "Check in with Sam", source_at,
          metadata: %{"detector" => "cold_thread", "chat_key" => chat_key}
        )
      ])

    {:ok, _result} =
      LocalMessages.ingest_batch(user_id, device_id, [
        %{
          "guid" => "local-reply-1",
          "chat_key" => chat_key,
          "chat_display_name" => "Sam",
          "is_from_me" => true,
          "text" => "Following up here.",
          "sent_at" => iso(reply_at)
        }
      ])

    summary = CompletionSweep.run_for_user(user_id, now: now, gmail_fetcher: no_gmail_fetcher())

    assert summary.completed == 1
    assert summary.completed_by_reason == %{"local_message_reply" => 1}

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "done"
    assert updated.metadata["resolution_note"] =~ "Newer outgoing local message"
  end

  test "marks a dropped-commitment todo done when the backing reminder is completed" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    device_id = Ecto.UUID.generate()
    reminder_guid = "reminder-guid-1"
    source_at = DateTime.add(now, -2 * 86_400, :second)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        todo_attrs("local_patterns", reminder_guid, "Dropped commitment: Send invoice", source_at,
          metadata: %{"detector" => "dropped_commitment", "reminder_guid" => reminder_guid}
        )
      ])

    {:ok, _result} =
      LocalReminders.ingest_batch(user_id, device_id, [
        %{
          "guid" => reminder_guid,
          "title" => "Send invoice",
          "due_at" => iso(source_at),
          "is_completed" => true,
          "completed_at" => iso(DateTime.add(now, -1_800, :second))
        }
      ])

    summary = CompletionSweep.run_for_user(user_id, now: now, gmail_fetcher: no_gmail_fetcher())

    assert summary.completed == 1
    assert summary.completed_by_reason == %{"completed_local_reminder" => 1}

    updated = Todos.get_for_user(user_id, todo.id)
    assert updated.status == "done"
    assert updated.metadata["resolution_note"] =~ "Backing local reminder"
  end

  test "marks only calendar conflicts older than the 24 hour grace window done" do
    user_id = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]
    expired_at = DateTime.add(now, -25 * 3_600, :second)
    recent_at = DateTime.add(now, -23 * 3_600, :second)

    {:ok, [expired, recent]} =
      Todos.upsert_many(user_id, [
        todo_attrs(
          "local_patterns",
          "event-a|event-b",
          "Calendar conflict today: A vs B",
          expired_at,
          metadata: %{"detector" => "calendar_conflict"}
        ),
        todo_attrs(
          "local_patterns",
          "event-c|event-d",
          "Calendar conflict today: C vs D",
          recent_at,
          metadata: %{"detector" => "calendar_conflict"}
        )
      ])

    summary = CompletionSweep.run_for_user(user_id, now: now, gmail_fetcher: no_gmail_fetcher())

    assert summary.completed == 1
    assert summary.completed_by_reason == %{"expired_calendar_conflict" => 1}

    assert Todos.get_for_user(user_id, expired.id).status == "done"
    assert Todos.get_for_user(user_id, recent.id).status == "open"
  end

  test "run_for_all_users sweeps every requested user and returns a rollup" do
    user_a = unique_user!()
    user_b = unique_user!()
    now = ~U[2026-06-02 12:00:00Z]

    {:ok, [_todo_a]} =
      Todos.upsert_many(user_a, [
        todo_attrs(
          "local_patterns",
          "event-a|event-b",
          "Calendar conflict today: A vs B",
          DateTime.add(now, -25 * 3_600, :second),
          metadata: %{"detector" => "calendar_conflict"}
        )
      ])

    {:ok, [_todo_b]} =
      Todos.upsert_many(user_b, [
        todo_attrs(
          "local_patterns",
          "event-c|event-d",
          "Calendar conflict today: C vs D",
          DateTime.add(now, -25 * 3_600, :second),
          metadata: %{"detector" => "calendar_conflict"}
        )
      ])

    summary =
      CompletionSweep.run_for_all_users(
        now: now,
        user_ids: [user_a, user_b],
        gmail_fetcher: no_gmail_fetcher()
      )

    assert summary.users == 2
    assert summary.checked == 2
    assert summary.completed == 2
    assert summary.completed_by_source == %{"local_patterns" => 2}
    assert summary.completed_by_reason == %{"expired_calendar_conflict" => 2}
  end

  defp no_gmail_fetcher do
    fn _user_id, _todo -> {:error, :not_found} end
  end
end
