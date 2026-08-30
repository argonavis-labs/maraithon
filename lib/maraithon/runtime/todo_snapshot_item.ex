defmodule Maraithon.Runtime.TodoSnapshotItem do
  @moduledoc "Immutable identity and state proof for one closure-eligible todo."

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Lineage.ChangesetValidators, as: V

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @eligible_statuses ~w(open snoozed)

  schema "todo_snapshot_items" do
    field :cycle_id, :binary_id
    field :user_id, :string
    field :connected_account_id, :id
    field :provider, :string
    field :ordinal, :integer
    field :todo_id, :binary_id
    field :eligible_status, :string
    field :todo_state_digest, :binary
    field :todo_updated_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def eligible_statuses, do: @eligible_statuses

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :id,
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :ordinal,
      :todo_id,
      :eligible_status,
      :todo_state_digest,
      :todo_updated_at,
      :inserted_at
    ])
    |> validate_required([
      :cycle_id,
      :user_id,
      :connected_account_id,
      :provider,
      :ordinal,
      :todo_id,
      :eligible_status,
      :todo_state_digest,
      :todo_updated_at,
      :inserted_at
    ])
    |> validate_inclusion(:eligible_status, @eligible_statuses)
    |> validate_number(:connected_account_id, greater_than: 0)
    |> validate_number(:ordinal, greater_than_or_equal_to: 0)
    |> V.validate_digest(:todo_state_digest)
    |> V.validate_bytes(:user_id, min: 1, max: 320)
    |> V.validate_bytes(:provider, min: 1, max: 80)
    |> unique_constraint([:cycle_id, :ordinal],
      name: :todo_snapshot_items_ordinal_unique_index
    )
    |> unique_constraint([:cycle_id, :todo_id, :todo_state_digest],
      name: :todo_snapshot_items_state_unique_index
    )
    |> foreign_key_constraint(:cycle_id, name: :todo_snapshot_items_cycle_owner_fkey)
    |> check_constraint(:ordinal, name: :todo_snapshot_items_shape_check)
    |> check_constraint(:todo_state_digest, name: :todo_snapshot_items_digest_check)
  end
end
