defmodule Maraithon.Runtime.Coordination.NodeIncarnation do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "runtime_node_incarnations" do
    field :activation_epoch, Ecto.UUID
    field :node_name, :string
    field :revision, :string
    field :state, :string
    field :lease_expires_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :draining_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :metadata, :map
    timestamps(type: :utc_datetime_usec)
  end
end
