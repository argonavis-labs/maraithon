defmodule Maraithon.Runtime.AgentDirective do
  @moduledoc """
  A bounded, idempotent unit of durable demand for one exact Agent owner.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(message channel_ingress connector_sync scheduled_wakeup manual_wake background_job runtime_control)
  @statuses ~w(pending processing completed dead_letter cancelled)

  schema "agent_directives" do
    belongs_to :agent, Agent
    field :user_id, :string
    field :kind, :string
    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext
    field :legacy_payload, :map, source: :payload, default: %{}
    field :payload_encryption_version, :integer
    field :payload_purged_at, :utc_datetime_usec
    field :dedupe_key, :string
    field :request_fingerprint, :binary
    field :status, :string, default: "pending"
    field :available_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :claim_token, Ecto.UUID
    field :claimed_by_generation, Ecto.UUID
    field :claimed_at, :utc_datetime_usec
    field :claim_expires_at, :utc_datetime_usec
    field :processing_started_at, :utc_datetime_usec
    field :terminal_at, :utc_datetime_usec
    field :terminal_claim_token, Ecto.UUID
    field :terminal_by_generation, Ecto.UUID
    field :last_error_code, :string
    field :active_run_id, :binary_id
    field :effect_admitted_at, :utc_datetime_usec
    field :effect_count, :integer, default: 0
    field :ambiguity_code, :string

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  def changeset(directive, attrs) do
    attrs = put_payload_encryption_metadata(attrs)

    directive
    |> cast(attrs, [
      :id,
      :agent_id,
      :user_id,
      :kind,
      :payload,
      :legacy_payload,
      :payload_encryption_version,
      :payload_purged_at,
      :dedupe_key,
      :request_fingerprint,
      :status,
      :available_at,
      :attempts,
      :max_attempts,
      :claim_token,
      :claimed_by_generation,
      :claimed_at,
      :claim_expires_at,
      :processing_started_at,
      :terminal_at,
      :terminal_claim_token,
      :terminal_by_generation,
      :last_error_code,
      :active_run_id,
      :effect_admitted_at,
      :effect_count,
      :ambiguity_code,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :agent_id,
      :user_id,
      :kind,
      :payload,
      :dedupe_key,
      :request_fingerprint,
      :status,
      :available_at,
      :attempts,
      :max_attempts
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:user_id, min: 1, max: 320, count: :bytes)
    |> validate_length(:dedupe_key, min: 1, max: 255, count: :bytes)
    |> validate_length(:request_fingerprint, is: 32, count: :bytes)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_number(:effect_count, greater_than_or_equal_to: 0)
    |> validate_length(:ambiguity_code, min: 1, max: 64, count: :bytes)
    |> validate_format(:ambiguity_code, ~r/^[a-z0-9_]+$/)
    |> validate_payload()
    |> unique_constraint([:agent_id, :dedupe_key])
    |> unique_constraint(:claim_token, name: :agent_directives_claim_token_index)
    |> unique_constraint(:agent_id, name: :agent_directives_one_processing_per_agent_index)
    |> unique_constraint(:terminal_claim_token,
      name: :agent_directives_terminal_claim_token_index
    )
    |> foreign_key_constraint(:agent_id, name: :agent_directives_agent_owner_fkey)
    |> foreign_key_constraint(:active_run_id,
      name: :agent_directives_active_run_owner_fkey
    )
    |> check_constraint(:kind, name: :agent_directives_kind_check)
    |> check_constraint(:status, name: :agent_directives_status_check)
    |> check_constraint(:request_fingerprint, name: :agent_directives_fingerprint_check)
    |> check_constraint(:payload, name: :agent_directives_payload_check)
    |> check_constraint(:attempts, name: :agent_directives_attempts_check)
    |> check_constraint(:attempts, name: :agent_directives_pending_attempts_check)
    |> check_constraint(:claim_token, name: :agent_directives_claim_check)
    |> check_constraint(:terminal_at, name: :agent_directives_terminal_check)
    |> check_constraint(:last_error_code, name: :agent_directives_error_check)
    |> check_constraint(:effect_count, name: :agent_directives_effect_count_check)
    |> check_constraint(:effect_admitted_at,
      name: :agent_directives_effect_boundary_check
    )
    |> check_constraint(:ambiguity_code,
      name: :agent_directives_ambiguity_code_check
    )
  end

  @doc false
  def materialize_legacy_payload(%__MODULE__{} = directive) do
    %{directive | payload: directive.payload || directive.legacy_payload}
  end

  defp put_payload_encryption_metadata(attrs) when is_map(attrs) do
    payload = Map.get(attrs, :payload, Map.get(attrs, "payload"))

    if is_map(payload) and not is_struct(payload) do
      if Map.has_key?(attrs, "payload") do
        attrs
        |> Map.put_new("legacy_payload", payload)
        |> Map.put("payload_encryption_version", 1)
      else
        attrs
        |> Map.put_new(:legacy_payload, payload)
        |> Map.put(:payload_encryption_version, 1)
      end
    else
      attrs
    end
  end

  defp put_payload_encryption_metadata(attrs), do: attrs

  defp validate_payload(changeset) do
    validate_change(changeset, :payload, fn :payload, payload ->
      if is_map(payload) and not is_struct(payload), do: [], else: [payload: "must be an object"]
    end)
  end
end
