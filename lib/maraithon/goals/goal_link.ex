defmodule Maraithon.Goals.GoalLink do
  @moduledoc """
  Typed association between one goal and another Maraithon or source-backed object.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Goals.Goal

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @resource_types ~w(todo person insight brief chat_thread memory source_observation scheduled_task)
  @relationships ~w(supports blocks evidence next_move progress context)
  @sources ~w(manual agent chat system)

  schema "goal_links" do
    field :resource_type, :string
    field :resource_id, :string
    field :relationship, :string
    field :source, :string
    field :confidence, :float
    field :metadata, :map, default: %{}

    belongs_to :goal, Goal
    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:goal_id, :user_id, :resource_type, :resource_id, :relationship, :source]
  @optional_fields [:confidence, :metadata]

  def changeset(goal_link, attrs) do
    goal_link
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:resource_type, @resource_types)
    |> validate_inclusion(:relationship, @relationships)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:resource_id, min: 1, max: 500)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:resource_type)
    |> normalize_string(:resource_id)
    |> normalize_string(:relationship)
    |> normalize_string(:source)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :goal_id, :resource_type, :resource_id, :relationship],
      name: :goal_links_user_goal_resource_relationship_index
    )
  end

  def resource_types, do: @resource_types
  def relationships, do: @relationships
  def sources, do: @sources

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, String.trim(value))
      _other -> changeset
    end
  end
end
