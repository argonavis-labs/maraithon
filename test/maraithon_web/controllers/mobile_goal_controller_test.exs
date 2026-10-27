defmodule MaraithonWeb.MobileGoalControllerTest do
  use MaraithonWeb.ConnCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Goals

  setup do
    email = "mobile-goals-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    {:ok, %{token: session_token}} = Accounts.create_session_for_user(user)
    %{user: user, session_token: session_token}
  end

  test "mobile goals can be listed, created, updated, reviewed, and archived", %{
    conn: conn,
    user: user,
    session_token: session_token
  } do
    spoof_reviewed_at = "2001-02-03T04:05:06Z"
    spoof_next_review_at = "2099-01-01T00:00:00Z"

    conn =
      conn
      |> auth(session_token)
      |> post(~p"/api/mobile/goals", %{
        "goal" => %{
          "user_id" => "ignored-user",
          "category" => "health_fitness",
          "title" => "Run three times a week",
          "desired_outcome" => "Build a steady weekly running habit.",
          "review_cadence" => "weekly",
          "last_reviewed_at" => spoof_reviewed_at,
          "next_review_at" => spoof_next_review_at,
          "metadata" => %{"unsafe" => true}
        }
      })

    response = json_response(conn, 201)

    assert %{
             "goal" => %{
               "id" => goal_id,
               "title" => "Run three times a week",
               "category" => "health_fitness",
               "sensitivity" => "sensitive",
               "last_reviewed_at" => nil
             }
           } = response

    refute response["goal"]["next_review_at"] == spoof_next_review_at

    created_goal = Goals.get_goal(user.id, goal_id, preload: false)
    assert created_goal.user_id == user.id
    assert created_goal.last_reviewed_at == nil
    assert created_goal.metadata == %{}

    conn =
      build_conn()
      |> auth(session_token)
      |> get(~p"/api/mobile/goals?status=active")

    assert %{"goals" => [%{"id" => ^goal_id}]} = json_response(conn, 200)

    conn =
      build_conn()
      |> auth(session_token)
      |> patch(~p"/api/mobile/goals/#{goal_id}", %{
        "goal" => %{
          "title" => "Run four times a week",
          "priority" => 85,
          "last_reviewed_at" => spoof_reviewed_at,
          "next_review_at" => spoof_next_review_at,
          "metadata" => %{"unsafe" => true}
        }
      })

    response = json_response(conn, 200)

    assert %{
             "goal" => %{
               "title" => "Run four times a week",
               "priority" => 85,
               "last_reviewed_at" => nil
             }
           } = response

    refute response["goal"]["next_review_at"] == spoof_next_review_at

    updated_goal = Goals.get_goal(user.id, goal_id, preload: false)
    assert updated_goal.last_reviewed_at == nil
    assert updated_goal.metadata == %{}

    conn =
      build_conn()
      |> auth(session_token)
      |> post(~p"/api/mobile/goals/#{goal_id}/progress", %{
        "progress" => %{
          "summary" => "Ran twice this week and scheduled the third run.",
          "progress_state" => "on_track"
        }
      })

    assert %{"progress_update" => %{"progress_state" => "on_track"}} =
             json_response(conn, 201)

    conn =
      build_conn()
      |> auth(session_token)
      |> post(~p"/api/mobile/goals/#{goal_id}/review")

    assert %{"review_run" => %{"status" => "completed"}} = json_response(conn, 200)

    conn =
      build_conn()
      |> auth(session_token)
      |> delete(~p"/api/mobile/goals/#{goal_id}")

    assert %{
             "deleted" => true,
             "delete_mode" => "archive_goal",
             "goal" => %{"status" => "archived"}
           } = json_response(conn, 200)
  end

  test "mobile goal detail includes progress and review history", %{
    conn: conn,
    user: user,
    session_token: session_token
  } do
    {:ok, goal} =
      Goals.create_goal(user.id, %{
        "category" => "work",
        "title" => "Ship the goals API",
        "desired_outcome" => "Mobile can read goal state."
      })

    {:ok, _progress} =
      Goals.record_progress(user.id, goal.id, %{
        "summary" => "API endpoints are wired.",
        "progress_state" => "on_track"
      })

    {:ok, _run} = Goals.review_goal_alignment(user.id, goal_id: goal.id, trigger: "manual")

    conn =
      conn
      |> auth(session_token)
      |> get(~p"/api/mobile/goals/#{goal.id}")

    assert %{
             "goal" => %{
               "id" => goal_id,
               "progress_updates" => [%{"summary" => "API endpoints are wired."}],
               "review_runs" => [%{"status" => "completed"}]
             }
           } = json_response(conn, 200)

    assert goal_id == goal.id
  end

  defp auth(conn, session_token) do
    put_req_header(conn, "authorization", "Bearer #{session_token}")
  end
end
