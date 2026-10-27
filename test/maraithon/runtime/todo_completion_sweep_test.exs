defmodule Maraithon.Runtime.TodoCompletionSweepTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.ConnectedAccounts
  alias Maraithon.Runtime.RecurringJobs
  alias Maraithon.Runtime.TodoCompletionSweep
  alias Maraithon.Todos

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    %{original_runtime: original_runtime}
  end

  test "durable schedule defaults its first deadline to the configured interval", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:todo_completion_sweep_interval_ms, 123_456)
      |> Keyword.delete(:todo_completion_sweep_initial_delay_ms)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    spec = Enum.find(RecurringJobs.specs(), &(&1.name == "todo_completion_sweep"))
    assert spec.schedule == {:interval, 123_456}
    assert spec.initial_delay_ms == 123_456
  end

  test "durable schedule accepts a separate first deadline", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:todo_completion_sweep_interval_ms, 123_456)
      |> Keyword.put(:todo_completion_sweep_initial_delay_ms, 5_000)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    spec = Enum.find(RecurringJobs.specs(), &(&1.name == "todo_completion_sweep"))
    assert spec.schedule == {:interval, 123_456}
    assert spec.initial_delay_ms == 5_000
  end

  test "manual run includes the cross-source completion pass" do
    summary = TodoCompletionSweep.run_once(user_ids: [], live_sources: false)

    assert %{
             users: 0,
             checked: 0,
             completed: 0,
             errors: 0,
             cross_source: %{
               users: 0,
               checked: 0,
               completed: 0,
               skipped: 0,
               errors: 0
             }
           } = summary
  end

  test "an account closure partition checks every open todo for cross-source evidence" do
    user_id = "account-closure-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, selected_account} =
      ConnectedAccounts.upsert_manual(user_id, "google:selected@example.com", %{})

    {:ok, other_account} =
      ConnectedAccounts.upsert_manual(user_id, "google:other@example.com", %{})

    {:ok, _todos} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "Selected account todo",
          "summary" => "Only this todo belongs to the selected closure partition.",
          "next_action" => "Keep it open for this assertion.",
          "source_account_id" => selected_account.id,
          "dedupe_key" => "account-closure:selected"
        },
        %{
          "source" => "manual",
          "title" => "Other account todo",
          "summary" => "This todo belongs to another account partition.",
          "next_action" => "Do not check it in the selected partition.",
          "source_account_id" => other_account.id,
          "dedupe_key" => "account-closure:other"
        }
      ])

    assert %{
             checked: 2,
             coverage_complete?: true,
             cross_source: %{checked: 2, expected: 2, model_calls: 0}
           } =
             TodoCompletionSweep.run_for_account(selected_account, live_sources: false)
  end

  test "an account closure proves every todo beyond the old per-cycle caps was checked" do
    user_id = "account-closure-exhaustive-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, account} =
      ConnectedAccounts.upsert_manual(user_id, "google:exhaustive@example.com", %{})

    todos =
      Enum.map(1..45, fn index ->
        %{
          "source" => "manual",
          "title" => "Exhaustive account todo #{index}",
          "summary" => "Every account todo must receive a completion decision.",
          "next_action" => "Keep this todo open.",
          "source_account_id" => account.id,
          "dedupe_key" => "account-closure:exhaustive:#{index}"
        }
      end)

    assert {:ok, inserted} = Todos.upsert_many(user_id, todos)
    assert length(inserted) == 45

    assert %{
             checked: 45,
             eligible_todos: 45,
             coverage_complete?: true,
             cross_source: %{checked: 45, expected: 45, model_calls: 0}
           } = TodoCompletionSweep.run_for_account(account, live_sources: false)
  end
end
