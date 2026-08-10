defmodule Maraithon.Runtime.AgentLifecycleOperation do
  @moduledoc """
  Durable, per-Agent proof that a composite lifecycle transition is draining.

  The immutable token and canonical payload let callers and the bounded
  reconciler adopt the exact same transition after a crash. The row is removed
  only in the transaction that applies the requested mutation (or by the
  Agent's delete cascade).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key false
  @foreign_key_type :binary_id
  @kinds ~w(stop update delete pause remove upgrade)
  @states ~w(draining)

  schema "agent_lifecycle_operations" do
    belongs_to :agent, Agent, primary_key: true

    field :operation_token, Ecto.UUID
    field :kind, :string
    field :state, :string, default: "draining"
    field :request_digest, :binary
    field :payload_digest, :binary
    field :payload, :map
    field :expected_owner_token, Ecto.UUID
    field :requires_external_drain, :boolean, default: false
    field :external_drain_confirmed_at, :utc_datetime_usec
    field :external_drain_evidence_digest, :binary
    field :initiated_at, :utc_datetime_usec
    field :last_attempted_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :agent_id,
    :operation_token,
    :kind,
    :state,
    :request_digest,
    :payload_digest,
    :payload,
    :requires_external_drain,
    :initiated_at,
    :last_attempted_at
  ]
  @optional_fields [
    :expected_owner_token,
    :external_drain_confirmed_at,
    :external_drain_evidence_digest
  ]

  def changeset(operation, attrs) do
    operation
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> validate_length(:request_digest, is: 32, count: :bytes)
    |> validate_length(:payload_digest, is: 32, count: :bytes)
    |> validate_length(:external_drain_evidence_digest, is: 32, count: :bytes)
    |> validate_change(:payload, fn :payload, payload ->
      if is_map(payload) and not is_struct(payload),
        do: [],
        else: [payload: "must be an object"]
    end)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:operation_token,
      name: :agent_lifecycle_operations_token_index
    )
    |> check_constraint(:kind, name: :agent_lifecycle_operations_kind_check)
    |> check_constraint(:state, name: :agent_lifecycle_operations_state_check)
    |> check_constraint(:request_digest, name: :agent_lifecycle_operations_digest_check)
    |> check_constraint(:payload, name: :agent_lifecycle_operations_payload_check)
    |> check_constraint(:requires_external_drain,
      name: :agent_lifecycle_operations_external_drain_check
    )
  end

  def kinds, do: @kinds
end
