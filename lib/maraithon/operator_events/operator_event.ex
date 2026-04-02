defmodule Maraithon.OperatorEvents.OperatorEvent do
  @moduledoc """
  Durable user-scoped operator event emitted from connected systems and conversations.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @scopes ~w(global project)

  schema "operator_events" do
    field :source, :string
    field :event_type, :string
    field :scope, :string, default: "global"
    field :source_item_id, :string
    field :dedupe_key, :string
    field :occurred_at, :utc_datetime_usec
    field :payload, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string, foreign_key: :user_id
    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :source, :event_type, :scope, :dedupe_key, :occurred_at]
  @optional_fields [:project_id, :source_item_id, :payload, :metadata]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:scope, @scopes)
    |> validate_length(:user_id, min: 3, max: 320)
    |> validate_length(:source, min: 2, max: 100)
    |> validate_length(:event_type, min: 2, max: 160)
    |> validate_length(:source_item_id, max: 255)
    |> validate_length(:dedupe_key, min: 4, max: 255)
    |> validate_change(:payload, fn :payload, value ->
      if is_map(value), do: [], else: [payload: "must be a map"]
    end)
    |> validate_change(:metadata, fn :metadata, value ->
      if is_map(value), do: [], else: [metadata: "must be a map"]
    end)
    |> validate_project_scope()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:dedupe_key, name: :operator_events_user_id_dedupe_key_index)
  end

  defp validate_project_scope(changeset) do
    case {get_field(changeset, :scope), get_field(changeset, :project_id)} do
      {"project", nil} ->
        add_error(changeset, :project_id, "must be present for project-scoped events")

      {"global", project_id} when not is_nil(project_id) ->
        put_change(changeset, :scope, "project")

      _ ->
        changeset
    end
  end
end
