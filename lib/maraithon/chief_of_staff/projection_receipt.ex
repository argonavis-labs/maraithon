defmodule Maraithon.ChiefOfStaff.ProjectionReceipt do
  @moduledoc """
  Immutable receipt connecting one semantic effect to exactly one Todo or Chief decision.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ~w(todo decision)

  schema "chief_projection_receipts" do
    field :receipt_key, :binary
    field :agent_work_result_id, :binary_id
    field :semantic_effect_id, :binary_id
    field :user_id, :string
    field :agent_id, :binary_id
    field :projection_kind, :string
    field :projection_key, :string
    field :todo_id, :binary_id
    field :decision_id, :binary_id
    field :attrs_digest, :binary
    field :projected_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def kinds, do: @kinds

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :id,
      :receipt_key,
      :agent_work_result_id,
      :semantic_effect_id,
      :user_id,
      :agent_id,
      :projection_kind,
      :projection_key,
      :todo_id,
      :decision_id,
      :attrs_digest,
      :projected_at,
      :inserted_at
    ])
    |> validate_required([
      :receipt_key,
      :agent_work_result_id,
      :semantic_effect_id,
      :user_id,
      :agent_id,
      :projection_kind,
      :projection_key,
      :attrs_digest,
      :projected_at,
      :inserted_at
    ])
    |> validate_inclusion(:projection_kind, @kinds)
    |> V.validate_digest(:receipt_key)
    |> V.validate_digest(:attrs_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:projection_key, min: 1, max: 512)
    |> validate_target()
    |> unique_constraint(:receipt_key,
      name: :chief_projection_receipts_receipt_key_unique_index
    )
    |> unique_constraint([:semantic_effect_id, :projection_kind, :projection_key],
      name: :chief_projection_receipts_effect_projection_unique_index
    )
    |> foreign_key_constraint(:agent_work_result_id,
      name: :chief_projection_receipts_result_owner_fkey
    )
    |> foreign_key_constraint(:semantic_effect_id,
      name: :chief_projection_receipts_effect_owner_fkey
    )
    |> foreign_key_constraint(:todo_id, name: :chief_projection_receipts_todo_owner_fkey)
    |> foreign_key_constraint(:decision_id,
      name: :chief_projection_receipts_decision_owner_fkey
    )
    |> check_constraint(:projection_kind, name: :chief_projection_receipts_target_check)
    |> check_constraint(:attrs_digest, name: :chief_projection_receipts_digest_check)
  end

  defp validate_target(changeset) do
    case {
      get_field(changeset, :projection_kind),
      get_field(changeset, :todo_id),
      get_field(changeset, :decision_id)
    } do
      {"todo", todo_id, nil} when not is_nil(todo_id) -> changeset
      {"decision", nil, decision_id} when not is_nil(decision_id) -> changeset
      _other -> add_error(changeset, :projection_kind, "must select exactly one matching target")
    end
  end
end
