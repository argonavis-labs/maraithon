defmodule Maraithon.DurablePayloadBindingRotation do
  @moduledoc """
  Bounded metadata-only rotation of contextual durable-payload MAC keys.

  Rotation verifies the persisted old-tag MAC over the typed row context before
  signing with the current key. It never decrypts/re-encrypts Vault ciphertext
  and never mutates payload, projection, lifecycle, or authority columns other
  than the selected binding triple.
  """

  alias Maraithon.DurablePayloadBinding
  alias Maraithon.DurablePayloadBindingLifecycle, as: Lifecycle
  alias Maraithon.DurablePayloadRegistry
  alias Maraithon.KeyRetirement
  alias Maraithon.Repo

  @default_limit 25
  @max_limit 100
  @default_max_batches 20
  @max_batches 1_000
  @tag_regex ~r/^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$/

  @doc "Counts one old binding tag across every fixed binding target."
  def preflight(old_tag) do
    with :ok <- validate_tag_shape(old_tag) do
      targets = Lifecycle.old_tag_counts(old_tag)

      {:ok,
       %{
         old_tag: old_tag,
         registry_sources: length(DurablePayloadRegistry.tables()),
         binding_targets: length(targets),
         total: Enum.sum(Enum.map(targets, & &1.old_tag_rows)),
         targets: targets
       }}
    end
  rescue
    _error -> {:error, :binding_old_tag_preflight_failed}
  catch
    :exit, _reason -> {:error, :binding_old_tag_preflight_failed}
  end

  @doc "Rotates one bounded fixed binding target under incident-operator authority."
  def rotate_batch(old_tag, table, binding_name \\ "payload", opts \\ [])

  def rotate_batch(old_tag, table, binding_name, opts)
      when is_binary(table) and binding_name in ["payload", "authority"] and is_list(opts) do
    with :ok <- validate_old_tag(old_tag),
         {:ok, target} <- fetch_target(table, binding_name),
         {:ok, config} <- options(opts),
         {:ok, evidence} <- Lifecycle.validate_evidence(opts) do
      transaction(fn ->
        :ok = Lifecycle.verify_protocol_evidence!(evidence)
        set_rotation_markers!()

        Lifecycle.run_target_batch(
          target,
          :rotate,
          config.limit,
          Map.put(evidence, :old_tag, old_tag)
        )
      end)
    end
  end

  def rotate_batch(_old_tag, _table, _binding_name, _opts),
    do: {:error, :invalid_binding_rotation_options}

  @doc "Runs bounded all-registry rotation rounds with durable digest progress."
  def rotate(old_tag, opts \\ [])

  def rotate(old_tag, opts) when is_list(opts) do
    with :ok <- validate_old_tag(old_tag),
         {:ok, config} <- options(opts),
         {:ok, _evidence} <- Lifecycle.validate_evidence(opts),
         {:ok, targets} <- selected_targets(opts) do
      run_rounds(old_tag, targets, opts, config, config.max_batches, %{
        batches: 0,
        migrated: 0,
        already_current: 0,
        failures: []
      })
    end
  end

  def rotate(_old_tag, _opts), do: {:error, :invalid_binding_rotation_options}

  @doc "Creates the PostgreSQL-clock global live-zero proof required before backup attestation."
  def prove_live_zero(old_tag, opts),
    do: KeyRetirement.prove_live_zero(:binding, old_tag, opts)

  @doc "Attests backup/WAL/PITR/restore evidence bound to an earlier zero proof."
  def attest_backup_evidence(old_tag, opts),
    do: KeyRetirement.attest_backup_evidence(:binding, old_tag, opts)

  @doc "Rechecks global zero and requires fresh backup-aware retirement evidence."
  def retirement_preflight(old_tag, opts \\ []),
    do: KeyRetirement.retirement_preflight(:binding, old_tag, opts)

  defp run_rounds(_old_tag, _targets, _opts, _config, 0, state), do: {:ok, state}

  defp run_rounds(old_tag, targets, opts, config, remaining, state) do
    result =
      Enum.reduce_while(targets, {:ok, state, 0}, fn target, {:ok, acc, progressed} ->
        case rotate_batch(
               old_tag,
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
      {:ok, next, 0} ->
        {:ok, next}

      {:ok, next, _progressed} ->
        run_rounds(old_tag, targets, opts, config, remaining - 1, next)

      {:error, _reason} = error ->
        error
    end
  end

  defp transaction(fun) do
    case Repo.transaction(
           fn ->
             Repo.query!("SET LOCAL ROLE maraithon_incident_operator", [], log: false)

             case Repo.query!("SELECT current_user", [], log: false).rows do
               [["maraithon_incident_operator"]] -> fun.()
               _invalid -> Repo.rollback(:incident_operator_credential_required)
             end
           end,
           timeout: 120_000
         ) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :binding_rotation_failed}
  catch
    :exit, _reason -> {:error, :binding_rotation_failed}
  end

  defp set_rotation_markers! do
    Repo.query!(
      "SELECT set_config('maraithon.binding_key_rotation', 'BINDING_KEY_ROTATION_V1', true)",
      [],
      log: false
    )

    Repo.query!(
      "SELECT set_config('maraithon.effect_writer_protocol', 'generation_fenced_v1', true)",
      [],
      log: false
    )

    :ok
  end

  defp validate_old_tag(old_tag) do
    with :ok <- validate_tag_shape(old_tag) do
      cond do
        old_tag == DurablePayloadBinding.current_key_tag() ->
          {:error, :current_binding_tag_cannot_be_rotated}

        old_tag not in DurablePayloadBinding.configured_key_tags() ->
          {:error, :binding_read_key_unavailable}

        true ->
          :ok
      end
    end
  end

  defp validate_tag_shape(old_tag) when is_binary(old_tag) do
    if old_tag == String.trim(old_tag) and Regex.match?(@tag_regex, old_tag),
      do: :ok,
      else: {:error, :invalid_binding_key_tag}
  end

  defp validate_tag_shape(_old_tag), do: {:error, :invalid_binding_key_tag}

  defp options(opts) do
    allowed = [
      :limit,
      :max_batches,
      :table,
      :binding,
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
      {:error, :invalid_binding_rotation_options}
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
        {:error, :invalid_binding_rotation_target}
    end
  end

  defp fetch_target(table, binding_name) do
    case DurablePayloadRegistry.fetch_binding_target(table, binding_name) do
      {:ok, target} -> {:ok, target}
      :error -> {:error, :invalid_binding_rotation_target}
    end
  end
end
