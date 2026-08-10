defmodule Maraithon.Runtime.Snapshot do
  @moduledoc """
  Point-in-time snapshot of an agent's behavior state.

  Written on every checkpoint wakeup and loaded when an agent (re)starts, so a
  restarted agent resumes with its accumulated context instead of a blank
  behavior state. The snapshot is the recovery boundary — events emitted
  between the last checkpoint and a crash are *not* replayed, because replaying
  behavior handlers would re-run their side effects.

  `behavior_state` and `budget` use a bounded, tagged JSON format that preserves
  atoms, tuples, typed map keys, ISO calendar values, and arbitrary bytes
  without storing executable ETF. The closed grammar deliberately rejects
  arbitrary structs, processes, functions, references, and other runtime-only
  terms. A bounded legacy ETF/plain-JSON reader remains temporarily available
  for migration; tagged v1 is the only write format.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Maraithon.DurablePayload
  alias Maraithon.Repo
  alias Maraithon.Runtime.SnapshotFormat

  require Logger

  schema "snapshots" do
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :state_name, :string
    field :state_data, Maraithon.Encrypted.Map, source: :state_data_ciphertext, redact: true
    field :legacy_state_data, :map, source: :state_data, default: %{}, redact: true
    field :budget, Maraithon.Encrypted.Map, source: :budget_ciphertext, redact: true
    field :legacy_budget, :map, source: :budget, default: %{}, redact: true
    field :schema_version, :integer
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(agent_id sequence_num state_name state_data budget schema_version)a

  @doc false
  def payload_binding_spec do
    %{
      table: "snapshots",
      identity_fields: [:id],
      scope_fields: [:agent_id, :sequence_num, :schema_version, :state_name],
      fields: [:state_data, :budget],
      purge_field: :payload_purged_at
    }
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_number(:sequence_num, greater_than_or_equal_to: 0)
    |> validate_number(:schema_version,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 2_147_483_647
    )
    |> check_constraint(:sequence_num, name: :snapshots_nonnegative_sequence)
    |> check_constraint(:schema_version, name: :snapshots_schema_version_range)
    |> check_constraint(:state_data, name: :snapshots_payload_objects)
    |> check_constraint(:state_data, name: :snapshots_payload_storage_bound)
    |> check_constraint(:state_data,
      name: :snapshots_tagged_v1_payloads,
      message: "does not match the tagged snapshot format"
    )
    |> mirror_legacy_payloads()
    |> put_payload_encryption_version()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
  end

  @doc """
  Persist a checkpoint snapshot of an agent's behavior state and budget.

  `schema_version` is the behavior's declared state-contract version at write
  time (SPEC 08 R1/R4); behaviors that don't declare one write `0`.
  """
  @spec persist(binary(), integer(), atom() | String.t(), term(), term(), non_neg_integer()) ::
          {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t() | atom()}
  def persist(agent_id, sequence_num, state_name, behavior_state, budget, schema_version) do
    with {:ok, encoded_state, state_bytes} <- SnapshotFormat.encode(behavior_state),
         {:ok, encoded_budget, budget_bytes} <- SnapshotFormat.encode(budget),
         true <- state_bytes + budget_bytes <= SnapshotFormat.max_encoded_bytes() do
      result =
        Repo.transaction(fn ->
          %{rows: [[snapshot_id]]} =
            Repo.query!(
              "SELECT nextval(pg_get_serial_sequence('public.snapshots', 'id'))",
              [],
              log: false
            )

          changeset =
            changeset(%__MODULE__{id: snapshot_id}, %{
              agent_id: agent_id,
              sequence_num: sequence_num,
              state_name: to_string(state_name),
              state_data: encoded_state,
              budget: encoded_budget,
              schema_version: schema_version
            })

          snapshot =
            case Repo.insert(changeset) do
              {:ok, snapshot} -> snapshot
              {:error, reason} -> Repo.rollback(reason)
            end

          prune_old!(agent_id)
          snapshot
        end)

      case result do
        {:ok, snapshot} ->
          :telemetry.execute(
            [:maraithon, :runtime, :snapshot, :persist],
            %{encoded_bytes: state_bytes + budget_bytes, sequence_num: sequence_num},
            %{format_version: SnapshotFormat.version()}
          )

          {:ok, snapshot}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :snapshot_too_large}
      {:error, _reason} = error -> error
    end
  end

  # Only the latest snapshots are recovery candidates. Retention runs in the
  # same database transaction as insertion so growth remains bounded even when
  # the writer crashes immediately after a checkpoint.
  @keep_snapshots 10

  def retention_count, do: @keep_snapshots

  defp prune_old!(agent_id) do
    stale_ids =
      from(snapshot in __MODULE__,
        where: snapshot.agent_id == ^agent_id,
        order_by: [desc: snapshot.sequence_num, desc: snapshot.id],
        offset: @keep_snapshots,
        select: snapshot.id
      )

    from(snapshot in __MODULE__, where: snapshot.id in subquery(stale_ids))
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Load the most recent snapshot for an agent.

  Returns `%{sequence_num, state_name, behavior_state, budget, schema_version}`
  with the terms decoded back to their original Elixir form, or `nil` when the
  agent has never been checkpointed. `schema_version` is never `nil`: the DB
  default backfills legacy rows to `0`, and this defends against hand-edited
  rows regardless.
  """
  @spec latest(binary()) ::
          %{
            sequence_num: integer(),
            state_name: String.t(),
            behavior_state: term(),
            budget: term(),
            schema_version: non_neg_integer()
          }
          | nil
  def latest(agent_id) do
    from(snapshot in __MODULE__,
      where: snapshot.agent_id == ^agent_id and is_nil(snapshot.payload_purged_at),
      order_by: [desc: snapshot.sequence_num, desc: snapshot.id],
      limit: @keep_snapshots
    )
    |> Repo.all()
    |> Enum.find_value(&decode_snapshot/1)
  end

  @doc """
  Emits bounded-retention health telemetry, including checkpoint age and size.
  """
  def emit_health_telemetry do
    case health_stats() do
      {:ok, stats} ->
        :telemetry.execute(
          [:maraithon, :runtime, :snapshot, :health],
          stats,
          %{format_version: SnapshotFormat.version(), retention_count: @keep_snapshots}
        )

        {:ok, stats}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  def health_stats do
    sql = """
    WITH latest AS (
      SELECT DISTINCT ON (s.agent_id)
        s.agent_id,
        s.inserted_at,
        COALESCE(octet_length(s.state_data_ciphertext), pg_column_size(s.state_data), 0) +
          COALESCE(octet_length(s.budget_ciphertext), pg_column_size(s.budget), 0) AS encoded_bytes
      FROM snapshots AS s
      WHERE s.payload_purged_at IS NULL
      ORDER BY s.agent_id, s.sequence_num DESC, s.id DESC
    ),
    active AS (
      SELECT a.id
      FROM agents AS a
      WHERE a.status IN ('running', 'degraded')
        AND a.install_status = 'enabled'
    )
    SELECT
      (SELECT count(*)::bigint FROM snapshots) AS retained_snapshot_count,
      (SELECT COALESCE(sum(
           COALESCE(octet_length(state_data_ciphertext), pg_column_size(state_data), 0) +
           COALESCE(octet_length(budget_ciphertext), pg_column_size(budget), 0)
         ), 0)::bigint FROM snapshots) AS retained_encoded_bytes,
      count(active.id)::bigint AS active_agent_count,
      count(active.id) FILTER (WHERE latest.agent_id IS NULL)::bigint
        AS active_agents_without_snapshot,
      COALESCE(
        max(
          CASE WHEN latest.inserted_at IS NULL THEN 0
               ELSE GREATEST(
                 0,
                 floor(extract(epoch FROM (clock_timestamp() - latest.inserted_at)) * 1000)
               )
          END
        ),
        0
      )::bigint AS max_checkpoint_age_ms,
      COALESCE(max(latest.encoded_bytes), 0)::bigint AS max_latest_encoded_bytes
    FROM active
    LEFT JOIN latest ON latest.agent_id = active.id
    """

    case Repo.query(sql, [], timeout: 5_000) do
      {:ok, %{rows: [[retained_count, retained_bytes, active_count, missing, age_ms, max_bytes]]}} ->
        {:ok,
         %{
           retained_snapshot_count: retained_count,
           retained_encoded_bytes: retained_bytes,
           active_agent_count: active_count,
           active_agents_without_snapshot: missing,
           max_checkpoint_age_ms: age_ms,
           max_latest_encoded_bytes: max_bytes
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_snapshot(%__MODULE__{payload_purged_at: %DateTime{}}), do: nil

  defp decode_snapshot(%__MODULE__{} = snapshot) do
    snapshot = hydrate_payloads!(snapshot)

    with {:ok, behavior_state} <- unwrap_term(snapshot.state_data),
         {:ok, budget} <- unwrap_term(snapshot.budget) do
      %{
        sequence_num: snapshot.sequence_num,
        state_name: snapshot.state_name,
        behavior_state: behavior_state,
        budget: budget,
        schema_version: snapshot.schema_version || 0
      }
    else
      {:error, reason} ->
        :telemetry.execute(
          [:maraithon, :runtime, :snapshot, :decode_error],
          %{count: 1},
          %{failure_code: Maraithon.Redaction.error_class(reason)}
        )

        Logger.warning("Skipping invalid Agent snapshot during recovery",
          snapshot_id: snapshot.id,
          sequence_num: snapshot.sequence_num,
          failure_code: Maraithon.Redaction.error_class(reason)
        )

        nil
    end
  end

  @doc false
  def hydrate_payloads!(%__MODULE__{} = snapshot, mode \\ DurablePayload.mode!()) do
    :ok = DurablePayload.verify_binding!(snapshot, payload_binding_spec(), mode)

    {state_data, budget} =
      case mode do
        :legacy ->
          {snapshot.state_data || snapshot.legacy_state_data,
           snapshot.budget || snapshot.legacy_budget}

        :exact ->
          if snapshot.payload_encryption_version == 1 and is_map(snapshot.state_data) and
               is_map(snapshot.budget) and snapshot.legacy_state_data == %{} and
               snapshot.legacy_budget == %{} do
            {snapshot.state_data, snapshot.budget}
          else
            raise ArgumentError, "exact Snapshot payload is not ciphertext-only"
          end
      end

    %{snapshot | state_data: state_data, budget: budget}
  end

  defp mirror_legacy_payloads(changeset) do
    if DurablePayload.legacy_write?() do
      changeset
      |> mirror_legacy(:state_data, :legacy_state_data)
      |> mirror_legacy(:budget, :legacy_budget)
    else
      changeset
      |> Ecto.Changeset.put_change(:legacy_state_data, %{})
      |> Ecto.Changeset.put_change(:legacy_budget, %{})
    end
  end

  defp mirror_legacy(changeset, field, legacy_field) do
    case Ecto.Changeset.fetch_change(changeset, field) do
      {:ok, value} -> Ecto.Changeset.put_change(changeset, legacy_field, value)
      :error -> changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :state_data) or Map.has_key?(changeset.changes, :budget),
      do: Ecto.Changeset.put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp unwrap_term(stored) do
    with {:ok, term, _storage_kind} <- SnapshotFormat.decode_stored(stored) do
      {:ok, term}
    end
  end
end
