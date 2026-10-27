defmodule Maraithon.Crm.PersonMerge do
  @moduledoc """
  Audit record for CRM person merges.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Crm.Person

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "crm_person_merges" do
    field :evidence, :string
    field :model_rationale, :string
    field :performed_by, :string
    field :metadata, :map, default: %{}
    field :performed_at, :utc_datetime_usec

    belongs_to :user, User, type: :string
    belongs_to :surviving_person, Person, type: :binary_id
    belongs_to :merged_person, Person, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :surviving_person_id, :merged_person_id, :performed_at]
  @optional_fields [:evidence, :model_rationale, :performed_by, :metadata]

  def changeset(merge, attrs) do
    merge
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:evidence, max: 4_000)
    |> validate_length(:model_rationale, max: 4_000)
    |> validate_length(:performed_by, max: 120)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:surviving_person_id)
    |> foreign_key_constraint(:merged_person_id)
    |> unique_constraint(:merged_person_id, name: :crm_person_merges_unique_pair)
  end
end
