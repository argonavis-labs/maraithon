defmodule Maraithon.Runtime.RuntimeIncident do
  @moduledoc """
  Structured runtime stability incident.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(node_boot node_shutdown agent_crash agent_resumed agent_stopped_unexpectedly db_outage db_recovered)

  schema "runtime_incidents" do
    field :kind, :string
    field :reason, :string
    field :metadata, :map, default: %{}
    field :node, :string
    field :occurred_at, :utc_datetime_usec

    belongs_to :agent, Agent

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:kind, :node, :occurred_at]
  @optional_fields [:agent_id, :reason, :metadata]

  def changeset(incident, attrs) do
    incident
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:kind, @kinds)
    |> foreign_key_constraint(:agent_id)
  end

  def kinds, do: @kinds
end
