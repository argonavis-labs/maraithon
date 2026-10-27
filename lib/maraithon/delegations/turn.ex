defmodule Maraithon.Delegations.Turn do
  @moduledoc "One bounded decision and the existing prepared action it authorises."
  use Maraithon.Delegations.Record

  @fields ~w(delegation_id seq grant_version source_revision wake_reason run_id prepared_action_id status model reserved_micro_usd cost_micro_usd model_calls available_at)a

  schema "delegation_turns" do
    payload_fields()
    field :delegation_id, :binary_id
    field :seq, :integer
    field :grant_version, :integer
    field :source_revision, :integer
    field :wake_reason, :string
    field :run_id, :binary_id
    field :prepared_action_id, :binary_id
    field :status, :string, default: "deciding"
    field :model, :string
    field :reserved_micro_usd, :integer, default: 0
    field :cost_micro_usd, :integer, default: 0
    field :model_calls, :integer, default: 0
    field :available_at, :utc_datetime_usec
  end

  def payload_binding_spec, do: Record.spec("delegation_turns", @fields)

  def changeset(row, attrs) do
    Record.changeset(row, attrs, @fields, [:delegation_id, :seq, :grant_version, :source_revision])
    |> validate_inclusion(:status, ~w(deciding validated dispatched settled superseded failed))
    |> validate_number(:reserved_micro_usd, greater_than_or_equal_to: 0)
    |> validate_number(:cost_micro_usd, greater_than_or_equal_to: 0)
    |> unique_constraint([:delegation_id, :seq])
    |> unique_constraint(:delegation_id, name: :delegation_turns_one_live)
  end
end
