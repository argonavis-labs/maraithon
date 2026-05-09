defmodule Maraithon.Agents.AgentRunStep do
  @moduledoc """
  Durable record for a single effect/tool/model step within an agent run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_run_steps" do
    field :sequence, :integer
    field :step_type, :string
    field :status, :string
    field :tool_name, :string
    field :effect_type, :string
    field :resolved_model, :string
    field :intelligence, :string
    field :finish_reason, :string
    field :generation_mode, :string
    field :request_payload, :map, default: %{}
    field :response_payload, :map, default: %{}
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :agent_run, AgentRun
    belongs_to :agent, Agent

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_run_id, :agent_id, :sequence, :step_type, :status, :started_at]
  @optional_fields [
    :tool_name,
    :effect_type,
    :resolved_model,
    :intelligence,
    :finish_reason,
    :generation_mode,
    :request_payload,
    :response_payload,
    :error,
    :completed_at
  ]

  def changeset(step, attrs) do
    step
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["requested", "completed", "failed"])
    |> foreign_key_constraint(:agent_run_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:agent_run_id, :sequence])
  end
end
