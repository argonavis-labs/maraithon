defmodule Maraithon.Memory.Event do
  @moduledoc """
  Audit trail for durable memory changes and recall usage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Memory.Item

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :string

  @event_types ~w(written updated recalled archived superseded rejected feedback_recorded confidence_updated)

  schema "memory_events" do
    field :event_type, :string
    field :source, :string, default: "system"
    field :payload, :map, default: %{}

    belongs_to :user, User, type: :string
    belongs_to :memory, Item, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :event_type, :source]
  @optional_fields [:memory_id, :payload]
  @all_fields @required_fields ++ @optional_fields
  @known_string_keys Map.new(@all_fields, &{Atom.to_string(&1), &1})

  def changeset(event, attrs) do
    event
    |> cast(normalize_attrs(attrs), @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_length(:source, min: 2, max: 120)
    |> validate_change(:payload, fn :payload, value ->
      if is_map(value), do: [], else: [payload: "must be a map"]
    end)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:memory_id)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case Map.fetch(@known_string_keys, key) do
          {:ok, field} -> Map.put(acc, field, value)
          :error -> acc
        end

      {key, value}, acc when is_atom(key) ->
        if key in @all_fields, do: Map.put(acc, key, value), else: acc

      _other, acc ->
        acc
    end)
  end

  defp normalize_attrs(_attrs), do: %{}
end
