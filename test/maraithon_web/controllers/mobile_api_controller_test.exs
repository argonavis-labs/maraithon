defmodule MaraithonWeb.MobileApiControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Accounts.MagicLink
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonMerge
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

    assert json_response(conn, 401) == %{
             "error" => "invalid_or_expired_code",
             "message" => "Sign-in code is invalid or expired."
           }
  end

  test "magic-link request returns clean validation errors", %{conn: conn} do
    conn =
      post(conn, ~p"/api/mobile/auth/magic-link", %{
        "email" => "not-an-email"
      })

    assert json_response(conn, 422) == %{
             "error" => "invalid_email",
             "message" => "Enter a valid email address."
           }
  end

  test "mobile todo errors include stable codes and human copy", %{conn: conn} do
    email = "mobile-todo-errors-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)
    missing_id = Ecto.UUID.generate()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todos/#{missing_id}")

    assert json_response(conn, 404) == %{
             "error" => "not_found",
             "message" => "That item is no longer available. Refresh to see current work."
           }

    {:ok, [todo]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "mobile",
          "title" => "Check mobile unsupported action",
          "summary" => "Regression coverage for mobile error copy.",
          "next_action" => "Tap an unsupported action.",
          "status" => "open"
        }
      ])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos/#{todo.id}/actions/not-real")

    assert json_response(conn, 422) == %{
             "error" => "unsupported_todo_action",
             "message" => "That work item action is not available here."
           }
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

    {:ok, [default_note_todo]} =
      Todos.upsert_many(user.id, [
        %{
          "source" => "mobile",
          "title" => "Dismiss without a custom note",
          "summary" => "Confirm default mobile resolution copy.",
          "next_action" => "Dismiss this item.",
          "status" => "open"
        }
      ])

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> delete(~p"/api/mobile/todos/#{default_note_todo.id}")

    assert %{"todo" => %{"id" => default_note_todo_id, "status" => "dismissed"}} =
             json_response(conn, 200)

    assert default_note_todo_id == default_note_todo.id
    default_dismissed = Todos.get_for_user(user.id, default_note_todo.id)
    assert default_dismissed.metadata["resolution_note"] == "Dismissed from mobile."
  end

  test "mobile todo activity lists user-created, done, and deleted events", %{conn: conn} do
    email = "mobile-todo-activity-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos", %{
        "todo" => %{
          "source" => "mobile",
          "title" => "Check activity logging",
          "summary" => "Confirm lifecycle activity appears in the mobile debug log.",
          "next_action" => "Create, complete, and delete this item.",
          "status" => "open"
        }
      })

    assert %{"todo" => %{"id" => todo_id}} = json_response(conn, 201)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/todos/#{todo_id}/actions/done", %{"note" => "Finished on mobile."})

    assert %{"todo" => %{"status" => "done"}} = json_response(conn, 200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> delete(~p"/api/mobile/todos/#{todo_id}", %{"note" => "No longer relevant from mobile."})

    assert %{"todo" => %{"status" => "dismissed"}} = json_response(conn, 200)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/todo-activity?limit=10")

    assert %{"activity" => [deleted, done, created]} = json_response(conn, 200)

    assert deleted["event_type"] == "deleted"
    assert deleted["actor_type"] == "user"
    assert deleted["actor_id"] == user.id
    assert deleted["todo_id"] == todo_id
    assert deleted["todo_title"] == "Check activity logging"
    assert deleted["metadata"]["note"] == "No longer relevant from mobile."

    assert done["event_type"] == "marked_done"
    assert done["actor_type"] == "user"
    assert done["metadata"]["note"] == "Finished on mobile."

    assert created["event_type"] == "created"
    assert created["actor_type"] == "user"
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
          "source_item_id" => "gmail-thread-mobile-private-123",
          "dedupe_key" => "gmail:mobile-private-thread-123",
          "metadata" => %{
            "person" => "Michael Berlingo",
            "company" => "Starteryou",
            "thread_state" => "waiting_on_kent",
            "source_quote" => "Can you send the next Starteryou UGC campaign update?",
            "why_it_matters" => "Michael is waiting on the UGC next-step decision.",
            "confidence" => 0.96,
            "generation_mode" => "llm",
            "model_rationale" => "Model score says this is important.",
            "quality_verification" => %{"score" => 10},
            "source_health" => %{"checked_sources" => ["gmail"]},
            "todo_intelligence" => %{"source" => "open_loop_model"}
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
                 "metadata" => metadata,
                 "action_card" =>
                   %{
                     "headline" => headline,
                     "context_items" => context_items,
                     "next_best_action" => next_action,
                     "available_buttons" => buttons
                   } = action_card
               } = todo_response
             ]
           } = json_response(conn, 200)

    assert todo_id == todo.id

    assert metadata == %{
             "company" => "Starteryou",
             "person" => "Michael Berlingo",
             "source_quote" => "Can you send the next Starteryou UGC campaign update?",
             "thread_state" => "waiting_on_kent",
             "why_it_matters" => "Michael is waiting on the UGC next-step decision."
           }

    refute Map.has_key?(metadata, "confidence")
    refute Map.has_key?(metadata, "generation_mode")
    refute Map.has_key?(metadata, "model_rationale")
    refute Map.has_key?(metadata, "quality_verification")
    refute Map.has_key?(metadata, "source_health")
    refute Map.has_key?(metadata, "todo_intelligence")
    refute Map.has_key?(todo_response, "owner_user_id")
    refute Map.has_key?(todo_response, "source_item_id")
    refute Map.has_key?(todo_response, "dedupe_key")

    encoded_todo = inspect(todo_response)
    refute encoded_todo =~ "gmail-thread-mobile-private-123"
    refute encoded_todo =~ "gmail:mobile-private-thread-123"
    assert headline =~ "Michael Berlingo"
    assert Enum.any?(context_items, &(&1["label"] == "Person"))
    refute Enum.any?(context_items, &(&1["label"] == "Confidence"))
    refute Map.has_key?(action_card, "confidence")
    refute Map.has_key?(action_card, "product_score")
    refute Map.has_key?(action_card, "source_health")
    assert next_action =~ "Draft"
    assert Enum.any?(buttons, &(&1["action"] == "done"))
    assert Enum.any?(buttons, &(&1["action"] == "helpful" and &1["label"] == "Helpful"))
    assert Enum.any?(buttons, &(&1["action"] == "not_helpful" and &1["label"] == "Less useful"))
    refute Enum.any?(buttons, &(&1["action"] in ["important", "keep_active"]))
    refute Enum.any?(buttons, &(&1["label"] == "Keep active"))

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
          "email" => "production-test-person@example.com",
          "metadata" => %{
            "mobile_status" => "active",
            "deal_stage" => "proposal",
            "deal_value" => "42000",
            "confidence" => 0.96,
            "model_rationale" => "Model score says this relationship is important.",
            "quality_verification" => %{"score" => 10},
            "source_health" => %{"checked_sources" => ["gmail"]}
          }
        }
      })

    assert %{
             "person" => %{
               "id" => person_id,
               "display_name" => "Production Test Person",
               "relationship_health" => "new",
               "relationship_warmth" => "new",
               "metadata" => metadata
             }
           } =
             json_response(conn, 201)

    assert metadata == %{
             "deal_stage" => "proposal",
             "deal_value" => "42000",
             "mobile_status" => "active"
           }

    persisted_metadata = Crm.get_person_for_user(user.id, person_id).metadata
    assert persisted_metadata == metadata

    {:ok, _person} =
      user.id
      |> Crm.get_person_for_user(person_id)
      |> Crm.update_person(%{
        "relationship_strength" => 72,
        "affinity_score" => 61
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/people/#{person_id}")

    assert %{
             "person" =>
               %{
                 "id" => ^person_id,
                 "display_name" => "Production Test Person",
                 "relationship_health" => "strong",
                 "relationship_warmth" => "warm",
                 "metadata" => ^metadata
               } = person_response
           } =
             json_response(conn, 200)

    refute Map.has_key?(person_response, "relationship_strength")
    refute Map.has_key?(person_response, "affinity_score")

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

  test "mobile people can request every relationship state for full refresh", %{conn: conn} do
    email = "mobile-people-all-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    {:ok, active} =
      Crm.create_person(user.id, %{
        "display_name" => "Active Relationship",
        "email" => "active-relationship@example.com",
        "metadata" => %{"mobile_status" => "active"}
      })

    {:ok, archived} =
      Crm.create_person(user.id, %{
        "display_name" => "Archived Relationship",
        "email" => "archived-relationship@example.com",
        "status" => "archived",
        "metadata" => %{"mobile_status" => "active"}
      })

    {:ok, merged} =
      Crm.create_person(user.id, %{
        "display_name" => "Merged Relationship",
        "email" => "merged-relationship@example.com",
        "status" => "merged",
        "metadata" => %{"mobile_status" => "active"}
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/people")

    assert %{"people" => default_people} = json_response(conn, 200)
    default_ids = MapSet.new(default_people, & &1["id"])
    assert MapSet.member?(default_ids, active.id)
    refute MapSet.member?(default_ids, archived.id)
    refute MapSet.member?(default_ids, merged.id)

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/people?status=all&limit=10")

    assert %{"people" => all_people} = json_response(conn, 200)
    people_by_id = Map.new(all_people, &{&1["id"], &1})

    assert MapSet.new(Map.keys(people_by_id)) == MapSet.new([active.id, archived.id, merged.id])
    assert people_by_id[archived.id]["status"] == "archived"
    assert people_by_id[merged.id]["status"] == "merged"
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

    {:ok, default_surviving} =
      Crm.create_person(user.id, %{
        "display_name" => "Default Merge Primary",
        "email" => "default-primary@example.com"
      })

    {:ok, default_duplicate} =
      Crm.create_person(user.id, %{
        "display_name" => "Default Merge Primary",
        "email" => "default-duplicate@example.com"
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/people/#{default_surviving.id}/merge", %{
        "merge" => %{"merged_person_id" => default_duplicate.id}
      })

    assert %{"merge" => %{"merged_person" => %{"status" => "merged"}}} =
             json_response(conn, 200)

    assert %PersonMerge{} =
             merge =
             Repo.get_by(PersonMerge,
               user_id: user.id,
               surviving_person_id: default_surviving.id,
               merged_person_id: default_duplicate.id
             )

    assert merge.performed_by == "mobile"
    assert merge.evidence == "Merged from mobile."
    assert merge.model_rationale == "Kept one person record and merged the duplicate from mobile."
    refute merge.model_rationale =~ "The user"

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

  test "mobile people errors include stable codes and human copy", %{conn: conn} do
    email = "mobile-people-errors-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> get(~p"/api/mobile/people/#{Ecto.UUID.generate()}")

    assert json_response(conn, 404) == %{
             "error" => "not_found",
             "message" => "That item is no longer available. Refresh to see current work."
           }

    {:ok, person} =
      Crm.create_person(user.id, %{
        "display_name" => "Merge Candidate",
        "relationship" => "Mobile regression"
      })

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer #{session_token}")
      |> post(~p"/api/mobile/people/#{person.id}/merge", %{})

    assert json_response(conn, 422) == %{
             "error" => "missing_duplicate",
             "message" => "Choose the duplicate person to merge."
           }
  end
end
