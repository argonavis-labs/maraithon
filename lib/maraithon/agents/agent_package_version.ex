defmodule Maraithon.Agents.AgentPackageVersion do
  @moduledoc """
  Immutable versioned manifest for an installable agent package.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.AgentPackage

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_package_versions" do
    field :version, :string
    field :changelog, :string
    field :behavior, :string
    field :system_prompt, :string
    field :model, :string
    field :intelligence, :string
    field :goals, {:array, :string}, default: []
    field :skill_paths, {:array, :string}, default: []
    field :required_connectors, :map, default: %{}
    field :tool_allowlist, {:array, :string}, default: []
    field :mcp_allowlist, {:array, :string}, default: []
    field :default_config, :map, default: %{}
    field :manifest, :map, default: %{}
    field :status, :string, default: "published"
    field :published_at, :utc_datetime_usec

    belongs_to :agent_package, AgentPackage

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_package_id, :version, :behavior]
  @optional_fields [
    :changelog,
    :system_prompt,
    :model,
    :intelligence,
    :goals,
    :skill_paths,
    :required_connectors,
    :tool_allowlist,
    :mcp_allowlist,
    :default_config,
    :manifest,
    :status,
    :published_at
  ]

  def changeset(version, attrs) do
    version
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["draft", "published", "deprecated", "disabled"])
    |> validate_manifest_agent_skill_paths()
    |> validate_behavior()
    |> foreign_key_constraint(:agent_package_id)
    |> unique_constraint([:agent_package_id, :version])
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

  defp validate_manifest_agent_skill_paths(changeset) do
    if get_field(changeset, :behavior) == "manifest_agent" do
      skill_paths =
        changeset
        |> get_field(:skill_paths, [])
        |> List.wrap()
        |> Enum.filter(fn path -> is_binary(path) and String.trim(path) != "" end)

      if skill_paths == [] do
        add_error(changeset, :skill_paths, "must include at least one Markdown skill path")
      else
        changeset
      end
    else
      changeset
    end
  end
end
