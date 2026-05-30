defmodule MaraithonWeb.PeopleLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Accounts
  alias Maraithon.Crm
  alias Maraithon.Crm.PersonMerge
  alias Maraithon.Memory
  alias Maraithon.Repo

  @user_email "people-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders people for the signed-in user and highlights the People nav", %{conn: conn} do
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
    assert html =~ "Relationship health"
    assert html =~ "Strong relationship"
    assert html =~ "Warm rapport"
    assert html =~ "No activity yet"
    refute html =~ "Never"
    refute html =~ "Strength 72"
    refute html =~ "Affinity 61"
    assert html =~ "Select duplicates to merge"
    refute has_element?(view, "#person-detail")
    refute has_element?(view, "#people-bulk-actions")
    refute has_element?(view, "form[phx-submit='save_relationship']")
    refute has_element?(view, "#people-bulk-merge")
    refute html =~ "Save context"
    refute html =~ "relationship-form-"
    refute html =~ ~s(id="people-bulk-actions")
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
    assert html =~ "Relationship not set"
    refute html =~ "Unknown"

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

  test "onboards a family member with handling preferences", %{conn: conn} do
    {:ok, view, html} = live(conn, "/operator/people")

    assert html =~ "Family context"
    assert html =~ "Needs setup"

    view
    |> element("button[phx-click='show_people_onboarding'][phx-value-mode='member']")
    |> render_click()

    assert has_element?(view, "#family-member-onboarding-form")

    view
    |> form("#family-member-onboarding-form",
      family_member: %{
        "display_name" => "Jack Fenwick",
        "preset" => "child",
        "communication_frequency" => "weekly",
        "preferred_communication_method" => "telegram",
        "todo_policy" => "family_logistics_only",
        "push_policy" => "time_sensitive_only",
        "contact_hint" => "jack@example.com",
        "notes" => "Jack is Kent's son."
      }
    )
    |> render_submit()

    [jack] = Crm.list_people(@user_email, query: "Jack", limit: 5)

    assert jack.relationship == "Child"
    assert jack.communication_frequency == "weekly"
    assert jack.preferred_communication_method == "telegram"
    assert jack.contact_details["emails"] == ["jack@example.com"]
    assert jack.notes == "Jack is Kent's son."
    assert jack.metadata["relationship_domain"] == "family"
    assert jack.metadata["relationship_preset"] == "child"
    assert jack.metadata["family_member"] == true
    assert jack.metadata["family_role"] == "child"
    assert jack.metadata["dependent_context"] == true
    assert jack.metadata["sensitivity"] == "child_family"
    assert jack.metadata["relationship_context_source"] == "people_onboarding"
    assert jack.metadata["todo_policy"] == "family_logistics_only"
    assert jack.metadata["push_policy"] == "time_sensitive_only"

    assert [%{id: jack_id}] = Crm.list_family_context(@user_email, limit: 5)
    assert jack_id == jack.id

    assert Enum.any?(Memory.list_items(@user_email, tag: "people_onboarding"), fn memory ->
             memory.source_ref_id == jack.id and memory.source == "people_onboarding"
           end)

    html = render(view)
    assert html =~ "Added Jack Fenwick to family context."
    assert html =~ "1 family member"
    assert html =~ "Family member"
    assert html =~ "Child"
    assert html =~ "Logistics only"
    assert html =~ "Time-sensitive only"
  end

  test "onboards a family proxy linked to a family member", %{conn: conn} do
    {:ok, jack} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Jack Fenwick",
        "relationship" => "Child",
        "metadata" => %{
          "relationship_domain" => "family",
          "relationship_preset" => "child",
          "family_member" => true,
          "family_role" => "child"
        }
      })

    {:ok, view, _html} = live(conn, "/operator/people")

    view
    |> element("button[phx-click='show_people_onboarding'][phx-value-mode='proxy']")
    |> render_click()

    assert has_element?(view, "#family-proxy-onboarding-form")

    view
    |> form("#family-proxy-onboarding-form",
      family_proxy: %{
        "display_name" => "Northview School Office",
        "preset" => "school_contact",
        "proxy_for_person_id" => jack.id,
        "preferred_communication_method" => "email",
        "todo_policy" => "family_logistics_only",
        "push_policy" => "digest_only",
        "contact_hint" => "office@northview.example",
        "notes" => "School logistics for Jack."
      }
    )
    |> render_submit()

    [school] = Crm.list_people(@user_email, query: "Northview", limit: 5)

    assert school.relationship == "School or child-care contact"
    assert school.preferred_communication_method == "email"
    assert school.metadata["relationship_domain"] == "family"
    assert school.metadata["relationship_preset"] == "school_contact"
    assert school.metadata["family_proxy"] == true
    assert school.metadata["proxy_role"] == "school_contact"
    assert school.metadata["proxy_for_person_id"] == jack.id
    assert school.metadata["default_todo_policy"] == "family_logistics"
    assert school.metadata["todo_policy"] == "family_logistics_only"
    assert school.metadata["push_policy"] == "digest_only"

    family_context_ids =
      @user_email
      |> Crm.list_family_context(limit: 10)
      |> Enum.map(& &1.id)

    assert jack.id in family_context_ids
    assert school.id in family_context_ids

    html = render(view)
    assert html =~ "Added Northview School Office as family-related context."
    assert html =~ "1 family member"
    assert html =~ "1 family contact"
    assert html =~ "Family contact"
    assert html =~ "School / child-care"
    assert html =~ "For Jack Fenwick"
    assert html =~ "Digest only"
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

    html = render(view)
    assert html =~ "2 selected"
    assert html =~ ~s(id="people-bulk-merge-direct")
    assert html =~ ~s(id="people-bulk-delete-direct")
    refute html =~ ~s(id="people-selection-actions")

    assert has_element?(
             view,
             "#people-bulk-actions-button",
             "Actions"
           )

    view
    |> element("#people-bulk-merge-direct", "Merge")
    |> render_click()

    assert has_element?(view, "#people-bulk-merge")

    view
    |> form("#people-bulk-merge", merge: %{"surviving_person_id" => canonical.id})
    |> render_submit()

    survivor = Crm.get_person_for_user(@user_email, canonical.id)
    merged = Crm.get_person_for_user(@user_email, duplicate.id)

    assert merged.status == "merged"
    assert merged.merged_into_id == canonical.id
    assert "christina.giannone@gmail.com" in survivor.contact_details["emails"]
    assert "cgiannone@framgroup.com" in survivor.contact_details["emails"]

    assert %PersonMerge{} =
             audit =
             Repo.get_by(PersonMerge,
               user_id: @user_email,
               surviving_person_id: canonical.id,
               merged_person_id: duplicate.id
             )

    assert audit.model_rationale ==
             "Kept the selected canonical People row and merged the selected duplicate rows."

    refute audit.model_rationale =~ "The user"

    html = render(view)
    assert html =~ "Merged 1 duplicate into Christina Giannone."
    assert html =~ "christina.giannone@gmail.com"
    assert html =~ "cgiannone@framgroup.com"
    refute has_element?(view, "#person-#{duplicate.id}")
  end

  test "bulk deletes selected people from the floating actions menu", %{conn: conn} do
    {:ok, first} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Delete Me One",
        "email" => "delete-one@example.com"
      })

    {:ok, second} =
      Crm.upsert_person(@user_email, %{
        "display_name" => "Delete Me Two",
        "email" => "delete-two@example.com"
      })

    {:ok, view, _html} = live(conn, "/operator/people?q=Delete Me")

    view
    |> element("input[phx-click='toggle_person_selection'][phx-value-id='#{first.id}']")
    |> render_click()

    view
    |> element("input[phx-click='toggle_person_selection'][phx-value-id='#{second.id}']")
    |> render_click()

    view
    |> element("#people-bulk-actions-button", "Actions")
    |> render_click()

    view
    |> element(
      "#people-bulk-action-menu button[phx-click='choose_people_bulk_action'][phx-value-action='delete']"
    )
    |> render_click()

    assert render(view) =~ "Delete contacts?"

    view
    |> element("button[phx-click='delete_selected_people']", "Delete contacts")
    |> render_click()

    assert Crm.get_person_for_user(@user_email, first.id) == nil
    assert Crm.get_person_for_user(@user_email, second.id) == nil

    html = render(view)
    assert html =~ "Deleted 2 contacts."
    refute html =~ "Delete Me One"
    refute html =~ "Delete Me Two"
    refute has_element?(view, "#people-bulk-actions")
  end
end
