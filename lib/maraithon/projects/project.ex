defmodule Maraithon.Projects.Project do
  @moduledoc """
  Schema for project-scoped operating context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Agents.Agent
  alias Maraithon.Projects.ProjectItem

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active paused archived)
  @priorities ~w(low normal high critical)

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :priority, :string, default: "normal"
    field :description, :string
    field :summary, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    has_many :agents, Agent, foreign_key: :project_id
    has_many :items, ProjectItem, foreign_key: :project_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:name]
  @optional_fields [:slug, :status, :priority, :description, :summary, :metadata]

  def changeset(project, attrs) do
    project
    |> cast(normalize_attrs(attrs), @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 160)
    |> validate_length(:slug, min: 1, max: 160)
    |> validate_length(:description, max: 2_000)
    |> validate_length(:summary, max: 4_000)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> maybe_put_generated_slug()
    |> unique_constraint(:slug, name: :projects_user_id_slug_index)
    |> foreign_key_constraint(:user_id)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when key in [:name, :slug, :status, :priority, :description, :summary] ->
        Map.put(acc, key, normalize_text(value))

      {key, value}, acc
      when key in ["name", "slug", "status", "priority", "description", "summary"] ->
        Map.put(acc, key, normalize_text(value))

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp normalize_attrs(attrs), do: attrs

  defp maybe_put_generated_slug(changeset) do
    current_slug =
      changeset
      |> get_field(:slug)
      |> normalize_slug()

    generated_slug =
      changeset
      |> get_field(:name)
      |> normalize_slug()

    cond do
      is_binary(current_slug) and current_slug != "" ->
        put_change(changeset, :slug, current_slug)

      is_binary(generated_slug) and generated_slug != "" ->
        put_change(changeset, :slug, generated_slug)

      true ->
        changeset
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_text(value), do: value

  defp normalize_slug(nil), do: nil

  defp normalize_slug(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp normalize_slug(value), do: value |> to_string() |> normalize_slug()
end
