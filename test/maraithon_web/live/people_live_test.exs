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

    assert html =~ "Relationships"
    assert html =~ "Charlie Smith"
    assert html =~ "Runner teammate"
    assert html =~ "Email: charlie@example.com"
    assert html =~ "Strength 72"
    assert html =~ "Select duplicates to merge"
    refute html =~ "Set relationship"
    refute html =~ "Merge duplicate"
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

  test "assigns relationship context from presets", %{conn: conn} do
    {:ok, christina} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@framgroup.com"
      })

    {:ok, view, html} = live(conn, "/operator/people?q=Christina&person_id=#{christina.id}")

    assert html =~ "Save context"
    assert html =~ "Contact points"

    view
    |> form("#relationship-form-#{christina.id}",
      relationship: %{
        "display_name" => "Christina Giannone",
        "preset" => "family_event_organizer",
        "relationship" => "",
        "communication_frequency" => "frequent",
        "preferred_communication_method" => "email",
        "notes" => "Coordinates family and social calendars."
      }
    )
    |> render_submit()

    updated = Crm.get_person_for_user(@user_email, christina.id)

    assert updated.relationship == "Family event organizer"
    assert updated.communication_frequency == "frequent"
    assert updated.preferred_communication_method == "email"
    assert updated.notes == "Coordinates family and social calendars."
    assert updated.metadata["relationship_preset"] == "family_event_organizer"
    assert updated.metadata["relationship_domain"] == "family"

    html = render(view)
    assert html =~ "Family event organizer"
    assert html =~ "Frequent"
  end

  test "opens detail panel from row click", %{conn: conn} do
    {:ok, christina} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@framgroup.com",
        "notes" => "Coordinates family and social calendars."
      })

    {:ok, view, _html} = live(conn, "/operator/people?q=Christina")

    view
    |> element("#person-#{christina.id}")
    |> render_click()

    assert_patch(view, "/operator/people?person_id=#{christina.id}&q=Christina")

    html = render(view)
    assert html =~ "Save context"
    assert html =~ "Coordinates family and social calendars."
  end

  test "bulk merges duplicate people from the visible list", %{conn: conn} do
    {:ok, canonical} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "christina.giannone@gmail.com",
        "relationship" => "Personal contact"
      })

    {:ok, duplicate} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Christina Giannone",
        "email" => "cgiannone@framgroup.com",
        "communication_frequency" => "frequent"
      })

    {:ok, view, html} = live(conn, "/operator/people?q=Christina")

    assert html =~ "christina.giannone@gmail.com"
    assert html =~ "cgiannone@framgroup.com"

    view
    |> element("input[phx-click='toggle_person_selection'][phx-value-id='#{canonical.id}']")
    |> render_click()

    view
    |> element("input[phx-click='toggle_person_selection'][phx-value-id='#{duplicate.id}']")
    |> render_click()

    assert render(view) =~ "2 selected"

    view
    |> form("#people-bulk-merge", merge: %{"surviving_person_id" => canonical.id})
    |> render_submit()

    survivor = Crm.get_person_for_user(@user_email, canonical.id)
    merged = Crm.get_person_for_user(@user_email, duplicate.id)

    assert merged.status == "merged"
    assert merged.merged_into_id == canonical.id
    assert "christina.giannone@gmail.com" in survivor.contact_details["emails"]
    assert "cgiannone@framgroup.com" in survivor.contact_details["emails"]

    html = render(view)
    assert html =~ "Merged 1 duplicate into Christina Giannone."
    assert html =~ "christina.giannone@gmail.com"
    assert html =~ "cgiannone@framgroup.com"
    refute has_element?(view, "#person-#{duplicate.id}")
  end
end
