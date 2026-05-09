defmodule Maraithon.Agents.Agent do
  @moduledoc """
  Schema for agent records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.AgentPackage
  alias Maraithon.Agents.AgentPackageVersion
  alias Maraithon.Agents.AgentRun
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agents" do
    field :user_id, :string
    field :behavior, :string
    field :config, :map, default: %{}
    field :status, :string, default: "stopped"
    field :install_status, :string, default: "enabled"
    field :started_at, :utc_datetime_usec
    field :stopped_at, :utc_datetime_usec
    field :installed_at, :utc_datetime_usec
    field :removed_at, :utc_datetime_usec
    field :connector_grants, :map, default: %{}
    field :schedule_policy, :map, default: %{}
    field :delivery_policy, :map, default: %{}
    field :memory_scope, :map, default: %{}
    belongs_to :project, Project
    belongs_to :agent_package, AgentPackage
    belongs_to :agent_package_version, AgentPackageVersion
    has_many :agent_runs, AgentRun

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:behavior]
  @optional_fields [
    :config,
    :status,
    :install_status,
    :started_at,
    :stopped_at,
    :installed_at,
    :removed_at,
    :connector_grants,
    :schedule_policy,
    :delivery_policy,
    :memory_scope
  ]

  def changeset(agent, attrs) do
    attrs = attrs || %{}

    agent
    |> cast(drop_system_fields(attrs), @required_fields ++ @optional_fields)
    |> maybe_put_system_field(attrs, :user_id)
    |> maybe_put_system_field(attrs, :project_id)
    |> maybe_put_system_field(attrs, :agent_package_id)
    |> maybe_put_system_field(attrs, :agent_package_version_id)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["stopped", "running", "degraded", "terminated"])
    |> validate_inclusion(:install_status, [
      "enabled",
      "paused",
      "setup_required",
      "error",
      "removed"
    ])
    |> validate_behavior()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:agent_package_id)
    |> foreign_key_constraint(:agent_package_version_id)
  end

  defp validate_behavior(changeset) do
    validate_change(changeset, :behavior, fn :behavior, behavior ->
      if Maraithon.Behaviors.exists?(behavior) do
        []
      else
        [behavior: "unknown behavior: #{behavior}"]
      end
    end)
  end

  defp drop_system_fields(attrs) do
    Map.drop(attrs, [:user_id, "user_id", :project_id, "project_id"])
  end

  defp maybe_put_system_field(changeset, attrs, field) do
    case fetch_system_field(attrs, field) do
      {:present, value} -> put_change(changeset, field, normalize_optional_string(value))
      :missing -> changeset
    end
  end

  defp fetch_system_field(attrs, field) when is_map(attrs) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> {:present, Map.get(attrs, field)}
      Map.has_key?(attrs, string_key) -> {:present, Map.get(attrs, string_key)}
      true -> :missing
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value
end
