defmodule Maraithon.Runtime.SourceDecisionReceipt do
  @moduledoc "Immutable create/update/skip decision for one discovery source item."

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @actions ~w(create update skip)
  @evaluators ~w(model deterministic policy)

  schema "source_decision_receipts" do
    field :cycle_id, :binary_id
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :source_ref_digest, :binary
    field :reason_job_id, :binary_id
    field :action, :string
    field :todo_id, :binary_id
    field :todo_state_digest, :binary
    field :evaluator, :string
    field :reason_code, :string
    field :evidence_digest, :binary
    field :decision_digest, :binary
    field :decided_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def actions, do: @actions
  def evaluators, do: @evaluators

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :id,
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :source_ref_digest,
      :reason_job_id,
      :action,
      :todo_id,
      :todo_state_digest,
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
      :source_ref_digest,
      :reason_job_id,
      :action,
      :evaluator,
      :reason_code,
      :decision_digest,
      :decided_at,
      :inserted_at
    ])
    |> validate_inclusion(:action, @actions)
    |> validate_inclusion(:evaluator, @evaluators)
    |> validate_number(:connected_account_id, greater_than: 0)
    |> validate_todo_shape()
    |> validate_format(:reason_code, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_length(:reason_code, max: 80)
    |> V.validate_digest(:source_ref_digest)
    |> V.validate_digest(:todo_state_digest)
    |> V.validate_digest(:evidence_digest)
    |> V.validate_digest(:decision_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> unique_constraint([:cycle_id, :source_ref_digest],
      name: :source_decision_receipts_ref_unique_index
    )
    |> foreign_key_constraint(:cycle_id,
      name: :source_decision_receipts_cycle_owner_fkey
    )
    |> foreign_key_constraint(:source_ref_digest,
      name: :source_decision_receipts_item_fkey
    )
    |> check_constraint(:action, name: :source_decision_receipts_shape_check)
    |> check_constraint(:decision_digest, name: :source_decision_receipts_digest_check)
  end

  defp validate_todo_shape(changeset) do
    action = get_field(changeset, :action)
    todo_id = get_field(changeset, :todo_id)
    todo_state_digest = get_field(changeset, :todo_state_digest)

    cond do
      action == "skip" and (not is_nil(todo_id) or not is_nil(todo_state_digest)) ->
        add_error(changeset, :todo_id, "must be absent for skip")

      action in ["create", "update"] and (is_nil(todo_id) or is_nil(todo_state_digest)) ->
        add_error(changeset, :todo_id, "and todo_state_digest are required")

      true ->
        changeset
    end
  end
end
