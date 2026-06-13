defmodule Maraithon.Goals.ReviewRun do
  @moduledoc """
  Durable audit record for scheduled or on-demand goal alignment reviews.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Goals.Goal

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @triggers ~w(scheduled manual chat briefing system)
  @statuses ~w(running completed failed partial)

  schema "goal_review_runs" do
    field :trigger, :string
    field :status, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :source_summary, :map, default: %{}
    field :result, :map, default: %{}
    field :error, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :goal, Goal
    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :trigger, :status, :started_at]
  @optional_fields [:goal_id, :finished_at, :source_summary, :result, :error, :metadata]

  def changeset(review_run, attrs) do
    review_run
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:trigger, @triggers)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_map(:source_summary)
    |> validate_map(:result)
    |> validate_map(:error)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:trigger)
    |> normalize_string(:status)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:user_id)
  end

  def triggers, do: @triggers
  def statuses, do: @statuses

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
