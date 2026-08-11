defmodule Maraithon.Runtime.AgentTerminationConvergenceTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.Agents
  alias Maraithon.Repo
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRegistry
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.AgentRuntimeLease
  alias Maraithon.Runtime.AgentTerminations
  alias Maraithon.Runtime.AgentTerminationProof
  alias Maraithon.Runtime.AgentWatcher
  alias Maraithon.Runtime.DatabaseClock

  setup do
    # DataCase enters maraithon_runtime, while ALTER TABLE remains owner-only.
    # Disable only these role-enforcement triggers transactionally so this suite
    # can focus on convergence; 140004 separately attests their fingerprints.
    as_database_owner(fn ->
      Repo.query!(
        "ALTER TABLE agent_runtime_leases DISABLE TRIGGER enforce_coordinated_agent_lease_trigger"
      )

      Repo.query!(
        "ALTER TABLE agent_termination_proofs DISABLE TRIGGER enforce_agent_termination_proof_trigger"
      )
    end)

    :ok
  end

  test "expired lease with a live process remains a replacement fence" do
    agent = running_agent("expired-live")
    lease = manual_lease(agent, expired?: true)
    pid = parked_process()
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    assert {:requested, incident} =
             as_migrator(fn ->
               AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])
             end)

    assert incident.status == "requested"
    assert Process.alive?(pid)
    assert AgentLeases.get(agent.id).owner_token == lease.owner_token
    assert AgentRestartGuards.get(agent.id) == nil
    assert AgentTerminations.proof_for(incident.id) == nil

    assert {:error, :agent_termination_unproven} =
             as_migrator(fn -> AgentLeases.claim(agent.id) end)
  end

  test "the original exact monitor DOWN records proof and converges the lease" do
    agent = running_agent("local-down")
    watcher = watcher(recover?: false)
    lease = manual_lease(agent, watcher: watcher)
    pid = registered_owner(agent.id, lease.owner_token)

    as_migrator(fn ->
      assert :ok = AgentWatcher.track(watcher, pid, agent.id, lease.owner_token)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000

      await_watcher_release(watcher, pid, 100)
    end)

    assert %{last_owner_token: owner_token, needs_recovery: true} =
             AgentRestartGuards.get(agent.id)

    assert owner_token == lease.owner_token
    assert AgentLeases.get(agent.id) == nil

    incident = AgentTerminations.get_by_lease(lease.owner_token)
    assert incident.status == "reconciled"

    assert %AgentTerminationProof{proof_kind: "local_down", local_pid: local_pid} =
             AgentTerminations.proof_for(incident.id)

    assert local_pid == inspect(pid)
  end

  test "watcher restart gap remains ambiguous and requires external evidence" do
    agent = running_agent("watcher-gap")
    watcher = watcher(recover?: false)
    lease = manual_lease(agent, watcher: watcher)
    pid = registered_owner(agent.id, lease.owner_token)

    assert :ok = AgentWatcher.track(watcher, pid, agent.id, lease.owner_token)
    watcher_ref = Process.monitor(watcher)
    :ok = GenServer.stop(watcher, :normal)
    assert_receive {:DOWN, ^watcher_ref, :process, ^watcher, :normal}, 1_000

    pid_ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^pid_ref, :process, ^pid, :killed}, 1_000
    expire_lease!(agent.id)

    replacement_watcher = watcher(recover?: false)
    _ = :sys.get_state(replacement_watcher)

    assert {:requested, incident} =
             as_migrator(fn ->
               AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])
             end)

    assert incident.status == "requested"
    assert AgentTerminations.proof_for(incident.id) == nil
    assert AgentLeases.get(agent.id).owner_token == lease.owner_token
    assert AgentRestartGuards.get(agent.id) == nil
  end

  test "signed external node-destruction proof releases only its exact coordination identity" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous = Application.get_env(:maraithon, AgentTerminations)

    Application.put_env(:maraithon, AgentTerminations,
      external_attestation_public_key: public_key
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:maraithon, AgentTerminations, previous),
        else: Application.delete_env(:maraithon, AgentTerminations)
    end)

    agent = running_agent("external-proof")
    lease = manual_lease(agent, expired?: true, coordinated?: true)

    assert {:requested, incident} =
             as_migrator(fn ->
               AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])
             end)

    evidence_id = "fly-machine-destroyed:#{Ecto.UUID.generate()}"
    digest = :crypto.hash(:sha256, "provider destruction receipt")
    proved_by = "incident-commander@example.com"
    payload = AgentTerminations.attestation_payload(incident, evidence_id, digest, proved_by)
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    assert {:error, :invalid_external_termination_attestation} =
             as_migrator(fn ->
               AgentTerminations.attest_external(incident.id, %{
                 evidence_id: evidence_id,
                 evidence_digest: digest,
                 signature: :crypto.strong_rand_bytes(64),
                 proved_by: proved_by
               })
             end)

    assert AgentLeases.get(agent.id).owner_token == lease.owner_token

    assert {:attested, proof} =
             as_migrator(fn ->
               AgentTerminations.attest_external(incident.id, %{
                 evidence_id: evidence_id,
                 evidence_digest: digest,
                 signature: signature,
                 proved_by: proved_by
               })
             end)

    assert proof.proof_kind == "external_node_destroyed"
    assert AgentLeases.get(agent.id).owner_token == lease.owner_token
    assert AgentTerminations.get(incident.id).status == "proven"

    assert {:recorded, guard} =
             as_migrator(fn -> AgentTerminations.reconcile_incident(incident.id) end)

    assert guard.last_owner_token == lease.owner_token
    assert AgentLeases.get(agent.id) == nil
    assert AgentTerminations.get(incident.id).status == "reconciled"
    assert AgentTerminations.proof_for(incident.id).proof_kind == "external_node_destroyed"
  end

  test "duplicate exact watcher DOWN is durably idempotent" do
    agent = running_agent("proof-idempotent")
    watcher = watcher(recover?: false)
    lease = manual_lease(agent, watcher: watcher)
    pid = registered_owner(agent.id, lease.owner_token)
    assert :ok = AgentWatcher.track(watcher, pid, agent.id, lease.owner_token)
    watcher_ref = watcher |> :sys.get_state() |> Map.fetch!(:pids) |> Map.fetch!(pid)

    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 1_000
    await_watcher_release(watcher, pid, 100)

    first_guard = AgentRestartGuards.get(agent.id)
    assert first_guard.last_owner_token == lease.owner_token
    assert first_guard.crash_count == 1

    send(watcher, {:DOWN, watcher_ref, :process, pid, :killed})
    _ = :sys.get_state(watcher)

    duplicate_guard = AgentRestartGuards.get(agent.id)
    assert duplicate_guard.generation == first_guard.generation
    assert duplicate_guard.crash_count == 1

    incident = AgentTerminations.get_by_lease(lease.owner_token)
    assert Repo.aggregate(AgentTerminationProof, :count, :id) == 1
    assert incident.request_count == 1
    assert incident.status == "reconciled"
  end

  test "an old-node stale lease blocks partition release until exact proof" do
    {public_key, private_key} = :crypto.generate_key(:eddsa, :ed25519)
    previous = Application.get_env(:maraithon, AgentTerminations)

    Application.put_env(:maraithon, AgentTerminations,
      external_attestation_public_key: public_key
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:maraithon, AgentTerminations, previous),
        else: Application.delete_env(:maraithon, AgentTerminations)
    end)

    partition_id = 63
    activation_epoch = Ecto.UUID.generate()
    old_node = Ecto.UUID.generate()
    new_node = Ecto.UUID.generate()
    transition_id = Ecto.UUID.generate()

    disable_partition_triggers!()

    Repo.query!(
      """
      UPDATE runtime_partitions
      SET activation_epoch = $2::uuid, ownership_epoch = ownership_epoch + 1,
          owner_node_incarnation_id = $3::uuid, transition_id = $4::uuid,
          state = 'draining', lease_expires_at = timezone('UTC', clock_timestamp()) - interval '1 minute',
          ready_at = NULL, draining_at = timezone('UTC', clock_timestamp()),
          updated_at = timezone('UTC', clock_timestamp())
      WHERE partition_id = $1
      """,
      [
        partition_id,
        Ecto.UUID.dump!(activation_epoch),
        Ecto.UUID.dump!(old_node),
        Ecto.UUID.dump!(transition_id)
      ]
    )

    enable_termination_partition_trigger!()
    agent = running_agent("partition-release")

    lease =
      manual_lease(agent,
        expired?: true,
        activation_epoch: activation_epoch,
        node_incarnation_id: old_node,
        partition_id: partition_id,
        partition_epoch: partition_epoch(partition_id)
      )

    assert {:requested, incident} =
             as_migrator(fn ->
               AgentRestartGuards.record_expired(agent.id, lease.owner_token, backoffs_ms: [0])
             end)

    assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
             release_partition_in_savepoint(partition_id)

    evidence_id = "destroyed-old-node:#{old_node}"
    digest = :crypto.hash(:sha256, "old node destruction receipt")
    proved_by = "incident-commander@example.com"
    payload = AgentTerminations.attestation_payload(incident, evidence_id, digest, proved_by)
    signature = :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])

    assert {:attested, _proof} =
             as_migrator(fn ->
               AgentTerminations.attest_external(incident.id, %{
                 evidence_id: evidence_id,
                 evidence_digest: digest,
                 signature: signature,
                 proved_by: proved_by
               })
             end)

    assert AgentLeases.get(agent.id).owner_token == lease.owner_token

    assert {:recorded, _guard} =
             as_migrator(fn -> AgentTerminations.reconcile_incident(incident.id) end)

    assert AgentLeases.get(agent.id) == nil
    assert :ok = release_partition!(partition_id)

    # A different node can now own the next epoch; the old exact identity was
    # never inferred from node-down or lease expiry.
    Repo.query!(
      """
      UPDATE runtime_partitions
      SET activation_epoch = $2::uuid, ownership_epoch = ownership_epoch + 1,
          owner_node_incarnation_id = $3::uuid, transition_id = $4::uuid,
          state = 'preparing', lease_expires_at = timezone('UTC', clock_timestamp()) + interval '1 minute',
          ready_at = NULL, draining_at = NULL, updated_at = timezone('UTC', clock_timestamp())
      WHERE partition_id = $1
      """,
      [
        partition_id,
        Ecto.UUID.dump!(activation_epoch),
        Ecto.UUID.dump!(new_node),
        Ecto.UUID.dump!(Ecto.UUID.generate())
      ]
    )

    assert [[^new_node]] =
             Repo.query!(
               "SELECT owner_node_incarnation_id::text FROM runtime_partitions WHERE partition_id = $1",
               [partition_id]
             ).rows
  end

  defp running_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        config: %{"name" => name},
        install_status: "enabled",
        status: "running"
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp manual_lease(agent, opts \\ []) do
    now = DatabaseClock.now!()
    expired? = Keyword.get(opts, :expired?, false)
    claimed_at = DateTime.add(now, -180, :second)
    renewed_at = DateTime.add(now, -120, :second)
    owner_token = Ecto.UUID.generate()
    watcher = Keyword.get(opts, :watcher)

    termination_capability_digest =
      if watcher do
        {:ok, digest} =
          AgentWatcher.prepare_lease_capability(watcher, agent.id, owner_token)

        digest
      else
        :crypto.hash(:sha256, :crypto.strong_rand_bytes(32))
      end

    lease_until =
      if expired?, do: DateTime.add(now, -60, :second), else: DateTime.add(now, 60, :second)

    coordinated? = Keyword.get(opts, :coordinated?, false)

    coordination =
      if coordinated? do
        %{
          coordination_activation_epoch: Ecto.UUID.generate(),
          coordination_node_incarnation_id: Ecto.UUID.generate(),
          coordination_partition_id: 1,
          coordination_partition_epoch: 1
        }
      else
        %{
          coordination_activation_epoch: Keyword.get(opts, :activation_epoch),
          coordination_node_incarnation_id: Keyword.get(opts, :node_incarnation_id),
          coordination_partition_id: Keyword.get(opts, :partition_id),
          coordination_partition_epoch: Keyword.get(opts, :partition_epoch)
        }
      end

    attrs =
      Map.merge(coordination, %{
        agent_id: agent.id,
        owner_token: owner_token,
        owner_node: Atom.to_string(node()),
        termination_capability_digest: termination_capability_digest,
        claimed_at: claimed_at,
        renewed_at: renewed_at,
        lease_until: lease_until,
        ready_at: nil,
        draining_at: nil
      })

    try do
      as_migrator(fn ->
        %AgentRuntimeLease{}
        |> AgentRuntimeLease.changeset(attrs)
        |> Repo.insert!()
      end)
    rescue
      error ->
        if watcher,
          do: AgentWatcher.discard_lease_capability(watcher, agent.id, owner_token)

        reraise error, __STACKTRACE__
    end
  end

  defp parked_process do
    spawn(fn -> receive do: (:stop -> :ok) end)
  end

  defp registered_owner(agent_id, owner_token) do
    parent = self()

    pid =
      spawn(fn ->
        result = Registry.register(AgentRegistry, agent_id, owner_token)
        send(parent, {:owner_registered, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:owner_registered, ^pid, {:ok, _owner}}, 1_000
    pid
  end

  defp watcher(opts) do
    suffix = System.unique_integer([:positive])
    name = :"termination_watcher_#{suffix}"

    start_supervised!(
      {AgentWatcher,
       name: name,
       reconcile?: false,
       recover?: Keyword.get(opts, :recover?, false),
       crash_loop_max: 3,
       crash_loop_window_ms: 60_000,
       reresume_backoffs: [0],
       shutdown_down_barrier_ms: 0},
      id: name
    )
  end

  defp await_watcher_release(_watcher, _pid, 0),
    do: flunk("AgentWatcher did not reconcile the exact DOWN")

  defp await_watcher_release(watcher, pid, attempts) do
    case :sys.get_state(watcher) do
      %{pids: pids, pending_downs: pending} when not is_map_key(pids, pid) ->
        if map_size(pending) == 0,
          do: :ok,
          else: await_watcher_release(watcher, pid, attempts - 1)

      _state ->
        await_watcher_release(watcher, pid, attempts - 1)
    end
  end

  defp expire_lease!(agent_id) do
    as_migrator(fn ->
      Repo.query!(
        """
        UPDATE agent_runtime_leases
        SET renewed_at = timezone('UTC', clock_timestamp()) - interval '2 minutes',
            lease_until = timezone('UTC', clock_timestamp()) - interval '1 minute',
            ready_at = NULL, draining_at = NULL,
            updated_at = timezone('UTC', clock_timestamp())
        WHERE agent_id = $1::uuid
        """,
        [Ecto.UUID.dump!(agent_id)]
      )
    end)
  end

  defp as_migrator(fun) when is_function(fun, 0), do: fun.()

  defp as_database_owner(fun) when is_function(fun, 0) do
    Repo.query!("RESET ROLE", [], log: false)

    try do
      fun.()
    after
      Repo.query!("SET LOCAL ROLE maraithon_runtime", [], log: false)
    end
  end

  defp disable_partition_triggers! do
    as_database_owner(fn ->
      Repo.query!(
        "ALTER TABLE runtime_partitions DISABLE TRIGGER enforce_runtime_partition_authority_trigger"
      )

      Repo.query!(
        "ALTER TABLE runtime_partitions DISABLE TRIGGER enforce_agent_termination_partition_release_trigger"
      )
    end)
  end

  defp enable_termination_partition_trigger! do
    as_database_owner(fn ->
      Repo.query!(
        "ALTER TABLE runtime_partitions ENABLE TRIGGER enforce_agent_termination_partition_release_trigger"
      )
    end)
  end

  defp release_partition_in_savepoint(partition_id) do
    Repo.transaction(fn ->
      case release_partition_query(partition_id) do
        {:ok, _result} -> :ok
        {:error, error} -> Repo.rollback(error)
      end
    end)
  end

  defp release_partition!(partition_id) do
    {:ok, %{num_rows: 1}} = release_partition_query(partition_id)
    :ok
  end

  defp release_partition_query(partition_id) do
    Repo.query(
      """
      UPDATE runtime_partitions
      SET activation_epoch = NULL, owner_node_incarnation_id = NULL,
          transition_id = NULL, state = 'unassigned', lease_expires_at = NULL,
          ready_at = NULL, draining_at = NULL,
          updated_at = timezone('UTC', clock_timestamp())
      WHERE partition_id = $1 AND state = 'draining'
      """,
      [partition_id]
    )
  end

  defp partition_epoch(partition_id) do
    [[epoch]] =
      Repo.query!(
        "SELECT ownership_epoch FROM runtime_partitions WHERE partition_id = $1",
        [partition_id]
      ).rows

    epoch
  end
end
