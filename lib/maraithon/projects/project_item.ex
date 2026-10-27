defmodule Maraithon.Projects.ProjectItem do
  @moduledoc """
  Project-local memory items such as notes, todos, decisions, resources, and grants.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @item_types ~w(note todo decision resource grant)
  @statuses ~w(active done archived)
  @sources ~w(manual agent connector)

  schema "project_items" do
    field :user_id, :string
    field :item_type, :string, default: "note"
    field :title, :string
    field :content, :string
    field :status, :string, default: "active"
    field :source, :string, default: "manual"
    field :metadata, :map, default: %{}

    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:item_type, :content]
  @optional_fields [:title, :status, :source, :metadata]

  def changeset(item, attrs) do
    item
    |> cast(normalize_attrs(attrs), @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:item_type, @item_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:title, max: 200)
    |> validate_length(:content, min: 2, max: 8_000)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
  end

  def item_types, do: @item_types

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.drop(attrs, [:user_id, "user_id", :project_id, "project_id"])
  end

  defp normalize_attrs(attrs), do: attrs
end
