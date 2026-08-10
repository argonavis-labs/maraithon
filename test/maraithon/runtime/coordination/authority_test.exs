defmodule Maraithon.Runtime.Coordination.AuthorityTest do
  use Maraithon.DataCase, async: false

  alias Maraithon.Accounts.User
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Repo
  alias Maraithon.Runtime.{BackgroundJob, BackgroundJobRunner}
  alias Maraithon.Runtime.Config

  alias Maraithon.Runtime.Coordination.{
    Authority,
    FairScheduler,
    Partitioning,
    Protocol,
    TaskAuthority,
    TaskClaims,
    TaskSupervisor
  }

  @revision "abcdef0"
  @evidence_id "fly:machines-destroyed:test-evidence"
  @activated_by "operator@example.test"
  @evidence_digest Base.encode16(:crypto.hash(:sha256, "non-secret-fleet-evidence"))

  setup_all do
    {login, database} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        [[login, database]] =
          Repo.query!("SELECT session_user, current_database()", []).rows

        unless Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_$]*\z/, login) and
                 Regex.match?(~r/\A[a-zA-Z_][a-zA-Z0-9_$-]*\z/, database) do
          raise "unsafe PostgreSQL test role/database identity"
        end

        Repo.query!(
          ~s(ALTER ROLE "#{login}" IN DATABASE "#{database}" SET role TO maraithon_runtime),
          []
        )

        {login, database}
      end)

    restart_repo!()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.query!("SET ROLE NONE", [])
        Repo.query!(~s(ALTER ROLE "#{login}" IN DATABASE "#{database}" RESET role), [])
      end)

      restart_repo!()
    end)

    :ok
  end

  test "direct SQL cannot activate before the catalog/backfill barrier" do
    activate_effect_protocol!()
    attest_effect_protocol!()

    defer_partition_catalog!()

    assert [[91]] =
             in_role!("maraithon_payload_verifier", fn ->
               Repo.query!("SELECT public.runtime_coordination_catalog_ready_count()", []).rows
             end)

    # Catch the expected check_violation inside a PostgreSQL subtransaction so
    # the outer SQL sandbox transaction remains usable.
    in_role!("maraithon_activation_operator", fn ->
      Repo.query!(
        """
        DO $block$
        DECLARE rejected boolean := false;
        BEGIN
          PERFORM set_config('maraithon.runtime_coordination_activation',
                             'ACTIVATE_PARTITION_FENCED_V1', true);
          BEGIN
            UPDATE public.runtime_coordination_protocols
            SET mode = 'partition_fenced_v1', activation_epoch = '00000000-0000-4000-8000-000000000001',
                activation_evidence_id = '#{@evidence_id}',
                activation_evidence_digest = decode('#{@evidence_digest}', 'hex'),
                activated_by = '#{@activated_by}', exact_revision = '#{@revision}',
                updated_at = timezone('UTC', clock_timestamp())
            WHERE name = 'runtime';
          EXCEPTION WHEN check_violation THEN
            rejected := true;
          END;
          IF NOT rejected THEN RAISE EXCEPTION 'unsafe activation unexpectedly succeeded'; END IF;
        END
        $block$;
        """,
        []
      )
    end)

    assert [["dark"]] = Repo.query!("SELECT mode FROM runtime_coordination_protocols", []).rows
    finalize_partition_catalog!()

    assert [[114]] =
             in_role!("maraithon_payload_verifier", fn ->
               Repo.query!("SELECT public.runtime_coordination_catalog_ready_count()", []).rows
             end)

    assert {:ok, :activated} = activate_coordination!()
  end

  test "ACL readiness rejects every single forbidden privilege" do
    forbidden = [
      {"maraithon_runtime", "runtime_coordination_protocols", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_runtime", "effect_execution_protocols", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_coordination_manifests", ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_task_outcome_evidence", ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "runtime_task_termination_proofs", ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_runtime", "effect_termination_attestations", ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_task_outcome_evidence",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_coordination_protocols",
       ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_node_incarnations", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "runtime_partitions", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_incident_operator", "effect_termination_attestations",
       ~w(UPDATE DELETE TRUNCATE)},
      {"maraithon_activation_operator", "runtime_task_assignments", ~w(INSERT DELETE TRUNCATE)},
      {"maraithon_activation_operator", "runtime_task_termination_proofs",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_payload_verifier", "runtime_task_outcome_evidence",
       ~w(INSERT UPDATE DELETE TRUNCATE)},
      {"maraithon_payload_verifier", "runtime_task_termination_proofs",
       ~w(INSERT UPDATE DELETE TRUNCATE)}
    ]

    assert [[true]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows

    Enum.each(forbidden, fn {role, table, privileges} ->
      Enum.each(privileges, fn privilege ->
        in_role!("maraithon_migrator", fn ->
          Repo.query!("GRANT #{privilege} ON TABLE public.#{table} TO #{role}", [])
        end)

        assert [[false]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows,
               "ACL readiness accepted #{privilege} on #{table} for #{role}"

        in_role!("maraithon_migrator", fn ->
          Repo.query!("REVOKE #{privilege} ON TABLE public.#{table} FROM #{role}", [])
        end)

        assert [[true]] = Repo.query!("SELECT public.runtime_coordination_acl_ready()", []).rows
      end)
    end)
  end

  test "exact Agent readiness stays closed while coordination is dark" do
    activate_effect_protocol!()
    old = Application.get_env(:maraithon, Maraithon.Runtime, [])
    on_exit(fn -> Application.put_env(:maraithon, Maraithon.Runtime, old) end)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      old
      |> Keyword.put(:exact_agent_runtime_enabled, true)
      |> Keyword.put(:multinode_coordination_enabled, true)
      |> Keyword.put(:allow_legacy_effect_protocol_in_test, false)
    )

    assert Protocol.mode() == :dark
    refute Config.exact_agent_runtime_ready?()
  end

  test "tenant concurrency is fair and deterministic under concurrent backlog" do
    %{node: node, partitions: partitions} = active_authority!(~w(tenant-a tenant-b))
    insert_user!("tenant-a")
    insert_user!("tenant-b")
    Enum.each(1..3, fn n -> insert_job!("tenant-a", "a-#{n}") end)
    insert_job!("tenant-b", "b-1")

    assert {:ok, {first, _assignment_a, _identity_a}} =
             FairScheduler.reserve_next(node, partitions)

    assert first.tenant_key == "user:tenant-a"

    # Default max_concurrency=1 makes the second reservation rotate to the
    # other tenant rather than repeatedly serving the lexicographically first.
    assert {:ok, {second, _assignment_b, _identity_b}} =
             FairScheduler.reserve_next(node, partitions)

    assert second.tenant_key == "user:tenant-b"
  end

  test "owner crash after durable reserve aborts the never-activated incarnation" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "owner-crash")
    parent = self()

    owner =
      spawn(fn ->
        result = FairScheduler.reserve_next(node, [partition])
        send(parent, {:durably_reserved, result})
        receive do: (:crash_after_commit -> exit(:simulated_runner_crash))
      end)

    assert_receive {:durably_reserved, {:ok, {reserved_job, assignment, identity}}}, 1_000
    assert reserved_job.id == job.id
    owner_ref = Process.monitor(owner)
    send(owner, :crash_after_commit)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :simulated_runner_crash}
    _ = :sys.get_state(TaskAuthority)

    final = TaskClaims.get(assignment.id)
    assert final.state == "settled"
    assert final.provider_boundary == "not_entered"
    assert final.outcome == "cancelled_before_provider"
    recovered_job = Repo.get!(BackgroundJob, job.id)
    assert recovered_job.status == "pending"
    assert is_nil(recovered_job.claim_token)
    assert is_nil(recovered_job.coordination_task_assignment_id)
    assert {:ok, :never_activated} = TaskSupervisor.terminate_exact(identity)
  end

  test "coupled supervisor restart proves a predecessor reservation never activated" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "predecessor")
    assignment_id = Ecto.UUID.generate()
    claim_token = Ecto.UUID.generate()

    assert {:ok, identity} =
             TaskSupervisor.reserve("background_job", job.id, claim_token, assignment_id)

    assert {:ok, assignment} = TaskClaims.reserve(node, partition, identity)

    old_authority = Process.whereis(TaskAuthority)
    old_ref = Process.monitor(old_authority)
    Process.exit(old_authority, :kill)
    assert_receive {:DOWN, ^old_ref, :process, ^old_authority, :killed}
    _ = :sys.get_state(TaskSupervisor)
    assert {:ok, new_supervisor_id} = TaskAuthority.identity()
    refute new_supervisor_id == identity.supervisor_id

    assert {:ok, :never_activated} = TaskSupervisor.terminate_exact(identity)
    final = TaskClaims.get(assignment.id)
    assert final.state == "settled"
    assert final.outcome == "cancelled_before_provider"
  end

  test "job heartbeat failure rolls back the task lease renewal" do
    %{node: node, partitions: partitions} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "renew-rollback")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, partitions)

    parent = self()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        :ok = TaskSupervisor.register_current!(identity)
        result = FairScheduler.activate_job(reserved_job, assignment)
        send(parent, {:renewal_task_started, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:renewal_task_started, {:ok, {running_job, running_assignment}}}
    test_pid = self()

    runner =
      start_supervised!(
        {BackgroundJobRunner,
         name: :coordination_renewal_test_runner,
         poll_interval_ms: 600_000,
         claim_timeout_ms: 300_000,
         renew_job_writer: fn _job, _now ->
           send(test_pid, :injected_job_heartbeat_failure)
           {0, []}
         end}
      )

    key = {running_job.id, running_job.claim_token}

    :sys.replace_state(runner, fn state ->
      entry = %{
        job: running_job,
        task: task,
        coordination: %{assignment: running_assignment, identity: identity},
        phase: :executing,
        stop_reason: nil
      }

      %{state | running: %{key => entry}, monitors: %{task.ref => key}}
    end)

    before_renewal = TaskClaims.get(running_assignment.id)
    send(runner, :renew_claims)
    assert_receive :injected_job_heartbeat_failure
    _ = :sys.get_state(runner)
    after_renewal = TaskClaims.get(running_assignment.id)
    assert after_renewal.lease_expires_at == before_renewal.lease_expires_at
    refute Process.alive?(task.pid)
    assert job.id == running_job.id
  end

  test "external destruction proof cannot manufacture a provider outcome" do
    %{node: node, partitions: [partition]} = active_authority!(["tenant-a"])
    insert_user!("tenant-a")
    job = insert_job!("tenant-a", "provider-work")

    assert {:ok, {reserved_job, assignment, identity}} =
             FairScheduler.reserve_next(node, [partition])

    assert reserved_job.id == job.id
    parent = self()

    task =
      Task.Supervisor.async_nolink(TaskSupervisor.task_supervisor(), fn ->
        :ok = TaskSupervisor.register_current!(identity)

        result =
          with {:ok, {running_job, running_assignment}} <-
                 FairScheduler.activate_job(reserved_job, assignment),
               {:ok, entered} <- TaskClaims.mark_provider_entered(running_assignment) do
            {:ok, running_job, entered}
          end

        send(parent, {:provider_entered, result})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:provider_entered, {:ok, running_job, entered}}

    # A normal settlement without immutable outcome evidence is rejected even
    # when direct SQL knows the assignment UUID/GUC.
    reject_assignment_update!(entered.id, """
      state = 'settled', provider_boundary = 'outcome_known',
      settled_at = timezone('UTC', clock_timestamp()), outcome = 'completed'
    """)

    assert TaskClaims.get(entered.id).state == "running"

    assert {:ok, requested} = TaskClaims.request_termination(entered)
    assert requested.provider_boundary == "outcome_unknown"

    proven =
      in_role!("maraithon_incident_operator", fn ->
        assert {:ok, proven} =
                 TaskClaims.record_external_termination(
                   requested,
                   "machine:destroyed:test",
                   @activated_by
                 )

        proven
      end)

    assert proven.state == "termination_proven"

    reject_assignment_update!(proven.id, """
      state = 'settled', settled_at = timezone('UTC', clock_timestamp()), outcome = 'completed'
    """)

    assert TaskClaims.get(proven.id).state == "termination_proven"

    assert {:ok, [{_, 1, "provider_outcome_ambiguous"}]} = TaskClaims.reconcile_proven(1)
    final = TaskClaims.get(proven.id)
    assert final.state == "outcome_ambiguous"
    assert final.outcome == "provider_outcome_ambiguous"
    assert Repo.get!(BackgroundJob, running_job.id).last_error == "provider_outcome_ambiguous"

    send(task.pid, :finish)
    assert_receive {:DOWN, ref, :process, _pid, :normal} when ref == task.ref
  end

  defp active_authority!(user_ids) do
    activate_effect_protocol!()
    attest_effect_protocol!()
    finalize_partition_catalog!()
    assert {:ok, :activated} = activate_coordination!()

    node =
      Authority.register_node(revision: @revision, node_name: "test-node", ttl_ms: 300_000)
      |> ok!()

    node = Authority.mark_node_ready(node) |> ok!()
    leader = Authority.acquire_leader(node, 300_000) |> ok!()
    leader = Authority.mark_leader_ready(leader) |> ok!()

    partitions =
      user_ids
      |> Enum.map(&Partitioning.partition_for("user:" <> &1))
      |> Enum.uniq()
      |> Enum.map(fn partition_id ->
        Authority.assign_partition(leader, node, partition_id, ttl_ms: 300_000) |> ok!()
        Authority.mark_partition_ready(node, partition_id) |> ok!()
      end)

    %{node: node, leader: leader, partitions: partitions}
  end

  defp activate_effect_protocol! do
    status =
      in_role!("maraithon_activation_operator", fn ->
        assert {:ok, status} =
                 ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())

        status
      end)

    assert status in [:activated, :already_active]
  end

  defp attest_effect_protocol! do
    status =
      in_role!("maraithon_activation_operator", fn ->
        assert {:ok, status} =
                 Protocol.attest_effect_activation_evidence(
                   Keyword.delete(coordination_activation_opts(), :confirmation)
                 )

        status
      end)

    assert status in [:attested, :already_attested]
  end

  defp activate_coordination! do
    in_role!("maraithon_activation_operator", fn ->
      Protocol.activate(coordination_activation_opts())
    end)
  end

  defp defer_partition_catalog! do
    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        "ALTER TABLE public.background_jobs DROP CONSTRAINT background_jobs_partition_shape",
        []
      )

      Repo.query!(
        """
        ALTER TABLE public.background_jobs ADD CONSTRAINT background_jobs_partition_shape CHECK (
          (tenant_key IS NULL AND partition_id IS NULL) OR
          (octet_length(tenant_key) BETWEEN 1 AND 512 AND partition_id >= 0 AND partition_id < 64)
        ) NOT VALID
        """,
        []
      )

      Repo.query!(
        "ALTER TABLE public.scheduled_jobs DROP CONSTRAINT scheduled_jobs_partition_shape",
        []
      )

      Repo.query!(
        """
        ALTER TABLE public.scheduled_jobs ADD CONSTRAINT scheduled_jobs_partition_shape CHECK (
          (tenant_key IS NULL AND partition_id IS NULL) OR
          (octet_length(tenant_key) BETWEEN 1 AND 512 AND partition_id >= 0 AND partition_id < 64)
        ) NOT VALID
        """,
        []
      )
    end)
  end

  defp finalize_partition_catalog! do
    in_role!("maraithon_migrator", fn ->
      Repo.query!(
        "ALTER TABLE public.background_jobs VALIDATE CONSTRAINT background_jobs_partition_shape",
        []
      )

      Repo.query!(
        "ALTER TABLE public.scheduled_jobs VALIDATE CONSTRAINT scheduled_jobs_partition_shape",
        []
      )
    end)
  end

  defp coordination_activation_opts do
    [
      confirmation: Protocol.activation_confirmation(),
      evidence_id: @evidence_id,
      evidence_digest: @evidence_digest,
      activated_by: @activated_by,
      exact_revision: @revision
    ]
  end

  defp insert_user!(id) do
    case Repo.transaction(fn ->
           Repo.query!("SET LOCAL ROLE NONE", [])

           user =
             %User{}
             |> User.changeset(%{id: id, email: "#{id}@example.test"})
             |> Repo.insert!()

           Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
           user
         end) do
      {:ok, user} -> user
      {:error, reason} -> flunk("login-role insert failed: #{inspect(reason)}")
    end
  end

  defp insert_job!(user_id, dedupe) do
    %BackgroundJob{}
    |> BackgroundJob.changeset(%{
      user_id: user_id,
      queue: "test",
      job_type: "test",
      payload: %{"dedupe" => dedupe},
      dedupe_key: Ecto.UUID.generate(),
      scheduled_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp reject_assignment_update!(assignment_id, set_sql) do
    Repo.query!(
      """
      DO $block$
      DECLARE rejected boolean := false;
      BEGIN
        PERFORM set_config('maraithon.runtime_task_action', '#{assignment_id}', true);
        BEGIN
          UPDATE public.runtime_task_assignments SET #{set_sql},
            updated_at = timezone('UTC', clock_timestamp())
          WHERE id = '#{assignment_id}'::uuid;
        EXCEPTION WHEN check_violation THEN
          rejected := true;
        END;
        IF NOT rejected THEN RAISE EXCEPTION 'unsafe assignment update unexpectedly succeeded'; END IF;
      END
      $block$;
      """,
      []
    )
  end

  defp restart_repo! do
    :ok = Supervisor.terminate_child(Maraithon.Supervisor, Repo)
    {:ok, _pid} = Supervisor.restart_child(Maraithon.Supervisor, Repo)
    :ok
  end

  defp in_role!(role, fun)
       when role in [
              "maraithon_migrator",
              "maraithon_runtime",
              "maraithon_payload_verifier",
              "maraithon_incident_operator",
              "maraithon_activation_operator"
            ] and is_function(fun, 0) do
    case Repo.transaction(fn ->
           Repo.query!("SET LOCAL ROLE " <> role, [])
           value = fun.()
           Repo.query!("SET LOCAL ROLE maraithon_runtime", [])
           value
         end) do
      {:ok, value} -> value
      {:error, reason} -> flunk("role-scoped transaction failed: #{inspect(reason)}")
    end
  end

  defp ok!({:ok, value}), do: value
end
