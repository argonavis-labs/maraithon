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

    assert html =~ "Contacts to merge"
    assert html =~ "Relationships to confirm"

    assert html =~
             "Approve contact merges and relationship labels before Maraithon updates People."

    refute html =~ "CRM cleanup"
    assert html =~ "Possible duplicate: Christina Giannone"
    assert html =~ "Merge contacts"
    assert html =~ "Recommended move:"
    assert html =~ "Review relationship: Emma Fenwick as your daughter"
    assert html =~ "Confirm before updating Emma Fenwick"
    assert html =~ "Confirm label"
    refute html =~ "Evidence-backed"
    refute html =~ "Next move:"
    refute html =~ "Suggested action:"
    refute html =~ "I think Emma Fenwick is your daughter"
    refute html =~ "confidence"
    refute html =~ "Hidden Person"
    assert has_element?(view, "a[href='/insights'][aria-current='page']", "Insights")
  end

  test "empty people insight copy stays approval oriented", %{conn: _conn} do
    conn = log_in_test_user(build_conn(), "insights-empty-live@example.com")
    {:ok, view, _html} = live(conn, "/insights")

    html = render(view)

    assert has_element?(view, "h2", "No People changes are waiting for approval.")

    assert has_element?(
             view,
             "p",
             "When Maraithon has a clear, source-backed reason to merge contacts or add a relationship label, it will ask here first. You can still edit People directly."
           )

    assert has_element?(
             view,
             "p",
             "Merge recommendations appear here only when records clearly describe the same person."
           )

    assert has_element?(
             view,
             "p",
             "Relationship labels appear here when there is enough context for you to confirm."
           )

    refute html =~ "Duplicate suggestions"
    refute html =~ "Relationship suggestions"
    refute html =~ "When checked People records"
    refute html =~ "When checked records"
    refute html =~ "checked evidence"
    refute html =~ "Evidence-backed"
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
    assert html =~ "Recommended move:"
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
    assert html =~ "Merged 1 contact into Christina Giannone."
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
        "Confirm label"
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
    assert html =~ "Relationship label confirmed for Emma Fenwick."
  end
end
