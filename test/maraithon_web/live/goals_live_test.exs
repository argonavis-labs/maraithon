defmodule MaraithonWeb.GoalsLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Goals

  @user_email "goals-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders saved goals and highlights the Goals nav", %{conn: conn} do
    {:ok, goal} =
      Goals.create_goal(@user_email, %{
        "category" => "work",
        "title" => "Ship the Goals tab",
        "desired_outcome" => "Maraithon can keep user outcomes in view."
      })

    {:ok, view, html} = live(conn, ~p"/goals?id=#{goal.id}")

    assert html =~ "Goals"
    assert html =~ "Ship the Goals tab"
    assert html =~ "Maraithon can keep user outcomes in view."
    assert html =~ "Saved goals"
    assert has_element?(view, "a[href='/goals'][aria-current='page']", "Goals")
  end

  test "creates a user-scoped goal from the tab", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/goals")

    view
    |> form("#new-goal-form",
      goal: %{
        "title" => "Lift three times a week",
        "category" => "health_fitness",
        "desired_outcome" => "Have a stable weekly lifting rhythm.",
        "why" => "Energy and injury prevention.",
        "success_metric" => "Three sessions logged weekly.",
        "target_at" => "2026-08-01",
        "review_cadence" => "weekly",
        "priority" => "70",
        "sensitivity" => "sensitive",
        "proactive_visibility" => "summary"
      }
    )
    |> render_submit()

    [goal] = Goals.list_goals(@user_email, category: "health_fitness", limit: 5)

    assert_patch(view, ~p"/goals?id=#{goal.id}")
    assert goal.user_id == @user_email
    assert goal.title == "Lift three times a week"
    assert render(view) =~ "Goal saved."
  end
end
