defmodule Maraithon.Projects.RecommendationDecision do
  @moduledoc """
  Durable user decision for one project recommendation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Insights.Insight
  alias Maraithon.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @decisions ~w(accepted rejected deferred)

  schema "project_recommendation_decisions" do
    field :user_id, :string
    field :decision, :string
    field :decision_note, :string
    field :accepted_plan, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    belongs_to :source_insight, Insight

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:decision]
  @optional_fields [:decision_note, :accepted_plan, :metadata]

  def changeset(decision, attrs) do
    attrs = attrs || %{}

    decision
    |> cast(drop_system_fields(attrs), @required_fields ++ @optional_fields)
    |> maybe_put_system_field(attrs, :user_id)
    |> maybe_put_system_field(attrs, :project_id)
    |> maybe_put_system_field(attrs, :source_insight_id)
    |> validate_required([:user_id, :project_id, :source_insight_id] ++ @required_fields)
    |> validate_inclusion(:decision, @decisions)
    |> validate_length(:decision_note, max: 4_000)
    |> validate_change(:accepted_plan, &validate_map/2)
    |> validate_change(:metadata, &validate_map/2)
    |> unique_constraint(:source_insight_id,
      name: :project_recommendation_decisions_user_id_source_insight_id_index
    )
  end

  defp validate_map(field, value) do
    if is_map(value), do: [], else: [{field, "must be a map"}]
  end

  defp drop_system_fields(attrs) do
    Map.drop(attrs, [
      :user_id,
      "user_id",
      :project_id,
      "project_id",
      :source_insight_id,
      "source_insight_id"
    ])
  end

  defp maybe_put_system_field(changeset, attrs, field) do
    case fetch_system_field(attrs, field) do
      {:present, value} -> put_change(changeset, field, normalize_optional_string(value))
      :missing -> changeset
    end
  end

  defp fetch_system_field(attrs, field) when is_map(attrs) do
    string_key = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> {:present, Map.get(attrs, field)}
      Map.has_key?(attrs, string_key) -> {:present, Map.get(attrs, string_key)}
      true -> :missing
    end
  end

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_optional_string(value), do: value
end
