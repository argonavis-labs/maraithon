defmodule Maraithon.ScheduledTasksTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.ScheduledTasks

  test "creates telegram scheduled tasks with run history and one-shot advancement" do
    user_id = "scheduled-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    future = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             ScheduledTasks.create_from_telegram(user_id, %{
               "title" => "Send daily summary",
               "once_at" => DateTime.to_iso8601(future),
               "prompt" => "Summarize today's priorities"
             })

    assert task.source == "telegram"
    assert task.schedule == %{"type" => "once", "at" => DateTime.to_iso8601(future)}

    assert task.command == %{
             "type" => "assistant_prompt",
             "prompt" => "Summarize today's priorities"
           }

    assert task.failure_destination == %{"type" => "telegram"}

    assert [listed] = ScheduledTasks.list_tasks(user_id)
    assert listed.id == task.id

    assert {:ok, run, updated_task} =
             ScheduledTasks.record_run(task, "completed", %{"result" => %{"ok" => true}})

    assert run.status == "completed"
    assert run.result == %{"ok" => true}
    assert updated_task.last_run_at
    assert updated_task.next_run_at == nil

    assert [stored_run] = ScheduledTasks.list_runs(user_id, task.id)
    assert stored_run.id == run.id
  end

  test "previews daily schedules and finds due active tasks" do
    user_id = "scheduled-due-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    now = ~U[2026-05-10 12:00:00Z]

    assert {:ok, preview} =
             ScheduledTasks.schedule_preview(
               %{"schedule" => %{"type" => "daily", "time" => "09:00"}},
               now: now
             )

    assert preview.next_run_at == ~U[2026-05-11 09:00:00Z]

    due_time = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             ScheduledTasks.create_task(user_id, %{
               "title" => "Soon",
               "once_at" => DateTime.to_iso8601(due_time),
               "command" => %{"type" => "assistant_prompt", "prompt" => "run"}
             })

    due_at = DateTime.add(due_time, 1, :second)
    assert [%{id: task_id}] = ScheduledTasks.due_tasks(due_at)
    assert task_id == task.id
  end

  test "serialized run history hides raw failure details" do
    user_id = "scheduled-error-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    future = DateTime.utc_now() |> DateTime.add(120, :second) |> DateTime.truncate(:second)

    assert {:ok, task} =
             ScheduledTasks.create_task(user_id, %{
               "title" => "Send status update",
               "once_at" => DateTime.to_iso8601(future),
               "command" => %{"type" => "assistant_prompt", "prompt" => "send it"}
             })

    raw_error = "http_status: 500 internal_stacktrace db_timeout token=secret"

    assert {:ok, run, _updated_task} =
             ScheduledTasks.record_run(task, "failed", %{"error" => raw_error})

    assert run.error == raw_error

    serialized = ScheduledTasks.serialize_run(run)

    assert serialized.error ==
             "That scheduled task did not complete. Review it before running it again."

    refute serialized.error =~ "http_status"
    refute serialized.error =~ "internal_stacktrace"
    refute serialized.error =~ "db_timeout"
    refute serialized.error =~ "token=secret"
  end
end
