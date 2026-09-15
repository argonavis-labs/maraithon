defmodule Maraithon.Delegations.Grant do
  @moduledoc "Immutable user authority. Each control or scope change creates a version."
  use Maraithon.Delegations.Record
  @fields ~w(delegation_id version origin_request_id control_state policy_version)a

  schema "delegation_grants" do
    payload_fields()
    field :delegation_id, :binary_id
    field :version, :integer
    field :origin_request_id, :string
    field :control_state, :string, default: "active"
    field :policy_version, :integer, default: 1
  end

  def payload_binding_spec, do: Record.spec("delegation_grants", @fields)

  def changeset(row, attrs) do
    Record.changeset(row, attrs, @fields, [:delegation_id, :version, :origin_request_id])
    |> validate_inclusion(:control_state, ~w(active paused revoked expired))
    |> validate_number(:version, greater_than: 0)
    |> validate_length(:origin_request_id, min: 1, max: 200)
    |> unique_constraint([:delegation_id, :version])
    |> unique_constraint([:user_id, :origin_request_id])
  end
end
