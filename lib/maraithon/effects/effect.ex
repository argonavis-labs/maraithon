defmodule Maraithon.Effects.Effect do
  @moduledoc """
  Schema for effect outbox records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "effects" do
    field :agent_id, :binary_id
    field :owner_user_id, :string
    field :idempotency_key, :binary_id
    field :effect_type, :string
    field :params, Maraithon.Encrypted.Map, source: :params_ciphertext, redact: true
    field :legacy_params, :map, source: :params, default: %{}
    field :effect_protocol_version, :integer
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :execution_lane, :string
    field :payload_purged_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec

    # `runtime_owner_generation` is Agent lease lineage. `claim_token` is a
    # fresh immutable Effect execution generation; the two are deliberately
    # independent.
    field :runtime_owner_generation, Ecto.UUID
    field :claim_token, Ecto.UUID
    field :claim_owner_node, :string
    field :claim_heartbeat_at, :utc_datetime_usec
    field :claim_expires_at, :utc_datetime_usec
    field :claim_supervisor_id, Ecto.UUID
    field :claim_task_id, Ecto.UUID

    field :cancellation_state, :string
    field :cancellation_reason, :string
    field :cancellation_requested_at, :utc_datetime_usec
    field :cancellation_target_claim_token, Ecto.UUID
    field :cancellation_last_attempt_at, :utc_datetime_usec
    field :cancellation_last_error, :string
    field :cancellation_settled_at, :utc_datetime_usec

    field :completion_claimed_by, :string
    field :completion_claimed_at, :utc_datetime_usec
    field :agent_run_id, :binary_id
    field :agent_run_step_id, :binary_id
    field :result_envelope, :map
    field :result_dispatched_at, :utc_datetime_usec
    field :result_dispatch_after, :utc_datetime_usec
    field :result_dispatch_attempts, :integer, default: 0
    field :result_acknowledged_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :last_failure_code, :string
    field :last_failure_attempt, :integer
    field :retry_after, :utc_datetime_usec
    field :result, Maraithon.Encrypted.Map, source: :result_ciphertext, redact: true
    field :legacy_result, :map, source: :result
    field :error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:id, :agent_id, :idempotency_key, :effect_type]
  @admission_fields [
    :params,
    :legacy_params,
    :effect_protocol_version,
    :payload_encryption_version,
    :execution_lane,
    :owner_user_id,
    :agent_run_id,
    :agent_run_step_id,
    :max_attempts
  ]
  @protocol_fields [
    :params,
    :legacy_params,
    :effect_protocol_version,
    :payload_encryption_version,
    :execution_lane,
    :payload_purged_at,
    :owner_user_id,
    :status,
    :claimed_by,
    :claimed_at,
    :runtime_owner_generation,
    :claim_token,
    :claim_owner_node,
    :claim_heartbeat_at,
    :claim_expires_at,
    :claim_supervisor_id,
    :claim_task_id,
    :cancellation_state,
    :cancellation_reason,
    :cancellation_requested_at,
    :cancellation_target_claim_token,
    :cancellation_last_attempt_at,
    :cancellation_last_error,
    :cancellation_settled_at,
    :completion_claimed_by,
    :completion_claimed_at,
    :agent_run_id,
    :agent_run_step_id,
    :result_envelope,
    :result_dispatched_at,
    :result_dispatch_after,
    :result_dispatch_attempts,
    :result_acknowledged_at,
    :attempts,
    :max_attempts,
    :last_failure_code,
    :last_failure_attempt,
    :retry_after,
    :result,
    :legacy_result,
    :error
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "effects",
      identity_fields: [:id],
      scope_fields: [:owner_user_id, :agent_id],
      fields: [:params, :result],
      purge_field: :payload_purged_at
    }
  end

  @doc """
  Builds an admission changeset.

  Execution authority, claim identity, cancellation state, and terminal outcome
  fields are deliberately not mass-assignable through this public changeset.
  """
  def changeset(effect, attrs) do
    attrs = put_protocol_metadata(attrs)

    effect
    |> cast(attrs, @required_fields ++ @admission_fields)
    |> validate()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
  end

  @doc false
  def protocol_changeset(effect, attrs) do
    attrs = put_protocol_metadata(attrs)

    effect
    |> cast(attrs, @required_fields ++ @protocol_fields)
    |> validate()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
  end

  defp put_protocol_metadata(attrs) when is_map(attrs) do
    params = Map.get(attrs, :params, Map.get(attrs, "params"))
    result_present? = Map.has_key?(attrs, :result) or Map.has_key?(attrs, "result")
    string_keys? = Map.has_key?(attrs, "params") or Map.has_key?(attrs, "result")

    exact_payload? =
      not is_nil(
        Map.get(attrs, :runtime_owner_generation, Map.get(attrs, "runtime_owner_generation"))
      )

    legacy_params = if exact_payload?, do: %{"redacted" => true}, else: params

    attrs =
      if is_map(params) and not is_struct(params) do
        if string_keys? do
          attrs
          |> Map.put_new(
            "effect_protocol_version",
            Map.get(params, "__maraithon_effect_protocol")
          )
          |> Map.put_new("execution_lane", Map.get(params, "__maraithon_execution_lane"))
          |> Map.put("payload_encryption_version", 1)
          |> Map.put_new("legacy_params", legacy_params)
        else
          attrs
          |> Map.put_new(
            :effect_protocol_version,
            Map.get(params, "__maraithon_effect_protocol")
          )
          |> Map.put_new(:execution_lane, Map.get(params, "__maraithon_execution_lane"))
          |> Map.put(:payload_encryption_version, 1)
          |> Map.put_new(:legacy_params, legacy_params)
        end
      else
        attrs
      end

    if result_present? do
      Map.put_new(
        attrs,
        if(string_keys?, do: "legacy_result", else: :legacy_result),
        if(exact_payload?, do: nil, else: Map.get(attrs, :result, Map.get(attrs, "result")))
      )
    else
      attrs
    end
  end

  defp put_protocol_metadata(attrs), do: attrs

  @doc false
  def materialize_legacy_payload(%__MODULE__{} = effect) do
    :ok = DurablePayload.verify_binding!(effect, payload_binding_spec())

    %{
      effect
      | params: effect.params || effect.legacy_params,
        result: effect.result || effect.legacy_result
    }
  end

  @doc false
  def result_payload(%__MODULE__{} = effect) do
    :ok = DurablePayload.verify_binding!(effect, payload_binding_spec())
    effect.result || effect.legacy_result
  end

  defp validate(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, [
      "pending",
      "claimed",
      "cancelling",
      "completed",
      "failed",
      "cancelled"
    ])
    |> validate_inclusion(:cancellation_state, ["requested", "settled"])
    |> validate_length(:claim_owner_node, min: 1, max: 255, count: :bytes)
    |> validate_length(:cancellation_reason, min: 1, max: 255, count: :bytes)
    |> validate_length(:cancellation_last_error, min: 1, max: 255, count: :bytes)
    |> unique_constraint(:idempotency_key)
    |> unique_constraint(:claim_token, name: :effects_claim_token_unique_index)
    |> unique_constraint([:claim_owner_node, :claim_supervisor_id, :claim_task_id],
      name: :effects_physical_task_identity_unique_index
    )
    |> check_constraint(:runtime_owner_generation,
      name: :effects_generation_fenced_shape_check
    )
  end
end
