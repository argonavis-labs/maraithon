defmodule MaraithonWeb.InsightsLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.Insights, as: CrmInsights

  @user_email "insights-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "requires authentication", %{conn: _conn} do
    assert {:error, {:redirect, %{to: "/"}}} = live(build_conn(), "/insights")
  end

  test "renders CRM insight cards for the signed-in user and highlights nav", %{conn: conn} do
    {:ok, _first} =
      Crm.create_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "christina@example.com"
      })

    {:ok, _second} =
      Crm.create_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@example.com"
      })

    {:ok, _emma} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Emma Fenwick",
        "first_name" => "Emma",
        "notes" => "Emma is your daughter."
      })

    other_user = "other-insights-live@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(other_user)

    {:ok, _hidden} =
      Crm.upsert_person(other_user, %{
        "display_name" => "Hidden Person",
        "notes" => "Hidden Person is your spouse."
      })

    {:ok, view, html} = live(conn, "/insights")

    assert html =~ "CRM cleanup"
    assert html =~ "Relationship suggestions"
    assert html =~ "Possible duplicate: Christina Giannone"
    assert html =~ "I think Emma Fenwick is your daughter"
    refute html =~ "Hidden Person"
    assert has_element?(view, "a[href='/insights'][aria-current='page']", "Insights")
  end

  test "applies a relationship suggestion and removes the card", %{conn: conn} do
    {:ok, emma} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Emma Fenwick",
        "first_name" => "Emma",
        "notes" => "Emma is your daughter."
      })

    suggestion =
      @user_email
      |> CrmInsights.list_for_user()
      |> Map.fetch!(:relationship_suggestions)
      |> List.first()

    {:ok, view, html} = live(conn, "/insights")
    assert html =~ "I think Emma Fenwick is your daughter"

    html =
      view
      |> element(
        "button[phx-click='apply_relationship_suggestion'][phx-value-id='#{suggestion.id}']",
        "Apply relationship"
      )
      |> render_click()

    updated = Crm.get_person_for_user(@user_email, emma.id)

    assert updated.relationship == "daughter"
    assert updated.metadata["relationship_context_source"] == "crm_insights"
    assert updated.metadata["relationship_suggestion_id"] == suggestion.id
    refute html =~ "I think Emma Fenwick is your daughter"
  end
end
