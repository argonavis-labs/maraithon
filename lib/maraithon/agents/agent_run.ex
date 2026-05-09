defmodule Maraithon.Agents.AgentRun do
  @moduledoc """
  Durable execution record for one runtime trigger cycle.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Agents.AgentRunStep
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_runs" do
    field :user_id, :string
    field :behavior, :string
    field :status, :string, default: "running"
    field :trigger_type, :string
    field :trigger, :map, default: %{}
    field :resolved_model, :string
    field :intelligence, :string
    field :finish_reason, :string
    field :generation_mode, :string
    field :active_skills, {:array, :string}, default: []
    field :tool_allowlist, {:array, :string}, default: []
    field :budget_snapshot, :map, default: %{}
    field :error, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :agent, Agent
    belongs_to :agent_package, AgentPackage
    belongs_to :agent_package_version, AgentPackageVersion
    belongs_to :project, Project
    has_many :steps, AgentRunStep, foreign_key: :agent_run_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :behavior, :status, :started_at]
  @optional_fields [
    :agent_package_id,
    :agent_package_version_id,
    :user_id,
    :project_id,
    :trigger_type,
    :trigger,
    :resolved_model,
    :intelligence,
    :finish_reason,
    :generation_mode,
    :active_skills,
    :tool_allowlist,
    :budget_snapshot,
    :error,
    :metadata,
    :completed_at
  ]

  def changeset(run, attrs) do
    run
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["running", "completed", "failed", "cancelled"])
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:agent_package_id)
    |> foreign_key_constraint(:agent_package_version_id)
    |> foreign_key_constraint(:project_id)
  end
end
