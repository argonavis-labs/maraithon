defmodule Maraithon.Runtime.TodoClosureReceipt do
  @moduledoc "Immutable completion decision and evidence digest for one snapshotted todo."

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @outcomes ~w(completed still_open acknowledged superseded)
  @evaluators ~w(model deterministic policy)

  schema "todo_closure_receipts" do
    field :cycle_id, :binary_id
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :todo_id, :binary_id
    field :reason_job_id, :binary_id
    field :todo_before_digest, :binary
    field :todo_after_digest, :binary
    field :outcome, :string
    field :evaluator, :string
    field :reason_code, :string
    field :evidence_digest, :binary
    field :decision_digest, :binary
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def outcomes, do: @outcomes
  def evaluators, do: @evaluators

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :id,
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :todo_id,
      :reason_job_id,
      :todo_before_digest,
      :todo_after_digest,
      :outcome,
      :evaluator,
      :reason_code,
      :evidence_digest,
      :decision_digest,
      :decided_at,
      :inserted_at
    ])
    |> validate_required([
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :todo_id,
      :reason_job_id,
      :todo_before_digest,
      :todo_after_digest,
      :outcome,
      :evaluator,
      :reason_code,
      :decision_digest,
      :decided_at,
      :inserted_at
    ])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_inclusion(:evaluator, @evaluators)
    |> validate_number(:connected_account_id, greater_than: 0)
    |> validate_evidence()
    |> validate_format(:reason_code, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_length(:reason_code, max: 80)
    |> V.validate_digest(:todo_before_digest)
    |> V.validate_digest(:todo_after_digest)
    |> V.validate_digest(:evidence_digest)
    |> V.validate_digest(:decision_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> unique_constraint([:cycle_id, :todo_id],
      name: :todo_closure_receipts_todo_unique_index
    )
    |> foreign_key_constraint(:cycle_id,
      name: :todo_closure_receipts_cycle_owner_fkey
    )
    |> foreign_key_constraint(:todo_before_digest,
      name: :todo_closure_receipts_snapshot_fkey
    )
    |> check_constraint(:outcome, name: :todo_closure_receipts_shape_check)
    |> check_constraint(:decision_digest, name: :todo_closure_receipts_digest_check)
  end

  defp validate_evidence(changeset) do
    if get_field(changeset, :outcome) == "completed" and
         is_nil(get_field(changeset, :evidence_digest)) do
      add_error(changeset, :evidence_digest, "is required for completed outcomes")
    else
      changeset
    end
  end
end
