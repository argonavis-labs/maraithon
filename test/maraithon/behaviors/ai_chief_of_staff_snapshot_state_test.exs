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

  test "oversized strings are truncated but keep their type and shape" do
    big = String.duplicate("é", 40_000)

    state = %{
      skill_states: %{"inbox" => %{candidates: [%{body: big, subject: "s"}], memo: "short"}}
    }

    snapshot = AIChiefOfStaff.snapshot_state(state)
    [candidate] = snapshot.skill_states["inbox"].candidates

    assert is_binary(candidate.body)
    assert byte_size(candidate.body) < 20_000
    assert String.valid?(candidate.body)
    assert String.ends_with?(candidate.body, "[truncated for checkpoint]")
    assert candidate.subject == "s"
    assert snapshot.skill_states["inbox"].memo == "short"
  end

  test "oversized strings inside structs are truncated and the struct kept" do
    big = String.duplicate("x", 70_000)
    state = %{skill_states: %{"inbox" => %{last_response: %URI{scheme: "https", path: big}}}}

    snapshot = AIChiefOfStaff.snapshot_state(state)
    %URI{scheme: "https", path: path} = snapshot.skill_states["inbox"].last_response

    assert byte_size(path) < 20_000
    assert String.ends_with?(path, "[truncated for checkpoint]")
  end

  test "non-map state passes through" do
    assert AIChiefOfStaff.snapshot_state(:opaque) == :opaque
  end
end
