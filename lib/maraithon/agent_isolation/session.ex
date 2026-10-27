defmodule Maraithon.AgentIsolation.Session do
  @moduledoc """
  Per-agent session state store.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active expired revoked)

  schema "agent_isolation_sessions" do
    belongs_to :agent, Agent

    field :user_id, :string
    field :session_key, :string
    field :status, :string, default: "active"
    field :state, :map, default: %{}
    field :expires_at, :utc_datetime_usec
    field :last_seen_at, :utc_datetime_usec
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :user_id, :session_key, :status]
  @optional_fields [:state, :expires_at, :last_seen_at, :metadata]

  def changeset(session, attrs) do
    session
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:session_key, min: 1, max: 200)
    |> validate_map(:state)
    |> validate_map(:metadata)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:agent_id, :session_key])
    |> normalize_string(:user_id)
    |> normalize_string(:session_key)
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
