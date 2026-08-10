defmodule Maraithon.Runtime.AgentTerminationIncident do
  @moduledoc """
  Durable ambiguity and retry state for one exact Agent lease incarnation.

  A requested incident is a replacement fence, not termination evidence.  It
  advances only after an immutable local-DOWN or signed external proof exists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "agent_termination_incidents" do
    field :activation_epoch, Ecto.UUID
    field :node_incarnation_id, Ecto.UUID
    field :partition_id, :integer
    field :partition_epoch, :integer
    field :agent_id, Ecto.UUID
    field :lease_token, Ecto.UUID
    field :owner_node, :string
    field :status, :string, default: "requested"
    field :request_reason, :string
    field :requested_at, :utc_datetime_usec
    field :last_requested_at, :utc_datetime_usec
    field :request_count, :integer, default: 1
    field :proof_id, Ecto.UUID
    field :proof_kind, :string
    field :proved_at, :utc_datetime_usec
    field :reconcile_attempts, :integer, default: 0
    field :retry_at, :utc_datetime_usec
    field :last_error, :string
    field :reconciled_at, :utc_datetime_usec
    field :reconciliation_policy, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(id activation_epoch node_incarnation_id partition_id partition_epoch agent_id
             lease_token owner_node status request_reason requested_at last_requested_at
             request_count proof_id proof_kind proved_at reconcile_attempts retry_at last_error
             reconciled_at reconciliation_policy)a

  def changeset(incident, attrs) do
    incident
    |> cast(attrs || %{}, @fields)
    |> validate_required([
      :id,
      :agent_id,
      :lease_token,
      :owner_node,
      :status,
      :request_reason,
      :requested_at,
      :last_requested_at,
      :request_count,
      :reconcile_attempts,
      :retry_at,
      :reconciliation_policy
    ])
    |> validate_inclusion(:status, ~w(requested proven reconciled))
    |> validate_number(:request_count, greater_than: 0)
    |> validate_number(:reconcile_attempts, greater_than_or_equal_to: 0)
    |> validate_length(:owner_node, min: 1, max: 255, count: :bytes)
    |> validate_length(:request_reason, min: 1, max: 255, count: :bytes)
    |> validate_length(:last_error, min: 1, max: 255, count: :bytes)
    |> unique_constraint(:lease_token,
      name: :agent_termination_incidents_lease_token_index
    )
    |> unique_constraint(:agent_id,
      name: :agent_termination_incidents_open_agent_index
    )
    |> check_constraint(:status, name: :agent_termination_incidents_shape)
  end
end
