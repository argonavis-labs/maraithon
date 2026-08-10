defmodule Maraithon.Runtime.Coordination.Protocol do
  @moduledoc """
  Database-owned, irreversible activation gate for partition-fenced runtime work.

  A configuration flag is only a capability interlock. PostgreSQL mode and the
  manual stopped-fleet cutover are the authority; a rolling node may never
  promote this protocol.
  """

  alias Ecto.Adapters.SQL
  alias Maraithon.Effects.ProtocolCutover, as: EffectProtocol
  alias Maraithon.Repo

  @name "runtime"
  @dark "dark"
  @active "partition_fenced_v1"
  @confirmation "NON_ROLLING_MULTINODE_FLEET_DRAINED"
  @migration 20_260_810_140_004

  def mode do
    case SQL.query(
           Repo,
           "SELECT mode FROM public.runtime_coordination_protocols WHERE name = $1",
           [@name]
         ) do
      {:ok, %{rows: [[@dark]]}} ->
        :dark

      {:ok, %{rows: [[@active]]}} ->
        if(storage_ready?(), do: :active, else: {:blocked, :storage_not_ready})

      {:ok, %{rows: []}} ->
        {:blocked, :protocol_missing}

      {:ok, _} ->
        {:blocked, :protocol_invalid}

      {:error, _} ->
        {:blocked, :protocol_unavailable}
    end
  rescue
    _ -> {:blocked, :protocol_unavailable}
  catch
    :exit, _ -> {:blocked, :protocol_unavailable}
  end

  def active?, do: mode() == :active
  def activation_confirmation, do: @confirmation

  def activation_epoch do
    case SQL.query(
           Repo,
           "SELECT activation_epoch FROM public.runtime_coordination_protocols WHERE name = $1 AND mode = $2",
           [@name, @active]
         ) do
      {:ok, %{rows: [[epoch]]}} when not is_nil(epoch) -> Ecto.UUID.load(epoch)
      _ -> :error
    end
  end

  def activation_preconditions do
    with :exact <- EffectProtocol.mode(),
         true <- storage_ready?(),
         {:ok, %{rows: [[0, 0, 0, 0, 0, 0]]}} <- SQL.query(Repo, quiescence_sql(), []) do
      :ok
    else
      :legacy ->
        {:error, :exact_effect_protocol_required}

      {:blocked, reason} ->
        {:error, {:effect_protocol_blocked, reason}}

      false ->
        {:error, :runtime_coordination_storage_not_ready}

      {:ok, %{rows: [[leases, jobs, schedules, effects, nodes, tasks]]}} ->
        {:error,
         {:runtime_coordination_requires_drain, leases, jobs, schedules, effects, nodes, tasks}}

      {:error, _} ->
        {:error, :runtime_coordination_protocol_unavailable}

      _ ->
        {:error, :runtime_coordination_preflight_failed}
    end
  end

  def activate(opts \\ []) when is_list(opts) do
    with @confirmation <- Keyword.get(opts, :confirmation),
         {:ok, epoch} <- cast_epoch(Keyword.get(opts, :activation_epoch, Ecto.UUID.generate())),
         {:ok, timeout} <- lock_timeout(Keyword.get(opts, :lock_timeout_ms, 15_000)),
         {:ok, evidence} <- activation_evidence(opts) do
      activate_locked(epoch, timeout, evidence)
    else
      nil -> {:error, :non_rolling_confirmation_required}
      value when value != @confirmation -> {:error, :non_rolling_confirmation_required}
      {:error, _} = error -> error
    end
  end

  def activate(_), do: {:error, :invalid_coordination_activation}

  @doc "One-way stopped-fleet evidence attestation for an already exact Effect cutover."
  def attest_effect_activation_evidence(opts) when is_list(opts) do
    with {:ok, evidence} <- activation_evidence(opts) do
      Repo.transaction(fn ->
        SQL.query!(
          Repo,
          "SELECT set_config('maraithon.effect_activation_evidence', 'ATTEST_STOPPED_FLEET_EVIDENCE', true)",
          []
        )

        case SQL.query!(
               Repo,
               """
               SELECT mode, activation_evidence_id, activation_evidence_digest, activated_by,
                      exact_revision
               FROM public.effect_execution_protocols WHERE name = 'effects' FOR UPDATE
               """,
               []
             ).rows do
          [["generation_fenced_v1", nil, nil, nil, nil]] ->
            %{num_rows: 1} =
              SQL.query!(
                Repo,
                """
                UPDATE public.effect_execution_protocols
                SET activation_evidence_id = $1, activation_evidence_digest = $2,
                    activated_by = $3, exact_revision = $4,
                    updated_at = timezone('UTC', clock_timestamp())
                WHERE name = 'effects' AND mode = 'generation_fenced_v1'
                  AND activation_evidence_digest IS NULL
                """,
                [evidence.id, evidence.digest, evidence.activated_by, evidence.revision]
              )

            :attested

          [["generation_fenced_v1", id, digest, by, revision]]
          when id == evidence.id and digest == evidence.digest and
                 by == evidence.activated_by and revision == evidence.revision ->
            :already_attested

          [["generation_fenced_v1", _, _, _, _]] ->
            Repo.rollback(:effect_activation_evidence_mismatch)

          [[mode, _, _, _, _]] ->
            Repo.rollback({:exact_effect_protocol_required, mode})

          [] ->
            Repo.rollback(:effect_protocol_missing)
        end
      end)
    end
  end

  def attest_effect_activation_evidence(_), do: {:error, :invalid_effect_activation_attestation}

  def locked_active! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "coordination fence requires transaction")

    case SQL.query!(
           Repo,
           "SELECT mode, activation_epoch FROM public.runtime_coordination_protocols WHERE name = $1 FOR SHARE",
           [@name]
         ).rows do
      [[@active, epoch]] when not is_nil(epoch) -> Ecto.UUID.load!(epoch)
      [[mode, _]] -> Repo.rollback({:coordination_protocol_not_active, mode})
      [] -> Repo.rollback(:coordination_protocol_missing)
    end
  end

  defp activate_locked(epoch, timeout, evidence) do
    try do
      Repo.transaction(
        fn ->
          SQL.query!(Repo, "SELECT set_config('lock_timeout', $1, true)", ["#{timeout}ms"])

          [[mode, evidence_id, evidence_digest, activated_by, exact_revision]] =
            SQL.query!(
              Repo,
              """
              SELECT mode, activation_evidence_id, activation_evidence_digest, activated_by,
                     exact_revision
              FROM public.runtime_coordination_protocols WHERE name = $1 FOR UPDATE
              """,
              [@name]
            ).rows

          case mode do
            @active ->
              if {evidence_id, evidence_digest, activated_by, exact_revision} ==
                   {evidence.id, evidence.digest, evidence.activated_by, evidence.revision},
                 do: :already_active,
                 else: Repo.rollback(:runtime_coordination_activation_evidence_mismatch)

            @dark ->
              # These locks serialize against every old admission/claim path. The
              # repeated quiescence check, not operator timing, closes the race.
              Enum.each(
                ~w(agent_runtime_leases agent_directives agent_runs agent_run_steps effects background_jobs scheduled_jobs runtime_node_incarnations runtime_task_assignments),
                fn table ->
                  SQL.query!(Repo, "LOCK TABLE public.#{table} IN SHARE MODE", [])
                end
              )

              case activation_preconditions_locked() do
                :ok -> :ok
                {:error, reason} -> Repo.rollback(reason)
              end

              SQL.query!(
                Repo,
                "SELECT set_config('maraithon.runtime_coordination_activation', 'ACTIVATE_PARTITION_FENCED_V1', true)",
                []
              )

              %{num_rows: 1} =
                SQL.query!(
                  Repo,
                  """
                  UPDATE public.runtime_coordination_protocols
                  SET mode = $2, activation_epoch = $3::uuid,
                      activation_evidence_id = $4, activation_evidence_digest = $5,
                      activated_by = $6, exact_revision = $7,
                      updated_at = timezone('UTC', clock_timestamp())
                  WHERE name = $1 AND mode = 'dark'
                  """,
                  [
                    @name,
                    @active,
                    Ecto.UUID.dump!(epoch),
                    evidence.id,
                    evidence.digest,
                    evidence.activated_by,
                    evidence.revision
                  ]
                )

              :activated

            _ ->
              Repo.rollback(:runtime_coordination_protocol_invalid)
          end
        end,
        timeout: timeout + 60_000
      )
    rescue
      error in Postgrex.Error ->
        if error.postgres && error.postgres[:code] in [:lock_not_available, :query_canceled],
          do: {:error, :runtime_coordination_lock_timeout},
          else: reraise(error, __STACKTRACE__)
    end
  end

  defp activation_preconditions_locked do
    if EffectProtocol.locked_mode!() != :exact do
      {:error, :exact_effect_protocol_required}
    else
      case SQL.query!(Repo, quiescence_sql(), []).rows do
        [[0, 0, 0, 0, 0, 0]] ->
          if(storage_ready?(), do: :ok, else: {:error, :runtime_coordination_storage_not_ready})

        [[a, b, c, d, e, f]] ->
          {:error, {:runtime_coordination_requires_drain, a, b, c, d, e, f}}
      end
    end
  end

  defp quiescence_sql do
    """
    SELECT
      (SELECT count(*) FROM public.agent_runtime_leases),
      (SELECT count(*) FROM public.background_jobs WHERE status = 'running'),
      (SELECT count(*) FROM public.scheduled_jobs WHERE status = 'dispatched'),
      (SELECT count(*) FROM public.effects WHERE status IN ('claimed', 'cancelling')),
      (SELECT count(*) FROM public.runtime_node_incarnations WHERE state <> 'revoked'),
      (SELECT count(*) FROM public.runtime_task_assignments
       WHERE state IN ('reserved', 'running', 'termination_requested', 'termination_proven'))
    """
  end

  defp storage_ready? do
    case SQL.query(
           Repo,
           """
           SELECT
             (SELECT count(*) FROM public.schema_migrations WHERE version = #{@migration}) = 1 AND
             public.runtime_coordination_catalog_ready_count() = 65 AND
             EXISTS (
               SELECT 1
               FROM public.runtime_coordination_protocols AS protocol
               JOIN public.runtime_coordination_manifests AS manifest ON manifest.name = protocol.name
               WHERE protocol.name = 'runtime' AND protocol.manifest_digest = decode(
                 md5(manifest.constraint_fingerprints::text || manifest.function_fingerprints::text ||
                     manifest.trigger_fingerprints::text || manifest.index_fingerprints::text) ||
                 md5('v1:' || manifest.constraint_fingerprints::text ||
                     manifest.function_fingerprints::text || manifest.trigger_fingerprints::text ||
                     manifest.index_fingerprints::text),
                 'hex'
               )
             )
           """,
           []
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp activation_evidence(opts) do
    with {:ok, id} <-
           bounded_string(
             Keyword.get(opts, :evidence_id),
             1,
             256,
             :invalid_activation_evidence_id
           ),
         {:ok, digest} <- digest(Keyword.get(opts, :evidence_digest)),
         {:ok, activated_by} <-
           bounded_string(Keyword.get(opts, :activated_by), 1, 320, :invalid_activation_operator),
         {:ok, revision} <-
           bounded_string(Keyword.get(opts, :exact_revision), 7, 255, :invalid_exact_revision) do
      {:ok, %{id: id, digest: digest, activated_by: activated_by, revision: revision}}
    end
  end

  defp bounded_string(value, min, max, error) when is_binary(value) do
    value = String.trim(value)
    if byte_size(value) in min..max, do: {:ok, value}, else: {:error, error}
  end

  defp bounded_string(_, _, _, error), do: {:error, error}

  defp digest(value) when is_binary(value) do
    case Base.decode16(String.trim(value), case: :mixed) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _ -> {:error, :invalid_activation_evidence_digest}
    end
  end

  defp digest(_), do: {:error, :invalid_activation_evidence_digest}

  defp cast_epoch(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, epoch} -> {:ok, epoch}
      :error -> {:error, :invalid_coordination_activation_epoch}
    end
  end

  defp cast_epoch(_), do: {:error, :invalid_coordination_activation_epoch}

  defp lock_timeout(value) when is_integer(value) and value in 100..300_000, do: {:ok, value}
  defp lock_timeout(_), do: {:error, :invalid_coordination_lock_timeout}
end
