defmodule Maraithon.Tools.TodoToolsTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Tools

  test "built-in todo tools ingest, list, and resolve todos" do
    user_id = "todo-tools-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    assert {:ok, upserted} =
             Tools.execute("upsert_todos", %{
               "user_id" => user_id,
               "todos" => [
                 %{
                   "source" => "telegram",
                   "title" => "Renew the domain",
                   "summary" => "The domain renewal needs to be handled this week.",
                   "next_action" => "Open the registrar and renew the domain.",
                   "due_date" => "2026-05-14",
                   "dedupe_key" => "telegram:domain-renewal"
                 }
               ]
             })

    assert upserted.source == "maraithon_todos"
    assert upserted.count == 1
    assert upserted.skipped_count == 0
    assert upserted.enrichment == %{errors: [], memories: [], person_links: []}
    [todo] = upserted.todos
    assert todo.owner_user_id == user_id

    assert {:ok, open_loops} =
             Tools.execute("get_open_loops", %{
               "user_id" => user_id,
               "query" => "domain",
               "limit" => 10
             })

    assert open_loops.source == "maraithon_open_loops"
    assert open_loops.totals.open_todos == 1

    assert {:ok, listed} =
             Tools.execute("list_todos", %{
               "user_id" => user_id,
               "query" => "domain",
               "statuses" => ["open"]
             })

    assert listed.count == 1
    [listed_todo] = listed.todos
    assert listed_todo.id == todo.id

    assert {:ok, resolved} =
             Tools.execute("resolve_todo", %{
               "user_id" => user_id,
               "todo_id" => todo.id,
               "status" => "done",
               "resolution_note" => "Renewed at the registrar."
             })

    assert resolved.source == "maraithon_todos"
    assert resolved.todo.status == "done"

    assert {:ok, done_list} =
             Tools.execute("list_todos", %{
               "user_id" => user_id,
               "query" => "domain",
               "statuses" => ["done"]
             })

    assert done_list.count == 1
  end
end
