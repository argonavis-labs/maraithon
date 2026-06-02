defmodule Maraithon.Runtime.TodoCompletionSweepTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Runtime.TodoCompletionSweep

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)
    end)

    %{original_runtime: original_runtime}
  end

  test "initial tick delay defaults to the configured sweep interval", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:todo_completion_sweep_interval_ms, 123_456)
      |> Keyword.delete(:todo_completion_sweep_initial_delay_ms)
      |> Keyword.put(:todo_completion_sweep_user_limit, 17)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    name = :"todo-completion-sweep-#{System.unique_integer([:positive])}"
    pid = start_supervised!({TodoCompletionSweep, name: name})
    state = :sys.get_state(pid)

    assert state.interval_ms == 123_456
    assert state.initial_delay_ms == 123_456
    assert state.user_limit == 17
  end

  test "initial tick delay can be configured separately", %{
    original_runtime: original_runtime
  } do
    runtime_config =
      original_runtime
      |> Keyword.put(:todo_completion_sweep_interval_ms, 123_456)
      |> Keyword.put(:todo_completion_sweep_initial_delay_ms, 5_000)
      |> Keyword.put(:todo_completion_sweep_user_limit, 23)

    Application.put_env(:maraithon, Maraithon.Runtime, runtime_config)

    name = :"todo-completion-sweep-#{System.unique_integer([:positive])}"
    pid = start_supervised!({TodoCompletionSweep, name: name})
    state = :sys.get_state(pid)

    assert state.interval_ms == 123_456
    assert state.initial_delay_ms == 5_000
    assert state.user_limit == 23
  end
end
