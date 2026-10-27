defmodule Maraithon.PeopleNetwork.Profile do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "people_network_profiles" do
    field :generation_id, Ecto.UUID, primary_key: true
    field :window_days, :integer, primary_key: true
    field :node_id, :string, primary_key: true
    field :user_id, :string
    field :display_name, :string
    field :rank, :float
    field :profile, :map, default: %{}
  end
end
