defmodule Maraithon.Runtime.Coordination.Partition do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:partition_id, :integer, autogenerate: false}
  schema "runtime_partitions" do
    field :activation_epoch, Ecto.UUID
    field :ownership_epoch, :integer
    field :effects_drained_epoch, :integer
    field :owner_node_incarnation_id, Ecto.UUID
    field :transition_id, Ecto.UUID
    field :state, :string
    field :lease_expires_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :draining_at, :utc_datetime_usec
    field :last_moved_at, :utc_datetime_usec
    field :fair_sequence, :integer
    timestamps(type: :utc_datetime_usec)
  end
end
