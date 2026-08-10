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
    field :consent_token, Ecto.UUID
    field :consent_actor_id, :string
    field :consented_at, :utc_datetime_usec
    field :consent_digest, :binary

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
    :metadata,
    :consent_token,
    :consent_actor_id,
    :consented_at,
    :consent_digest
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
    |> validate_activation_consent()
    |> validate_length(:consent_actor_id, min: 1, max: 320)
    |> validate_length(:consent_digest, is: 32, count: :bytes)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint(:agent_id)
    |> unique_constraint([:user_id, :identity_key])
    |> unique_constraint(:consent_token, name: :agent_isolation_bindings_consent_token_index)
    |> check_constraint(:consent_token, name: :agent_isolation_bindings_consent_proof_check)
    |> normalize_string(:user_id)
    |> normalize_string(:identity_key)
  end

  def statuses, do: @statuses

  defp validate_activation_consent(changeset) do
    status = get_field(changeset, :status)
    original_status = changeset.data.status

    activation? =
      status == "active" and (is_nil(changeset.data.id) or original_status != "active")

    authority_change? =
      status == "active" and
        Enum.any?(
          ~w(identity_key credential_refs connector_scope memory_scope tool_policy routing_bindings)a,
          &Map.has_key?(changeset.changes, &1)
        )

    proof_refresh? =
      status == "active" and
        Enum.any?(
          ~w(consent_token consent_actor_id consented_at consent_digest)a,
          &Map.has_key?(changeset.changes, &1)
        )

    if activation? or authority_change? or proof_refresh? do
      required = [:consent_token, :consent_actor_id, :consented_at, :consent_digest]
      changeset = validate_required(changeset, required)

      fresh_token_required? =
        (activation? and not is_nil(changeset.data.id)) or authority_change? or proof_refresh?

      changeset =
        if fresh_token_required? and is_nil(get_change(changeset, :consent_token)) do
          add_error(changeset, :consent_token, "must be renewed with the consent proof")
        else
          changeset
        end

      if get_field(changeset, :consent_actor_id) == get_field(changeset, :user_id) do
        changeset
      else
        add_error(changeset, :consent_actor_id, "must match the Binding user")
      end
    else
      changeset
    end
  end

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
