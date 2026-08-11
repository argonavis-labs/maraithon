defmodule Maraithon.Runtime.SnapshotAuthorityTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.Coordination.{Authority, Partition, Partitioning}
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol
  alias Maraithon.Runtime.Snapshot
  alias Maraithon.Runtime.SnapshotFormat
  alias Maraithon.Runtime.SnapshotMigration
  alias Maraithon.Runtime.SnapshotQuarantine

  @moduletag database_role: :session

  @activation_evidence [
    evidence_id: "test:stopped-fleet:snapshot-authority",
    evidence_digest: :crypto.hash(:sha256, "test snapshot authority evidence"),
    activated_by: "snapshot-authority@example.test",
    revision: String.duplicate("b", 40)
  ]

  setup do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      original_runtime
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.delete(:coordination_test_session)
      |> Keyword.delete(:coordination_test_leader)
    )

    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, original_runtime) end)

    set_role(:runtime)
    assert ProtocolCutover.mode() == :legacy

    assert {:ok, :attested} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    set_role(:runtime)
    :ok
  end

  test "exact Snapshot INSERT rejects raw and stale runtime writers but accepts the ready lease owner" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_token} = exact_agent("snapshot-insert-authority")

    clear_owner_token!()
    assert_exact_insert_rejected!(agent.id, 1)

    put_owner_token!(Ecto.UUID.generate())
    assert_exact_insert_rejected!(agent.id, 2)

    snapshot = persist_exact!(agent.id, owner_token, 3)
    assert snapshot.agent_id == agent.id
    assert snapshot.sequence_num == 3
    assert Snapshot.latest(agent.id).behavior_state == %{sequence: 3}
  end

  test "exact Snapshot INSERT rejects wrong node, partition, user, Agent, Binding, guard, and lifecycle authority" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_token} = exact_agent("snapshot-negative-authority")

    corruptions = [
      {"node",
       fn ->
         Repo.query!(
           "UPDATE agent_runtime_leases " <>
             "SET coordination_node_incarnation_id = $2::uuid WHERE agent_id = $1::uuid",
           [uuid(agent.id), uuid(Ecto.UUID.generate())]
         )
       end},
      {"partition",
       fn ->
         Repo.query!(
           "UPDATE agent_runtime_leases " <>
             "SET coordination_partition_id = (coordination_partition_id + 1) % 64 " <>
             "WHERE agent_id = $1::uuid",
           [uuid(agent.id)]
         )
       end},
      {"user",
       fn ->
         Repo.query!(
           "UPDATE users SET privacy_erasure_requested_at = clock_timestamp() WHERE id = $1",
           [agent.user_id]
         )
       end},
      {"Agent",
       fn ->
         Repo.query!("UPDATE agents SET status = 'stopped' WHERE id = $1::uuid", [uuid(agent.id)])
       end},
      {"Binding",
       fn ->
         Repo.query!(
           "UPDATE agent_isolation_bindings SET status = 'paused' WHERE agent_id = $1::uuid",
           [uuid(agent.id)]
         )
       end},
      {"restart guard",
       fn ->
         Repo.query!(
           """
           INSERT INTO agent_restart_guards (
             agent_id, generation, tripped, needs_recovery, inserted_at, updated_at
           ) VALUES ($1::uuid, gen_random_uuid(), true, false, clock_timestamp(), clock_timestamp())
           ON CONFLICT (agent_id) DO UPDATE SET tripped = true
           """,
           [uuid(agent.id)]
         )
       end},
      {"lifecycle", fn -> insert_lifecycle_operation!(agent.id) end}
    ]

    Enum.with_index(corruptions, 10)
    |> Enum.each(fn {{label, corruption}, sequence_num} ->
      assert_raise Postgrex.Error, ~r/Exact Snapshot insertion requires/, fn ->
        Repo.transaction(
          fn ->
            with_replica_setup!(corruption)
            set_role(:runtime)
            put_owner_token!(owner_token)
            insert_exact!(agent.id, sequence_num)
          end,
          mode: :savepoint
        )
      end

      assert Repo.aggregate(Snapshot, :count, :id) == 0,
             "#{label} authority unexpectedly wrote a Snapshot"
    end)
  end

  test "incident UPDATE authority is operation-specific for Binding rotation and Vault reencryption" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_token} = exact_agent("snapshot-operator-update")
    snapshot = persist_exact!(agent.id, owner_token, 1)

    set_role(:incident)

    new_mac = :crypto.hash(:sha256, "rotated binding")

    operator_update!(:binding, fn ->
      Repo.query!(
        "UPDATE snapshots SET payload_binding_mac = $2 WHERE id = $1",
        [snapshot.id, new_mac]
      )
    end)

    assert snapshot_column(snapshot.id, "payload_binding_mac") == new_mac

    assert_operator_update_rejected!(:binding, fn ->
      Repo.query!(
        "UPDATE snapshots " <>
          "SET state_data_ciphertext = state_data_ciphertext || decode('00', 'hex') " <>
          "WHERE id = $1",
        [snapshot.id]
      )
    end)

    prior_state_bytes = snapshot_octets(snapshot.id, "state_data_ciphertext")

    operator_update!(:vault, fn ->
      Repo.query!(
        "UPDATE snapshots " <>
          "SET state_data_ciphertext = state_data_ciphertext || decode('00', 'hex') " <>
          "WHERE id = $1",
        [snapshot.id]
      )
    end)

    assert snapshot_octets(snapshot.id, "state_data_ciphertext") == prior_state_bytes + 1

    assert_operator_update_rejected!(:vault, fn ->
      Repo.query!(
        "UPDATE snapshots SET payload_binding_mac = $2 WHERE id = $1",
        [snapshot.id, :crypto.hash(:sha256, "wrong operation")]
      )
    end)

    assert_operator_update_rejected!([:binding, :vault], fn ->
      Repo.query!(
        "UPDATE snapshots SET payload_binding_mac = $2 WHERE id = $1",
        [snapshot.id, :crypto.hash(:sha256, "ambiguous operation")]
      )
    end)
  end

  test "ordinary runtime pruning preserves the exact top-ten recovery boundary" do
    agent = legacy_agent("snapshot-prune-boundary", "stopped")

    snapshots =
      Enum.map(1..11, fn sequence_num ->
        insert_legacy_snapshot!(
          agent.id,
          sequence_num,
          tagged(%{sequence: sequence_num}),
          tagged(%{})
        )
      end)

    oldest = hd(snapshots)
    second_oldest = Enum.at(snapshots, 1)

    assert_raise Postgrex.Error, ~r/Snapshot deletion requires bounded prune/, fn ->
      Repo.transaction(
        fn -> Repo.delete!(oldest) end,
        mode: :savepoint
      )
    end

    Repo.query!(
      "SELECT set_config('maraithon.snapshot_history_prune', " <>
        "'PRUNE_BEYOND_RECOVERY_WINDOW_V1', true)"
    )

    assert Repo.delete!(oldest).id == oldest.id

    assert_raise Postgrex.Error, ~r/preserve the newest ten/, fn ->
      Repo.transaction(
        fn -> Repo.delete!(second_oldest) end,
        mode: :savepoint
      )
    end

    assert Repo.aggregate(Snapshot, :count, :id) == 10
  end

  test "legacy lifecycle delete erases retained Snapshots while ordinary deletion remains fenced" do
    agent = legacy_agent("snapshot-legacy-lifecycle-erasure", "stopped")
    snapshot = insert_legacy_snapshot!(agent.id, 1, tagged(%{}), tagged(%{}))

    assert_raise Postgrex.Error, ~r/Snapshot deletion requires bounded prune/, fn ->
      Repo.transaction(
        fn -> Repo.delete!(snapshot) end,
        mode: :savepoint
      )
    end

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :delete,
               %{"reason" => "operator_requested"},
               fn _locked -> %{"action" => "delete"} end
             )

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Repo.get(Snapshot, snapshot.id) == nil
    assert Agents.get_agent(agent.id) == nil
  end

  test "exact lifecycle delete erases retained Snapshots while ordinary deletion remains fenced" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_token} = exact_agent("snapshot-lifecycle-erasure")
    snapshot = persist_exact!(agent.id, owner_token, 1)
    clear_snapshot_writer_markers!()

    assert_raise Postgrex.Error, ~r/Snapshot deletion requires bounded prune/, fn ->
      Repo.transaction(
        fn -> Repo.delete!(snapshot) end,
        mode: :savepoint
      )
    end

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :delete,
               %{"reason" => "operator_requested"},
               fn _locked -> %{"action" => "delete"} end
             )

    # Lease disappearance is a precondition of lifecycle finalization. The
    # termination-proof subsystem owns that separate proof; bypass only its
    # trigger here so this test stays focused on Snapshot cascade authority.
    with_replica_setup!(fn ->
      Repo.query!("DELETE FROM agent_runtime_leases WHERE agent_id = $1::uuid", [uuid(agent.id)])
    end)

    set_role(:runtime)

    if Agents.get_agent(agent.id) do
      assert {:ok, %{status: :finalized, action: :deleted}} =
               AgentLifecycleOperations.finalize(agent.id, fence.operation_token)
    end

    assert Repo.get(Snapshot, snapshot.id) == nil
    assert Agents.get_agent(agent.id) == nil
  end

  test "legacy format migration assumes migrator while direct runtime rewrite stays rejected" do
    agent = legacy_agent("snapshot-legacy-format", "stopped")

    legacy =
      insert_legacy_snapshot!(
        agent.id,
        1,
        legacy_etf(%{mode: :scanning}),
        legacy_etf(%{llm_calls: 2})
      )

    assert_raise Postgrex.Error, ~r/Legacy Snapshot mutation requires/, fn ->
      Repo.transaction(
        fn ->
          Repo.query!(
            "SELECT set_config('maraithon.snapshot_format_migration', " <>
              "'MIGRATE_LEGACY_SNAPSHOT_V1', true)"
          )

          Repo.update_all(
            from(snapshot in Snapshot, where: snapshot.id == ^legacy.id),
            set: [legacy_state_data: tagged(%{mode: :scanning}), legacy_budget: tagged(%{})]
          )
        end,
        mode: :savepoint
      )
    end

    assert {:ok, %{migrated: 1}} =
             SnapshotMigration.migrate_batch(after_id: legacy.id - 1, batch_size: 1)

    set_role(:migrator)
    migrated = Repo.get!(Snapshot, legacy.id)
    assert migrated.legacy_state_data["format"] == SnapshotFormat.format()
  end

  test "migration role quarantines and prunes; runtime and activation logins cannot assume it" do
    Enum.each([:runtime, :migrator], fn starting_role ->
      set_role(:runtime)
      invalid_agent = legacy_agent("snapshot-quarantine-#{starting_role}", "stopped")

      invalid =
        insert_legacy_snapshot!(
          invalid_agent.id,
          1,
          %{"format" => "etf_base64", "data" => "not base64"},
          %{}
        )

      prune_agent = legacy_agent("snapshot-role-prune-#{starting_role}", "stopped")

      Enum.each(1..11, fn sequence_num ->
        insert_legacy_snapshot!(
          prune_agent.id,
          sequence_num,
          tagged(%{sequence: sequence_num}),
          tagged(%{})
        )
      end)

      # The test session is a provisioning superuser, so either starting role
      # can exercise the module's explicit SET LOCAL ROLE. Dedicated login
      # probes below prove runtime/activation sessions cannot make that jump.
      set_role(starting_role)

      assert {:ok, batch} = SnapshotMigration.migrate_batch(batch_size: 25)
      assert batch.quarantined >= 1
      assert Repo.get(Snapshot, invalid.id) == nil
      assert Repo.get_by!(SnapshotQuarantine, snapshot_id: invalid.id).status == "quarantined"

      assert {:ok, prune} =
               SnapshotMigration.prune_all(prune_batch_size: 5, max_batches: 10)

      assert prune.complete

      assert Repo.aggregate(
               from(snapshot in Snapshot, where: snapshot.agent_id == ^prune_agent.id),
               :count,
               :id
             ) == 10
    end)

    assert_cannot_assume_migrator!(:runtime)
    assert_cannot_assume_migrator!(:activation)
  end

  defp activate_exact do
    effect_result =
      ProtocolCutover.activate(
        [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
      )

    set_role(:runtime)

    case effect_result do
      {:ok, effect_status} when effect_status in [:activated, :already_active] ->
        set_role(:activation)

        runtime_result =
          CoordinationProtocol.activate(
            [confirmation: CoordinationProtocol.activation_confirmation()] ++
              @activation_evidence
          )

        set_role(:runtime)

        case runtime_result do
          {:ok, runtime_status} when runtime_status in [:activated, :already_active] ->
            ensure_coordination_authority!()
            {:ok, effect_status}

          {:error, reason} ->
            {:error, reason}
        end

      other ->
        other
    end
  end

  defp ensure_coordination_authority! do
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)

    unless Keyword.get(runtime, :coordination_test_session) do
      {:ok, joining} =
        Authority.register_node(
          node_name: "snapshot-authority@test",
          revision: String.duplicate("b", 40),
          ttl_ms: 300_000
        )

      {:ok, session} = Authority.mark_node_ready(joining)
      {:ok, preparing_leader} = Authority.acquire_leader(session, 300_000)
      {:ok, leader} = Authority.mark_leader_ready(preparing_leader)

      Application.put_env(
        :maraithon,
        Maraithon.Runtime,
        runtime
        |> Keyword.put(:coordination_test_session, session)
        |> Keyword.put(:coordination_test_leader, leader)
      )
    end

    :ok
  end

  defp ensure_user_partition!(user_id) do
    runtime = Application.fetch_env!(:maraithon, Maraithon.Runtime)
    session = Keyword.fetch!(runtime, :coordination_test_session)
    leader = Keyword.fetch!(runtime, :coordination_test_leader)
    partition_id = user_id |> Partitioning.tenant_key() |> Partitioning.partition_for()

    case Repo.get!(Partition, partition_id) do
      %Partition{state: "unassigned"} ->
        {:ok, _preparing} =
          Authority.assign_partition(leader, session, partition_id, ttl_ms: 300_000)

        {:ok, _ready} = Authority.mark_partition_ready(session, partition_id)
        :ok

      %Partition{
        state: "ready",
        owner_node_incarnation_id: owner_id,
        activation_epoch: activation_epoch
      }
      when owner_id == session.id and activation_epoch == session.activation_epoch ->
        :ok
    end
  end

  defp exact_agent(name) do
    agent = legacy_agent(name, "running", binding?: true)
    :ok = ensure_user_partition!(agent.user_id)
    {:ok, claimed} = AgentLeases.claim(agent.id, ttl_ms: 60_000)
    {:ok, _ready} = AgentLeases.mark_ready(agent.id, claimed.owner_token)
    {agent, claimed.owner_token}
  end

  defp legacy_agent(name, status, opts \\ []) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: status,
        started_at: if(status in ["running", "degraded"], do: DateTime.utc_now()),
        config: %{"name" => name, "prompt" => "test", "subscribe" => [], "tools" => []}
      })

    if Keyword.get(opts, :binding?, false) do
      {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    end

    agent
  end

  defp persist_exact!(agent_id, owner_token, sequence_num) do
    {:ok, snapshot} =
      Repo.transaction(fn ->
        :ok = AgentLeases.fence_ready!(agent_id, owner_token)

        {:ok, snapshot} =
          Snapshot.persist(agent_id, sequence_num, :idle, %{sequence: sequence_num}, %{}, 1)

        snapshot
      end)

    snapshot
  end

  defp assert_exact_insert_rejected!(agent_id, sequence_num) do
    assert_raise Postgrex.Error, ~r/Exact Snapshot insertion requires/, fn ->
      Repo.transaction(
        fn -> insert_exact!(agent_id, sequence_num) end,
        mode: :savepoint
      )
    end
  end

  defp insert_exact!(agent_id, sequence_num) do
    case Snapshot.persist(agent_id, sequence_num, :idle, %{sequence: sequence_num}, %{}, 1) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp insert_legacy_snapshot!(agent_id, sequence_num, state_data, budget) do
    attrs = %{
      agent_id: agent_id,
      sequence_num: sequence_num,
      state_name: "idle",
      legacy_state_data: state_data,
      legacy_budget: budget,
      schema_version: 0,
      inserted_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    {1, [snapshot]} = Repo.insert_all(Snapshot, [attrs], returning: true)
    snapshot
  end

  defp insert_lifecycle_operation!(agent_id) do
    Repo.query!(
      """
      INSERT INTO agent_lifecycle_operations (
        agent_id, operation_token, kind, state, request_digest, payload_digest,
        payload, requires_external_drain, initiated_at, last_attempted_at,
        inserted_at, updated_at
      ) VALUES (
        $1::uuid, gen_random_uuid(), 'pause', 'draining',
        digest('snapshot request', 'sha256'), digest('snapshot payload', 'sha256'),
        '{}'::jsonb, false, clock_timestamp(), clock_timestamp(),
        clock_timestamp(), clock_timestamp()
      )
      """,
      [uuid(agent_id)]
    )
  end

  defp with_replica_setup!(fun) do
    reset_role()
    Repo.query!("SET LOCAL session_replication_role = replica")

    try do
      fun.()
    after
      Repo.query!("SET LOCAL session_replication_role = origin")
    end
  end

  defp operator_update!(operations, fun) do
    operations = List.wrap(operations)

    Repo.transaction(
      fn ->
        set_operator_markers!(operations)
        result = fun.()
        clear_operator_markers!()
        result
      end,
      mode: :savepoint
    )
  end

  defp assert_operator_update_rejected!(operations, fun) do
    assert_raise Postgrex.Error, ~r/Exact Snapshot update requires/, fn ->
      Repo.transaction(
        fn ->
          set_operator_markers!(List.wrap(operations))
          fun.()
        end,
        mode: :savepoint
      )
    end
  end

  defp set_operator_markers!(operations) do
    if :binding in operations do
      Repo.query!(
        "SELECT set_config('maraithon.binding_key_rotation', 'BINDING_KEY_ROTATION_V1', true)"
      )
    end

    if :vault in operations do
      Repo.query!("SELECT set_config('maraithon.vault_reencryption', 'VAULT_REENCRYPT_V1', true)")
    end
  end

  defp clear_operator_markers! do
    Repo.query!("SELECT set_config('maraithon.binding_key_rotation', '', true)")
    Repo.query!("SELECT set_config('maraithon.vault_reencryption', '', true)")
  end

  defp snapshot_column(id, column) do
    %{rows: [[value]]} = Repo.query!("SELECT #{column} FROM snapshots WHERE id = $1", [id])
    value
  end

  defp snapshot_octets(id, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT octet_length(#{column}) FROM snapshots WHERE id = $1", [id])

    value
  end

  defp put_owner_token!(owner_token) do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.agent_lease_owner_token', $1, true)",
      [owner_token]
    )
  end

  defp clear_owner_token! do
    SQL.query!(Repo, "SELECT set_config('maraithon.agent_lease_owner_token', '', true)", [])
  end

  defp clear_snapshot_writer_markers! do
    clear_owner_token!()
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])
    SQL.query!(Repo, "SELECT set_config('maraithon.snapshot_history_prune', '', true)", [])
  end

  defp assert_cannot_assume_migrator!(role) do
    role_name =
      case role do
        :runtime -> "maraithon_runtime"
        :activation -> "maraithon_activation_operator"
      end

    assert_raise Postgrex.Error, ~r/permission denied to set role/, fn ->
      Repo.transaction(
        fn ->
          reset_role()
          Repo.query!("SET LOCAL SESSION AUTHORIZATION #{role_name}")
          Repo.query!("SET LOCAL ROLE maraithon_migrator")
        end,
        mode: :savepoint
      )
    end
  end

  defp set_role(role) do
    reset_role()

    role_name =
      case role do
        :runtime -> "maraithon_runtime"
        :migrator -> "maraithon_migrator"
        :incident -> "maraithon_incident_operator"
        :activation -> "maraithon_activation_operator"
      end

    Repo.query!("SET LOCAL ROLE #{role_name}", [], log: false)
  end

  defp reset_role do
    Repo.query!("RESET ROLE", [], log: false)
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

  defp uuid(value), do: Ecto.UUID.dump!(value)
end
