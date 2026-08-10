defmodule Maraithon.Runtime.SnapshotTest do
  use Maraithon.DataCase, async: true

  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.Runtime.SnapshotFormat

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

    assert {:ok, _} = Snapshot.persist(agent.id, 42, :idle, behavior_state, budget, 3)

    loaded = Snapshot.latest(agent.id)
    assert loaded.sequence_num == 42
    assert loaded.state_name == "idle"
    # Symbols, nested maps, and symbol-keyed maps survive through the tagged,
    # language-neutral JSON representation.
    assert loaded.behavior_state == behavior_state
    assert loaded.budget == budget
    # SPEC 08 R1: the behavior's schema version rides alongside the snapshot.
    assert loaded.schema_version == 3
  end

  test "latest/1 returns nil when the agent has never been checkpointed", %{agent: agent} do
    assert Snapshot.latest(agent.id) == nil
  end

  test "latest/1 returns the snapshot with the highest sequence_num", %{agent: agent} do
    {:ok, _} = Snapshot.persist(agent.id, 10, :idle, %{v: 1}, %{llm_calls: 1, tool_calls: 1}, 0)
    {:ok, _} = Snapshot.persist(agent.id, 30, :idle, %{v: 3}, %{llm_calls: 1, tool_calls: 1}, 0)
    {:ok, _} = Snapshot.persist(agent.id, 20, :idle, %{v: 2}, %{llm_calls: 1, tool_calls: 1}, 0)

    assert Snapshot.latest(agent.id).behavior_state == %{v: 3}
  end

  test "latest/1 returns schema_version 0 for a legacy row written before versioning", %{
    agent: agent
  } do
    # Simulate a pre-SPEC-08 snapshot row: insert without touching the
    # schema_version column so the DB default (0) backfills it, exactly as
    # `ADD COLUMN ... DEFAULT 0` did for every existing production row.
    {1, _} =
      Maraithon.Repo.insert_all(Snapshot, [
        %{
          agent_id: agent.id,
          sequence_num: 5,
          state_name: "idle",
          legacy_state_data: %{"legacy" => true},
          legacy_budget: %{"llm_calls" => 1},
          inserted_at: DateTime.utc_now()
        }
      ])

    loaded = Snapshot.latest(agent.id)
    assert loaded.schema_version == 0
    # Reader-first compatibility retains bounded raw-JSON v0 rows.
    assert loaded.behavior_state == %{"legacy" => true}
  end

  test "fresh checkpoints use format v1 and retention is transactionally bounded", %{agent: agent} do
    Enum.each(1..15, fn sequence ->
      assert {:ok, _snapshot} =
               Snapshot.persist(agent.id, sequence, :idle, %{sequence: sequence}, %{}, 1)
    end)

    snapshots =
      Snapshot
      |> Ecto.Query.where([snapshot], snapshot.agent_id == ^agent.id)
      |> Ecto.Query.order_by([snapshot], desc: snapshot.sequence_num)
      |> Repo.all()

    assert length(snapshots) == Snapshot.retention_count()
    assert Enum.map(snapshots, & &1.sequence_num) == Enum.to_list(15..6//-1)

    assert Enum.all?(snapshots, fn snapshot ->
             snapshot.state_data["format"] == SnapshotFormat.format() and
               snapshot.state_data["format_version"] == SnapshotFormat.version() and
               snapshot.budget["format"] == SnapshotFormat.format()
           end)
  end

  test "a corrupt newest checkpoint falls back to the prior retained checkpoint", %{agent: agent} do
    assert {:ok, _snapshot} = Snapshot.persist(agent.id, 1, :idle, %{healthy: true}, %{}, 0)

    {1, _rows} =
      Repo.insert_all(Snapshot, [
        %{
          agent_id: agent.id,
          sequence_num: 2,
          state_name: "idle",
          legacy_state_data: %{
            "format" => SnapshotFormat.format(),
            "format_version" => 999,
            "value" => %{}
          },
          legacy_budget: %{},
          schema_version: 0,
          inserted_at: DateTime.utc_now()
        }
      ])

    loaded = Snapshot.latest(agent.id)
    assert loaded.sequence_num == 1
    assert loaded.behavior_state == %{healthy: true}
  end

  test "legacy compressed ETF is rejected before decoding", %{agent: agent} do
    compressed =
      :erlang.term_to_binary(%{unsafe: String.duplicate("compressed", 10_000)}, compressed: 9)

    assert <<131, 80, _rest::binary>> = compressed

    {1, _rows} =
      Repo.insert_all(Snapshot, [
        %{
          agent_id: agent.id,
          sequence_num: 1,
          state_name: "idle",
          legacy_state_data: %{"format" => "etf_base64", "data" => Base.encode64(compressed)},
          legacy_budget: %{"format" => "etf_base64", "data" => Base.encode64(compressed)},
          schema_version: 0,
          inserted_at: DateTime.utc_now()
        }
      ])

    assert Snapshot.latest(agent.id) == nil
  end
end
