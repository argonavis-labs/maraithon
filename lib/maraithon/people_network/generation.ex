defmodule Maraithon.PeopleNetwork.Generation do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "people_network_generations" do
    field :user_id, :string
    field :as_of, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :invalidated_at, :utc_datetime_usec
    field :summary, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
