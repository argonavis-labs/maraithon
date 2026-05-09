defmodule Maraithon.TodosTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Todos

  test "done todos stay closed when the same work is upserted again" do
    user_id = unique_user_email("todos-closed")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due",
          summary: "The billing account is overdue and needs a user decision."
        )
      ])

    assert {:ok, done_todo} = Todos.mark_done(user_id, todo.id, note: "Handled in console.")
    assert done_todo.status == "done"

    {:ok, [reupserted]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due",
          summary: "A refreshed Gmail scan still sees the billing thread."
        )
      ])

    assert reupserted.id == todo.id
    assert reupserted.status == "done"
    assert Todos.list_open_for_user(user_id, kind: "gmail_triage") == []
  end

  test "todos can be searched by query and filtered by status" do
    user_id = unique_user_email("todos-search")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, [billing, oauth]} =
      Todos.upsert_many(user_id, [
        gmail_todo_attrs("thread-billing", "Billing account past due"),
        gmail_todo_attrs("thread-oauth", "OAuth verification reply owed",
          summary: "Google needs acknowledgement and an ETA."
        )
      ])

    assert {:ok, _done_todo} = Todos.mark_done(user_id, billing.id, note: "Paid and confirmed.")

    [open_todo] = Todos.list_open_for_user(user_id, kind: "gmail_triage")
    assert open_todo.id == oauth.id

    [done_todo] =
      Todos.list_for_user(user_id,
        statuses: ["done"],
        query: "billing",
        kind: "gmail_triage"
      )

    assert done_todo.id == billing.id
    assert done_todo.status == "done"
  end

  test "todos persist durable source, owner, due date, notes, and action draft details" do
    user_id = unique_user_email("todos-detail")
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:todos@example.com", %{
        metadata: %{"account_email" => "todos@example.com"}
      })

    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "gmail",
          "kind" => "gmail_triage",
          "title" => "Reply to renewal thread",
          "todo" => "A renewal thread needs a committed owner and ETA.",
          "next_action" => "Reply in-thread with the owner and timing.",
          "due_date" => "2026-05-14",
          "notes" => "Customer is waiting on procurement details.",
          "action_plan" => "Draft as Kent, then confirm the exact ETA before sending.",
          "action_draft" => %{kind: "gmail_reply", body: "I will confirm the ETA today."},
          "source_account_id" => account.id,
          "metadata" => %{"google_account_email" => "todos@example.com"},
          "dedupe_key" => "gmail:renewal-thread"
        }
      ])

    assert todo.owner_user_id == user_id
    assert todo.owner_label == nil
    assert todo.source_account_id == account.id
    assert todo.source_account_label == "todos@example.com"
    assert DateTime.to_date(todo.due_at) == ~D[2026-05-14]
    assert todo.summary == "A renewal thread needs a committed owner and ETA."
    assert todo.notes == "Customer is waiting on procurement details."
    assert todo.action_plan == "Draft as Kent, then confirm the exact ETA before sending."

    assert todo.action_draft == %{
             "kind" => "gmail_reply",
             "body" => "I will confirm the ETA today."
           }

    assert [todo.id] ==
             Todos.list_for_user(user_id,
               source_account_id: account.id,
               due_before: "2026-05-15",
               query: "procurement"
             )
             |> Enum.map(& &1.id)
  end

  defp gmail_todo_attrs(thread_id, title, overrides \\ []) do
    defaults = %{
      "source" => "gmail",
      "kind" => "gmail_triage",
      "attention_mode" => "act_now",
      "title" => title,
      "summary" => "This Gmail thread still needs a user response.",
      "next_action" => "Reply in-thread and close the loop.",
      "priority" => 90,
      "source_item_id" => thread_id,
      "source_occurred_at" => "2026-04-02T04:19:00Z",
      "dedupe_key" => "gmail:gmail_triage:#{thread_id}",
      "metadata" => %{
        "thread_id" => thread_id,
        "subject" => title,
        "from" => "ops@example.com",
        "google_account_email" => "kent@voteagora.com"
      }
    }

    Enum.into(overrides, defaults)
  end

  defp unique_user_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.com"
  end
end
