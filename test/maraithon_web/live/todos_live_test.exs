defmodule MaraithonWeb.TodosLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maraithon.Memory
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
    assert html =~ "Saved see-less feedback for 2 todos"
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
    assert html =~ "Maraithon will show fewer todos like that."

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

  defp install_see_less_model do
    original = Application.get_env(:maraithon, :todos, [])

    Application.put_env(
      :maraithon,
      :todos,
      Keyword.put(original, :see_less_llm_complete, fn prompt ->
        assert prompt =~ "TODO_SEE_LESS_TRAINING_JSON_V1"

        {:ok,
         Jason.encode!(%{
           "title" => "See less: generic newsletters",
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
end
