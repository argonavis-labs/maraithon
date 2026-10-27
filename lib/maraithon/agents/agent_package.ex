defmodule Maraithon.Agents.AgentPackage do
  @moduledoc """
  Marketplace package definition for an installable agent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.AgentPackageVersion

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "agent_packages" do
    field :slug, :string
    field :name, :string
    field :summary, :string
    field :category, :string
    field :source_kind, :string, default: "builtin"
    field :status, :string, default: "published"
    field :owner_user_id, :string
    field :manifest, :map, default: %{}

    belongs_to :latest_version, AgentPackageVersion
    has_many :versions, AgentPackageVersion

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:slug, :name]
  @optional_fields [
    :summary,
    :category,
    :source_kind,
    :status,
    :owner_user_id,
    :manifest,
    :latest_version_id
  ]

  def changeset(package, attrs) do
    package
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> normalize_slug()
    |> validate_required(@required_fields)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]*$/)
    |> validate_inclusion(:source_kind, ["builtin", "private", "marketplace", "imported"])
    |> validate_inclusion(:status, ["draft", "published", "deprecated", "disabled"])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:latest_version_id)
  end

  defp normalize_slug(changeset) do
    update_change(changeset, :slug, fn slug ->
      slug
      |> to_string()
      |> String.trim()
      |> String.downcase()
    end)
  end
end
