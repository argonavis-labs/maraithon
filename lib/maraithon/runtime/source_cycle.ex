defmodule Maraithon.Runtime.SourceCycle do
  @moduledoc """
  Immutable, bounded proof root for one source-account discovery or closure cycle.

  The row contains only cursor bounds, counts, hashes, and durable job identities.
  Source content and model text never belong in this ledger.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @roles ~w(discovery closure)
  @boundaries ~w(lower_inclusive_upper_exclusive lower_exclusive_upper_inclusive provider_native)

  schema "source_cycles" do
    field :cycle_key, :binary
    field :proof_version, :integer, default: 1
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :role, :string
    field :cursor_kind, :string
    field :lower_cursor, :string
    field :upper_cursor, :string
    field :boundary, :string
    field :acquisition_job_id, :binary_id
    field :reason_job_ids, {:array, Ecto.UUID}, default: []
    field :finalizer_job_id, :binary_id
    field :reason_job_count, :integer
    field :job_manifest_digest, :binary
    field :source_item_count, :integer
    field :source_manifest_digest, :binary
    field :todo_snapshot_count, :integer
    field :todo_snapshot_manifest_digest, :binary
    field :captured_at, :utc_datetime_usec
    field :sealed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def roles, do: @roles
  def boundaries, do: @boundaries

  def changeset(cycle, attrs) do
    cycle
    |> cast(attrs, [
      :id,
      :cycle_key,
      :proof_version,
      :user_id,
      :connected_account_id,
      :provider,
      :role,
      :cursor_kind,
      :lower_cursor,
      :upper_cursor,
      :boundary,
      :acquisition_job_id,
      :reason_job_ids,
      :finalizer_job_id,
      :reason_job_count,
      :job_manifest_digest,
      :source_item_count,
      :source_manifest_digest,
      :todo_snapshot_count,
      :todo_snapshot_manifest_digest,
      :captured_at,
      :sealed_at,
      :inserted_at
    ])
    |> validate_required([
      :cycle_key,
      :proof_version,
      :user_id,
      :connected_account_id,
      :provider,
      :role,
      :cursor_kind,
      :upper_cursor,
      :boundary,
      :acquisition_job_id,
      :reason_job_ids,
      :reason_job_count,
      :job_manifest_digest,
      :source_item_count,
      :source_manifest_digest,
      :todo_snapshot_count,
      :todo_snapshot_manifest_digest,
      :captured_at,
      :sealed_at,
      :inserted_at
    ])
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:boundary, @boundaries)
    |> validate_number(:proof_version, equal_to: 1)
    |> validate_number(:connected_account_id, greater_than: 0)
    |> validate_number(:reason_job_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 20_000
    )
    |> validate_number(:source_item_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 50_000
    )
    |> validate_number(:todo_snapshot_count,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 20_000
    )
    |> validate_reason_jobs()
    |> validate_role_shape()
    |> validate_fanout_shape()
    |> validate_denominator_fanout()
    |> validate_time_order()
    |> V.validate_digest(:cycle_key)
    |> V.validate_digest(:job_manifest_digest)
    |> V.validate_digest(:source_manifest_digest)
    |> V.validate_digest(:todo_snapshot_manifest_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> V.validate_bytes(:cursor_kind, min: 1, max: 80)
    |> V.validate_bytes(:lower_cursor, min: 1, max: 4096)
    |> V.validate_bytes(:upper_cursor, min: 1, max: 4096)
    |> unique_constraint(:cycle_key, name: :source_cycles_cycle_key_unique_index)
    |> unique_constraint(:acquisition_job_id,
      name: :source_cycles_acquisition_job_unique_index
    )
    |> unique_constraint(:finalizer_job_id, name: :source_cycles_finalizer_job_unique_index)
    |> foreign_key_constraint(:connected_account_id,
      name: :source_cycles_account_owner_fkey
    )
    |> check_constraint(:role, name: :source_cycles_shape_check)
    |> check_constraint(:cycle_key, name: :source_cycles_digest_check)
  end

  defp validate_reason_jobs(changeset) do
    validate_change(changeset, :reason_job_ids, fn :reason_job_ids, job_ids ->
      count = get_field(changeset, :reason_job_count)

      cond do
        not is_list(job_ids) ->
          [reason_job_ids: "must be a list"]

        Enum.any?(job_ids, &(Ecto.UUID.cast(&1) == :error)) ->
          [reason_job_ids: "contains an invalid id"]

        length(job_ids) != length(Enum.uniq(job_ids)) ->
          [reason_job_ids: "must be unique"]

        length(job_ids) != count ->
          [reason_job_ids: "must match reason_job_count"]

        true ->
          []
      end
    end)
  end

  defp validate_role_shape(changeset) do
    if get_field(changeset, :role) == "discovery" and
         get_field(changeset, :todo_snapshot_count, 0) != 0 do
      add_error(changeset, :todo_snapshot_count, "must be zero for discovery")
    else
      changeset
    end
  end

  defp validate_fanout_shape(changeset) do
    reason_job_count = get_field(changeset, :reason_job_count, 0)
    finalizer_job_id = get_field(changeset, :finalizer_job_id)

    cond do
      reason_job_count == 0 and not is_nil(finalizer_job_id) ->
        add_error(changeset, :finalizer_job_id, "must be absent without reason jobs")

      reason_job_count > 0 and is_nil(finalizer_job_id) ->
        add_error(changeset, :finalizer_job_id, "is required with reason jobs")

      true ->
        changeset
    end
  end

  defp validate_denominator_fanout(changeset) do
    role = get_field(changeset, :role)
    reason_job_count = get_field(changeset, :reason_job_count, 0)

    denominator_count =
      case role do
        "discovery" -> get_field(changeset, :source_item_count, 0)
        "closure" -> get_field(changeset, :todo_snapshot_count, 0)
        _other -> 0
      end

    if denominator_count == 0 == (reason_job_count == 0) do
      changeset
    else
      add_error(changeset, :reason_job_count, "must match whether the cycle has work")
    end
  end

  defp validate_time_order(changeset) do
    case {get_field(changeset, :captured_at), get_field(changeset, :sealed_at)} do
      {%DateTime{} = captured_at, %DateTime{} = sealed_at} ->
        if DateTime.compare(captured_at, sealed_at) == :gt,
          do: add_error(changeset, :sealed_at, "must not precede captured_at"),
          else: changeset

      _other ->
        changeset
    end
  end
end
