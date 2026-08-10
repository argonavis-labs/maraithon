defmodule Maraithon.Runtime.TodoCompletionSweepTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.RecurringJobs
  alias Maraithon.Runtime.TodoCompletionSweep

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
end
