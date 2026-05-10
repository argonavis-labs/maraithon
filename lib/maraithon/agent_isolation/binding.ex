defmodule Maraithon.AgentIsolation.Binding do
  @moduledoc """
  Per-agent identity, credential scope, memory scope, routing, and tool policy.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.AgentIsolation.Session

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active paused revoked)

  schema "agent_isolation_bindings" do
    belongs_to :agent, Agent

    field :user_id, :string
    field :identity_key, :string
    field :status, :string, default: "active"
    field :credential_refs, :map, default: %{}
    field :connector_scope, :map, default: %{}
    field :memory_scope, :map, default: %{}
    field :tool_policy, :map, default: %{}
    field :routing_bindings, :map, default: %{}
    field :metadata, :map, default: %{}

    has_many :sessions, Session, foreign_key: :agent_id, references: :agent_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_id, :user_id, :identity_key, :status]
  @optional_fields [
    :credential_refs,
    :connector_scope,
    :memory_scope,
    :tool_policy,
    :routing_bindings,
    :metadata
  ]

  def changeset(binding, attrs) do
    binding
    |> cast(attrs || %{}, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320)
    |> validate_length(:identity_key, min: 1, max: 200)
    |> validate_map(:credential_refs)
    |> validate_map(:connector_scope)
    |> validate_map(:memory_scope)
    |> validate_map(:tool_policy)
    |> validate_map(:routing_bindings)
    |> validate_map(:metadata)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:agent_id)
    |> unique_constraint([:user_id, :identity_key])
    |> normalize_string(:user_id)
    |> normalize_string(:identity_key)
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
