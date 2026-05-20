defmodule MaraithonWeb.PeopleLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.Crm

  @user_email "people-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders CRM people for the signed-in user and highlights the People nav", %{conn: conn} do
    {:ok, _person} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Charlie Smith",
        "email" => "charlie@example.com",
        "relationship" => "Runner teammate",
        "preferred_communication_method" => "email",
        "communication_frequency" => "weekly",
        "relationship_strength" => 72,
        "affinity_score" => 61
      })

    other_user = "other-people-live@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(other_user)
    {:ok, _other_person} = Crm.upsert_person(other_user, %{"display_name" => "Hidden Person"})

    {:ok, view, html} = live(conn, "/operator/people")

    assert html =~ "CRM people"
    assert html =~ "Charlie Smith"
    assert html =~ "Runner teammate"
    assert html =~ "Email: charlie@example.com"
    assert html =~ "Strength 72"
    refute html =~ "Hidden Person"
    assert has_element?(view, "a[href='/operator/people'][aria-current='page']", "People")
  end

  test "search filters people and reset clears the query", %{conn: conn} do
    {:ok, _charlie} = Crm.upsert_person(@user_email, %{"display_name" => "Charlie Smith"})
    {:ok, _dana} = Crm.upsert_person(@user_email, %{"display_name" => "Dana Lee"})

    {:ok, view, _html} = live(conn, "/operator/people")

    view
    |> form("#people-filters", filters: %{"q" => "Dana"})
    |> render_change()

    assert_patch(view, "/operator/people?q=Dana")

    html = render(view)
    assert html =~ "Dana Lee"
    refute html =~ "Charlie Smith"

    view
    |> element("button[phx-click=clear_filters]", "Reset")
    |> render_click()

    assert_patch(view, "/operator/people")

    html = render(view)
    assert html =~ "Dana Lee"
    assert html =~ "Charlie Smith"
  end
end
