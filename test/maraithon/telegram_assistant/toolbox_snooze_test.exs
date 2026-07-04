defmodule Maraithon.TelegramAssistant.ToolboxSnoozeTest do
  # SPEC 01 R3: the conversational snooze accepts everything ingest accepts
  # (bare dates, naive datetimes) and resolves them in the user's local time,
  # instead of the old strict full-offset ISO parse that silently failed.
  use Maraithon.DataCase, async: true

  alias Maraithon.Accounts
  alias Maraithon.Agents
  alias Maraithon.TelegramAssistant.Toolbox
  alias Maraithon.Todos

  setup do
    user_id = "toolbox-snooze-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)
    %{user_id: user_id, runtime_context: %{user_id: user_id, surface: "telegram"}}
  end

  test "a bare-date snooze_until succeeds and resolves to end-of-day (UTC fallback without a timezone)",
       %{user_id: user_id, runtime_context: runtime_context} do
    todo = create_todo(user_id, "bare-date")

    assert {:ok, %{todo: %{status: "snoozed"}}} =
             Toolbox.execute(
               "resolve_todo",
               %{"todo_id" => todo.id, "status" => "snoozed", "snooze_until" => "2099-07-06"},
               runtime_context
             )

    reloaded = Todos.get_for_user(user_id, todo.id)
    assert reloaded.status == "snoozed"
    assert DateTime.compare(reloaded.snoozed_until, ~U[2099-07-06 23:59:59Z]) == :eq
  end

  test "a naive-datetime snooze_until succeeds and resolves in the user's local time", %{
    user_id: user_id,
    runtime_context: runtime_context
  } do
    {:ok, _agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "ai_chief_of_staff",
        config: %{
          "name" => "Chief of Staff",
          "timezone" => "America/Toronto",
          "timezone_name" => "America/Toronto",
          "timezone_offset_hours" => -5
        }
      })

    todo = create_todo(user_id, "naive-datetime")

    # "Snooze that until Monday 9am" resolved without an offset: 9am local
    # July (DST, -4) = 13:00 UTC.
    assert {:ok, %{todo: %{status: "snoozed"}}} =
             Toolbox.execute(
               "resolve_todo",
               %{
                 "todo_id" => todo.id,
                 "status" => "snoozed",
                 "snooze_until" => "2099-07-06T09:00:00"
               },
               runtime_context
             )

    reloaded = Todos.get_for_user(user_id, todo.id)
    assert DateTime.compare(reloaded.snoozed_until, ~U[2099-07-06 13:00:00Z]) == :eq
  end

  test "a snooze resolved to the past clamps forward to the next occurrence of that weekday/time",
       %{user_id: user_id, runtime_context: runtime_context} do
    todo = create_todo(user_id, "past-clamp")

    # 2020-01-06 was a Monday — a model resolving "Monday" into the past.
    assert {:ok, %{todo: %{status: "snoozed"}}} =
             Toolbox.execute(
               "resolve_todo",
               %{
                 "todo_id" => todo.id,
                 "status" => "snoozed",
                 "snooze_until" => "2020-01-06T09:00:00Z"
               },
               runtime_context
             )

    reloaded = Todos.get_for_user(user_id, todo.id)
    assert DateTime.compare(reloaded.snoozed_until, DateTime.utc_now()) == :gt
    # Same weekday (Monday) and same wall time preserved by whole-week clamping.
    assert Date.day_of_week(DateTime.to_date(reloaded.snoozed_until)) == 1
    assert reloaded.snoozed_until.hour == 9
  end

  test "unparseable and missing snooze_until keep the {:error, reason} contract shape", %{
    user_id: user_id,
    runtime_context: runtime_context
  } do
    todo = create_todo(user_id, "invalid")

    # Toolbox polishes internal reason codes into user-facing copy, but the
    # {:error, reason} tuple contract must survive (callers must not crash).
    assert {:error, invalid_reason} =
             Toolbox.execute(
               "resolve_todo",
               %{"todo_id" => todo.id, "status" => "snoozed", "snooze_until" => "next Monday-ish"},
               runtime_context
             )

    assert is_binary(invalid_reason)
    assert invalid_reason =~ "snooze"

    assert {:error, missing_reason} =
             Toolbox.execute(
               "resolve_todo",
               %{"todo_id" => todo.id, "status" => "snoozed"},
               runtime_context
             )

    assert is_binary(missing_reason)

    # And the todo is untouched by the failed snooze attempts.
    assert Todos.get_for_user(user_id, todo.id).status == "open"
  end

  defp create_todo(user_id, key) do
    {:ok, [todo]} =
      Todos.upsert_many(user_id, [
        %{
          "source" => "manual",
          "title" => "Revisit the vendor renewal quote",
          "summary" => "The vendor renewal quote can wait a few days.",
          "next_action" => "Reopen the quote and decide.",
          "dedupe_key" => "toolbox-snooze-#{key}"
        }
      ])

    todo
  end
end
