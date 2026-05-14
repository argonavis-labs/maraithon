defmodule Maraithon.Runtime.SnapshotTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Runtime.Snapshot

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "snapshot-test"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent}
  end

  test "round-trips behavior state and budget losslessly, including atom keys", %{agent: agent} do
    behavior_state = %{
      mode: :scanning,
      counters: %{seen: 12, acted: 3},
      last_subject: "Permission form due Friday",
      tags: [:work, :followup]
    }

    budget = %{llm_calls: 487, tool_calls: 991}

    assert {:ok, _} = Snapshot.persist(agent.id, 42, :idle, behavior_state, budget)

    loaded = Snapshot.latest(agent.id)
    assert loaded.sequence_num == 42
    assert loaded.state_name == "idle"
    # Atoms, nested maps, and atom-keyed maps all survive — a plain JSON
    # round-trip would have turned these into strings.
    assert loaded.behavior_state == behavior_state
    assert loaded.budget == budget
  end

  test "latest/1 returns nil when the agent has never been checkpointed", %{agent: agent} do
    assert Snapshot.latest(agent.id) == nil
  end

  test "latest/1 returns the snapshot with the highest sequence_num", %{agent: agent} do
    {:ok, _} = Snapshot.persist(agent.id, 10, :idle, %{v: 1}, %{llm_calls: 1, tool_calls: 1})
    {:ok, _} = Snapshot.persist(agent.id, 30, :idle, %{v: 3}, %{llm_calls: 1, tool_calls: 1})
    {:ok, _} = Snapshot.persist(agent.id, 20, :idle, %{v: 2}, %{llm_calls: 1, tool_calls: 1})

    assert Snapshot.latest(agent.id).behavior_state == %{v: 3}
  end
end
