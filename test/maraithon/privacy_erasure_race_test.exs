defmodule Maraithon.PrivacyErasureRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Maraithon.Accounts
  alias Maraithon.Accounts.User
  alias Maraithon.Agents
  alias Maraithon.Agents.Agent
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Privacy.ErasureAgentTarget
  alias Maraithon.Privacy.ErasureRequest
  alias Maraithon.PrivacyErasure
  alias Maraithon.Repo
  alias Maraithon.Runtime.BackgroundJob
  alias Maraithon.Runtime.Coordination.Protocol, as: CoordinationProtocol

  @activation_evidence [
    evidence_id: "test:stopped-fleet:privacy-erasure-race",
    evidence_digest: :crypto.hash(:sha256, "privacy erasure race stopped fleet evidence"),
    activated_by: "privacy-erasure-race@example.test",
    revision: String.duplicate("f", 40)
  ]
  @protocol_harness_lock {20_260_811, 140_007}

  test "Agent creation wins the user lock and dark erasure rejects the Agent-bearing snapshot" do
    user = unboxed(fn -> user_fixture("creation-first") end)
    on_exit(fn -> cleanup_user(user.id) end)
    parent = self()

    creator =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
              )

            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:creator_holds_user, self(), backend_pid})
            assert_receive :release_creator, 5_000

            {:ok, agent} =
              Agents.create_agent(%{
                user_id: user.id,
                behavior: "prompt_agent",
                status: "stopped"
              })

            agent
          end)
        end)
      end)

    assert_receive {:creator_holds_user, creator_pid, _creator_backend_pid}, 5_000

    requestor =
      Task.async(fn ->
        unboxed(fn ->
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:request_started, backend_pid})
          PrivacyErasure.request_user(user.id)
        end)
      end)

    assert_receive {:request_started, _requestor_backend_pid}, 5_000
    send(creator_pid, :release_creator)

    assert {:ok, %Agent{} = agent} = Task.await(creator, 5_000)

    assert {:error, :exact_runtime_required_for_agent_erasure} =
             Task.await(requestor, 5_000)

    assert %Agent{} = unboxed(fn -> Repo.get(Agent, agent.id) end)

    refute unboxed(fn ->
             Repo.exists?(
               from(request in ErasureRequest,
                 where: request.subject_user_id == ^user.id
               )
             )
           end)
  end

  @tag timeout: 120_000
  test "exact erasure snapshots an Agent committed ahead of the user lock" do
    user = unboxed(fn -> user_fixture("exact-creation-first") end)
    on_exit(fn -> cleanup_user(user.id) end)
    parent = self()

    with_committed_exact_pair(fn ->
      creator =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              _locked =
                Repo.one!(
                  from(candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
                )

              [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
              send(parent, {:exact_creator_holds_user, self(), backend_pid})
              assert_receive :release_exact_creator, 15_000

              {:ok, agent} =
                Agents.create_agent(%{
                  user_id: user.id,
                  behavior: "prompt_agent",
                  status: "stopped"
                })

              agent
            end)
          end)
        end)

      assert_receive {:exact_creator_holds_user, creator_pid, creator_backend_pid}, 5_000

      requestor =
        Task.async(fn ->
          unboxed(fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:exact_request_started, backend_pid})
            PrivacyErasure.request_user(user.id)
          end)
        end)

      assert_receive {:exact_request_started, requestor_backend_pid}, 5_000
      await_lock_barrier!(requestor, requestor_backend_pid, creator_backend_pid)
      send(creator_pid, :release_exact_creator)

      assert {:ok, %Agent{} = agent} = Task.await(creator, 5_000)
      assert {:ok, %ErasureRequest{} = request} = Task.await(requestor, 5_000)

      assert unboxed(fn ->
               Repo.exists?(
                 from(target in ErasureAgentTarget,
                   where: target.request_id == ^request.id,
                   where: target.agent_id == ^agent.id
                 )
               )
             end)
    end)
  end

  test "a committed request fence rejects a creation that was waiting on the user" do
    user = unboxed(fn -> user_fixture("request-first") end)
    on_exit(fn -> cleanup_user(user.id) end)
    parent = self()

    requestor =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            _locked =
              Repo.one!(
                from(candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
              )

            {:ok, request} = PrivacyErasure.request_user(user.id)
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
            send(parent, {:request_fenced, self(), backend_pid})
            assert_receive :release_request, 15_000
            request
          end)
        end)
      end)

    assert_receive {:request_fenced, request_pid, request_backend_pid}, 5_000

    creator =
      Task.async(fn ->
        unboxed(fn ->
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()", []).rows
          send(parent, {:creator_started, backend_pid})

          Agents.create_agent(%{
            user_id: user.id,
            behavior: "prompt_agent",
            status: "stopped"
          })
        end)
      end)

    assert_receive {:creator_started, creator_backend_pid}, 5_000
    await_lock_barrier!(creator, creator_backend_pid, request_backend_pid)
    send(request_pid, :release_request)

    assert {:ok, %ErasureRequest{}} = Task.await(requestor, 5_000)
    assert {:error, :privacy_erasure_requested} = Task.await(creator, 5_000)
  end

  # Unboxed contenders can observe only a committed cutover. A dedicated
  # connection holds this session advisory lock across activation, the race,
  # and restoration so no other committed protocol harness can interleave.
  defp with_committed_exact_pair(fun) do
    lock_owner = start_protocol_harness_lock!()

    try do
      snapshot = unboxed(&protocol_pair_snapshot!/0)

      try do
        # Exact setup goes through the real one-way activation APIs.
        unboxed(&activate_committed_exact_pair!/0)
        fun.()
      after
        # Reversing the one-way test cutover is cleanup-only and runs as the
        # database session owner; application roles never receive this power.
        unboxed(fn -> restore_protocol_pair!(snapshot) end)
      end
    after
      release_protocol_harness_lock!(lock_owner)
    end
  end

  defp start_protocol_harness_lock! do
    parent = self()
    release_ref = make_ref()
    {lock_key_1, lock_key_2} = @protocol_harness_lock

    owner =
      Task.async(fn ->
        unboxed(fn ->
          Repo.query!(
            "SELECT pg_advisory_lock($1::integer, $2::integer)",
            [lock_key_1, lock_key_2]
          )

          send(parent, {:protocol_harness_lock_acquired, self(), release_ref})

          try do
            receive do
              {:release_protocol_harness_lock, ^release_ref} -> :ok
            after
              110_000 -> flunk("protocol harness lock release timed out")
            end
          after
            Repo.query!(
              "SELECT pg_advisory_unlock($1::integer, $2::integer)",
              [lock_key_1, lock_key_2]
            )
          end
        end)
      end)

    assert_receive {:protocol_harness_lock_acquired, owner_pid, ^release_ref}, 60_000
    assert owner.pid == owner_pid
    {owner, release_ref}
  end

  defp release_protocol_harness_lock!({owner, release_ref}) do
    send(owner.pid, {:release_protocol_harness_lock, release_ref})
    assert :ok = Task.await(owner, 5_000)
  end

  defp protocol_pair_snapshot! do
    case Repo.transaction(fn ->
           runtime = protocol_row!("runtime_coordination_protocols", "runtime")
           effect = protocol_row!("effect_execution_protocols", "effects")
           %{runtime: runtime, effect: effect}
         end) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> flunk("protocol snapshot failed: #{inspect(reason)}")
    end
  end

  defp protocol_row!(table, name) do
    Repo.query!(
      """
      SELECT mode, activated_at, activation_epoch, activation_evidence_id,
             activation_evidence_digest, activated_by, exact_revision, updated_at
      FROM #{table}
      WHERE name = $1
      FOR SHARE
      """,
      [name]
    ).rows
    |> List.first()
    |> case do
      nil -> flunk("#{table} protocol authority is missing")
      row -> row
    end
  end

  defp activate_committed_exact_pair! do
    assert {:ok, attestation} =
             CoordinationProtocol.attest_effect_activation_evidence(@activation_evidence)

    assert attestation in [:attested, :already_attested]

    assert {:ok, effect_activation} =
             ProtocolCutover.activate(
               [confirmation: ProtocolCutover.activation_confirmation()] ++ @activation_evidence
             )

    assert effect_activation in [:activated, :already_active]

    assert {:ok, runtime_activation} =
             Repo.transaction(fn ->
               Repo.query!("SET LOCAL ROLE maraithon_activation_operator", [])

               case CoordinationProtocol.activate(
                      [confirmation: CoordinationProtocol.activation_confirmation()] ++
                        @activation_evidence
                    ) do
                 {:ok, status} -> status
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)

    assert runtime_activation in [:activated, :already_active]
  end

  defp restore_protocol_pair!(snapshot) do
    case Repo.transaction(fn ->
           Repo.query!("SET LOCAL ROLE NONE", [])
           set_protocol_guards!("DISABLE")
           restore_protocol_row!("effect_execution_protocols", "effects", snapshot.effect)
           restore_protocol_row!("runtime_coordination_protocols", "runtime", snapshot.runtime)
           set_protocol_guards!("ENABLE")
         end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> flunk("protocol cleanup failed: #{inspect(reason)}")
    end
  end

  defp restore_protocol_row!(table, name, row) do
    [mode, activated_at, epoch, evidence_id, evidence_digest, activated_by, revision, updated_at] =
      row

    assert %{num_rows: 1} =
             Repo.query!(
               """
               UPDATE #{table}
               SET mode = $1, activated_at = $2, activation_epoch = $3::uuid,
                   activation_evidence_id = $4, activation_evidence_digest = $5,
                   activated_by = $6, exact_revision = $7, updated_at = $8
               WHERE name = $9
               """,
               [
                 mode,
                 activated_at,
                 epoch,
                 evidence_id,
                 evidence_digest,
                 activated_by,
                 revision,
                 updated_at,
                 name
               ]
             )
  end

  defp set_protocol_guards!(action) when action in ["DISABLE", "ENABLE"] do
    for {table, trigger} <- [
          {"effect_execution_protocols", "enforce_effect_protocol_one_way_trigger"},
          {"effect_execution_protocols", "enforce_effect_activation_evidence_trigger"},
          {"effect_execution_protocols", "enforce_operational_privacy_activation_trigger"},
          {"runtime_coordination_protocols", "enforce_runtime_coordination_protocol_trigger"}
        ] do
      Repo.query!("ALTER TABLE #{table} #{action} TRIGGER #{trigger}", [])
    end

    :ok
  end

  defp await_lock_barrier!(waiter, waiter_backend_pid, blocker_backend_pid) do
    blocked =
      Enum.reduce_while(1..500, false, fn _attempt, _blocked ->
        case Task.yield(waiter, 10) do
          nil ->
            blocking_pids =
              unboxed(fn ->
                [[blocking_pids]] =
                  Repo.query!("SELECT pg_blocking_pids($1::integer)", [waiter_backend_pid]).rows

                blocking_pids
              end)

            if blocker_backend_pid in blocking_pids,
              do: {:halt, true},
              else: {:cont, false}

          completed ->
            flunk("database lock waiter completed before the barrier: #{inspect(completed)}")
        end
      end)

    assert blocked,
           "database lock barrier was not observed for backend #{waiter_backend_pid}"
  end

  defp cleanup_user(nil), do: :ok

  defp cleanup_user(user_id) do
    unboxed(fn ->
      request_ids =
        Repo.all(
          from(request in ErasureRequest,
            where: request.subject_user_id == ^user_id,
            select: request.id
          )
        )

      Repo.delete_all(
        from(job in BackgroundJob,
          where: job.dedupe_key in ^Enum.map(request_ids, &("privacy-erasure:" <> &1))
        )
      )

      Repo.delete_all(from(request in ErasureRequest, where: request.id in ^request_ids))
      Repo.delete_all(from(agent in Agent, where: agent.user_id == ^user_id))
      Repo.delete_all(from(user in User, where: user.id == ^user_id))
    end)

    :ok
  end

  defp user_fixture(prefix) do
    email = "privacy-race-#{prefix}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.get_or_create_user_by_email(email)
    user
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
