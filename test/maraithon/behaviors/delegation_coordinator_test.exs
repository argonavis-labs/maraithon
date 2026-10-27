defmodule Maraithon.Behaviors.DelegationCoordinatorTest do
  use ExUnit.Case, async: true
  alias Maraithon.Behaviors.DelegationCoordinator, as: Behavior
  alias Maraithon.Runtime.Agent

  test "the runtime upgrades an older checkpoint and the coordinator keeps reducing work" do
    wake = ~U[2026-09-16 12:00:00Z]

    snapshot = %{
      schema_version: 0,
      budget: %{llm_calls: 0, tool_calls: 0},
      behavior_state: %{
        "version" => 0,
        "work_cursor" => 42,
        "next_wake_at" => DateTime.to_iso8601(wake),
        "transient" => "discard on restore"
      }
    }

    {state, budget} = Agent.restore_from_snapshot(Behavior, %{}, snapshot, "local-eval")

    assert state == %{
             "version" => 1,
             "work_cursor" => 42,
             "next_wake_at" => DateTime.to_iso8601(wake)
           }

    assert budget == snapshot.budget
    assert Behavior.next_wakeup(state) == {:absolute, wake}
    assert Behavior.migrate_state(0, state, %{}) == state

    context = %{
      write: fn _reduce ->
        send(self(), :reduction_requested)
        {:ok, %{cursor: 43, next_wake: wake, changed: [], more?: false}}
      end
    }

    assert {:idle, %{"work_cursor" => 43}} = Behavior.handle_wakeup(state, context)
    assert_received :reduction_requested
  end
end
