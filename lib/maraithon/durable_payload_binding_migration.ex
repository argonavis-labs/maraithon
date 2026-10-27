defmodule Maraithon.DurablePayloadBindingMigration do
  @moduledoc """
  Bounded all-registry migration from missing or legacy collapsed binding
  contexts to typed contextual bindings.

  Source rows are selected only from the closed durable registry and locked
  with `FOR UPDATE SKIP LOCKED`. Missing metadata is hydrated from authenticated
  bounded ciphertext. Existing typed bindings are never rewritten; a legacy
  MAC must verify with its persisted key tag before replacement.
  """

  alias Maraithon.DurablePayloadBindingLifecycle, as: Lifecycle
  alias Maraithon.DurablePayloadContraction
  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.Repo

  @default_limit 25
  @max_limit 100
  @default_max_batches 20
  @max_batches 1_000

  @doc "Returns content-free missing/incomplete metadata counts for all 18 sources."
  def preflight do
    targets =
      Enum.map(Lifecycle.targets(), fn target ->
        %{rows: [[missing, incomplete, purged_invalid]]} =
          Repo.query!(
            """
            SELECT
              COUNT(*) FILTER (
                WHERE source.#{target.purge} IS NULL
                  AND source.#{target.binding_version_column} IS NULL
                  AND source.#{target.binding_key_tag_column} IS NULL
                  AND source.#{target.binding_mac_column} IS NULL
              ),
              COUNT(*) FILTER (
                WHERE source.#{target.purge} IS NULL
                  AND NOT (
                    (source.#{target.binding_version_column} IS NULL
                     AND source.#{target.binding_key_tag_column} IS NULL
                     AND source.#{target.binding_mac_column} IS NULL) OR
                    (source.#{target.binding_version_column} = 1
                     AND source.#{target.binding_key_tag_column} IS NOT NULL
                     AND octet_length(source.#{target.binding_mac_column}) = 32)
                  )
              ),
              COUNT(*) FILTER (
                WHERE source.#{target.purge} IS NOT NULL
                  AND NOT (
                    source.#{target.binding_version_column} IS NULL
                    AND source.#{target.binding_key_tag_column} IS NULL
                    AND source.#{target.binding_mac_column} IS NULL
                  )
              )
            FROM public.#{target.table} AS source
            """,
            [],
            log: false
          )

        %{
          table: target.table,
          binding: target.binding_name,
          missing: missing,
          incomplete: incomplete,
          purged_invalid: purged_invalid
        }
      end)

    {:ok,
     %{
       registry_sources: length(DurablePayloadRegistry.tables()),
       binding_targets: length(targets),
       missing: Enum.sum(Enum.map(targets, & &1.missing)),
       incomplete: Enum.sum(Enum.map(targets, & &1.incomplete)),
       purged_invalid: Enum.sum(Enum.map(targets, & &1.purged_invalid)),
       targets: targets
     }}
  rescue
    _error -> {:error, :binding_migration_preflight_failed}
  catch
    :exit, _reason -> {:error, :binding_migration_preflight_failed}
  end

  @doc "Migrates one fixed, bounded binding target behind stopped-fleet evidence."
  def rebind_batch(table, binding_name \\ "payload", opts \\ [])

  def rebind_batch(table, binding_name, opts)
      when is_binary(table) and binding_name in ["payload", "authority"] and is_list(opts) do
    with {:ok, target} <- fetch_target(table, binding_name),
         {:ok, config} <- options(opts),
         {:ok, evidence} <- Lifecycle.validate_evidence(opts) do
      contraction_opts =
        Keyword.take(opts, [
          :confirmation,
          :evidence_id,
          :evidence_digest,
          :operator,
          :revision
        ])

      DurablePayloadContraction.transaction(contraction_opts, fn ->
        Lifecycle.run_target_batch(target, :rebind, config.limit, evidence)
      end)
    end
  end

  def rebind_batch(_table, _binding_name, _opts),
    do: {:error, :invalid_binding_migration_options}

  @doc "Runs a bounded number of all-registry rounds with durable digest progress."
  def rebind(opts \\ [])

  def rebind(opts) when is_list(opts) do
    with {:ok, config} <- options(opts),
         {:ok, _evidence} <- Lifecycle.validate_evidence(opts),
         {:ok, targets} <- selected_targets(opts) do
      run_rounds(targets, opts, config, config.max_batches, %{
        batches: 0,
        migrated: 0,
        already_current: 0,
        failures: []
      })
    end
  end

  def rebind(_opts), do: {:error, :invalid_binding_migration_options}

  defp run_rounds(_targets, _opts, _config, 0, state), do: {:ok, state}

  defp run_rounds(targets, opts, config, remaining, state) do
    result =
      Enum.reduce_while(targets, {:ok, state, 0}, fn target, {:ok, acc, progressed} ->
        case rebind_batch(
               target.table,
               target.binding_name,
               Keyword.put(opts, :limit, config.limit)
             ) do
          {:ok, batch} ->
            batch_progress = batch.migrated + batch.already_current + length(batch.failures)

            next = %{
              batches: acc.batches + 1,
              migrated: acc.migrated + batch.migrated,
              already_current: acc.already_current + batch.already_current,
              failures: acc.failures ++ batch.failures
            }

            {:cont, {:ok, next, progressed + batch_progress}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)

    case result do
      {:ok, next, 0} -> {:ok, next}
      {:ok, next, _progressed} -> run_rounds(targets, opts, config, remaining - 1, next)
      {:error, _reason} = error -> error
    end
  end

  defp options(opts) do
    allowed = [
      :limit,
      :max_batches,
      :table,
      :binding,
      :confirmation,
      :evidence_id,
      :evidence_digest,
      :operator,
      :revision
    ]

    limit = Keyword.get(opts, :limit, @default_limit)
    max_batches = Keyword.get(opts, :max_batches, @default_max_batches)

    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)) and
         is_integer(limit) and limit in 1..@max_limit and is_integer(max_batches) and
         max_batches in 1..@max_batches do
      {:ok, %{limit: limit, max_batches: max_batches}}
    else
      {:error, :invalid_binding_migration_options}
    end
  end

  defp selected_targets(opts) do
    case {Keyword.get(opts, :table), Keyword.get(opts, :binding, "payload")} do
      {nil, "payload"} ->
        {:ok, Lifecycle.targets()}

      {table, binding} when is_binary(table) and binding in ["payload", "authority"] ->
        case fetch_target(table, binding) do
          {:ok, target} -> {:ok, [target]}
          {:error, _reason} = error -> error
        end

      _invalid ->
        {:error, :invalid_binding_migration_target}
    end
  end

  defp fetch_target(table, binding_name) do
    case DurablePayloadRegistry.fetch_binding_target(table, binding_name) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :invalid_binding_migration_target}
    end
  end
end
