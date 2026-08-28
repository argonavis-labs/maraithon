defmodule Maraithon.Effects.ProtocolCutover do
  @moduledoc """
  Database-owned, one-way Effect execution protocol cutover.

  `legacy` and `generation_fenced_v1` are mutually exclusive writer modes.
  Reads that cannot prove the singleton mode fail closed; no application flag
  or node-local fallback can activate exact execution. The persisted
  `activation_epoch` is immutable cutover audit identity, not a session secret
  or a substitute for a future protocol-version migration. The trigger owns
  safety invariants, not database-owner authorization: a database owner can
  perform the same safe transition with SQL. Deployments using one owner
  credential therefore rely on operational credential access control for the
  human-authorization boundary; a separate operator role is stronger.
  """

  alias Ecto.Adapters.SQL
  alias Maraithon.Repo
  alias Maraithon.Runtime.Coordination.StorageVerificationCache

  @name "effects"
  @legacy "legacy"
  @exact "generation_fenced_v1"
  @confirmation "NON_ROLLING_FLEET_DRAINED"

  @type mode :: :legacy | :exact | {:blocked, term()}

  @doc "Return the authoritative database mode, failing closed on any read error."
  @spec mode() :: mode()
  def mode do
    case SQL.query(Repo, "SELECT mode FROM public.effect_execution_protocols WHERE name = $1", [
           @name
         ]) do
      {:ok, %{rows: [[@legacy]]}} ->
        :legacy

      {:ok, %{rows: [[@exact]]}} ->
        case ensure_exact_storage_ready() do
          :ok -> :exact
          {:error, reason} -> {:blocked, reason}
        end

      {:ok, %{rows: []}} ->
        {:blocked, :effect_protocol_row_missing}

      {:ok, _unexpected} ->
        {:blocked, :effect_protocol_invalid}

      {:error, _reason} ->
        {:blocked, :effect_protocol_unavailable}
    end
  rescue
    _error -> {:blocked, :effect_protocol_unavailable}
  catch
    :exit, _reason -> {:blocked, :effect_protocol_unavailable}
  end

  @doc false
  def locked_mode! do
    require_transaction!()

    case SQL.query!(
           Repo,
           "SELECT mode FROM public.effect_execution_protocols WHERE name = $1 FOR SHARE",
           [@name]
         ).rows do
      [[@legacy]] ->
        :legacy

      [[@exact]] ->
        :ok = ensure_exact_storage_ready!()
        :exact

      [] ->
        Repo.rollback(:effect_protocol_row_missing)

      _unexpected ->
        Repo.rollback(:effect_protocol_invalid)
    end
  end

  def exact_writes_enabled?, do: mode() == :exact
  def exact_reconciliation_enabled?, do: mode() == :exact
  def enabled?, do: exact_writes_enabled?()

  @doc false
  def require_exact_write! do
    case locked_mode!() do
      :exact -> mark_exact_writer!()
      other -> Repo.rollback(protocol_error(other))
    end
  end

  @doc false
  def require_exact_reconciliation!, do: require_exact_write!()

  @doc false
  def require_legacy_admission! do
    case locked_mode!() do
      :legacy -> :ok
      other -> Repo.rollback(protocol_error(other))
    end
  end

  @doc false
  def require_legacy_mutation!, do: require_legacy_admission!()

  @doc false
  def require_current_mutation! do
    case locked_mode!() do
      :exact -> mark_exact_writer!()
      :legacy -> :ok
      other -> Repo.rollback(protocol_error(other))
    end
  end

  @doc false
  def protocol_error({:blocked, reason}), do: {:effect_protocol_mismatch, reason}
  def protocol_error(mode), do: {:effect_protocol_mismatch, mode}

  @doc """
  Verify the stopped-fleet activation gates without changing protocol mode.

  This is diagnostic only. `activate/1` repeats every check while holding
  `SHARE` locks on `effects` and runtime leases, which is the race-free authority.
  """
  def activation_preconditions do
    case mode() do
      :legacy ->
        with :ok <- ensure_no_runtime_leases(),
             :ok <- ensure_durable_work_graph_drained(),
             :ok <- ensure_legacy_work_drained(),
             :ok <- ensure_effect_payloads_encrypted(),
             :ok <- ensure_directive_payloads_encrypted(),
             :ok <- ensure_durable_payload_proofs(),
             :ok <- ensure_exact_storage_ready_uncached() do
          :ok
        end

      :exact ->
        ensure_exact_storage_ready_uncached()

      {:blocked, _reason} = blocked ->
        {:error, protocol_error(blocked)}

      other ->
        {:error, protocol_error(other)}
    end
  end

  @doc """
  Atomically and irreversibly activate generation-fenced Effect execution.

  The exact confirmation text is intentional: activation is allowed only after
  all legacy runtime revisions and workers have been stopped. Repeated calls
  are idempotent once exact mode is active. There is no downgrade API.
  """
  def activate(opts \\ [])

  def activate(opts) when is_list(opts) do
    StorageVerificationCache.invalidate()

    try do
      do_activate(opts)
    after
      StorageVerificationCache.invalidate()
    end
  end

  def activate(_opts), do: {:error, :invalid_effect_protocol_activation}

  defp do_activate(opts) do
    case Keyword.get(opts, :confirmation) do
      @confirmation ->
        with {:ok, activation_epoch} <- activation_epoch(Keyword.get(opts, :activation_epoch)),
             {:ok, lock_timeout_ms} <- activation_lock_timeout(opts),
             {:ok, evidence} <- activation_evidence(opts) do
          activate_with_locks(activation_epoch, lock_timeout_ms, evidence)
        end

      _invalid_confirmation ->
        {:error, :effect_protocol_non_rolling_confirmation_required}
    end
  end

  def activation_confirmation, do: @confirmation

  defp activate_with_locks(activation_epoch, lock_timeout_ms, evidence) do
    try do
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SET LOCAL ROLE maraithon_activation_operator", [])

          SQL.query!(
            Repo,
            "SELECT set_config('lock_timeout', $1, true)",
            [Integer.to_string(lock_timeout_ms) <> "ms"]
          )

          runtime =
            case SQL.query!(
                   Repo,
                   """
                   SELECT mode, activation_evidence_id, activation_evidence_digest,
                          activated_by, exact_revision
                   FROM public.runtime_coordination_protocols
                   WHERE name = 'runtime'
                   FOR SHARE
                   """,
                   []
                 ).rows do
              [[mode, id, digest, activated_by, revision]]
              when mode in ["dark", "partition_fenced_v1"] ->
                %{
                  mode: mode,
                  id: id,
                  digest: digest,
                  activated_by: activated_by,
                  revision: revision
                }

              [[mode, _, _, _, _]] ->
                Repo.rollback({:runtime_coordination_protocol_invalid, mode})

              [] ->
                Repo.rollback(:runtime_coordination_protocol_missing)
            end

          current = locked_activation_mode!()

          case current do
            @exact ->
              if runtime.mode == "partition_fenced_v1" and
                   {runtime.id, runtime.digest, runtime.revision} !=
                     {evidence.id, evidence.digest, evidence.revision},
                 do: Repo.rollback(:runtime_effect_protocol_evidence_mismatch)

              :ok = ensure_activation_evidence_matches!(evidence)
              if runtime.mode == "partition_fenced_v1", do: ensure_pair_evidence_matches!(runtime)
              :ok = ensure_exact_storage_ready_uncached!()
              :already_active

            @legacy ->
              if runtime.mode != "dark",
                do: Repo.rollback(:effect_activation_requires_dark_runtime)

              :ok = ensure_activation_evidence_matches!(evidence)

              # Consistent order: protocol row, Effect table, lease table.
              # SHARE blocks writers and DDL while preserving read-only
              # observability during a cutover attempt.
              SQL.query!(
                Repo,
                "SELECT public.lock_durable_runtime_activation_sources()",
                []
              )

              :ok = ensure_no_runtime_leases!()
              :ok = ensure_durable_work_graph_drained!()
              :ok = ensure_legacy_work_drained!()
              :ok = ensure_effect_payloads_encrypted!()
              :ok = ensure_directive_payloads_encrypted!()
              :ok = ensure_durable_payload_proofs!()
              :ok = ensure_exact_storage_ready_uncached!()

              SQL.query!(
                Repo,
                "SELECT set_config('maraithon.effect_protocol_activation', $1, true)",
                [@exact]
              )

              %{num_rows: 1} =
                SQL.query!(
                  Repo,
                  """
                  UPDATE public.effect_execution_protocols
                  SET mode = $2, activated_at = timezone('UTC', clock_timestamp()),
                      activation_epoch = $3::uuid,
                      updated_at = timezone('UTC', clock_timestamp())
                  WHERE name = $1 AND mode = 'legacy'
                  """,
                  [@name, @exact, Ecto.UUID.dump!(activation_epoch)]
                )

              :activated

            _unknown ->
              Repo.rollback(:effect_protocol_invalid)
          end
        end,
        timeout: lock_timeout_ms + 60_000
      )
    rescue
      error in Postgrex.Error ->
        if lock_timeout_error?(error) do
          {:error, :effect_protocol_lock_timeout}
        else
          reraise error, __STACKTRACE__
        end
    end
  end

  defp activation_lock_timeout(opts) do
    case Keyword.get(opts, :lock_timeout_ms, 15_000) do
      value when is_integer(value) and value >= 100 and value <= 300_000 -> {:ok, value}
      _invalid -> {:error, :invalid_effect_protocol_lock_timeout}
    end
  end

  defp lock_timeout_error?(%Postgrex.Error{postgres: postgres}) when is_map(postgres) do
    postgres[:code] in [:lock_not_available, :query_canceled] and
      String.contains?(to_string(postgres[:message]), "lock timeout")
  end

  defp lock_timeout_error?(_error), do: false

  defp locked_activation_mode! do
    case SQL.query!(
           Repo,
           "SELECT mode FROM public.effect_execution_protocols WHERE name = $1 FOR UPDATE",
           [@name]
         ).rows do
      [[mode]] -> mode
      [] -> Repo.rollback(:effect_protocol_row_missing)
      _unexpected -> Repo.rollback(:effect_protocol_invalid)
    end
  end

  defp mark_exact_writer! do
    SQL.query!(
      Repo,
      "SELECT set_config('maraithon.effect_writer_protocol', $1, true)",
      [@exact]
    )

    :ok
  end

  defp ensure_effect_payloads_encrypted do
    case SQL.query!(
           Repo,
           """
           SELECT COUNT(*)
           FROM public.effects
           WHERE payload_encryption_version IS DISTINCT FROM 1
              OR (payload_purged_at IS NULL AND params_ciphertext IS NULL)
              OR (payload_purged_at IS NOT NULL AND
                  (params_ciphertext IS NOT NULL OR result_ciphertext IS NOT NULL))
              OR params IS DISTINCT FROM '{"redacted": true}'::jsonb
              OR result IS NOT NULL
           """,
           []
         ).rows do
      [[0]] -> :ok
      [[count]] -> {:error, {:effect_payload_encryption_backfill_required, count}}
    end
  end

  defp ensure_effect_payloads_encrypted! do
    case ensure_effect_payloads_encrypted() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_directive_payloads_encrypted do
    case SQL.query!(
           Repo,
           """
           SELECT COUNT(*)
           FROM public.agent_directives
           WHERE payload_encryption_version IS DISTINCT FROM 1
              OR payload_ciphertext IS NULL
              OR payload IS DISTINCT FROM '{"redacted": true}'::jsonb
           """,
           []
         ).rows do
      [[0]] -> :ok
      [[count]] -> {:error, {:directive_payload_encryption_backfill_required, count}}
    end
  end

  defp ensure_directive_payloads_encrypted! do
    case ensure_directive_payloads_encrypted() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_durable_payload_proofs do
    case SQL.query(Repo, "SELECT public.durable_payload_proof_failures()", [], log: false) do
      {:ok, %{rows: [[0]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:durable_payload_proof_required, count}}
      {:error, _reason} -> {:error, :durable_payload_proof_unavailable}
    end
  end

  defp ensure_durable_payload_proofs! do
    case ensure_durable_payload_proofs() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Bounded positive cache; see StorageVerificationCache. Activation paths
  # call the *_uncached variants directly.
  defp ensure_exact_storage_ready do
    StorageVerificationCache.fetch(
      {__MODULE__, @exact},
      &ensure_exact_storage_ready_uncached/0,
      &(&1 == :ok)
    )
  end

  defp ensure_exact_storage_ready! do
    StorageVerificationCache.fetch(
      {__MODULE__, @exact},
      &ensure_exact_storage_ready_uncached!/0,
      &(&1 == :ok)
    )
  end

  defp ensure_exact_storage_ready_uncached do
    with :ok <- ensure_exact_migrations_recorded(),
         :ok <- ensure_exact_catalog_helpers_ready(),
         :ok <- ensure_payload_roles_ready(),
         :ok <- ensure_exact_indexes_ready(),
         :ok <- ensure_exact_constraints_ready(),
         :ok <- ensure_exact_triggers_ready() do
      :ok
    end
  end

  defp ensure_exact_storage_ready_uncached! do
    :ok = ensure_exact_migrations_recorded!()
    :ok = ensure_exact_catalog_helpers_ready!()
    :ok = ensure_payload_roles_ready!()
    :ok = ensure_exact_indexes_ready!()
    :ok = ensure_exact_constraints_ready!()
    :ok = ensure_exact_triggers_ready!()
  end

  defp ensure_exact_migrations_recorded do
    case SQL.query(
           Repo,
           "SELECT COUNT(*) FROM public.schema_migrations WHERE version IN (20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007, 20260811000420)",
           []
         ) do
      {:ok, %{rows: [[11]]}} -> :ok
      {:ok, _missing} -> {:error, :effect_protocol_migrations_not_recorded}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_exact_migrations_recorded! do
    case SQL.query!(
           Repo,
           "SELECT COUNT(*) FROM public.schema_migrations WHERE version IN (20260810132102, 20260810132103, 20260810140000, 20260810140001, 20260810140002, 20260810140003, 20260810140004, 20260810140005, 20260810140006, 20260810140007, 20260811000420)",
           []
         ).rows do
      [[11]] -> :ok
      _missing -> Repo.rollback(:effect_protocol_migrations_not_recorded)
    end
  end

  defp ensure_exact_catalog_helpers_ready do
    case SQL.query(Repo, exact_catalog_helpers_ready_sql(), []) do
      {:ok, %{rows: [[7]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:effect_protocol_catalog_helpers_not_ready, count}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_exact_catalog_helpers_ready! do
    case SQL.query!(Repo, exact_catalog_helpers_ready_sql(), []).rows do
      [[7]] -> :ok
      [[count]] -> Repo.rollback({:effect_protocol_catalog_helpers_not_ready, count})
    end
  end

  defp exact_catalog_helpers_ready_sql do
    """
    WITH required(
      function_id,
      expected_volatility,
      expected_language,
      expected_security_definer
    ) AS (
      VALUES
        ('public.generation_fenced_effect_index_matches(text)'::regprocedure, 's'::"char", 'sql', false),
        ('public.generation_fenced_effect_indexes_ready_count()'::regprocedure, 's'::"char", 'sql', false),
        ('public.durable_payload_row_identity(text,text)'::regprocedure, 'i'::"char", 'sql', false),
        ('public.durable_payload_digest_part(text,jsonb,text)'::regprocedure, 'i'::"char", 'sql', false),
        ('public.durable_payload_proof_failures()'::regprocedure, 's'::"char", 'plpgsql', false),
        ('public.durable_payload_roles_ready()'::regprocedure, 's'::"char", 'plpgsql', false),
        ('public.delete_durable_payload_verification(text,text)'::regprocedure, 'v'::"char", 'plpgsql', true)
    )
    SELECT COUNT(*)
    FROM required
    JOIN pg_catalog.pg_proc AS function_row
      ON function_row.oid = required.function_id
     AND function_row.provolatile = required.expected_volatility
     AND function_row.prosecdef = required.expected_security_definer
     AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
    JOIN pg_catalog.pg_language AS language_row
      ON language_row.oid = function_row.prolang
     AND language_row.lanname = required.expected_language
    JOIN public.effect_execution_protocol_manifests AS manifest
      ON manifest.name = 'effects'
     AND manifest.function_fingerprints ->> function_row.proname = md5(function_row.prosrc)
    """
  end

  defp ensure_payload_roles_ready do
    case SQL.query(
           Repo,
           "SELECT public.durable_payload_roles_ready() AND " <>
             "public.durable_payload_catalog_ready() AND public.privacy_protocol_catalog_ready()",
           [],
           log: false
         ) do
      {:ok, %{rows: [[true]]}} -> :ok
      {:ok, _not_ready} -> {:error, :durable_payload_verifier_privileges_not_ready}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_payload_roles_ready! do
    case ensure_payload_roles_ready() do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_exact_indexes_ready do
    case SQL.query(Repo, exact_indexes_ready_sql(), []) do
      {:ok, %{rows: [[6]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:effect_protocol_indexes_not_ready, count}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_exact_indexes_ready! do
    case SQL.query!(Repo, exact_indexes_ready_sql(), []).rows do
      [[6]] -> :ok
      [[count]] -> Repo.rollback({:effect_protocol_indexes_not_ready, count})
    end
  end

  defp exact_indexes_ready_sql do
    "SELECT public.generation_fenced_effect_indexes_ready_count()"
  end

  defp ensure_exact_constraints_ready do
    case SQL.query(Repo, exact_constraints_ready_sql(), []) do
      {:ok, %{rows: [[7]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:effect_protocol_constraints_not_ready, count}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_exact_constraints_ready! do
    case SQL.query!(Repo, exact_constraints_ready_sql(), []).rows do
      [[7]] -> :ok
      [[count]] -> Repo.rollback({:effect_protocol_constraints_not_ready, count})
    end
  end

  defp exact_constraints_ready_sql do
    """
    WITH required(relation_id, constraint_name) AS (
      VALUES
        ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_singleton_check'),
        ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_mode_check'),
        ('public.effect_execution_protocols'::regclass, 'effect_execution_protocol_activation_shape_check'),
        ('public.effect_execution_protocol_manifests'::regclass,
         'effect_execution_protocol_manifest_singleton_check'),
        ('public.effect_termination_attestations'::regclass,
         'effect_termination_attestations_shape_check'),
        ('public.effects'::regclass, 'effects_execution_status_check'),
        ('public.effects'::regclass, 'effects_generation_fenced_shape_check')
    )
    SELECT COUNT(*)
    FROM required
    JOIN pg_catalog.pg_constraint AS constraint_row
      ON constraint_row.conrelid = required.relation_id
     AND constraint_row.conname = required.constraint_name
     AND constraint_row.contype = 'c'
     AND constraint_row.convalidated
    JOIN public.effect_execution_protocol_manifests AS manifest
      ON manifest.name = 'effects'
     AND manifest.constraint_fingerprints ->> required.constraint_name =
           md5(pg_catalog.pg_get_constraintdef(constraint_row.oid, true))
    """
  end

  defp ensure_exact_triggers_ready do
    case SQL.query(Repo, exact_triggers_ready_sql(), []) do
      {:ok, %{rows: [[19]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:effect_protocol_triggers_not_ready, count}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_exact_triggers_ready! do
    case SQL.query!(Repo, exact_triggers_ready_sql(), []).rows do
      [[19]] -> :ok
      [[count]] -> Repo.rollback({:effect_protocol_triggers_not_ready, count})
    end
  end

  defp exact_triggers_ready_sql do
    """
    WITH required(trigger_name, relation_id, function_id, trigger_type) AS (
      VALUES
        ('enforce_effect_execution_protocol_trigger', 'public.effects'::regclass,
         'public.enforce_effect_execution_protocol()'::regprocedure, 31),
        ('enforce_agent_directive_protocol_trigger', 'public.agent_directives'::regclass,
         'public.enforce_agent_directive_protocol()'::regprocedure, 31),
        ('enforce_effect_protocol_one_way_trigger', 'public.effect_execution_protocols'::regclass,
         'public.enforce_effect_protocol_one_way()'::regprocedure, 27),
        ('enforce_effect_termination_attestation_trigger',
         'public.effect_termination_attestations'::regclass,
         'public.enforce_effect_termination_attestation()'::regprocedure, 31),
        ('reject_effect_protocol_manifest_mutation_trigger',
         'public.effect_execution_protocol_manifests'::regclass,
         'public.reject_effect_protocol_manifest_mutation()'::regprocedure, 27),
        ('reject_effect_protocol_manifest_truncate_trigger',
         'public.effect_execution_protocol_manifests'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34),
        ('reject_effect_termination_attestations_truncate_trigger',
         'public.effect_termination_attestations'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34),
        ('reject_effect_protocol_truncate_trigger', 'public.effect_execution_protocols'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34),
        ('reject_effects_truncate_trigger', 'public.effects'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34),
        ('guard_durable_payload_verification_write_trigger',
         'public.durable_payload_verifications'::regclass,
         'public.guard_durable_payload_verification_write()'::regprocedure, 23),
        ('guard_durable_payload_verification_failure_write_trigger',
         'public.durable_payload_verification_failures'::regclass,
         'public.guard_durable_payload_verification_failure_write()'::regprocedure, 23),
        ('enforce_durable_history_payload_protocol_trigger', 'public.events'::regclass,
         'public.enforce_durable_history_payload_protocol()'::regprocedure, 31),
        ('enforce_durable_history_payload_protocol_trigger', 'public.agent_run_steps'::regclass,
         'public.enforce_durable_history_payload_protocol()'::regprocedure, 31),
        ('invalidate_durable_payload_verification_trigger', 'public.effects'::regclass,
         'public.invalidate_durable_payload_verification()'::regprocedure, 29),
        ('invalidate_durable_payload_verification_trigger', 'public.agent_directives'::regclass,
         'public.invalidate_durable_payload_verification()'::regprocedure, 29),
        ('invalidate_durable_payload_verification_trigger', 'public.events'::regclass,
         'public.invalidate_durable_payload_verification()'::regprocedure, 29),
        ('invalidate_durable_payload_verification_trigger', 'public.agent_run_steps'::regclass,
         'public.invalidate_durable_payload_verification()'::regprocedure, 29),
        ('reject_durable_payload_verifications_truncate_trigger',
         'public.durable_payload_verifications'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34),
        ('reject_durable_payload_verification_failures_truncate_trigger',
         'public.durable_payload_verification_failures'::regclass,
         'public.reject_durable_effect_truncate()'::regprocedure, 34)
    )
    SELECT COUNT(*)
    FROM required
    JOIN pg_catalog.pg_trigger AS trigger_row
      ON trigger_row.tgrelid = required.relation_id
     AND trigger_row.tgname = required.trigger_name
     AND trigger_row.tgfoid = required.function_id
     AND trigger_row.tgtype = required.trigger_type
     AND NOT trigger_row.tgisinternal
     AND trigger_row.tgenabled IN ('O', 'A')
    JOIN pg_catalog.pg_proc AS function_row
      ON function_row.oid = required.function_id
     AND function_row.provolatile = 'v'
     AND NOT function_row.prosecdef
     AND function_row.proconfig = ARRAY['search_path=pg_catalog, public']::text[]
    JOIN pg_catalog.pg_language AS language_row
      ON language_row.oid = function_row.prolang
     AND language_row.lanname = 'plpgsql'
    JOIN public.effect_execution_protocol_manifests AS manifest
      ON manifest.name = 'effects'
     AND manifest.function_fingerprints ->> function_row.proname = md5(function_row.prosrc)
    """
  end

  defp ensure_no_runtime_leases do
    case SQL.query(Repo, "SELECT COUNT(*) FROM public.agent_runtime_leases", []) do
      {:ok, %{rows: [[0]]}} -> :ok
      {:ok, %{rows: [[count]]}} -> {:error, {:runtime_workers_require_drain, count}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_durable_work_graph_drained do
    case SQL.query(Repo, durable_work_graph_sql(), []) do
      {:ok, %{rows: [[0, 0, 0]]}} ->
        :ok

      {:ok, %{rows: [[directives, runs, steps]]}} ->
        {:error, {:durable_agent_work_requires_drain, directives, runs, steps}}

      {:error, _reason} ->
        {:error, :effect_protocol_unavailable}
    end
  end

  defp ensure_legacy_work_drained do
    case legacy_work_counts() do
      {:ok, {0, 0}} -> :ok
      {:ok, {active, terminal}} -> {:error, {:legacy_effects_require_drain, active, terminal}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_no_runtime_leases! do
    case SQL.query!(Repo, "SELECT COUNT(*) FROM public.agent_runtime_leases", []).rows do
      [[0]] -> :ok
      [[count]] -> Repo.rollback({:runtime_workers_require_drain, count})
    end
  end

  defp ensure_durable_work_graph_drained! do
    case SQL.query!(Repo, durable_work_graph_sql(), []).rows do
      [[0, 0, 0]] ->
        :ok

      [[directives, runs, steps]] ->
        Repo.rollback({:durable_agent_work_requires_drain, directives, runs, steps})
    end
  end

  defp ensure_legacy_work_drained! do
    case legacy_work_counts!() do
      {0, 0} -> :ok
      {active, terminal} -> Repo.rollback({:legacy_effects_require_drain, active, terminal})
    end
  end

  defp legacy_work_counts do
    case SQL.query(Repo, legacy_work_sql(), []) do
      {:ok, %{rows: [[active, terminal]]}} -> {:ok, {active, terminal}}
      {:error, _reason} -> {:error, :effect_protocol_unavailable}
    end
  end

  defp legacy_work_counts! do
    case SQL.query!(Repo, legacy_work_sql(), []).rows do
      [[active, terminal]] -> {active, terminal}
    end
  end

  defp durable_work_graph_sql do
    """
    SELECT
      (SELECT COUNT(*) FROM public.agent_directives WHERE status = 'processing'),
      (SELECT COUNT(*) FROM public.agent_runs WHERE status = 'running'),
      (SELECT COUNT(*) FROM public.agent_run_steps WHERE status = 'requested')
    """
  end

  defp legacy_work_sql do
    """
    SELECT
      COUNT(*) FILTER (
        WHERE runtime_owner_generation IS NULL
          AND NOT ((
            (status = 'cancelled' AND result_envelope IS NULL) OR
            (status IN ('completed', 'failed', 'cancelled') AND
             result_envelope IS NOT NULL AND result_acknowledged_at IS NOT NULL)
          ) IS TRUE)
          AND NOT ((
            status IN ('completed', 'failed', 'cancelled') AND
            result_envelope IS NOT NULL AND result_acknowledged_at IS NULL
          ) IS TRUE)
      ),
      COUNT(*) FILTER (
        WHERE runtime_owner_generation IS NULL
          AND status IN ('completed', 'failed', 'cancelled')
          AND result_envelope IS NOT NULL
          AND result_acknowledged_at IS NULL
      )
    FROM public.effects
    """
  end

  defp activation_evidence(opts) do
    id = Keyword.get(opts, :evidence_id)
    digest = Keyword.get(opts, :evidence_digest)
    revision = Keyword.get(opts, :revision)

    if is_binary(id) and byte_size(id) in 1..128 and
         Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/, id) and
         is_binary(digest) and byte_size(digest) == 32 and
         is_binary(revision) and Regex.match?(~r/^[0-9a-f]{40}([0-9a-f]{24})?$/, revision) do
      {:ok, %{id: id, digest: digest, revision: revision}}
    else
      {:error, :effect_protocol_activation_evidence_required}
    end
  end

  defp ensure_activation_evidence_matches!(evidence) do
    case SQL.query!(
           Repo,
           """
           SELECT activation_evidence_id, activation_evidence_digest, exact_revision
           FROM public.effect_execution_protocols
           WHERE name = $1
           """,
           [@name]
         ).rows do
      [[id, digest, revision]]
      when id == evidence.id and digest == evidence.digest and revision == evidence.revision ->
        :ok

      _mismatch ->
        Repo.rollback(:effect_protocol_activation_evidence_mismatch)
    end
  end

  defp ensure_pair_evidence_matches!(runtime) do
    expected = [runtime.id, runtime.digest, runtime.activated_by, runtime.revision]

    case SQL.query!(
           Repo,
           """
           SELECT activation_evidence_id, activation_evidence_digest, activated_by,
                  exact_revision
           FROM public.effect_execution_protocols
           WHERE name = $1
           """,
           [@name]
         ).rows do
      [^expected] -> :ok
      _mismatch -> Repo.rollback(:runtime_effect_protocol_evidence_mismatch)
    end
  end

  defp activation_epoch(nil), do: {:ok, Ecto.UUID.generate()}

  defp activation_epoch(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_effect_protocol_activation_epoch}
    end
  end

  defp activation_epoch(_value), do: {:error, :invalid_effect_protocol_activation_epoch}

  defp require_transaction! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "Effect protocol lock requires a transaction")
  end
end
