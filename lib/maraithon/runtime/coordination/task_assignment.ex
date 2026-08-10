defmodule Maraithon.Runtime.Coordination.TaskAssignment do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "runtime_task_assignments" do
    field :activation_epoch, Ecto.UUID
    field :work_kind, :string
    field :work_id, Ecto.UUID
    field :claim_token, Ecto.UUID
    field :partition_id, :integer
    field :partition_epoch, :integer
    field :node_incarnation_id, Ecto.UUID
    field :supervisor_id, Ecto.UUID
    field :local_task_id, Ecto.UUID
    field :state, :string
    field :provider_boundary, :string
    field :lease_expires_at, :utc_datetime_usec
    field :ready_at, :utc_datetime_usec
    field :termination_requested_at, :utc_datetime_usec
    field :termination_proven_at, :utc_datetime_usec
    field :settled_at, :utc_datetime_usec
    field :outcome, :string
    timestamps(type: :utc_datetime_usec)
  end
end
