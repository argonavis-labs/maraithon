defmodule Maraithon.UserMemory.Profile do
  @moduledoc """
  Durable per-user operating profile shared across agent runtimes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  schema "user_memory_profiles" do
    field :summary, :string
    field :profile, :map, default: %{}
    field :source_window_start, :utc_datetime_usec
    field :source_window_end, :utc_datetime_usec
    field :confidence, :float, default: 0.0

    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :summary]
  @optional_fields [:profile, :source_window_start, :source_window_end, :confidence]

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:summary, min: 4, max: 5000)
    |> validate_change(:profile, fn :profile, value ->
      if is_map(value), do: [], else: [profile: "must be a map"]
    end)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:user_id)
  end
end
