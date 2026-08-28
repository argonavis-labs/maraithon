defmodule Maraithon.Behaviors.SnapshotBudgetTest do
  use ExUnit.Case, async: false

  alias Maraithon.Behaviors.SnapshotBudget
  alias Maraithon.Behaviors.SnapshotTrim

  test "measures state with the durable snapshot encoder" do
    assert {:ok, bytes} = SnapshotBudget.check(%{skill_state: %{message_id: "m-1"}})
    assert is_integer(bytes) and bytes > 0
  end

  test "reports the path of a scalar that cannot be encoded" do
    state = %{skill_states: %{tracker: %{pending_effect: %{body: String.duplicate("x", 65_537)}}}}

    assert {:error, {:snapshot_scalar_too_large, [path]}} = SnapshotBudget.check(state)
    assert Enum.join(path, ".") == "skill_states.tracker.pending_effect.body"
  end

  test "truncation is an error with Cloud Logging-safe joined paths" do
    state = %{
      skill_states: %{
        tracker: %{body: String.duplicate("x", 16_385)},
        advisor: %{content: String.duplicate("y", 16_385)}
      }
    }

    Maraithon.LogBuffer.clear()
    SnapshotTrim.trim(state)
    Logger.flush()
    _ = :sys.get_state(Maraithon.LogBuffer)

    entry =
      Maraithon.LogBuffer.recent_matching(1, fn entry ->
        entry.message == "Checkpoint truncated oversized state strings"
      end)
      |> List.first()

    assert entry.level == :error
    assert entry.metadata["failure_code"] == "snapshot_scalar_truncated"

    paths = entry.metadata["paths"]
    assert is_binary(paths)
    assert paths =~ "skill_states.advisor.content"
    assert paths =~ "skill_states.tracker.body"
    refute paths =~ "["
  end
end
