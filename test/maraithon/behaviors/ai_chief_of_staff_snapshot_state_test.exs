defmodule Maraithon.Behaviors.AIChiefOfStaffSnapshotStateTest do
  use ExUnit.Case, async: true

  alias Maraithon.Behaviors.AIChiefOfStaff

  test "checkpoint state drops transient source bundles at every nesting level" do
    bundle = %{
      "gmail" => %{"messages" => List.duplicate(%{"body" => String.duplicate("x", 1000)}, 50)}
    }

    state = %{
      user_id: "u1",
      source_bundle: bundle,
      assistant_fetch_telemetry: %{fetched: 3},
      skill_states: %{
        "followthrough" => %{
          inbox_state: %{source_bundle: bundle, keep: 1},
          slack_state: %{source_bundle: nil}
        },
        "goal_alignment" => %{review_interval_hours: 24}
      },
      decided: DateTime.utc_now()
    }

    snapshot = AIChiefOfStaff.snapshot_state(state)

    assert snapshot.source_bundle == nil
    assert snapshot.assistant_fetch_telemetry == nil
    assert snapshot.skill_states["followthrough"].inbox_state == %{source_bundle: nil, keep: 1}
    assert snapshot.skill_states["goal_alignment"] == %{review_interval_hours: 24}
    assert snapshot.decided == state.decided
    # The live state is untouched.
    assert state.source_bundle == bundle
  end

  test "non-map state passes through" do
    assert AIChiefOfStaff.snapshot_state(:opaque) == :opaque
  end
end
