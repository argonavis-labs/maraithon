defmodule Maraithon.ScheduledTasks.Task do
  @moduledoc """
  User-facing scheduled task definition.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.ScheduledTasks.Run

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active paused cancelled)
  @sources ~w(api telegram system)

  schema "user_scheduled_tasks" do
    field :user_id, :string
    field :title, :string
    field :description, :string
    field :schedule, :map, default: %{}
    field :timezone, :string, default: "Etc/UTC"
    field :status, :string, default: "active"
    field :command, :map, default: %{}
    field :failure_destination, :map, default: %{}
    field :source, :string, default: "api"
    field :metadata, :map, default: %{}
    field :last_run_at, :utc_datetime_usec
    field :next_run_at, :utc_datetime_usec

    has_many :runs, Run

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :title, :schedule, :timezone, :status, :command, :source]
  @optional_fields [
    :description,
    :failure_destination,
    :metadata,
    :last_run_at,
    :next_run_at
  ]

  def changeset(task, attrs) do
    task
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:title, min: 1, max: 200)
    |> validate_length(:description, max: 2_000)
    |> validate_length(:timezone, min: 3, max: 80)
    |> validate_map(:schedule)
    |> validate_map(:command)
    |> validate_map(:failure_destination)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:title)
    |> normalize_string(:timezone)
    |> normalize_string(:source)
  end

  def statuses, do: @statuses
  def sources, do: @sources

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) -> put_change(changeset, field, String.trim(value))
      _ -> changeset
    end
  end
end
