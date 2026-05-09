defmodule Maraithon.Crm.PersonLink do
  @moduledoc """
  Polymorphic link between a CRM person and user-owned Maraithon data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Crm.Person

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "crm_person_links" do
    field :resource_type, :string
    field :resource_id, :string
    field :resource_source, :string
    field :title, :string
    field :summary, :string
    field :relationship_note, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    belongs_to :person, Person, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:resource_type, :resource_id]
  @optional_fields [:resource_source, :title, :summary, :relationship_note, :metadata]

  def changeset(link, attrs) do
    link
    |> cast(normalize_attrs(attrs), @required_fields ++ @optional_fields)
    |> validate_required([:user_id, :person_id] ++ @required_fields)
    |> validate_length(:resource_type, min: 2, max: 80)
    |> validate_length(:resource_id, min: 1, max: 255)
    |> validate_length(:resource_source, max: 120)
    |> validate_length(:title, max: 240)
    |> validate_length(:summary, max: 2_000)
    |> validate_length(:relationship_note, max: 4_000)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> unique_constraint(:resource_id,
      name: :crm_person_links_user_id_person_id_resource_type_resource_id_index
    )
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:person_id)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), normalize_value(key, value))
    end)
    |> normalize_todo_alias()
  end

  defp normalize_attrs(attrs), do: attrs

  defp normalize_todo_alias(%{"todo_id" => todo_id} = attrs) when is_binary(todo_id) do
    attrs
    |> Map.put_new("resource_type", "todo")
    |> Map.put_new("resource_id", String.trim(todo_id))
  end

  defp normalize_todo_alias(attrs), do: attrs

  defp normalize_key(:resourceType), do: "resource_type"
  defp normalize_key(:resourceId), do: "resource_id"
  defp normalize_key(:resourceSource), do: "resource_source"
  defp normalize_key(:relationshipNote), do: "relationship_note"
  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> normalize_key()
  defp normalize_key("resourceType"), do: "resource_type"
  defp normalize_key("resourceId"), do: "resource_id"
  defp normalize_key("resourceSource"), do: "resource_source"
  defp normalize_key("relationshipNote"), do: "relationship_note"
  defp normalize_key("type"), do: "resource_type"
  defp normalize_key("id"), do: "resource_id"
  defp normalize_key("source"), do: "resource_source"
  defp normalize_key("note"), do: "relationship_note"
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: to_string(key)

  defp normalize_value(_key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_value(_key, value), do: value
end
