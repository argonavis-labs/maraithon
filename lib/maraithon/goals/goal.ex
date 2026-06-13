defmodule Maraithon.Goals.Goal do
  @moduledoc """
  Durable user-scoped outcome or direction used by Maraithon's Chief of Staff loops.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Goals.{GoalLink, ProgressUpdate, ReviewRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ~w(work person health_fitness life)
  @statuses ~w(active paused achieved archived)
  @sensitivities ~w(standard sensitive private)
  @proactive_visibilities ~w(full summary none)
  @review_cadences ~w(daily weekly monthly manual)

  schema "goals" do
    field :category, :string
    field :status, :string, default: "active"
    field :title, :string
    field :desired_outcome, :string
    field :why, :string
    field :success_metric, :string
    field :priority, :integer, default: 50
    field :sensitivity, :string, default: "standard"
    field :proactive_visibility, :string, default: "summary"
    field :review_cadence, :string, default: "weekly"
    field :starts_on, :date
    field :target_at, :utc_datetime_usec
    field :last_reviewed_at, :utc_datetime_usec
    field :next_review_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    has_many :progress_updates, ProgressUpdate
    has_many :links, GoalLink
    has_many :review_runs, ReviewRun

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :category,
    :status,
    :title,
    :desired_outcome,
    :priority,
    :sensitivity,
    :proactive_visibility,
    :review_cadence
  ]
  @optional_fields [
    :why,
    :success_metric,
    :starts_on,
    :target_at,
    :last_reviewed_at,
    :next_review_at,
    :metadata
  ]

  def changeset(goal, attrs) do
    goal
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:sensitivity, @sensitivities)
    |> validate_inclusion(:proactive_visibility, @proactive_visibilities)
    |> validate_inclusion(:review_cadence, @review_cadences)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:title, min: 4, max: 240)
    |> validate_length(:desired_outcome, min: 8, max: 2_000)
    |> validate_length(:why, max: 2_000)
    |> validate_length(:success_metric, max: 2_000)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:category)
    |> normalize_string(:status)
    |> normalize_string(:title)
    |> normalize_string(:desired_outcome)
    |> normalize_string(:why)
    |> normalize_string(:success_metric)
    |> normalize_string(:sensitivity)
    |> normalize_string(:proactive_visibility)
    |> normalize_string(:review_cadence)
    |> foreign_key_constraint(:user_id)
  end

  def categories, do: @categories
  def statuses, do: @statuses
  def sensitivities, do: @sensitivities
  def proactive_visibilities, do: @proactive_visibilities
  def review_cadences, do: @review_cadences

  defp validate_map(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_map(value), do: [], else: [{field, "must be a map"}]
    end)
  end

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) ->
        normalized = String.trim(value)

        if normalized == "" and field in [:why, :success_metric] do
          put_change(changeset, field, nil)
        else
          put_change(changeset, field, normalized)
        end

      _other ->
        changeset
    end
  end
end
