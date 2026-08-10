defmodule Maraithon.Runtime.EffectGenerationFenceTest do
  use Maraithon.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Maraithon.Accounts
  alias Maraithon.AgentIsolation
  alias Maraithon.AgentIsolation.Binding
  alias Maraithon.Agents
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Effects
  alias Maraithon.Effects.Cancellation
  alias Maraithon.Effects.CancellationPlan
  alias Maraithon.Effects.Effect
  alias Maraithon.Effects.ProtocolCutover
  alias Maraithon.Effects.TerminalEnvelope
  alias Maraithon.Effects.TerminationAttestations
  alias Maraithon.Runtime.Agent, as: RuntimeAgent
  alias Maraithon.Runtime.AgentDirective
  alias Maraithon.Runtime.AgentDirectives
  alias Maraithon.Runtime.AgentLifecycleOperations
  alias Maraithon.Runtime.AgentLeases
  alias Maraithon.Runtime.AgentRestartGuards
  alias Maraithon.Runtime.BootGate
  alias Maraithon.Runtime.DatabaseClock
  alias Maraithon.Runtime.EffectClaimRenewer
  alias Maraithon.Runtime.EffectRunner
  alias Maraithon.Runtime.EffectTaskAuthority
  alias Maraithon.Runtime.Effects.LLMRateLimiter

  defmodule BlockingProvider do
    @moduledoc false

    def complete(params) do
      test_pid = Application.fetch_env!(:maraithon, :generation_fence_test_pid)
      send(test_pid, {:exact_provider_entered, self(), params})

      receive do
        :release ->
          {:ok,
           %{
             content: "released",
             model: "blocking-v1",
             tokens_in: 1,
             tokens_out: 1,
             finish_reason: "stop",
             usage: %{}
           }}
      after
        10_000 -> {:error, :provider_timeout}
      end
    end
  end

  setup do
    assert ProtocolCutover.mode() == :legacy
    :ok
  end

  test "public Effect changesets cannot mass-assign execution authority" do
    changeset =
      Effect.changeset(%Effect{}, %{
        id: Ecto.UUID.generate(),
        agent_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        effect_type: "tool_call",
        runtime_owner_generation: Ecto.UUID.generate(),
        claim_token: Ecto.UUID.generate(),
        status: "completed",
        cancellation_state: "settled",
        result_envelope: %{"status" => "ok"}
      })

    refute Map.has_key?(changeset.changes, :runtime_owner_generation)
    refute Map.has_key?(changeset.changes, :claim_token)
    refute Map.has_key?(changeset.changes, :status)
    refute Map.has_key?(changeset.changes, :cancellation_state)
    refute Map.has_key?(changeset.changes, :result_envelope)
  end

  test "claim renewal is a stable no-op with no exact work in legacy mode" do
    renewer = Process.whereis(EffectClaimRenewer)
    assert is_pid(renewer)
    assert {:ok, %{active: 0, lost: 0}} = EffectClaimRenewer.renew_now()
    assert Process.whereis(EffectClaimRenewer) == renewer
  end

  test "legacy payload writers dual-write before irreversible encrypted contraction" do
    agent = legacy_agent("durable-payload-encryption")
    sentinel = "payload-sentinel-#{System.unique_integer([:positive])}"

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{"secret" => sentinel})

    effect = Repo.get!(Effect, effect_id)
    assert get_in(effect.params, ["args", "secret"]) == sentinel
    assert get_in(effect.legacy_params, ["args", "secret"]) == sentinel
    assert effect.payload_encryption_version == 1

    assert %{rows: [[legacy_effect_params, 0]]} =
             SQL.query!(
               Repo,
               """
               SELECT params,
                      position(convert_to($2, 'UTF8') in params_ciphertext)
               FROM public.effects
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(effect_id), sentinel]
             )

    assert get_in(legacy_effect_params, ["args", "secret"]) == sentinel

    assert {:ok, directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => sentinel},
               "payload-encryption-#{System.unique_integer([:positive])}"
             )

    stored_directive = Repo.get!(AgentDirective, directive.id)
    assert stored_directive.payload == %{"body" => sentinel}
    assert stored_directive.legacy_payload == %{"body" => sentinel}
    assert stored_directive.payload_encryption_version == 1

    assert %{rows: [[%{"body" => ^sentinel}, 0]]} =
             SQL.query!(
               Repo,
               """
               SELECT payload,
                      position(convert_to($2, 'UTF8') in payload_ciphertext)
               FROM public.agent_directives
               WHERE id = $1::uuid
               """,
               [Ecto.UUID.dump!(directive.id), sentinel]
             )

    assert {:ok, 1} = Effects.backfill_legacy_payload_encryption()
    assert {:ok, 1} = AgentDirectives.backfill_legacy_payload_encryption()

    assert Repo.get!(Effect, effect_id).params == effect.params
    assert Repo.get!(AgentDirective, directive.id).payload == stored_directive.payload

    assert %{rows: [[%{"redacted" => true}, %{"redacted" => true}]]} =
             SQL.query!(
               Repo,
               """
               SELECT
                 (SELECT params FROM public.effects WHERE id = $1::uuid),
                 (SELECT payload FROM public.agent_directives WHERE id = $2::uuid)
               """,
               [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(directive.id)]
             )
  end

  test "an unactivated exact Agent incarnation expires its spawn-monitor window" do
    agent = legacy_agent("exact-activation-watchdog")

    assert {:ok, pid} =
             RuntimeAgent.start_link(%{
               agent: agent,
               owner_token: Ecto.UUID.generate(),
               guard_generation: nil,
               lease_ttl_ms: 1_000,
               lease_renew_interval_ms: 1
             })

    Process.unlink(pid)
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, :exact_activation_timeout}, 1_500
  end

  test "structural index attestation accepts equivalent catalogs and rejects drift" do
    expiry_name = "effects_exact_claim_expiry_index"
    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects USING btree (
        claim_expires_at ASC NULLS LAST,
        id ASC NULLS LAST
      )
      WHERE (((status)::text = ('claimed')::text) AND
             runtime_owner_generation IS NOT NULL AND claim_token IS NOT NULL)
      """,
      []
    )

    assert %{rows: [[true]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [expiry_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects (id, claim_expires_at)
      WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL AND
            claim_token IS NOT NULL
      """,
      []
    )

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [expiry_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects (claim_expires_at DESC, id)
      WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL AND
            claim_token IS NOT NULL
      """,
      []
    )

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [expiry_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects (claim_expires_at, id)
      WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL
      """,
      []
    )

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [expiry_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects (claim_expires_at, id)
      WHERE status = 'CLAIMED' AND runtime_owner_generation IS NOT NULL AND
            claim_token IS NOT NULL
      """,
      []
    )

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [expiry_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{expiry_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE INDEX #{expiry_name}
      ON public.effects (claim_expires_at, id)
      WHERE status = 'claimed' AND runtime_owner_generation IS NOT NULL AND
            claim_token IS NOT NULL
      """,
      []
    )

    physical_name = "effects_physical_task_identity_unique_index"
    SQL.query!(Repo, "DROP INDEX public.#{physical_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX #{physical_name}
      ON public.effects (claim_owner_node text_pattern_ops, claim_supervisor_id, claim_task_id)
      WHERE claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL
      """,
      []
    )

    assert %{rows: [[false]]} =
             SQL.query!(
               Repo,
               "SELECT public.generation_fenced_effect_index_matches($1)",
               [physical_name]
             )

    SQL.query!(Repo, "DROP INDEX public.#{physical_name}", [])

    SQL.query!(
      Repo,
      """
      CREATE UNIQUE INDEX #{physical_name}
      ON public.effects (claim_owner_node, claim_supervisor_id, claim_task_id)
      WHERE claim_supervisor_id IS NOT NULL AND claim_task_id IS NOT NULL
      """,
      []
    )
  end

  test "activation lock contention fails closed and remains retryable" do
    parent = self()

    {blocker, blocker_ref} =
      spawn_monitor(fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            SQL.query!(Repo, "LOCK TABLE public.effects IN ROW EXCLUSIVE MODE", [])
            send(parent, :effect_activation_lock_held)

            receive do
              :release_effect_activation_lock -> :ok
            end
          end)
        end)
      end)

    assert_receive :effect_activation_lock_held, 2_000

    assert {:error, :effect_protocol_lock_timeout} =
             ProtocolCutover.activate(
               confirmation: ProtocolCutover.activation_confirmation(),
               lock_timeout_ms: 100
             )

    assert ProtocolCutover.mode() == :legacy
    send(blocker, :release_effect_activation_lock)
    assert_receive {:DOWN, ^blocker_ref, :process, ^blocker, :normal}, 2_000
  end

  test "direct SQL activation refuses a missing required migration record" do
    SQL.query!(
      Repo,
      "DELETE FROM public.schema_migrations WHERE version = 20260810132102",
      []
    )

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn ->
            SQL.query!(
              Repo,
              "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
              []
            )

            SQL.query!(
              Repo,
              """
              UPDATE public.effect_execution_protocols
              SET mode = 'generation_fenced_v1',
                  activated_at = timezone('UTC', clock_timestamp()),
                  activation_epoch = $1::uuid
              WHERE name = 'effects'
              """,
              [Ecto.UUID.dump!(Ecto.UUID.generate())]
            )
          end,
          mode: :savepoint
        )
      end

    assert Exception.message(error) =~ "requires both recorded exact migrations"

    SQL.query!(
      Repo,
      """
      INSERT INTO public.schema_migrations(version, inserted_at)
      VALUES (20260810132102, timezone('UTC', clock_timestamp()))
      ON CONFLICT (version) DO NOTHING
      """,
      []
    )
  end

  test "activation attests constraint definitions and trigger function source" do
    assert {:ok, :activated} = activate_exact()

    assert {:error, :constraint_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(
                   Repo,
                   "ALTER TABLE public.effects DROP CONSTRAINT effects_execution_status_check",
                   []
                 )

                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.effects
                   ADD CONSTRAINT effects_execution_status_check CHECK (TRUE)
                   """,
                   []
                 )

                 assert {:blocked, {:effect_protocol_constraints_not_ready, 6}} =
                          ProtocolCutover.mode()

                 Repo.rollback(:constraint_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:error, :function_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(
                   Repo,
                   """
                   CREATE OR REPLACE FUNCTION public.enforce_effect_execution_protocol()
                   RETURNS trigger
                   LANGUAGE plpgsql
                   SET search_path = pg_catalog, public
                   AS $function$
                   BEGIN
                     IF TG_OP = 'DELETE' THEN
                       RETURN OLD;
                     END IF;

                     RETURN NEW;
                   END;
                   $function$;
                   """,
                   []
                 )

                 assert {:blocked, {:effect_protocol_triggers_not_ready, 8}} =
                          ProtocolCutover.mode()

                 Repo.rollback(:function_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:error, :catalog_helper_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(
                   Repo,
                   """
                   CREATE OR REPLACE FUNCTION public.generation_fenced_effect_indexes_ready_count()
                   RETURNS bigint
                   LANGUAGE sql
                   STABLE
                   SET search_path = pg_catalog, public
                   AS $function$ SELECT 5::bigint $function$;
                   """,
                   []
                 )

                 assert {:blocked, {:effect_protocol_catalog_helpers_not_ready, 1}} =
                          ProtocolCutover.mode()

                 Repo.rollback(:catalog_helper_drift_probe)
               end,
               mode: :savepoint
             )

    assert {:error, :manifest_guard_drift_probe} =
             Repo.transaction(
               fn ->
                 SQL.query!(
                   Repo,
                   """
                   ALTER TABLE public.effect_execution_protocol_manifests
                   DISABLE TRIGGER reject_effect_protocol_manifest_mutation_trigger
                   """,
                   []
                 )

                 assert {:blocked, {:effect_protocol_triggers_not_ready, 8}} =
                          ProtocolCutover.mode()

                 Repo.rollback(:manifest_guard_drift_probe)
               end,
               mode: :savepoint
             )

    assert :ok = ProtocolCutover.activation_preconditions()
  end

  test "activation refuses unresolved durable Agent run and step rows" do
    agent = legacy_agent("effect-cutover-work-graph")
    now = DateTime.utc_now()

    run =
      %AgentRun{}
      |> AgentRun.changeset(%{
        agent_id: agent.id,
        user_id: agent.user_id,
        behavior: agent.behavior,
        status: "running",
        trigger_type: "manual",
        started_at: now
      })
      |> Repo.insert!()

    step =
      %AgentRunStep{}
      |> AgentRunStep.changeset(%{
        agent_run_id: run.id,
        agent_id: agent.id,
        sequence: 1,
        step_type: "tool",
        status: "requested",
        started_at: now
      })
      |> Repo.insert!()

    assert {:error, {:durable_agent_work_requires_drain, 0, 1, 1}} = activate_exact()

    assert_raise Postgrex.Error, ~r/requires drained durable Agent work/, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
            []
          )

          SQL.query!(
            Repo,
            """
            UPDATE public.effect_execution_protocols
            SET mode = 'generation_fenced_v1',
                activated_at = timezone('UTC', clock_timestamp()),
                activation_epoch = gen_random_uuid(),
                updated_at = timezone('UTC', clock_timestamp())
            WHERE name = 'effects'
            """,
            []
          )
        end,
        mode: :savepoint
      )
    end

    step
    |> AgentRunStep.changeset(%{
      status: "failed",
      error: "cutover_drained",
      completed_at: now
    })
    |> Repo.update!()

    run
    |> AgentRun.changeset(%{status: "completed", completed_at: now})
    |> Repo.update!()

    assert {:ok, :activated} = activate_exact()
  end

  test "exact activation rejects unmarked Directive writers" do
    agent = legacy_agent("directive-protocol-writer-fence")

    assert {:ok, directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => "encrypted"},
               "directive-writer-fence"
             )

    assert {:ok, 1} = AgentDirectives.backfill_legacy_payload_encryption()
    assert {:ok, :activated} = activate_exact()

    assert_raise Postgrex.Error,
                 ~r/requires generation-fenced writer marker/,
                 fn ->
                   Repo.transaction(
                     fn ->
                       SQL.query!(
                         Repo,
                         "UPDATE public.agent_directives SET attempts = attempts WHERE id = $1::uuid",
                         [Ecto.UUID.dump!(directive.id)]
                       )
                     end,
                     mode: :savepoint
                   )
                 end
  end

  test "activation is DB-owned, refuses undrained legacy work, and cannot downgrade" do
    SQL.query!(Repo, "CREATE TEMP TABLE effect_execution_protocols (name text, mode text)", [])

    SQL.query!(
      Repo,
      "INSERT INTO pg_temp.effect_execution_protocols VALUES ('effects', 'generation_fenced_v1')",
      []
    )

    SQL.query!(Repo, "SET LOCAL search_path = pg_temp, public", [])
    assert ProtocolCutover.mode() == :legacy
    SQL.query!(Repo, "SET LOCAL search_path = public", [])

    agent = legacy_agent("effect-cutover")
    owner_generation = Ecto.UUID.generate()

    assert {:error, :durable_effect_cancellation_disabled} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    assert {:ok, effect_id} = Effects.request(agent.id, :tool_call, "time", %{})

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "SELECT set_config('maraithon.effect_protocol_activation', 'generation_fenced_v1', true)",
            []
          )

          SQL.query!(
            Repo,
            """
            UPDATE public.effect_execution_protocols
            SET mode = 'generation_fenced_v1',
                activated_at = timezone('UTC', clock_timestamp()),
                activation_epoch = $1::uuid
            WHERE name = 'effects'
            """,
            [Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert {:error, {:legacy_effects_require_drain, 1, 0}} = activate_exact()

    now = DateTime.utc_now()

    Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
      set: [
        status: "completed",
        result: %{"ok" => true},
        result_envelope: TerminalEnvelope.success(),
        updated_at: now
      ]
    )

    assert {:error, {:legacy_effects_require_drain, 0, 1}} = activate_exact()

    Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
      set: [result_acknowledged_at: now, updated_at: now]
    )

    assert {:ok, 1} = Effects.backfill_legacy_payload_encryption()
    assert {:ok, :activated} = activate_exact()
    assert ProtocolCutover.mode() == :exact
    assert {:ok, :already_active} = activate_exact()

    assert {:error, :safe_legacy_delete_probe} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               assert {1, nil} =
                        Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))

               Repo.rollback(:safe_legacy_delete_probe)
             end)

    assert Repo.get!(Effect, effect_id).runtime_owner_generation == nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "UPDATE public.effect_execution_protocols SET mode = 'legacy' WHERE name = 'effects'",
            []
          )
        end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn -> SQL.query!(Repo, "TRUNCATE public.effect_execution_protocols", []) end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn -> SQL.query!(Repo, "TRUNCATE public.effects", []) end,
        mode: :savepoint
      )
    end

    assert ProtocolCutover.mode() == :exact

    SQL.query!(Repo, "DROP INDEX public.effects_exact_pending_claim_index", [])

    assert {:blocked, {:effect_protocol_indexes_not_ready, 5}} = ProtocolCutover.mode()

    assert {:error, {:effect_protocol_mismatch, {:effect_protocol_indexes_not_ready, 5}}} =
             ProtocolCutover.activation_preconditions()

    assert {:error, {:effect_protocol_indexes_not_ready, 5}} =
             ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())

    SQL.query!(
      Repo,
      """
      CREATE INDEX effects_exact_pending_claim_index
        ON public.effects (retry_after NULLS FIRST, inserted_at, id)
        WHERE status = 'pending' AND runtime_owner_generation IS NOT NULL
      """,
      []
    )

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )

    assert {:blocked, {:effect_protocol_triggers_not_ready, 8}} = ProtocolCutover.mode()

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects DROP CONSTRAINT effects_execution_status_check",
      []
    )

    SQL.query!(
      Repo,
      """
      ALTER TABLE public.effects
      ADD CONSTRAINT effects_execution_status_check
      CHECK (status IN ('pending', 'claimed', 'cancelling', 'completed', 'failed', 'cancelled'))
      NOT VALID
      """,
      []
    )

    assert {:blocked, {:effect_protocol_constraints_not_ready, 6}} = ProtocolCutover.mode()

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects VALIDATE CONSTRAINT effects_execution_status_check",
      []
    )

    assert :ok = ProtocolCutover.activation_preconditions()

    assert {:ok, :already_active} =
             ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())
  end

  test "exact admission requires the current ready Agent generation and old SQL cannot claim it" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-admission")

    assert {:error, :effect_runtime_owner_generation_required} =
             Effects.request(agent.id, :tool_call, "time", %{})

    assert {:error, _reason} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: Ecto.UUID.generate()
             )

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    effect = Repo.get!(Effect, effect_id)
    assert effect.status == "pending"
    assert effect.runtime_owner_generation == owner_generation
    assert is_nil(effect.claim_token)

    # SQL sandbox wraps the test in one transaction, so clear the transaction-
    # local marker installed by nested exact admission before proving that an
    # unmarked writer is rejected.
    SQL.query!(Repo, "SELECT set_config('maraithon.effect_writer_protocol', '', true)", [])

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          now = DatabaseClock.now!()

          %Effect{}
          |> Effect.protocol_changeset(%{
            id: Ecto.UUID.generate(),
            agent_id: agent.id,
            owner_user_id: agent.user_id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "tool_call",
            params: %{"__maraithon_effect_protocol" => 2},
            status: "claimed",
            runtime_owner_generation: owner_generation,
            claim_token: Ecto.UUID.generate(),
            claim_owner_node: Atom.to_string(node()),
            claim_heartbeat_at: now,
            claim_expires_at: DateTime.add(now, 60, :second),
            claim_supervisor_id: Ecto.UUID.generate(),
            claim_task_id: Ecto.UUID.generate(),
            claimed_by: Atom.to_string(node()),
            claimed_at: now
          })
          |> Repo.insert!()
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            """
            UPDATE effects
            SET status = 'claimed', claimed_by = 'old@node',
                claimed_at = timezone('UTC', clock_timestamp())
            WHERE id = $1::uuid
            """,
            [Ecto.UUID.dump!(effect_id)]
          )
        end,
        mode: :savepoint
      )
    end

    assert Repo.get!(Effect, effect_id).status == "pending"

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "UPDATE effects SET result_dispatch_attempts = 9 WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id)]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(
            Repo,
            "UPDATE effects SET runtime_owner_generation = $2::uuid WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "DELETE FROM effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(effect_id)
          ])
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(Repo, "DELETE FROM effects WHERE id = $1::uuid", [
            Ecto.UUID.dump!(effect_id)
          ])
        end,
        mode: :savepoint
      )
    end

    assert Repo.get!(Effect, effect_id).status == "pending"
  end

  test "stale Agent generation cannot cancel successor-owned work" do
    assert {:ok, :activated} = activate_exact()
    {agent, old_generation} = exact_agent("effect-stale-cancel")

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: old_generation
             )

    assert {:ok, :released} = AgentLeases.release(agent.id, old_generation)
    {:ok, successor} = AgentLeases.claim(agent.id, ttl_ms: 60_000)
    {:ok, _ready} = AgentLeases.mark_ready(agent.id, successor.owner_token)

    assert {:error, :effect_cancellation_owner_generation_lost} =
             EffectRunner.cancel_active_for_agent(agent.id, "stale_cleanup",
               expected_runtime_owner_generation: old_generation
             )

    assert Repo.get!(Effect, effect_id).status == "pending"

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "successor_cleanup",
               expected_runtime_owner_generation: successor.owner_token
             )

    cancelled = Repo.get!(Effect, effect_id)
    assert cancelled.status == "cancelled"
    assert cancelled.runtime_owner_generation == old_generation
  end

  test "pre-command exact CAS installs a fresh writer marker before provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-fresh-entry-marker")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, _effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "fresh marker"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

    # SQL Sandbox can retain SET LOCAL through nested savepoints. Explicitly
    # erase that artifact so provider entry proves the task's final CAS opened
    # its own transaction and installed a new exact-writer marker.
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.effect_writer_protocol', '', true)",
      []
    )

    assert %{rows: [[""]]} =
             SQL.query!(
               Repo,
               "SELECT current_setting('maraithon.effect_writer_protocol', true)",
               []
             )

    send(runner, :poll)
    assert_receive {:exact_provider_entered, worker, _params}, 2_000
    send(worker, :release)
  end

  test "a Binding pause committed during exact launch prevents provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-binding-entry-fence")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{"model" => "blocking-v1", "messages" => []},
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    authority = Process.whereis(EffectTaskAuthority)
    :ok = :sys.suspend(authority)

    on_exit(fn ->
      if Process.alive?(authority) do
        try do
          :sys.resume(authority)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    send(runner, :poll)

    binding = Repo.get_by!(Binding, agent_id: agent.id, user_id: agent.user_id)
    binding |> Ecto.Changeset.change(status: "paused") |> Repo.update!()

    :ok = :sys.resume(authority)
    _ = :sys.get_state(runner)
    refute_receive {:exact_provider_entered, _worker, _params}, 200
    refute Repo.get!(Effect, effect_id).status == "completed"
  end

  test "a lifecycle fence committed during exact launch prevents provider entry" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-lifecycle-entry-fence")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{"model" => "blocking-v1", "messages" => []},
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    authority = Process.whereis(EffectTaskAuthority)
    :ok = :sys.suspend(authority)

    on_exit(fn ->
      if Process.alive?(authority) do
        try do
          :sys.resume(authority)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    send(runner, :poll)

    assert {:ok, _fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :stop,
               %{"reason" => "concurrent_entry_fence"},
               fn _locked -> %{"action" => "stop"} end
             )

    :ok = :sys.resume(authority)
    _ = :sys.get_state(runner)
    refute_receive {:exact_provider_entered, _worker, _params}, 200
    refute Repo.get!(Effect, effect_id).status == "completed"
  end

  test "DB-first cancellation kills the exact physical task before settling ambiguity" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-cancel")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "block"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    assert_receive {:exact_provider_entered, worker, _params}, 2_000
    worker_ref = Process.monitor(worker)

    claimed = Repo.get!(Effect, effect_id)
    assert claimed.status == "claimed"
    assert claimed.claim_token != owner_generation
    assert claimed.claim_owner_node == Atom.to_string(node())
    assert claimed.claim_supervisor_id != nil
    assert claimed.claim_task_id != nil

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)
    :ok = :sys.suspend(runner)

    on_exit(fn ->
      if Process.alive?(runner) do
        try do
          :sys.resume(runner)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    # Claim renewal is an independent supervised heartbeat, not EffectRunner
    # poll progress or a synchronous cancellation RPC side effect.
    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()
    :ok = :sys.resume(runner)
    renewed = Repo.get!(Effect, effect_id)
    assert DateTime.compare(renewed.claim_expires_at, claimed.claim_expires_at) == :gt

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          SQL.query!(
            Repo,
            "UPDATE effects SET claim_task_id = $2::uuid WHERE id = $1::uuid",
            [Ecto.UUID.dump!(effect_id), Ecto.UUID.dump!(Ecto.UUID.generate())]
          )
        end,
        mode: :savepoint
      )
    end

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "agent_stopped",
               expected_runtime_owner_generation: owner_generation
             )

    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.cancellation_target_claim_token == claimed.claim_token
    assert settled.claim_token == claimed.claim_token
    assert settled.result_envelope == TerminalEnvelope.error(:effect_outcome_ambiguous)
    assert settled.cancellation_settled_at != nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
            set: [status: "completed"]
          )
        end,
        mode: :savepoint
      )
    end

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()

          Repo.update_all(from(effect in Effect, where: effect.id == ^effect_id),
            set: [error: "rewritten_terminal_outcome"]
          )
        end,
        mode: :savepoint
      )
    end

    replay = %CancellationPlan{
      agent_id: agent.id,
      user_id: agent.user_id,
      reason: "agent_stopped",
      claims: [
        %{
          effect_id: claimed.id,
          agent_id: agent.id,
          claim_token: claimed.claim_token,
          runtime_owner_generation: claimed.runtime_owner_generation,
          owner_node: claimed.claim_owner_node,
          supervisor_id: claimed.claim_supervisor_id,
          task_id: claimed.claim_task_id
        }
      ],
      pending_cancelled: 0,
      requested: 1,
      more?: false
    }

    assert {:ok, %{duplicate_settlements: 1, unresolved: []}} =
             Effects.finish_cancel_active_for_agent_post_commit(replay)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))
        end,
        mode: :savepoint
      )
    end

    # Exact terminal delivery bookkeeping is a reviewed monotonic exception to
    # immutable terminal provenance: reserve advances attempts/timestamps and
    # acknowledgement may be set once without changing the outcome.
    assert {:ok, true} = Effects.reserve_terminal_result_dispatch(settled)
    reserved = Repo.get!(Effect, effect_id)
    assert reserved.result_dispatch_attempts == 1
    assert reserved.result_dispatched_at != nil
    assert reserved.result_dispatch_after != nil
    assert {:ok, false} = Effects.reserve_terminal_result_dispatch(reserved)

    assert {:ok, 1} = Effects.acknowledge_terminal_result(effect_id, agent.id)
    acknowledged = Repo.get!(Effect, effect_id)
    assert acknowledged.result_acknowledged_at != nil
    assert acknowledged.result_envelope == settled.result_envelope

    assert {:ok, 1} =
             Effects.purge_terminal_payloads(
               DateTime.add(acknowledged.result_acknowledged_at, 1, :second)
             )

    purged = Repo.get!(Effect, effect_id)
    assert purged.payload_purged_at != nil
    assert purged.params == nil
    assert purged.result == nil
    assert purged.result_envelope == settled.result_envelope
    assert purged.result_acknowledged_at == acknowledged.result_acknowledged_at

    assert {:cached_payload_expired, %{status: "failed", result_envelope: result_envelope}} =
             Effects.check_idempotency(purged.idempotency_key)

    assert result_envelope == settled.result_envelope

    assert {:error, :safe_delete_probe} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               assert {1, nil} =
                        Repo.delete_all(from(effect in Effect, where: effect.id == ^effect_id))

               Repo.rollback(:safe_delete_probe)
             end)
  end

  test "heartbeat protocol uncertainty immediately terminates physical exact work" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-heartbeat-uncertainty")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, _effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "heartbeat"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    assert_receive {:exact_provider_entered, worker, _params}, 2_000
    worker_ref = Process.monitor(worker)

    renewer = Process.whereis(EffectClaimRenewer)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), renewer)
    assert {:ok, %{active: 1, lost: 0}} = EffectClaimRenewer.renew_now()

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )

    assert {:error, :effect_claim_heartbeat_failed} = EffectClaimRenewer.renew_now()
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )
  end

  test "cancellation before task activation removes the exact reservation" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-preactivation-cancel")
    now = DatabaseClock.now!()
    effect_id = Ecto.UUID.generate()
    claim_token = Ecto.UUID.generate()

    assert {:ok, identity} =
             Maraithon.Runtime.EffectTaskSupervisor.reserve(
               effect_id,
               agent.id,
               claim_token
             )

    insert_claimed_exact_effect!(
      agent,
      owner_generation,
      claim_token,
      Atom.to_string(node()),
      identity.supervisor_id,
      identity.task_id,
      now,
      effect_id
    )

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "cancel_before_activation",
               expected_runtime_owner_generation: owner_generation
             )

    test_pid = self()

    task =
      Task.Supervisor.async_nolink(Maraithon.Runtime.ExactEffectTaskSupervisor, fn ->
        Maraithon.Runtime.EffectTaskSupervisor.register_current!(identity)
        send(test_pid, :late_effect_task_authorized)
      end)

    assert_receive {:DOWN, ref, :process, _pid, _reason} when ref == task.ref, 2_000
    refute_receive :late_effect_task_authorized, 50

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
  end

  test "a still-running task generation cannot be overwritten by a retry successor" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-running-retry-fence")
    configure_blocking_provider()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "retry fence"}]
               },
               runtime_owner_generation: owner_generation
             )

    pending = Repo.get!(Effect, effect_id)
    stop_existing_runner()
    BootGate.close()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)

    :sys.replace_state(runner, fn state ->
      %{state | running: Map.put(state.running, effect_id, pending)}
    end)

    BootGate.open()
    send(runner, :poll)
    _ = :sys.get_state(runner)

    refute_receive {:exact_provider_entered, _worker, _params}, 100

    unclaimed = Repo.get!(Effect, effect_id)
    assert unclaimed.status == "pending"
    assert unclaimed.claim_token == nil

    :sys.replace_state(runner, fn state ->
      %{state | running: Map.delete(state.running, effect_id)}
    end)
  end

  test "coupled Task.Supervisor restart kills predecessor tasks before absence settlement" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-registry-restart")
    configure_blocking_provider()
    BootGate.open()
    LLMRateLimiter.reset()

    assert {:ok, effect_id} =
             Effects.request(
               agent.id,
               :llm_call,
               nil,
               %{
                 "model" => "blocking-v1",
                 "messages" => [%{"role" => "user", "content" => "block"}]
               },
               runtime_owner_generation: owner_generation
             )

    stop_existing_runner()
    runner = start_supervised!({EffectRunner, []})
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), runner)
    send(runner, :poll)

    assert_receive {:exact_provider_entered, worker, _params}, 2_000
    worker_ref = Process.monitor(worker)
    :ok = :sys.suspend(runner)

    on_exit(fn ->
      if Process.alive?(runner) do
        try do
          :sys.resume(runner)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {:ok, old_identity} = Maraithon.Runtime.EffectTaskSupervisor.identity()
    old_task_supervisor = Process.whereis(Maraithon.Runtime.ExactEffectTaskSupervisor)
    task_supervisor_ref = Process.monitor(old_task_supervisor)
    Process.exit(old_task_supervisor, :kill)

    assert_receive {:DOWN, ^task_supervisor_ref, :process, ^old_task_supervisor, _reason}, 2_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 2_000

    # A synchronous system-state call runs only after the nested one-for-all
    # group has killed predecessor tasks and installed a fresh authority.
    _ = :sys.get_state(Maraithon.Runtime.EffectTaskSupervisor)
    new_task_supervisor = Process.whereis(Maraithon.Runtime.ExactEffectTaskSupervisor)
    refute new_task_supervisor == old_task_supervisor
    assert {:ok, new_identity} = Maraithon.Runtime.EffectTaskSupervisor.identity()
    refute new_identity == old_identity

    assert {:ok, 1} =
             EffectRunner.cancel_active_for_agent(agent.id, "registry_restarted",
               expected_runtime_owner_generation: owner_generation
             )

    settled = Repo.get!(Effect, effect_id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.cancellation_target_claim_token == settled.claim_token

    :ok = :sys.resume(runner)
  end

  test "expired claims are fenced in bounded pages without takeover" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-expired-page")
    expired_heartbeat = DatabaseClock.now!() |> DateTime.add(-120, :second)

    first =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        "expired-owner@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        expired_heartbeat
      )

    second =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        "expired-owner@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        expired_heartbeat
      )

    assert [%CancellationPlan{claims: [%{effect_id: first_page_id}]} = first_plan] =
             Cancellation.fence_expired_claims(1)

    assert first_page_id in [first.id, second.id]
    assert {:pending, %{unresolved: [_unreachable]}} = Cancellation.execute(first_plan)

    assert [%CancellationPlan{claims: [%{effect_id: second_page_id}]} = second_plan] =
             Cancellation.fence_expired_claims(1)

    assert second_page_id in [first.id, second.id]
    refute second_page_id == first_page_id
    assert {:pending, %{unresolved: [_unreachable]}} = Cancellation.execute(second_plan)

    assert Enum.all?([first.id, second.id], fn effect_id ->
             effect = Repo.get!(Effect, effect_id)

             effect.status == "cancelling" and effect.cancellation_state == "requested" and
               is_nil(effect.cancellation_settled_at)
           end)
  end

  test "a tripped restart guard settles pending work from every orphan generation" do
    assert {:ok, :activated} = activate_exact()
    {agent, first_generation} = exact_agent("effect-crash-loop-pending")

    assert {:ok, first_effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: first_generation
             )

    assert {:recorded, first_guard} =
             AgentRestartGuards.record_crash(
               agent.id,
               first_generation,
               :first_simulated_crash,
               max_crashes: 3,
               backoffs_ms: [0]
             )

    refute first_guard.tripped

    assert {:ok, second_lease} =
             AgentLeases.claim_recovery(agent.id, first_guard.generation, ttl_ms: 60_000)

    assert {:ok, _ready_lease} =
             AgentLeases.finish_recovery(
               agent.id,
               second_lease.owner_token,
               first_guard.generation
             )

    assert {:ok, second_effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: second_lease.owner_token
             )

    assert {:recorded, tripped_guard} =
             AgentRestartGuards.record_crash(
               agent.id,
               second_lease.owner_token,
               :second_simulated_crash,
               max_crashes: 2,
               backoffs_ms: [0]
             )

    assert tripped_guard.tripped

    for {effect_id, generation} <- [
          {first_effect_id, first_generation},
          {second_effect_id, second_lease.owner_token}
        ] do
      cancelled = Repo.get!(Effect, effect_id)
      assert cancelled.status == "cancelled"
      assert cancelled.cancellation_state == "settled"
      assert cancelled.error == "agent_crash_loop_tripped"
      assert cancelled.runtime_owner_generation == generation
    end
  end

  test "tripped pending work converges after exact storage readiness is repaired" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-crash-loop-deferred")

    assert {:ok, effect_id} =
             Effects.request(agent.id, :tool_call, "time", %{},
               runtime_owner_generation: owner_generation
             )

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects DISABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )

    assert {:blocked, {:effect_protocol_triggers_not_ready, 8}} = ProtocolCutover.mode()

    assert {:recorded, guard} =
             AgentRestartGuards.record_crash(
               agent.id,
               owner_generation,
               :simulated_storage_drift_crash,
               max_crashes: 1,
               backoffs_ms: [0]
             )

    assert guard.tripped
    assert Repo.get!(Effect, effect_id).status == "pending"

    SQL.query!(
      Repo,
      "ALTER TABLE public.effects ENABLE TRIGGER enforce_effect_execution_protocol_trigger",
      []
    )

    assert {:ok, 1} = AgentRestartGuards.reconcile_tripped_pending(10)
    assert Repo.get!(Effect, effect_id).status == "cancelled"
  end

  test "unreachable physical ownership remains durably cancelling" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-unreachable")
    now = DatabaseClock.now!()
    claim_token = Ecto.UUID.generate()

    effect =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        claim_token,
        "unreachable@invalid",
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    assert {:error, :effect_task_termination_incomplete} =
             EffectRunner.cancel_active_for_agent(agent.id, "agent_stopped",
               expected_runtime_owner_generation: owner_generation
             )

    cancelling = Repo.get!(Effect, effect.id)
    assert cancelling.status == "cancelling"
    assert cancelling.cancellation_state == "requested"
    assert cancelling.cancellation_target_claim_token == claim_token
    assert cancelling.claim_token == claim_token
    assert cancelling.result_envelope == nil
    assert cancelling.cancellation_settled_at == nil
    assert cancelling.cancellation_last_attempt_at != nil
    assert cancelling.cancellation_last_error != nil

    identity = %{
      effect_id: cancelling.id,
      claim_token: cancelling.claim_token,
      owner_node: cancelling.claim_owner_node,
      supervisor_id: cancelling.claim_supervisor_id,
      task_id: cancelling.claim_task_id
    }

    assert {:error, :effect_termination_confirmation_required} =
             TerminationAttestations.record(
               identity,
               "infra-ticket-1234",
               "operator@example.com",
               "WRONG_CONFIRMATION"
             )

    assert {:ok, attestation} =
             TerminationAttestations.record(
               identity,
               "infra-ticket-1234",
               "operator@example.com",
               TerminationAttestations.confirmation()
             )

    assert attestation.effect_id == cancelling.id
    assert TerminationAttestations.proof?(identity)

    assert {:ok, %{claims_settled: 1, unresolved: []}} =
             Cancellation.reconcile_agent(agent.id, 10)

    settled = Repo.get!(Effect, effect.id)
    assert settled.status == "failed"
    assert settled.cancellation_state == "settled"
    assert settled.result_envelope == TerminalEnvelope.error(:effect_outcome_ambiguous)

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          SQL.query!(
            Repo,
            "DELETE FROM public.effect_termination_attestations WHERE id = $1::uuid",
            [Ecto.UUID.dump!(attestation.id)]
          )
        end,
        mode: :savepoint
      )
    end

    acknowledged_at = DatabaseClock.now!()

    assert {:ok, :deleted} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               {1, _rows} =
                 Repo.update_all(
                   from(stored in Effect, where: stored.id == ^effect.id),
                   set: [result_acknowledged_at: acknowledged_at, updated_at: acknowledged_at]
                 )

               {1, _rows} =
                 Repo.delete_all(from(stored in Effect, where: stored.id == ^effect.id))

               :deleted
             end)

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT COUNT(*) FROM public.effect_termination_attestations WHERE id = $1::uuid",
               [Ecto.UUID.dump!(attestation.id)]
             )
  end

  test "lifecycle recovery cancels pending exact work and closes the work graph atomically" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-lifecycle-convergence")

    assert {:ok, _directive} =
             AgentDirectives.enqueue(
               agent.id,
               agent.user_id,
               "message",
               %{"body" => "crash-boundary"},
               "lifecycle-convergence"
             )

    assert {:ok, directive} =
             AgentDirectives.claim_next(agent.id, agent.user_id, owner_generation)

    assert {:ok, run} =
             Agents.start_exact_runtime_agent_run(agent, owner_generation, %{
               trigger_type: "message",
               trigger: %{"directive_id" => directive.id}
             })

    assert {:ok, step} =
             Agents.record_agent_run_step(run.id, agent.id, %{
               sequence: 1,
               step_type: "effect",
               effect_type: "tool_call",
               status: "requested",
               request_payload: %{"tool" => "time"}
             })

    effect_id = Ecto.UUID.generate()

    assert {:ok, %Effect{id: ^effect_id}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()
               now = DatabaseClock.now!()

               stored_directive =
                 Repo.one!(
                   from(stored in AgentDirective,
                     where: stored.id == ^directive.id,
                     lock: "FOR UPDATE"
                   )
                 )

               assert {:ok, stored_directive} =
                        AgentDirectives.bind_run_locked(stored_directive, run.id, now)

               assert {:ok, _stored_directive, 1} =
                        AgentDirectives.admit_effect_locked(stored_directive, run.id, now)

               %Effect{}
               |> Effect.protocol_changeset(%{
                 id: effect_id,
                 agent_id: agent.id,
                 owner_user_id: agent.user_id,
                 idempotency_key: Ecto.UUID.generate(),
                 effect_type: "tool_call",
                 params: %{
                   "__maraithon_effect_protocol" => 2,
                   "tool" => "time",
                   "args" => %{}
                 },
                 status: "pending",
                 runtime_owner_generation: owner_generation,
                 agent_run_id: run.id,
                 agent_run_step_id: step.id,
                 attempts: 0,
                 max_attempts: 3
               })
               |> Repo.insert!()
             end)

    assert {:ok, fence} =
             AgentLifecycleOperations.begin(
               agent.id,
               :update,
               %{"revision" => "after-crash"},
               fn locked ->
                 %{
                   "action" => "update",
                   "attrs" => %{
                     "behavior" => locked.behavior,
                     "config" => Map.put(locked.config || %{}, "revision", "after-crash")
                   }
                 }
               end
             )

    SQL.query!(
      Repo,
      """
      UPDATE public.agent_runtime_leases
      SET claimed_at = timezone('UTC', clock_timestamp()) - interval '3 minutes',
          renewed_at = timezone('UTC', clock_timestamp()) - interval '2 minutes',
          draining_at = timezone('UTC', clock_timestamp()) - interval '90 seconds',
          lease_until = timezone('UTC', clock_timestamp()) - interval '1 minute',
          updated_at = timezone('UTC', clock_timestamp())
      WHERE agent_id = $1::uuid
      """,
      [Ecto.UUID.dump!(agent.id)]
    )

    assert {:recorded, _guard} =
             AgentRestartGuards.record_expired(agent.id, owner_generation, backoffs_ms: [0])

    assert {:ok, %{status: :reconciliation_pending}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Repo.get!(Effect, effect_id).status == "cancelled"

    assert {:ok, %{status: :finalized, agent: resumed}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert resumed.status == "running"
    assert resumed.active_run_id == nil
    assert resumed.config["revision"] == "after-crash"
    assert Repo.get!(AgentDirective, directive.id).status == "cancelled"
    assert Repo.get!(AgentRun, run.id).status == "cancelled"
    assert Repo.get!(AgentRunStep, step.id).status == "failed"
    assert AgentLifecycleOperations.get(agent.id) == nil
  end

  test "lifecycle delete erases an unacknowledged terminal exact result without false ack" do
    assert {:ok, :activated} = activate_exact()
    {agent, owner_generation} = exact_agent("effect-lifecycle-erasure")
    now = DatabaseClock.now!()

    claimed =
      insert_claimed_exact_effect!(
        agent,
        owner_generation,
        Ecto.UUID.generate(),
        Atom.to_string(node()),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        now
      )

    assert {:ok, {1, nil}} =
             Repo.transaction(fn ->
               ProtocolCutover.require_exact_write!()

               Repo.update_all(
                 from(effect in Effect,
                   where: effect.id == ^claimed.id and effect.status == "claimed"
                 ),
                 set: [
                   status: "completed",
                   result: %{"ok" => true},
                   error: nil,
                   result_envelope: TerminalEnvelope.success(),
                   completion_claimed_by: claimed.claim_owner_node,
                   completion_claimed_at: now,
                   claimed_by: nil,
                   claimed_at: nil,
                   updated_at: now
                 ]
               )
             end)

    terminal = Repo.get!(Effect, claimed.id)
    assert terminal.result_acknowledged_at == nil

    assert_raise Postgrex.Error, fn ->
      Repo.transaction(
        fn ->
          ProtocolCutover.require_exact_write!()
          Repo.delete_all(from(effect in Effect, where: effect.id == ^claimed.id))
        end,
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

    assert {:ok, :released} = AgentLeases.release(agent.id, owner_generation)

    assert {:ok, %{status: :finalized, action: :deleted}} =
             AgentLifecycleOperations.finalize(agent.id, fence.operation_token)

    assert Repo.get(Effect, claimed.id) == nil
    assert Agents.get_agent(agent.id) == nil
  end

  defp insert_claimed_exact_effect!(
         agent,
         owner_generation,
         claim_token,
         owner_node,
         supervisor_id,
         task_id,
         now,
         effect_id \\ Ecto.UUID.generate()
       ) do
    {:ok, effect} =
      Repo.transaction(fn ->
        ProtocolCutover.require_exact_write!()

        pending =
          %Effect{}
          |> Effect.protocol_changeset(%{
            id: effect_id,
            agent_id: agent.id,
            owner_user_id: agent.user_id,
            idempotency_key: Ecto.UUID.generate(),
            effect_type: "tool_call",
            params: %{"__maraithon_effect_protocol" => 2, "tool" => "time", "args" => %{}},
            status: "pending",
            runtime_owner_generation: owner_generation,
            attempts: 0,
            max_attempts: 3
          })
          |> Repo.insert!()

        {1, _rows} =
          Repo.update_all(
            from(effect in Effect,
              where: effect.id == ^pending.id and effect.status == "pending"
            ),
            set: [
              status: "claimed",
              claim_token: claim_token,
              claim_owner_node: owner_node,
              claim_heartbeat_at: now,
              claim_expires_at: DateTime.add(now, 60, :second),
              claim_supervisor_id: supervisor_id,
              claim_task_id: task_id,
              claimed_by: owner_node,
              claimed_at: now,
              updated_at: now
            ]
          )

        Repo.get!(Effect, pending.id)
      end)

    effect
  end

  defp activate_exact do
    ProtocolCutover.activate(confirmation: ProtocolCutover.activation_confirmation())
  end

  defp legacy_agent(name) do
    user_id = "#{name}-#{System.unique_integer([:positive])}@example.com"
    {:ok, _user} = Accounts.get_or_create_user_by_email(user_id)

    {:ok, agent} =
      Agents.create_agent(%{
        user_id: user_id,
        behavior: "prompt_agent",
        status: "running",
        started_at: DateTime.utc_now(),
        config: %{"name" => name, "prompt" => "test", "subscribe" => [], "tools" => []}
      })

    {:ok, _binding} = AgentIsolation.grant_binding_consent(agent, binding_consent(agent))
    agent
  end

  defp exact_agent(name) do
    agent = legacy_agent(name)
    {:ok, claimed} = AgentLeases.claim(agent.id, ttl_ms: 60_000)
    {:ok, _ready} = AgentLeases.mark_ready(agent.id, claimed.owner_token)
    {agent, claimed.owner_token}
  end

  defp configure_blocking_provider do
    original_runtime = Application.get_env(:maraithon, Maraithon.Runtime, [])
    original_test_pid = Application.get_env(:maraithon, :generation_fence_test_pid)

    Application.put_env(
      :maraithon,
      Maraithon.Runtime,
      Keyword.put(original_runtime, :llm_provider, BlockingProvider)
    )

    Application.put_env(:maraithon, :generation_fence_test_pid, self())

    on_exit(fn ->
      Application.put_env(:maraithon, Maraithon.Runtime, original_runtime)

      if is_nil(original_test_pid) do
        Application.delete_env(:maraithon, :generation_fence_test_pid)
      else
        Application.put_env(:maraithon, :generation_fence_test_pid, original_test_pid)
      end

      LLMRateLimiter.reset()
    end)
  end

  defp stop_existing_runner do
    case Process.whereis(EffectRunner) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end
end
