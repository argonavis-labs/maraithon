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

    assert html =~ "People cleanup"
    refute html =~ "CRM cleanup"
    assert html =~ "Relationship suggestions"
    assert html =~ "Possible duplicate: Christina Giannone"
    assert html =~ "Merge contacts"
    assert html =~ "Suggested action:"
    assert html =~ "Review relationship: Emma Fenwick as your daughter"
    assert html =~ "Confirm before updating Emma Fenwick"
    refute html =~ "I think Emma Fenwick is your daughter"
    refute html =~ "confidence"
    refute html =~ "Hidden Person"
    assert has_element?(view, "a[href='/insights'][aria-current='page']", "Insights")
  end

  test "empty people insight copy stays scoped to checked records", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/insights")

    html = render(view)

    assert has_element?(view, "h2", "Available records did not surface people insights.")

    assert has_element?(
             view,
             "p",
             "Merge suggestions will appear here after checked records point to the same person."
           )

    assert has_element?(
             view,
             "p",
             "Relationship suggestions will appear here after checked evidence points to a label you can confirm."
           )

    refute html =~ "No people insights right now"
    refute html =~ "No people insights surfaced from checked records."
    refute html =~ "No duplicate candidates surfaced in checked people data."
    refute html =~ "No relationship suggestions surfaced from checked evidence."
    refute html =~ "looks clean"
    refute html =~ "No duplicate people found"
    refute html =~ "No relationship suggestions found"
  end

  test "merges a duplicate suggestion from the insight card", %{conn: conn} do
    {:ok, canonical} =
      Crm.create_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "christina@example.com",
        "relationship" => "family event organizer",
        "notes" => "Coordinates family logistics.",
        "interaction_count" => 12,
        "relationship_strength" => 80
      })

    {:ok, duplicate} =
      Crm.create_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@example.com",
        "interaction_count" => 1,
        "relationship_strength" => 10
      })

    suggestion =
      @user_email
      |> CrmInsights.list_for_user()
      |> Map.fetch!(:duplicate_suggestions)
      |> List.first()

    {:ok, view, html} = live(conn, "/insights")
    assert html =~ "Suggested action:"
    assert html =~ "keep Christina Giannone"

    html =
      view
      |> element(
        "button[phx-click='merge_duplicate_suggestion'][phx-value-id='#{suggestion.id}']",
        "Merge contacts"
      )
      |> render_click()

    merged = Crm.get_person_for_user(@user_email, duplicate.id)
    survivor = Crm.get_person_for_user(@user_email, canonical.id)

    assert merged.status == "merged"
    assert merged.merged_into_id == survivor.id
    assert survivor.relationship == "family event organizer"
    refute html =~ "Possible duplicate: Christina Giannone"
    assert html =~ "Merged 1 duplicate into Christina Giannone."
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
    assert html =~ "Review relationship: Emma Fenwick as your daughter"
    refute html =~ "I think Emma Fenwick is your daughter"

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
    assert updated.metadata["relationship_domain"] == "family"
    assert updated.metadata["relationship_preset"] == "child"
    assert updated.metadata["family_member"] == true
    assert updated.metadata["family_role"] == "child"
    assert updated.metadata["dependent_context"] == true
    assert updated.metadata["sensitivity"] == "child_family"
    assert updated.metadata["todo_policy"] == "family_logistics_only"
    assert updated.metadata["push_policy"] == "time_sensitive_only"
    assert [%{id: updated_id}] = Crm.list_family_context(@user_email, limit: 5)
    assert updated_id == emma.id
    refute html =~ "Review relationship: Emma Fenwick as your daughter"
  end
end
