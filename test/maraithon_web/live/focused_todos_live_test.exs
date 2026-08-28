defmodule MaraithonWeb.FocusedTodosLiveTest do
  use MaraithonWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Maraithon.Repo
  alias Maraithon.Todos
  alias Maraithon.Todos.Todo

  @user_email "focused-todos-live@example.com"

  setup %{conn: conn} do
    Repo.delete_all(from todo in Todo, where: todo.user_id == ^@user_email)
    {:ok, conn: log_in_test_user(conn, @user_email)}
  end

  test "authenticated shell keeps Todos primary and Apps available for connections", %{conn: conn} do
    assert {:ok, [_todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "manual",
                 "kind" => "general",
                 "title" => "Prepare the launch update",
                 "summary" => "The team needs a concise status update.",
                 "next_action" => "Confirm the remaining owner and send the update.",
                 "priority" => 80,
                 "dedupe_key" => "focused-todos-live:list"
               }
             ])

    {:ok, view, html} = live(conn, "/todos")

    assert html =~ "Maraithon"
    assert html =~ "Todos"
    assert html =~ "Prepare the launch update"
    assert html =~ "Confirm the remaining owner and send the update."
    assert html =~ "Add a todo"
    assert html =~ "Search and filter"
    assert has_element?(view, "a[href='/connectors']", "Apps")
    refute html =~ ">Settings<"
    refute html =~ "Primary navigation"
    refute has_element?(view, "#todo-detail")
  end

  test "todo route leads with resolution guidance and safe supporting details", %{conn: conn} do
    assert {:ok, [todo]} =
             Todos.upsert_many(@user_email, [
               %{
                 "source" => "gmail",
                 "kind" => "gmail_triage",
                 "title" => "Reply with the launch decision",
                 "summary" => "A teammate is waiting for the final decision.",
                 "next_action" => "Send the decision and name the owner.",
                 "notes" => "Keep the reply concise.",
                 "action_plan" => "Review the evidence, confirm the owner, and reply.",
                 "priority" => 90,
                 "dedupe_key" => "focused-todos-live:detail",
                 "metadata" => %{
                   "person" => "Launch teammate",
                   "why_now" => "The next phase is blocked on this answer.",
                   "source_quote" => "Can you confirm the decision and owner?",
                   "token" => "must-not-render"
                 }
               }
             ])

    {:ok, view, html} = live(conn, "/todos/#{todo.id}")

    assert has_element?(view, "#todo-detail")
    assert html =~ "Brief"
    assert html =~ "Reply with the launch decision"
    assert html =~ "Back to todos"
    assert html =~ "Ask Maraithon"
    refute html =~ "How to solve this"
    refute html =~ "Supporting details"
    refute html =~ "must-not-render"

    brief_html = render_async(view, 10_000)
    assert brief_html =~ "Why this matters"
    assert brief_html =~ "Do this"
    assert brief_html =~ "Send the reply below and mark it done."
    refute brief_html =~ "must-not-render"
  end
end
