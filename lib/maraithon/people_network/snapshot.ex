defmodule Maraithon.PeopleNetwork.Snapshot do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:user_id, :string, autogenerate: false}
  schema "people_network_snapshots" do
    field :generation_id, Ecto.UUID
    field :refreshed_at, :utc_datetime_usec
  end
end
