defmodule MaraithonWeb.MobileApiControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Accounts.MagicLink
  alias Maraithon.Crm
  alias Maraithon.Repo
  alias Maraithon.Todos

  test "magic-link consume returns a mobile session and me verifies it", %{conn: conn} do
    email = "mobile-auth-#{System.unique_integer([:positive])}@example.com"
    {:ok, %{token: token, user: user}} = Accounts.request_magic_link(email)

    conn = post(conn, ~p"/api/mobile/auth/magic/#{token}")

    assert %{
             "session_token" => session_token,
             "user" => %{"email" => ^email, "id" => user_id}
           } = json_response(conn, 200)

    assert user_id == user.id

    conn =
      build_conn()
      |> put_req_header("authorization", "bearer   #{session_token}")
      |> get(~p"/api/mobile/me")

    assert %{"user" => %{"email" => ^email}} = json_response(conn, 200)
  end

  test "magic-code request stores a code hash and code consume returns a mobile session", %{
    conn: conn
  } do
    email = "mobile-code-request-#{System.unique_integer([:positive])}@example.com"

    conn =
      post(conn, ~p"/api/mobile/auth/magic-link", %{
        "email" => email
      })

    assert %{
             "magic_code" => %{
               "email" => ^email,
               "expires_in_seconds" => 900,
               "delivery" => "email_code"
             },
             "magic_link" => %{"delivery" => "email_code"}
           } = json_response(conn, 200)

    assert %MagicLink{code_hash: code_hash} = Repo.get_by(MagicLink, sent_to_email: email)
    assert is_binary(code_hash)

    {:ok, %{code: code, user: user}} =
      Accounts.request_magic_code(
        "mobile-code-consume-#{System.unique_integer([:positive])}@example.com"
      )

    conn = post(build_conn(), ~p"/api/mobile/auth/magic-code", %{"code" => code})

    assert %{
             "session_token" => session_token,
             "user" => %{"id" => user_id}
           } = json_response(conn, 200)

    assert user_id == user.id
    assert Accounts.get_active_session(session_token)
  end

  test "magic-code consume returns clean invalid errors", %{conn: conn} do
    conn = post(conn, ~p"/api/mobile/auth/magic-code", %{"code" => "bad-code"})

    assert %{"error" => "invalid_or_expired_code"} = json_response(conn, 401)
  end

  test "magic-link request returns clean validation errors", %{conn: conn} do
    conn =
      post(conn, ~p"/api/mobile/auth/magic-link", %{
        "email" => "not-an-email"
      })

    assert %{"error" => "invalid_email"} = json_response(conn, 422)
  end

  test "mobile todos can be listed, created, and updated", %{conn: conn} do
    email = "mobile-todos-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos", %{
        "todo" => %{
          "user_id" => Ecto.UUID.generate(),
          "owner_user_id" => Ecto.UUID.generate(),
          "source" => "mobile",
          "title" => "Call production test lead",
          "summary" => "Confirm the native mobile todo create path.",
          "next_action" => "Call the lead from the mobile app.",
          "priority" => 80,
          "status" => "open"
        }
      })

    assert %{"todo" => %{"id" => todo_id, "title" => "Call production test lead"}} =
             json_response(conn, 201)

    created = Todos.get_for_user(user.id, todo_id)
    assert created.user_id == user.id
    assert created.owner_user_id == user.id

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todos/#{todo_id}")

    assert %{"todo" => %{"id" => ^todo_id, "title" => "Call production test lead"}} =
             json_response(conn, 200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> patch(~p"/api/mobile/todos/#{todo_id}", %{
        "todo" => %{"title" => "Call updated production test lead", "status" => "done"}
      })

    assert %{"todo" => %{"title" => "Call updated production test lead", "status" => "done"}} =
             json_response(conn, 200)

    assert Todos.get_for_user(user.id, todo_id).status == "done"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> delete(~p"/api/mobile/todos/#{todo_id}", %{"note" => "No longer relevant from mobile."})

    assert %{
             "deleted" => true,
             "delete_mode" => "dismiss_as_no_longer_relevant",
             "todo" => %{"id" => ^todo_id, "status" => "dismissed"}
           } = json_response(conn, 200)

    dismissed = Todos.get_for_user(user.id, todo_id)
    assert dismissed.status == "dismissed"
    assert dismissed.metadata["resolution_note"] == "No longer relevant from mobile."
  end

  test "mobile todos expose action cards and one-tap actions", %{conn: conn} do
    email = "mobile-todo-actions-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    {:ok, [todo]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "gmail",
          "title" => "Reply to Michael Berlingo on Starteryou UGC Campaigns",
          "summary" => "Michael Berlingo asked about Starteryou UGC Campaigns.",
          "next_action" => "Draft a reply with the campaign owner, ETA, and next artifact.",
          "metadata" => %{
            "person" => "Michael Berlingo",
            "company" => "Starteryou",
            "thread_state" => "waiting_on_kent",
            "source_quote" => "Can you send the next Starteryou UGC campaign update?"
          }
        }
      ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todos?include_cards=true&limit=5")

    assert %{
             "todos" => [
               %{
                 "id" => todo_id,
                 "action_card" => %{
                   "headline" => headline,
                   "context_items" => context_items,
                   "next_best_action" => next_action,
                   "available_buttons" => buttons
                 }
               }
             ]
           } = json_response(conn, 200)

    assert todo_id == todo.id
    assert headline =~ "Michael Berlingo"
    assert Enum.any?(context_items, &(&1["label"] == "Person"))
    assert next_action =~ "Draft"
    assert Enum.any?(buttons, &(&1["action"] == "done"))
    assert Enum.any?(buttons, &(&1["action"] == "not_helpful" and &1["label"] == "Not Important"))

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos/#{todo.id}/actions/done", %{"include_card" => "true"})

    assert %{
             "action" => "done",
             "todo" => %{"status" => "done", "action_card" => %{"headline" => _headline}}
           } = json_response(conn, 200)

    assert Todos.get_for_user(user.id, todo.id).status == "done"
  end

  test "mobile todo not important action records feedback without dismissing", %{conn: conn} do
    email = "mobile-todo-feedback-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    {:ok, [todo]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "gmail",
          "title" => "Maybe reply to stale low-priority thread",
          "summary" => "A stale follow-up should be trainable without being closed.",
          "next_action" => "Ask Kent if this still matters.",
          "status" => "open"
        }
      ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos/#{todo.id}/actions/not_important")

    assert %{"action" => "not_helpful", "todo" => %{"status" => "open"}} =
             json_response(conn, 200)

    updated = Todos.get_for_user(user.id, todo.id)
    assert updated.status == "open"

    assert get_in(updated.metadata, ["assistant_feedback", "value"]) == "not_helpful"
    assert get_in(updated.metadata, ["assistant_feedback", "source"]) == "mobile"
  end

  test "mobile todos support active, source, attention, and due filters", %{conn: conn} do
    email = "mobile-todo-filters-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)
    today_due = DateTime.new!(Date.utc_today(), ~T[12:00:00], "Etc/UTC")

    {:ok, [_focused, _snoozed, done]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "gmail",
          "title" => "Reply to focused customer",
          "summary" => "A focused customer needs a reply.",
          "next_action" => "Reply today.",
          "attention_mode" => "monitor",
          "due_at" => DateTime.to_iso8601(today_due)
        },
        %{
          "source" => "slack",
          "title" => "Check snoozed Slack item",
          "summary" => "A snoozed Slack item should still count as active.",
          "next_action" => "Review later.",
          "status" => "snoozed"
        },
        %{
          "source" => "gmail",
          "title" => "Finished customer reply",
          "summary" => "This is done and should not appear in active filters.",
          "next_action" => "No action.",
          "status" => "done"
        }
      ])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todos?status=active&limit=10")

    active_titles =
      conn
      |> json_response(200)
      |> Map.fetch!("todos")
      |> Enum.map(& &1["title"])

    assert "Reply to focused customer" in active_titles
    assert "Check snoozed Slack item" in active_titles
    refute "Finished customer reply" in active_titles

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todos?status=active&source=gmail&attention=monitor&due=today")

    assert %{"todos" => [%{"title" => "Reply to focused customer"}]} = json_response(conn, 200)
    assert Todos.get_for_user(user.id, done.id).status == "done"
  end

  test "mobile people can be listed, created, and updated", %{conn: conn} do
    email = "mobile-people-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/people", %{
        "person" => %{
          "user_id" => Ecto.UUID.generate(),
          "interaction_count" => 99,
          "display_name" => "Production Test Person",
          "relationship" => "Mobile integration",
          "email" => "production-test-person@example.com"
        }
      })

    assert %{"person" => %{"id" => person_id, "display_name" => "Production Test Person"}} =
             json_response(conn, 201)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/people/#{person_id}")

    assert %{"person" => %{"id" => ^person_id, "display_name" => "Production Test Person"}} =
             json_response(conn, 200)

    last_contacted_at = "2026-05-26T13:45:00Z"
    last_contacted_at_response = "2026-05-26T13:45:00.000000Z"

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> patch(~p"/api/mobile/people/#{person_id}", %{
        "person" => %{
          "notes" => "Updated from the mobile API test.",
          "last_contacted_at" => last_contacted_at
        }
      })

    assert %{
             "person" => %{
               "notes" => "Updated from the mobile API test.",
               "last_interaction_at" => ^last_contacted_at_response
             }
           } =
             json_response(conn, 200)

    assert Crm.get_person_for_user(user.id, person_id).notes ==
             "Updated from the mobile API test."

    assert DateTime.compare(
             Crm.get_person_for_user(user.id, person_id).last_interaction_at,
             ~U[2026-05-26 13:45:00Z]
           ) == :eq

    assert Crm.get_person_for_user(user.id, person_id).interaction_count == 0
  end

  test "mobile people can be merged and deleted", %{conn: conn} do
    email = "mobile-people-crud-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    {:ok, surviving} =
      Crm.create_person(user.id, %{
        "display_name" => "Christina Giannone",
        "email" => "christina@example.com",
        "relationship" => "Family coordinator"
      })

    {:ok, duplicate} =
      Crm.create_person(user.id, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@example.com",
        "notes" => "Duplicate mobile CRM record."
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/people/#{surviving.id}/merge", %{
        "merge" => %{
          "merged_person_id" => duplicate.id,
          "evidence" => "Same family contact from two connected sources."
        }
      })

    assert %{
             "merge" => %{
               "surviving_person" => %{"id" => surviving_id},
               "merged_person" => %{"id" => merged_id, "status" => "merged"}
             }
           } = json_response(conn, 200)

    assert surviving_id == surviving.id
    assert merged_id == duplicate.id
    assert Crm.get_person_for_user(user.id, duplicate.id).merged_into_id == surviving.id

    {:ok, disposable} =
      Crm.create_person(user.id, %{
        "display_name" => "Disposable CRM Contact",
        "email" => "delete-me@example.com"
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> delete(~p"/api/mobile/people/#{disposable.id}")

    assert %{"ok" => true, "deleted_person_id" => deleted_id} = json_response(conn, 200)
    assert deleted_id == disposable.id
    refute Crm.get_person_for_user(user.id, disposable.id)
  end
end
