defmodule Maraithon.Projects.RepoGrant do
  @moduledoc """
  Explicit repo access grant for one project delivery loop.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(github)
  @scopes ~w(read_only branch_write pr_open)
  @statuses ~w(active revoked pending)

  schema "project_repo_grants" do
    field :user_id, :string
    field :granted_by_user_id, :string
    field :provider, :string, default: "github"
    field :repo_full_name, :string
    field :scope, :string
    field :status, :string, default: "active"
    field :granted_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:provider, :repo_full_name, :scope, :status, :granted_at]
  @optional_fields [:metadata]

  def changeset(grant, attrs) do
    attrs = attrs || %{}

    grant
    |> cast(drop_system_fields(attrs), @required_fields ++ @optional_fields)
    |> maybe_put_system_field(attrs, :user_id)
    |> maybe_put_system_field(attrs, :granted_by_user_id)
    |> maybe_put_system_field(attrs, :project_id)
    |> validate_required([:user_id, :granted_by_user_id, :project_id] ++ @required_fields)
    |> validate_inclusion(:provider, @providers)
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:repo_full_name, min: 3, max: 255)
    |> validate_change(:metadata, &validate_map/2)
    |> unique_constraint(:repo_full_name,
      name: :project_repo_grants_project_repo_scope_index
    )
  end

  def scope_order("read_only"), do: 1
  def scope_order("branch_write"), do: 2
  def scope_order("pr_open"), do: 3
  def scope_order(_scope), do: 0

  defp validate_map(field, value) do
    if is_map(value), do: [], else: [{field, "must be a map"}]
  end

  defp drop_system_fields(attrs) do
    Map.drop(attrs, [
      :user_id,
      "user_id",
      :granted_by_user_id,
      "granted_by_user_id",
      :project_id,
      "project_id"
    ])
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
