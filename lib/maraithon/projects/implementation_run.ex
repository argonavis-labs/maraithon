defmodule Maraithon.Projects.ImplementationRun do
  @moduledoc """
  Tracked delivery run for accepted project work.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Projects.{Project, RecommendationDecision}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending_plan awaiting_repo_access queued running blocked awaiting_review completed failed)

  schema "project_implementation_runs" do
    field :user_id, :string
    field :repo_full_name, :string
    field :status, :string
    field :branch_name, :string
    field :pull_request_url, :string
    field :result_summary, :string
    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    belongs_to :project, Project
    belongs_to :agent, Agent
    belongs_to :recommendation_decision, RecommendationDecision

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:status, :queued_at]
  @optional_fields [
    :repo_full_name,
    :branch_name,
    :pull_request_url,
    :result_summary,
    :started_at,
    :completed_at,
    :metadata
  ]

  def changeset(run, attrs) do
    attrs = attrs || %{}

    run
    |> cast(drop_system_fields(attrs), @required_fields ++ @optional_fields)
    |> maybe_put_system_field(attrs, :user_id)
    |> maybe_put_system_field(attrs, :project_id)
    |> maybe_put_system_field(attrs, :agent_id)
    |> maybe_put_system_field(attrs, :recommendation_decision_id)
    |> validate_required([:user_id, :project_id, :recommendation_decision_id] ++ @required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:repo_full_name, max: 255)
    |> validate_length(:branch_name, max: 255)
    |> validate_length(:pull_request_url, max: 2_000)
    |> validate_length(:result_summary, max: 6_000)
    |> validate_change(:metadata, &validate_map/2)
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
      :agent_id,
      "agent_id",
      :recommendation_decision_id,
      "recommendation_decision_id"
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
