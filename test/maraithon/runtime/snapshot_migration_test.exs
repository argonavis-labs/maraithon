defmodule Maraithon.Runtime.SnapshotMigrationTest do
  use Maraithon.DataCase, async: false

  import Ecto.Query

  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.Runtime.SnapshotFormat
  alias Maraithon.Runtime.SnapshotMigration
  alias Maraithon.Runtime.SnapshotQuarantine

  setup do
    {:ok, agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "snapshot-migration-test"},
        status: "running",
        started_at: DateTime.utc_now()
      })

    %{agent: agent}
  end

  test "a bounded resumable batch transcodes ETF and plain JSON to tagged v1", %{agent: agent} do
    etf_state = %{mode: :scanning, cursor: {"inbox", 12}}

    first =
      insert_snapshot!(agent.id, 1,
        state_data: legacy_etf(etf_state),
        budget: legacy_etf(%{llm_calls: 4})
      )

    second =
      insert_snapshot!(agent.id, 2,
        state_data: %{"plain" => [1, 2, 3]},
        budget: %{"llm_calls" => 5}
      )

    assert {:ok, batch} =
             SnapshotMigration.migrate_batch(batch_size: 1, after_id: 0)

    assert batch.scanned == 1
    assert batch.migrated == 1
    assert batch.next_cursor == first.id
    refute batch.pass_complete

    migrated_first = Repo.get!(Snapshot, first.id)
    assert migrated_first.state_data["format"] == SnapshotFormat.format()

    assert {:ok, batch} =
             SnapshotMigration.migrate_batch(batch_size: 1, after_id: batch.next_cursor)

    assert batch.migrated == 1
    assert batch.next_cursor == second.id

    # Rewinding the cursor is intentionally safe: both rows are now only
    # validated, not changed or duplicated.
    assert {:ok, retried} = SnapshotMigration.migrate_batch(batch_size: 25, after_id: 0)
    assert retried.tagged_v1 == 2
    assert retried.migrated == 0

    loaded = Snapshot.latest(agent.id)
    assert loaded.sequence_num == 2
    assert loaded.behavior_state == %{"plain" => [1, 2, 3]}
  end

  test "invalid active-Agent rows remain until a newer valid checkpoint exists", %{agent: agent} do
    # A corrupt sequence can be ahead of the event stream. Freshness is
    # therefore proven by a later source-row id, not by trusting this value.
    invalid =
      insert_snapshot!(agent.id, 999,
        state_data: %{
          "format" => SnapshotFormat.format(),
          "format_version" => 999,
          "value" => %{}
        },
        budget: %{}
      )

    assert {:ok, batch} = SnapshotMigration.migrate_batch(batch_size: 25)
    assert batch.blocked_active == 1
    assert Repo.get(Snapshot, invalid.id)

    assert {:error, {:snapshot_prune_requires_clean_format, preflight}} =
             SnapshotMigration.prune_all()

    assert preflight.invalid_snapshot_count == 1

    assert Repo.get(Snapshot, invalid.id)

    report = Repo.get_by!(SnapshotQuarantine, snapshot_id: invalid.id)
    assert report.status == "blocked_active"
    assert report.quarantined_at == nil
    assert is_binary(report.payload_digest)
    refute Map.has_key?(Map.from_struct(report), :state_data)
    refute Map.has_key?(Map.from_struct(report), :budget)

    assert {:ok, fresh} = Snapshot.persist(agent.id, 2, :idle, %{fresh: true}, %{}, 0)
    assert fresh.id > invalid.id

    assert {:ok, batch} = SnapshotMigration.migrate_batch(batch_size: 25)
    assert batch.quarantined == 1
    assert Repo.get(Snapshot, invalid.id) == nil

    report = Repo.get_by!(SnapshotQuarantine, snapshot_id: invalid.id)
    assert report.status == "quarantined"
    assert report.quarantined_at
    assert Snapshot.latest(agent.id).behavior_state == %{fresh: true}
  end

  test "invalid stopped-Agent rows are quarantined immediately", %{agent: running_agent} do
    {:ok, stopped_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "stopped-snapshot"},
        status: "stopped"
      })

    invalid =
      insert_snapshot!(stopped_agent.id, 1,
        state_data: %{"format" => "etf_base64", "data" => "not base64"},
        budget: %{}
      )

    # Keep the setup Agent relevant: its status must not influence a different
    # stopped Agent's quarantine decision.
    assert running_agent.status == "running"

    assert {:ok, batch} = SnapshotMigration.migrate_batch(batch_size: 25)
    assert batch.quarantined == 1
    assert batch.blocked_active == 0
    assert Repo.get(Snapshot, invalid.id) == nil
    assert Repo.get_by!(SnapshotQuarantine, snapshot_id: invalid.id).status == "quarantined"
  end

  test "preflight emits exact legacy, invalid, and global over-retention counts", %{agent: agent} do
    {:ok, stopped_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "retention-preflight"},
        status: "stopped"
      })

    tagged_rows =
      Enum.map(1..12, fn sequence ->
        tagged_attrs(stopped_agent.id, sequence, %{sequence: sequence})
      end)

    assert {12, nil} = Repo.insert_all(Snapshot, tagged_rows)
    insert_snapshot!(agent.id, 1, state_data: %{"legacy" => true}, budget: %{})

    insert_snapshot!(agent.id, 2,
      state_data: %{
        "format" => SnapshotFormat.format(),
        "format_version" => 1,
        "value" => %{"$type" => "future"}
      },
      budget: tagged(%{})
    )

    handler_id = "snapshot-preflight-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:maraithon, :runtime, :snapshot, :migration, :preflight],
        fn event, measurements, metadata, _config ->
          send(parent, {:snapshot_preflight, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, stats} = SnapshotMigration.preflight(batch_size: 2)
    assert stats.legacy_snapshot_count == 1
    assert stats.invalid_snapshot_count == 1
    assert stats.active_invalid_without_fresh_checkpoint_count == 1
    assert stats.agents_over_retention == 1
    assert stats.over_retention_snapshot_count == 2

    assert_receive {:snapshot_preflight, _event, measurements, metadata}
    assert measurements.legacy_snapshot_count == 1
    assert measurements.invalid_snapshot_count == 1
    assert measurements.agents_over_retention == 1
    assert metadata.format_version == 1
  end

  test "global prune keeps ten newest rows for active and stopped Agents", %{agent: active_agent} do
    {:ok, stopped_agent} =
      Agents.create_agent(%{
        behavior: "prompt_agent",
        config: %{"name" => "global-prune-stopped"},
        status: "stopped"
      })

    Enum.each([active_agent, stopped_agent], fn agent ->
      rows = Enum.map(1..14, &tagged_attrs(agent.id, &1, %{sequence: &1}))
      assert {14, nil} = Repo.insert_all(Snapshot, rows)
    end)

    assert {:ok, result} =
             SnapshotMigration.prune_all(prune_batch_size: 3, max_batches: 20)

    assert result.complete
    assert result.deleted == 8

    Enum.each([active_agent, stopped_agent], fn agent ->
      sequences =
        Snapshot
        |> where([snapshot], snapshot.agent_id == ^agent.id)
        |> order_by([snapshot], desc: snapshot.sequence_num)
        |> select([snapshot], snapshot.sequence_num)
        |> Repo.all()

      assert sequences == Enum.to_list(14..5//-1)
    end)
  end

  test "format proof adds and validates the exact dual-payload v1 constraint", %{agent: agent} do
    assert {:ok, _snapshot} = Snapshot.persist(agent.id, 1, :idle, %{valid: true}, %{}, 0)

    assert {:ok, proof} = SnapshotMigration.finalize(batch_size: 2)
    assert proof.legacy_snapshot_count == 0
    assert proof.invalid_snapshot_count == 0
    assert proof.agents_over_retention == 0
    assert proof.format_constraint_installed
    assert proof.format_constraint_validated

    attrs = %{
      agent_id: agent.id,
      sequence_num: 2,
      state_name: "idle",
      state_data: %{"legacy" => true},
      budget: %{},
      schema_version: 0
    }

    assert {:error, changeset} = Snapshot.changeset(%Snapshot{}, attrs) |> Repo.insert()

    assert "does not match the tagged snapshot format" in errors_on(changeset).state_data
  end

  defp insert_snapshot!(agent_id, sequence_num, opts) do
    attrs = %{
      agent_id: agent_id,
      sequence_num: sequence_num,
      state_name: "idle",
      state_data: Keyword.fetch!(opts, :state_data),
      budget: Keyword.fetch!(opts, :budget),
      schema_version: Keyword.get(opts, :schema_version, 0),
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    {1, [snapshot]} = Repo.insert_all(Snapshot, [attrs], returning: true)
    snapshot
  end

  defp tagged_attrs(agent_id, sequence_num, state) do
    %{
      agent_id: agent_id,
      sequence_num: sequence_num,
      state_name: "idle",
      state_data: tagged(state),
      budget: tagged(%{}),
      schema_version: 0,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }
  end

  defp tagged(term) do
    {:ok, envelope, _bytes} = SnapshotFormat.encode(term)
    envelope
  end

  defp legacy_etf(term) do
    %{
      "format" => "etf_base64",
      "data" => term |> :erlang.term_to_binary() |> Base.encode64()
    }
  end
end
