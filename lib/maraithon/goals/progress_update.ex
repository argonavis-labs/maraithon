defmodule Maraithon.Goals.ProgressUpdate do
  @moduledoc """
  Append-only progress, risk, or review note for one user goal.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.Goals.Goal

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @sources ~w(manual agent briefing chat system)
  @progress_states ~w(on_track at_risk blocked stale achieved unknown)

  schema "goal_progress_updates" do
    field :source, :string
    field :summary, :string
    field :progress_state, :string
    field :confidence, :float
    field :evidence, :map, default: %{}
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime_usec

    belongs_to :goal, Goal
    belongs_to :user, User, type: :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:goal_id, :user_id, :source, :summary, :progress_state, :occurred_at]
  @optional_fields [:confidence, :evidence, :metadata]

  def changeset(progress_update, attrs) do
    progress_update
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:progress_state, @progress_states)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:summary, min: 4, max: 2_000)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_map(:evidence)
    |> validate_map(:metadata)
    |> normalize_string(:user_id)
    |> normalize_string(:source)
    |> normalize_string(:summary)
    |> normalize_string(:progress_state)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:user_id)
  end

  def progress_states, do: @progress_states
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
