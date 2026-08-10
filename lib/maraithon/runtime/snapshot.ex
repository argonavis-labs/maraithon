defmodule Maraithon.Runtime.Snapshot do
  @moduledoc """
  Point-in-time snapshot of an agent's behavior state.

  Written on every checkpoint wakeup and loaded when an agent (re)starts, so a
  restarted agent resumes with its accumulated context instead of a blank
  behavior state. The snapshot is the recovery boundary — events emitted
  between the last checkpoint and a crash are *not* replayed, because replaying
  behavior handlers would re-run their side effects.

  `behavior_state` and `budget` use a bounded, tagged JSON format that preserves
  atoms, tuples, arbitrary map keys, structs, and binary values without storing
  executable ETF. Legacy ETF rows remain read-only compatible while fresh
  checkpoints age them out under the bounded retention policy.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Maraithon.Repo
  alias Maraithon.Runtime.SnapshotFormat

  require Logger

  schema "snapshots" do
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :state_name, :string
    field :state_data, :map
    field :budget, :map
    field :schema_version, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w(agent_id sequence_num state_name state_data budget schema_version)a

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
          changeset =
            changeset(%__MODULE__{}, %{
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
      where: snapshot.agent_id == ^agent_id,
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
        pg_column_size(s.state_data) + pg_column_size(s.budget) AS encoded_bytes
      FROM snapshots AS s
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
      (SELECT COALESCE(sum(pg_column_size(state_data) + pg_column_size(budget)), 0)::bigint
         FROM snapshots) AS retained_encoded_bytes,
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

  defp decode_snapshot(%__MODULE__{} = snapshot) do
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

  defp unwrap_term(%{"format" => format} = envelope)
       when format == "maraithon.agent_snapshot" do
    SnapshotFormat.decode(envelope)
  end

  # Read-only compatibility for checkpoints written before format version 1.
  # The old writer never compressed ETF, so compressed payloads are rejected to
  # avoid decompression bombs. Fresh writes can never produce this shape.
  defp unwrap_term(%{"format" => "etf_base64", "data" => data}) when is_binary(data) do
    max_etf_bytes = SnapshotFormat.max_encoded_bytes()
    max_base64_bytes = div((max_etf_bytes + 2) * 4, 3)

    with true <- byte_size(data) <= max_base64_bytes,
         {:ok, binary} <- Base.decode64(data),
         true <- byte_size(binary) <= max_etf_bytes,
         false <- compressed_etf?(binary),
         term <- :erlang.binary_to_term(binary, [:safe]),
         {:ok, _envelope, _bytes} <- SnapshotFormat.encode(term) do
      {:ok, term}
    else
      _other -> {:error, :invalid_legacy_snapshot}
    end
  rescue
    _error -> {:error, :invalid_legacy_snapshot}
  end

  # Rows predating the original ETF wrapper were plain JSON. Keep that
  # migration path bounded, but do not treat a known future format as plain
  # state.
  defp unwrap_term(other) do
    with true <-
           Maraithon.BoundedJSON.valid?(other, SnapshotFormat.max_encoded_bytes(),
             max_binary_bytes: 262_144,
             max_depth: 32,
             max_nodes: 100_000,
             max_map_entries: 20_000,
             max_list_items: 20_000
           ),
         {:ok, encoded} <- Jason.encode(other),
         true <- byte_size(encoded) <= SnapshotFormat.max_encoded_bytes() do
      {:ok, other}
    else
      _other -> {:error, :invalid_legacy_snapshot}
    end
  end

  defp compressed_etf?(<<131, 80, _rest::binary>>), do: true
  defp compressed_etf?(_binary), do: false
end
