defmodule MaraithonWeb.TodosLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Maraithon.{Agents, Memory, Repo, Timezones}
  alias Maraithon.Todos
  alias Maraithon.Todos.Brief
  alias Maraithon.Todos.Todo

  @user_email "todos-live@example.com"

  setup %{conn: conn} do
    Repo.delete_all(from todo in Todo, where: todo.user_id == ^@user_email)

    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders work items on their own page and highlights the Work nav", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to Michael Berlingo",
                 "summary" => "Starteryou UGC Campaigns needs a concrete next step.",
                 "next_action" => "Draft a reply with status, owner, and ETA.",
                 "priority" => 91,
                 "dedupe_key" => "todos-live:render:one",
                 "metadata" => %{"account" => @user_email}
               }
             ])

    {:ok, view, _html} = live(conn, "/todos")
    html = render(view)

    assert html =~ "Work list"
    assert html =~ "Reply to Michael Berlingo"
    assert html =~ "Starteryou UGC Campaigns"
    assert html =~ "Draft a reply with current status, a clear owner, and timing."
    assert html =~ "follow-ups that need confirmation"
    assert html =~ "personal commitments"
    assert html =~ "1 work item shown."
    assert html =~ "Search"
    assert html =~ "Status"
    assert html =~ "Attention"
    assert html =~ "Due"
    assert html =~ "Past due"
    refute html =~ "Overdue"
    assert html =~ "Added by you"
    refute html =~ "Late"
    refute html =~ "stale follow-ups"
    refute html =~ "personal tasks"
    refute html =~ "todo shown"
    refute html =~ "Draft a reply with status, owner, and ETA."
    refute html =~ ">Manual<"
    assert has_element?(view, "a[href='/todos'][aria-current='page']", "Work")

    row_html =
      view
      |> element("#todo-#{todo.id}")
      |> render()

    assert row_html =~ "Critical"
    refute row_html =~ ">91<"

    detail_html =
      view
      |> element("#todo-#{todo.id}")
      |> render_click()

    assert detail_html =~ "Critical"
    refute detail_html =~ "priority 91"
    refute detail_html =~ ">91<"
  end

  test "empty work list copy stays user-facing", %{conn: conn} do
    {:ok, view, html} = live(conn, "/todos")

    assert html =~ "Add follow-up"
    assert html =~ "Your open work list is clear."
    assert html =~ "when the next move is clear"
    refute html =~ "No work items match these filters."
    refute html =~ "No active work right now"
    refute html =~ "No todos"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "",
        "status" => "done",
        "attention" => "all",
        "due" => "all",
        "source" => "all"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "No completed work in this filter."
    refute html =~ "No work items match these filters."
    refute html =~ "visible in this view"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "",
        "status" => "active",
        "attention" => "all",
        "due" => "overdue",
        "source" => "all"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "No past-due work in this filter."
    refute html =~ "No work items match these filters."
    refute html =~ "visible in this view"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "",
        "status" => "active",
        "attention" => "all",
        "due" => "all",
        "source" => "imessage"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "No work from iMessage in this filter."
    refute html =~ "No work items match these filters."
    refute html =~ "visible in this view"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "nothing here",
        "status" => "active",
        "attention" => "all",
        "due" => "all",
        "source" => "all"
      }
    )
    |> render_change()

    assert render(view) =~ "No work matches that search."
  end

  test "creates manual follow-ups scoped to the signed-in user", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/todos")

    view
    |> form("#new-todo-form",
      todo: %{
        "title" => "Call Sarah about renewal",
        "next_action" => "Confirm renewal timeline and owner.",
        "due_at" => "2026-06-04T09:30",
        "priority" => "75",
        "notes" => "Mention budget sensitivity before confirming the ETA."
      }
    )
    |> render_submit()

    [todo] = Todos.list_for_user(@user_email, source: "manual", limit: 5)

    assert_patch(view, "/todos/#{todo.id}")

    html = render(view)
    assert html =~ "Added follow-up."
    assert html =~ "Call Sarah about renewal"
    assert html =~ "Confirm renewal timeline and owner."
    assert html =~ "Mention budget sensitivity before confirming the ETA."
    assert html =~ "Added by you"
    assert html =~ "High"

    assert todo.user_id == @user_email
    assert todo.owner_user_id == @user_email
    assert todo.source == "manual"
    assert todo.priority == 75
    assert DateTime.truncate(todo.due_at, :second) == ~U[2026-06-04 14:30:00Z]
    assert todo.metadata["created_from"] == "todos_web"

    other_email = "todos-live-other-#{System.unique_integer([:positive])}@example.com"
    other_conn = log_in_test_user(build_conn(), other_email)

    {:ok, _other_view, other_html} = live(other_conn, "/todos")

    refute other_html =~ "Call Sarah about renewal"
  end

  test "manual follow-up form validates user input", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/todos")

    html =
      view
      |> form("#new-todo-form",
        todo: %{
          "title" => "Pay",
          "next_action" => "ok",
          "due_at" => "not-a-date",
          "priority" => "90",
          "notes" => "Keep this note in the form."
        }
      )
      |> render_submit()

    assert html =~ "Check the follow-up details and try again."
    assert html =~ "Enter a work item with at least 4 characters."
    assert html =~ "Enter a next action with at least 4 characters."
    assert html =~ "Enter a valid due date and time."
    assert html =~ "Keep this note in the form."
    assert Todos.list_for_user(@user_email, source: "manual", limit: 5) == []
  end

  test "generated work source is labeled as Maraithon", %{conn: conn} do
    assert {:ok, [_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "title" => "Review generated work item",
                 "summary" => "This item was created from Maraithon operating context.",
                 "next_action" => "Review the context and decide whether to keep it open.",
                 "dedupe_key" => "todos-live:system-source"
               }
             ])

    {:ok, _view, html} = live(conn, "/todos")

    assert html =~ "Review generated work item"
    assert html =~ "Maraithon"
    refute html =~ "&gt;System&lt;"
    refute html =~ "Unknown"
  end

  test "renders and filters work dates in the Chief of Staff timezone", %{conn: conn} do
    {:ok, _agent} =
      Agents.create_agent(%{
        user_id: @user_email,
        behavior: "founder_followthrough_agent",
        config: %{"timezone" => "America/Toronto", "timezone_offset_hours" => -5}
      })

    local_today = local_today("America/Toronto", -5)

    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Send the board packet",
                 "summary" => "The board packet is due before the afternoon review.",
                 "next_action" => "Send the board packet and confirm the review window.",
                 "priority" => 90,
                 "due_at" => ~U[2026-05-30 18:30:00Z],
                 "dedupe_key" => "todos-live:timezone:board-packet"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Today local follow-up",
                 "summary" => "This should appear in the local today filter.",
                 "next_action" => "Handle the local today follow-up.",
                 "due_at" => local_to_utc(local_today, ~T[10:00:00], "America/Toronto", -5),
                 "dedupe_key" => "todos-live:timezone:today"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Tomorrow local follow-up",
                 "summary" => "This should not appear in the local today filter.",
                 "next_action" => "Handle this tomorrow.",
                 "due_at" =>
                   local_to_utc(Date.add(local_today, 1), ~T[10:00:00], "America/Toronto", -5),
                 "dedupe_key" => "todos-live:timezone:tomorrow"
               }
             ])

    {:ok, _view, html} = live(conn, "/todos")

    assert html =~ "May 30, 2026 at 2:30 PM ET"
    refute html =~ "2026-05-30 18:30 UTC"

    {:ok, _view, today_html} = live(conn, "/todos?due=today")

    assert today_html =~ "Today local follow-up"
    refute today_html =~ "Tomorrow local follow-up"
  end

  test "next 7 days filter excludes past-due work", %{conn: conn} do
    now = DateTime.utc_now()

    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Expired renewal follow-up",
                 "summary" => "This should stay in the Past due filter.",
                 "next_action" => "Handle the late renewal separately.",
                 "due_at" => DateTime.add(now, -1, :hour),
                 "dedupe_key" => "todos-live:week-filter:past"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Upcoming board review",
                 "summary" => "This should appear in the next seven days.",
                 "next_action" => "Send the board review notes.",
                 "due_at" => DateTime.add(now, 2, :day),
                 "dedupe_key" => "todos-live:week-filter:soon"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Later offsite prep",
                 "summary" => "This is beyond the next seven days.",
                 "next_action" => "Prepare the later offsite packet.",
                 "due_at" => DateTime.add(now, 8, :day),
                 "dedupe_key" => "todos-live:week-filter:later"
               }
             ])

    {:ok, _view, html} = live(conn, "/todos?due=week")

    assert html =~ "Next 7 days"
    assert html =~ "Upcoming board review"
    refute html =~ "Expired renewal follow-up"
    refute html =~ "Later offsite prep"
  end

  test "searches and filters todos through query-backed controls", %{conn: conn} do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Boardy follow-up",
                 "summary" => "Send the recap.",
                 "next_action" => "Draft the Boardy recap.",
                 "priority" => 85,
                 "dedupe_key" => "todos-live:filter:boardy"
               },
               %{
                 "source" => "slack",
                 "kind" => "general",
                 "title" => "Slack monitor item",
                 "summary" => "Watch the thread.",
                 "next_action" => "Keep monitoring.",
                 "attention_mode" => "monitor",
                 "priority" => 50,
                 "dedupe_key" => "todos-live:filter:slack"
               }
             ])

    {:ok, view, _html} = live(conn, "/todos")

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "Boardy",
        "status" => "active",
        "attention" => "all",
        "due" => "all",
        "source" => "all"
      }
    )
    |> render_change()

    assert_patch(view, "/todos?q=Boardy")

    html = render(view)
    assert html =~ "Boardy follow-up"
    refute html =~ "Slack monitor item"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "",
        "status" => "active",
        "attention" => "monitor",
        "due" => "all",
        "source" => "slack"
      }
    )
    |> render_change()

    html = render(view)
    assert html =~ "Slack monitor item"
    refute html =~ "Boardy follow-up"
  end

  test "decisions filter shows only work waiting on an operator choice", %{conn: conn} do
    assert {:ok, [decision, _reference]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Approve investor reply",
                 "summary" => "The investor asked whether the revised terms are approved.",
                 "next_action" => "Send the revised terms and confirm the review window.",
                 "priority" => 88,
                 "dedupe_key" => "todos-live:decision-filter:investor",
                 "metadata" => %{
                   "account" => @user_email,
                   "person" => "Jordan Lee",
                   "why_now" => "Jordan is waiting on your approval.",
                   "source_quote" => "Can you approve the revised terms?"
                 }
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Read market update",
                 "summary" => "Background market note for later reference.",
                 "next_action" => "File the note.",
                 "priority" => 35,
                 "dedupe_key" => "todos-live:decision-filter:reference"
               }
             ])

    {:ok, view, html} = live(conn, "/todos?attention=decision")

    assert html =~ "Decisions"
    assert html =~ "Approve investor reply"
    assert html =~ "Decision"
    assert html =~ "Recommended:"
    refute html =~ "Next:"
    refute html =~ "Read market update"

    detail_html =
      view
      |> element("#todo-#{decision.id}")
      |> render_click()

    assert_patch(view, "/todos/#{decision.id}?attention=decision")
    assert detail_html =~ "Approve investor reply"
    assert detail_html =~ "Brief"
    assert detail_html =~ "Send the revised terms and confirm the review window."
    refute detail_html =~ "Thinking it through"
    refute detail_html =~ ~s(aria-busy="true")
    refute detail_html =~ "Decision to make"
    refute detail_html =~ "Sources checked"
    refute detail_html =~ "Supporting details"
    refute detail_html =~ "Decision ready for review"
    refute detail_html =~ "Handle this now, snooze it, or dismiss it."

    # The brief is generated asynchronously on the brief model tier.
    brief_html = render_async(view, 10_000)
    assert brief_html =~ "Why this matters"
    assert brief_html =~ "Mock Person is blocked on this and it is due today."
    assert brief_html =~ "Do this"
    assert brief_html =~ "Send the reply below and mark it done."
    assert brief_html =~ "Reply to"
    assert brief_html =~ "Thanks for the nudge"
  end

  test "detail panel keeps source-health internals off the page", %{
    conn: conn
  } do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Confirm Tuesday pickup with school",
                 "summary" => "The school asked whether Tuesday pickup should move to 4 PM.",
                 "next_action" => "Confirm the Tuesday pickup plan with the school.",
                 "priority" => 92,
                 "dedupe_key" => "todos-live:source-gap:school-pickup",
                 "metadata" => %{
                   "life_domain" => "family",
                   "source_evidence" =>
                     "The school asked whether Tuesday pickup should move to 4 PM.",
                   "record" => %{
                     "person" => "Oak Street School",
                     "relationship_context" => "school logistics"
                   }
                 }
               }
             ])

    {:ok, view, _html} = live(conn, "/todos?todo_id=#{todo.id}")

    detail_html =
      view
      |> element("#todo-detail")
      |> render()

    assert detail_html =~ "Confirm Tuesday pickup with school"
    assert detail_html =~ "Source"
    assert detail_html =~ "Gmail"
    refute detail_html =~ "Sources checked"
    refute detail_html =~ "source_health"
    refute detail_html =~ "desktop: not connected"
    refute detail_html =~ "school logistics"
  end

  test "a precomputed Gmail brief opens with thread history and an inline reply", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Send Michael your availability",
                 "summary" => "Michael is waiting for evening availability.",
                 "next_action" => "Reply with availability.",
                 "priority" => 90,
                 "dedupe_key" => "todos-live:precomputed-email-thread",
                 "metadata" => %{"account" => @user_email, "person" => "Michael Lippi"}
               }
             ])

    reply = %{
      "channel" => "gmail",
      "to" => "michael@example.com",
      "subject" => "Re: Great Catching Up",
      "body" => "Hi Michael,\n\nChristina and I are free Tuesday evening.\n\nKent",
      "resolves_todo" => true
    }

    brief = %{
      "version" => Brief.version(),
      "fingerprint" => Brief.fingerprint(todo),
      "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "why_it_matters" => "Michael is waiting to schedule the conversation.",
      "situation" => "You committed to check with Christina and reply.",
      "recommendation" => "Send the prepared reply.",
      "reply" => reply,
      "source_subject" => "Great Catching Up",
      "source_history" => [
        %{
          "speaker" => "Michael Lippi",
          "at" => "Today at 12:56 PM",
          "text" => "Let me know when you and Christina are available."
        },
        %{
          "speaker" => "Kent",
          "at" => "Today at 1:10 PM",
          "text" => "I will sync with Christina tonight.",
          "from_user" => true
        }
      ]
    }

    assert {:ok, _briefed} =
             Todos.put_brief(
               @user_email,
               todo.id,
               brief,
               Brief.action_draft_from_reply(reply)
             )

    {:ok, view, html} = live(conn, "/todos?todo_id=#{todo.id}")

    assert html =~ "Email thread"
    assert html =~ "Great Catching Up"
    assert html =~ "Michael Lippi"
    assert html =~ "I will sync with Christina tonight."
    assert html =~ "Review the wording, then send without leaving this todo."
    assert has_element?(view, "#todo-source-history")
    assert has_element?(view, "#todo-reply-form")
    assert has_element?(view, "#todo-reply-form button", "Send email")
    refute html =~ "Thinking it through"
  end

  test "source filter includes local companion sources", %{conn: conn} do
    assert {:ok, [imessage_todo, _notes_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "imessage",
                 "kind" => "local_followup",
                 "title" => "Reply to iMessage thread",
                 "summary" => "A local message needs a response.",
                 "next_action" => "Reply with the updated pickup plan.",
                 "priority" => 82,
                 "dedupe_key" => "todos-live:source-filter:imessage"
               },
               %{
                 "source" => "notes",
                 "kind" => "local_note",
                 "title" => "Review Notes context",
                 "summary" => "A note captured useful planning context.",
                 "next_action" => "Pull the note into the plan.",
                 "priority" => 60,
                 "dedupe_key" => "todos-live:source-filter:notes"
               }
             ])

    {:ok, view, html} = live(conn, "/todos")

    source_filter_html =
      view
      |> element("select[name='filters[source]']")
      |> render()

    assert source_filter_html =~ "Calendar"
    assert source_filter_html =~ "iMessage"
    assert source_filter_html =~ "Notes"
    assert source_filter_html =~ "Reminders"
    assert source_filter_html =~ "Files"
    assert source_filter_html =~ "Browser History"
    assert source_filter_html =~ "Voice Memos"

    assert html =~ "iMessage"
    assert html =~ "Notes"

    view
    |> form("#todo-filters",
      filters: %{
        "q" => "",
        "status" => "active",
        "attention" => "all",
        "due" => "all",
        "source" => "imessage"
      }
    )
    |> render_change()

    assert_patch(view, "/todos?source=imessage")

    html = render(view)
    assert html =~ "Reply to iMessage thread"
    assert html =~ "iMessage"
    refute html =~ "Review Notes context"

    imessage_row =
      view
      |> element("#todo-#{imessage_todo.id}")
      |> render()

    refute imessage_row =~ "Google Calendar"
  end

  test "sorts by table columns using database-backed order", %{conn: conn} do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Low priority todo",
                 "summary" => "Lower priority work.",
                 "next_action" => "Handle later.",
                 "priority" => 20,
                 "dedupe_key" => "todos-live:sort:low"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "High priority todo",
                 "summary" => "Higher priority work.",
                 "next_action" => "Handle first.",
                 "priority" => 95,
                 "dedupe_key" => "todos-live:sort:high"
               }
             ])

    {:ok, _view, asc_html} = live(conn, "/todos?sort=priority&dir=asc")
    assert String.match?(asc_html, ~r/Low priority work item.*High priority work item/s)

    {:ok, _view, desc_html} = live(conn, "/todos?sort=priority&dir=desc")
    assert String.match?(desc_html, ~r/High priority work item.*Low priority work item/s)
  end

  test "bulk marks selected todos done", %{conn: conn} do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Bulk todo one",
                 "summary" => "First selected todo.",
                 "next_action" => "Handle the first selected todo.",
                 "priority" => 91,
                 "dedupe_key" => "todos-live:bulk:one"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Bulk todo two",
                 "summary" => "Second selected todo.",
                 "next_action" => "Handle the second selected todo.",
                 "priority" => 90,
                 "dedupe_key" => "todos-live:bulk:two"
               }
             ])

    {:ok, view, _html} = live(conn, "/todos")
    [first, second] = Todos.list_open_for_user(@user_email, limit: 2)

    view
    |> element("input[phx-click='toggle_todo_selection'][phx-value-id='#{first.id}']")
    |> render_click()

    view
    |> element("input[phx-click='toggle_todo_selection'][phx-value-id='#{second.id}']")
    |> render_click()

    assert render(view) =~ "2 selected"

    view
    |> element("#todo-bulk-actions button[phx-click='complete_selected_todos']")
    |> render_click()

    assert Todos.list_open_for_user(@user_email) == []
    refute has_element?(view, "#todo-#{first.id}")
    refute has_element?(view, "#todo-#{second.id}")
  end

  test "row Done action completes the todo without blocking the LiveView click", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Finish the row action",
                 "summary" => "The row action should reach the server.",
                 "next_action" => "Mark this work item done.",
                 "priority" => 90,
                 "dedupe_key" => "todos-live:row-done"
               }
             ])

    {:ok, view, _html} = live(conn, "/todos")

    assert has_element?(view, "#todo-#{todo.id} button[phx-click='complete_todo']", "Done")
    refute has_element?(view, "#todo-#{todo.id} button[phx-click='complete_todo'][onclick]")

    refute has_element?(
             view,
             "#todo-#{todo.id} input[phx-click='toggle_todo_selection'][onclick]"
           )

    view
    |> element("#todo-#{todo.id} button[phx-click='complete_todo']")
    |> render_click()

    assert Todos.get_for_user(@user_email, todo.id).status == "done"
    refute has_element?(view, "#todo-#{todo.id}")
  end

  test "Gmail-style shortcuts move, select, open, complete, and dismiss the active todo", %{
    conn: conn
  } do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "First shortcut todo",
                 "summary" => "This should be active first.",
                 "next_action" => "Open the first todo.",
                 "priority" => 99,
                 "dedupe_key" => "todos-live:shortcuts:first"
               },
               %{
                 "source" => "slack",
                 "kind" => "general",
                 "title" => "Second shortcut todo",
                 "summary" => "This should be active second.",
                 "next_action" => "Complete the second todo.",
                 "priority" => 90,
                 "dedupe_key" => "todos-live:shortcuts:second"
               },
               %{
                 "source" => "calendar",
                 "kind" => "general",
                 "title" => "Third shortcut todo",
                 "summary" => "This should be dismissed last.",
                 "next_action" => "Dismiss the third todo.",
                 "priority" => 80,
                 "dedupe_key" => "todos-live:shortcuts:third"
               }
             ])

    [first, second, third] = Todos.list_for_user(@user_email, statuses: ["open"], limit: 3)
    {:ok, view, _html} = live(conn, "/todos")

    assert has_element?(view, "#todo-keyboard-scope[data-view='index']")
    assert has_element?(view, "#todo-#{first.id}[data-active='true'][aria-current='true']")
    refute has_element?(view, "#todo-#{second.id}[data-active='true']")

    render_hook(view, "todo_shortcut", %{"key" => "j"})
    assert has_element?(view, "#todo-#{second.id}[data-active='true'][aria-current='true']")

    render_hook(view, "todo_shortcut", %{"key" => "x"})

    assert has_element?(
             view,
             "#todo-#{second.id} input[phx-click='toggle_todo_selection'][checked]"
           )

    assert render(view) =~ "1 selected"

    render_hook(view, "todo_shortcut", %{"key" => "k"})
    assert has_element?(view, "#todo-#{first.id}[data-active='true']")

    render_hook(view, "todo_shortcut", %{"key" => "o"})
    assert_patch(view, "/todos/#{first.id}")
    assert has_element?(view, "#todo-keyboard-scope[data-view='detail']")

    render_hook(view, "todo_shortcut", %{"key" => "j"})
    assert_patch(view, "/todos/#{second.id}")

    render_hook(view, "todo_shortcut", %{"key" => "u"})
    assert_patch(view, "/todos")
    assert has_element?(view, "#todo-#{second.id}[data-active='true']")

    render_hook(view, "resolve_todo_shortcut", %{
      "action" => "complete",
      "id" => second.id
    })

    assert Todos.get_for_user(@user_email, second.id).status == "done"
    refute has_element?(view, "#todo-#{second.id}")
    assert has_element?(view, "#todo-#{third.id}[data-active='true']")

    render_hook(view, "resolve_todo_shortcut", %{
      "action" => "dismiss",
      "id" => third.id
    })

    assert Todos.get_for_user(@user_email, third.id).status == "dismissed"
    refute has_element?(view, "#todo-#{third.id}")
    assert has_element?(view, "#todo-#{first.id}[data-active='true']")
  end

  test "shortcut help is rendered up front for instant client-side display", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/todos")

    assert has_element?(
             view,
             "#todo-keyboard-scope[data-shortcuts-ready='false'][aria-busy='true']"
           )

    assert has_element?(
             view,
             "#todo-loading-shell[data-todo-loading-shell='true'][role='status']"
           )

    assert has_element?(view, "#todo-loading-shell .todo-boot-sr-only", "Loading todos…")
    assert has_element?(view, "#todo-loading-shell .todo-boot-nav")
    assert has_element?(view, "#todo-loading-shell .todo-boot-table")

    assert has_element?(
             view,
             "#todo-ready-content[data-todo-ready-content='true'][hidden][inert][aria-hidden='true']"
           )

    assert has_element?(
             view,
             "#todo-shortcuts-trigger[data-shortcuts-trigger='true']",
             "Shortcuts"
           )

    assert has_element?(view, "#todo-shortcuts-modal[data-shortcuts-modal='true'][hidden]")
    assert has_element?(view, "#todo-shortcuts-modal [role='dialog'][aria-modal='true']")
    assert has_element?(view, "#todo-shortcuts-close[data-shortcuts-close='true']")
    assert render(view) =~ "The blue row is the active todo."
    assert render(view) =~ "Mark done"
    assert render(view) =~ "Focus search"
  end

  test "bulk see less records feedback and dismisses selected todos", %{conn: conn} do
    install_see_less_model()

    assert {:ok, [first, second]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Read vendor newsletter one",
                 "summary" => "A generic vendor newsletter has no direct ask.",
                 "next_action" => "No action needed.",
                 "priority" => 42,
                 "dedupe_key" => "todos-live:bulk-see-less:one"
               },
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Read vendor newsletter two",
                 "summary" => "Another generic vendor newsletter with no direct ask.",
                 "next_action" => "No action needed.",
                 "priority" => 41,
                 "dedupe_key" => "todos-live:bulk-see-less:two"
               }
             ])

    {:ok, view, _html} = live(conn, "/todos")

    view
    |> element("input[phx-click='toggle_todo_selection'][phx-value-id='#{first.id}']")
    |> render_click()

    view
    |> element("input[phx-click='toggle_todo_selection'][phx-value-id='#{second.id}']")
    |> render_click()

    view
    |> element("#todo-bulk-actions button[phx-click='see_less_selected_todos']")
    |> render_click()

    html = render(view)
    refute html =~ "Read vendor newsletter one"
    refute html =~ "Read vendor newsletter two"
    assert html =~ "Similar work will show up less often"
    assert Todos.get_for_user(@user_email, first.id).status == "dismissed"
    assert Todos.get_for_user(@user_email, second.id).status == "dismissed"
  end

  test "opens detail panel from selected todo URL and row click", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Review detail todo",
                 "summary" => "This todo should show a fuller detail view.",
                 "next_action" => "Open the thread and reply.",
                 "notes" => "Keep the answer short.",
                 "action_plan" => "Check context, draft reply, send.",
                 "priority" => 94,
                 "dedupe_key" => "todos-live:detail",
                 "metadata" => %{
                   "account" => @user_email,
                   "person" => "Michael Berlingo",
                   "company" => "Starteryou",
                   "subject" => "Starteryou campaign reply",
                   "why_it_matters" => "Michael is waiting on the campaign decision.",
                   "source_quote" => "The customer asked for a status, owner, and ETA.",
                   "resolution_note" => "Archive-only implementation detail.",
                   "thread_id" => "thread-123",
                   "source_insight_id" => "insight-secret",
                   "confidence" => 0.96,
                   "model_rationale" => "Model score says this matters.",
                   "token" => "secret-token"
                 }
               }
             ])

    {:ok, view, _html} = live(conn, "/todos?todo_id=#{todo.id}")
    _html = render(view)

    detail_html =
      view
      |> element("#todo-detail")
      |> render()

    assert has_element?(view, "#todo-detail")
    assert detail_html =~ "Review detail work item"
    assert detail_html =~ "This work item should show a fuller detail view."
    assert detail_html =~ "Brief"
    assert detail_html =~ @user_email
    assert detail_html =~ "Back to todos"
    assert detail_html =~ "Ask Maraithon"
    assert detail_html =~ "Mark done"
    assert has_element?(view, "#todo-next-action-form-#{todo.id}")
    refute detail_html =~ "Decision to make"
    refute detail_html =~ "Recommended move"
    refute detail_html =~ "Sources checked"
    refute detail_html =~ "Supporting details"
    refute detail_html =~ "Source metadata"
    refute detail_html =~ "Decision context"
    refute detail_html =~ "Decision ready for review"
    refute detail_html =~ "Source evidence"
    refute detail_html =~ "Archive-only implementation detail"
    refute detail_html =~ "Resolution note"
    refute detail_html =~ "thread-123"
    refute detail_html =~ "insight-secret"
    refute detail_html =~ "confidence"
    refute detail_html =~ "Model score"
    refute detail_html =~ "secret-token"

    brief_html = render_async(view, 10_000)
    assert brief_html =~ "Why this matters"
    assert brief_html =~ "The situation"
    assert brief_html =~ "Do this"
    assert brief_html =~ "Open the source thread and confirm nothing changed."
    assert brief_html =~ "Under 2 minutes"
    assert brief_html =~ "Reply to"
    assert brief_html =~ "Subject"
    assert brief_html =~ "Re: Mock thread"
    assert brief_html =~ "Thanks for the nudge"
    assert brief_html =~ "Copy"
    assert brief_html =~ "Open in Gmail"
    # The Gmail deep link intentionally carries the thread id, the same way
    # the mobile source_action does. Internal scoring fields still must not
    # reach the page.
    assert brief_html =~ "mail.google.com/mail/u/0/#all/thread-123"
    refute brief_html =~ "secret-token"

    assert Todos.get_for_user(@user_email, todo.id).action_draft["style"] == "ready_to_send"

    {:ok, click_view, _html} = live(conn, "/todos")

    click_view
    |> element("#todo-#{todo.id}")
    |> render_click()

    assert_patch(click_view, "/todos/#{todo.id}")
    assert render(click_view) =~ "Review detail work item"
  end

  test "detail actions stay at the top and completion advances to the next todo", %{conn: conn} do
    assert {:ok, _todos} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "First ranked detail todo",
                 "summary" => "Complete this one first.",
                 "next_action" => "Finish the first item.",
                 "priority" => 99,
                 "dedupe_key" => "todos-live:detail-navigation:first"
               },
               %{
                 "source" => "slack",
                 "kind" => "general",
                 "title" => "Second ranked detail todo",
                 "summary" => "This item should open next.",
                 "next_action" => "Continue with the second item.",
                 "priority" => 80,
                 "dedupe_key" => "todos-live:detail-navigation:second"
               }
             ])

    [first, second] = Todos.list_for_user(@user_email, statuses: ["open"], limit: 2)
    {:ok, view, _html} = live(conn, "/todos/#{first.id}")

    assert has_element?(
             view,
             "#todo-keyboard-scope[phx-hook='.TodoKeyboardShortcuts'][data-view='detail']"
           )

    assert has_element?(view, "#todo-detail > header #todo-primary-actions")

    assert has_element?(
             view,
             "#todo-primary-actions button[phx-click='complete_todo']",
             "Mark done"
           )

    assert has_element?(view, "#todo-primary-actions a", "Ask Maraithon")
    refute has_element?(view, "#todo-detail aside button[phx-click='complete_todo']")
    assert has_element?(view, "#previous-todo[disabled]")

    assert has_element?(
             view,
             "#next-todo[href='/todos/#{second.id}'][aria-keyshortcuts='ArrowRight J']"
           )

    view
    |> element("#next-todo")
    |> render_click()

    assert_patch(view, "/todos/#{second.id}")

    assert has_element?(
             view,
             "#previous-todo[href='/todos/#{first.id}'][aria-keyshortcuts='ArrowLeft K']"
           )

    view
    |> element("#previous-todo")
    |> render_click()

    assert_patch(view, "/todos/#{first.id}")

    view
    |> element("#todo-primary-actions button[phx-click='complete_todo']")
    |> render_click()

    assert_patch(view, "/todos/#{second.id}")
    assert Todos.get_for_user(@user_email, first.id).status == "done"
    assert render(view) =~ "Second ranked detail work item"
  end

  test "detail panel edits the next action without losing context", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply to board packet",
                 "summary" => "A board member is waiting on the financing packet.",
                 "next_action" => "Send the old packet.",
                 "notes" => "Keep the response concise.",
                 "priority" => 92,
                 "dedupe_key" => "todos-live:edit-next-action"
               }
             ])

    {:ok, view, _html} = live(conn, "/todos?todo_id=#{todo.id}")

    view
    |> form("#todo-next-action-form-#{todo.id}",
      todo: %{
        "next_action" => "Send the financing packet and confirm the next review window."
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Updated next action."
    assert html =~ "Send the financing packet and confirm the next review window."
    refute html =~ "Send the old packet."

    updated = Todos.get_for_user(@user_email, todo.id)
    assert updated.title == "Reply to board packet"
    assert updated.summary == "A board member is waiting on the financing packet."
    assert updated.notes == "Keep the response concise."
    assert updated.next_action == "Send the financing packet and confirm the next review window."
  end

  test "see less action records feedback memory and removes todo from active list", %{conn: conn} do
    install_see_less_model()

    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Read vendor newsletter",
                 "summary" => "A generic vendor newsletter has no direct ask.",
                 "next_action" => "No action needed.",
                 "priority" => 42,
                 "dedupe_key" => "todos-live:see-less"
               }
             ])

    {:ok, view, html} = live(conn, "/todos")
    assert html =~ "Read vendor newsletter"

    view
    |> element("#todo-#{todo.id} button[phx-click='see_less_todo']")
    |> render_click()

    html = render(view)
    refute html =~ "Read vendor newsletter"
    assert html =~ "Similar work will show up less often."

    [memory] =
      Memory.list_items(@user_email,
        kind: "relevance_feedback",
        tag: "todo_relevance",
        limit: 5
      )

    assert memory.polarity == "negative"
    assert memory.source_ref_id == todo.id

    dismissed = Todos.get_for_user(@user_email, todo.id)
    assert dismissed.status == "dismissed"
    assert get_in(dismissed.metadata, ["assistant_feedback", "value"]) == "see_less"
  end

  test "todo action errors hide internal reasons", %{conn: conn} do
    actions = [
      {"Complete stale todo", "complete_todo", "todos-live:stale-complete"},
      {"Dismiss stale todo", "dismiss_todo", "todos-live:stale-dismiss"},
      {"Show less unavailable work item", "see_less_todo", "todos-live:stale-show-less"}
    ]

    for {title, click, dedupe_key} <- actions do
      assert {:ok, [todo]} =
               Todos.upsert_many(@user_email, [
                 %{
                   "source" => "gmail",
                   "kind" => "gmail_triage",
                   "title" => title,
                   "summary" => "This row will be stale before the action.",
                   "next_action" => "Use the stale action.",
                   "priority" => 90,
                   "dedupe_key" => dedupe_key
                 }
               ])

      {:ok, view, _html} = live(conn, "/todos")

      Maraithon.Repo.delete!(todo)

      html =
        view
        |> element("#todo-#{todo.id} button[phx-click='#{click}']")
        |> render_click()

      refute html =~ title
      refute html =~ ":not_found"
      refute html =~ "not_found"
    end
  end

  defp install_see_less_model do
    original = Application.get_env(:maraithon, :todos, [])

    Application.put_env(
      :maraithon,
      :todos,
      Keyword.put(original, :see_less_llm_complete, fn prompt ->
        assert prompt =~ "TODO_SEE_LESS_TRAINING_JSON_V1"

        {:ok,
         Jason.encode!(%{
           "title" => "Show less: generic newsletters",
           "summary" => "Generic newsletters without direct asks should not become todos.",
           "content" =>
             "When a newsletter has no direct ask, decision, deadline, or personal impact, skip it instead of creating a todo.",
           "pattern_key" => "generic_newsletters_without_direct_asks",
           "categories" => ["newsletter", "no_direct_ask"],
           "negative_signals" => ["generic update", "no direct ask"],
           "exceptions" => ["explicit deadline"],
           "confidence" => 0.88,
           "reasoning" => "The selected todo is not actionable."
         })}
      end)
    )

    on_exit(fn -> Application.put_env(:maraithon, :todos, original) end)
  end

  defp local_today(timezone_name, fallback_offset) do
    now = DateTime.utc_now()
    offset = Timezones.offset_at(timezone_name, now, fallback_offset)

    now
    |> DateTime.add(offset, :hour)
    |> DateTime.to_date()
  end

  defp local_to_utc(date, time, timezone_name, fallback_offset) do
    local = DateTime.new!(date, time, "Etc/UTC")
    offset = Timezones.offset_for_local(timezone_name, local, fallback_offset)
    DateTime.add(local, -offset, :hour)
  end
end
