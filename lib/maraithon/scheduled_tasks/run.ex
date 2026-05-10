defmodule Maraithon.ScheduledTasks.Run do
  @moduledoc """
  Durable run history for user-facing scheduled tasks.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.ScheduledTasks.Task

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed cancelled)

  schema "user_scheduled_task_runs" do
    belongs_to :task, Task

    field :user_id, :string
    field :status, :string, default: "pending"
    field :scheduled_for, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :result, :map, default: %{}
    field :error, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:task_id, :user_id, :status, :scheduled_for]
  @optional_fields [:started_at, :finished_at, :result, :error, :metadata]

  def changeset(run, attrs) do
    run
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:error, max: 4_000)
    |> validate_map(:result)
    |> validate_map(:metadata)
    |> foreign_key_constraint(:task_id)
    |> normalize_string(:user_id)
  end

  def statuses, do: @statuses

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
