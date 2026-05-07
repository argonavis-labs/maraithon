defmodule Maraithon.Commitments.Commitment do
  @moduledoc """
  Durable user-scoped obligation that represents what the operator owes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open done dismissed snoozed)

  schema "commitments" do
    field :source, :string
    field :source_id, :string
    field :title, :string
    field :owed_to, :string
    field :project, :string
    field :due_at, :utc_datetime_usec
    field :status, :string, default: "open"
    field :priority, :integer, default: 50
    field :evidence, {:array, :string}, default: []
    field :metadata, :map, default: %{}
    field :closed_at, :utc_datetime_usec
    field :snoozed_until, :utc_datetime_usec

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :source,
    :title,
    :status
  ]

  @optional_fields [
    :source_id,
    :owed_to,
    :project,
    :due_at,
    :priority,
    :evidence,
    :metadata,
    :closed_at,
    :snoozed_until
  ]

  def changeset(commitment, attrs) do
    commitment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_length(:source, min: 2, max: 100)
    |> validate_length(:source_id, max: 255)
    |> validate_length(:title, min: 4, max: 500)
    |> validate_length(:owed_to, max: 255)
    |> validate_length(:project, max: 255)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:source_id, name: :commitments_user_id_source_source_id_index)
  end
end
