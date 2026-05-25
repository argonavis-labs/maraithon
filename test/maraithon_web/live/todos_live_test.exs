defmodule MaraithonWeb.TodosLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Todos

  @user_email "todos-live@example.com"

  setup %{conn: conn} do
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "renders todos on their own page and highlights the Todos nav", %{conn: conn} do
    assert {:ok, _todos} =
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

    {:ok, view, html} = live(conn, "/todos")

    assert html =~ "Todo list"
    assert html =~ "Reply to Michael Berlingo"
    assert html =~ "Starteryou UGC Campaigns"
    assert html =~ "Search"
    assert html =~ "Status"
    assert html =~ "Due"
    assert has_element?(view, "a[href='/todos'][aria-current='page']", "Todos")
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
    assert String.match?(asc_html, ~r/Low priority todo.*High priority todo/s)

    {:ok, _view, desc_html} = live(conn, "/todos?sort=priority&dir=desc")
    assert String.match?(desc_html, ~r/High priority todo.*Low priority todo/s)
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
                   "thread_id" => "thread-123"
                 }
               }
             ])

    {:ok, view, html} = live(conn, "/todos?todo_id=#{todo.id}")

    assert has_element?(view, "#todo-detail")
    assert html =~ "Review detail todo"
    assert html =~ "This todo should show a fuller detail view."
    assert html =~ "Open the thread and reply."
    assert html =~ "Keep the answer short."
    assert html =~ "Source metadata"

    {:ok, click_view, _html} = live(conn, "/todos")

    click_view
    |> element("#todo-#{todo.id}")
    |> render_click()

    assert_patch(click_view, "/todos?todo_id=#{todo.id}")
    assert render(click_view) =~ "Review detail todo"
  end
end
