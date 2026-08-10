defmodule Maraithon.Runtime.BackgroundJob do
  @moduledoc """
  Durable app-level background job record.

  These jobs are for work that should not block web, Telegram, or agent runtime
  request paths: source ingestion, relationship learning, open-loop refreshes,
  and other user-scoped follow-up work.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload

  @max_payload_bytes 640_000
  @max_result_bytes 256_000
  @payload_bounds [
    max_binary_bytes: 128_000,
    max_depth: 16,
    max_nodes: 20_000,
    max_map_entries: 2_000,
    max_list_items: 4_000
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed cancelled)

  schema "background_jobs" do
    field :user_id, :string
    field :queue, :string, default: "default"
    field :job_type, :string
    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext, redact: true
    field :legacy_payload, :map, source: :payload, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :status, :string, default: "pending"
    field :dedupe_key, :string
    field :partition_key, :string
    field :rate_limit_key, :string
    field :telegram_bot_id, :string
    field :telegram_update_id, :integer
    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :scheduled_at, :utc_datetime_usec
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :claim_token, Ecto.UUID
    field :completed_at, :utc_datetime_usec
    field :failed_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :result, Maraithon.Encrypted.Map, source: :result_ciphertext, redact: true
    field :legacy_result, :map, source: :result, default: %{}, redact: true
    field :last_error, :string
    field :tenant_key, :string
    field :partition_id, :integer
    field :coordination_activation_epoch, Ecto.UUID
    field :coordination_partition_epoch, :integer
    field :coordination_node_incarnation_id, Ecto.UUID
    field :coordination_task_assignment_id, Ecto.UUID
    field :coordination_task_supervisor_id, Ecto.UUID
    field :coordination_local_task_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:queue, :job_type, :scheduled_at]
  @optional_fields [
    :user_id,
    :payload,
    :status,
    :dedupe_key,
    :partition_key,
    :rate_limit_key,
    :telegram_bot_id,
    :telegram_update_id,
    :attempts,
    :max_attempts,
    :claimed_by,
    :claimed_at,
    :completed_at,
    :failed_at,
    :cancelled_at,
    :result,
    :last_error
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "background_jobs",
      identity_fields: [:id],
      scope_fields: [:user_id],
      fields: [:payload, :result],
      purge_field: :payload_purged_at
    }
  end

  def max_payload_bytes, do: @max_payload_bytes
  def max_result_bytes, do: @max_result_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(job, attrs) do
    attrs = put_new_payload_defaults(job, attrs || %{})

    job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:telegram_update_id, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0, less_than_or_equal_to: 25)
    |> normalize_string(:queue)
    |> normalize_string(:job_type)
    |> normalize_string(:user_id)
    |> normalize_string(:dedupe_key)
    |> normalize_string(:partition_key)
    |> normalize_string(:rate_limit_key)
    |> normalize_string(:telegram_bot_id)
    |> DurablePayload.put_bounded_map(:payload, @max_payload_bytes, @payload_bounds)
    |> DurablePayload.put_bounded_map(:result, @max_result_bytes, @payload_bounds)
    |> mirror_legacy_payload(:payload, :legacy_payload)
    |> mirror_legacy_payload(:result, :legacy_result)
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> check_constraint(:telegram_update_id, name: :background_jobs_telegram_order_fields)
    |> foreign_key_constraint(:user_id, name: :background_jobs_user_id_fkey)
    |> unique_constraint(:dedupe_key,
      name: :background_jobs_dedupe_key_index,
      message: "already has an active background job"
    )
    |> unique_constraint(:dedupe_key,
      name: :background_jobs_telegram_webhook_dedupe_index,
      message: "already accepted this Telegram update"
    )
  end

  @doc false
  def hydrate_payloads(job, mode \\ DurablePayload.mode!())

  def hydrate_payloads(%__MODULE__{} = job, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(job, payload_binding_spec(), mode)
    {payload, result} = read_payloads!(job, mode)
    %{job | payload: payload, result: result}
  end

  def hydrate_payloads(other, _mode), do: other

  @doc false
  def read_payloads!(%__MODULE__{payload_purged_at: %DateTime{}} = job, _mode) do
    if is_nil(job.payload) and is_nil(job.result) and job.legacy_payload == %{} and
         job.legacy_result == %{} do
      {%{}, %{}}
    else
      raise ArgumentError, "purged BackgroundJob payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = job, :legacy) do
    payload = job.payload || legacy_map(job.legacy_payload)
    result = job.result || legacy_map(job.legacy_result)

    if json_map?(payload) and json_map?(result) do
      {payload, result}
    else
      raise ArgumentError, "BackgroundJob payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = job, :exact) do
    if job.payload_encryption_version == 1 and json_map?(job.payload) and
         json_map?(job.result) and job.legacy_payload == %{} and job.legacy_result == %{} do
      {job.payload, job.result}
    else
      raise ArgumentError, "exact BackgroundJob payload is not ciphertext-only"
    end
  end

  defp put_new_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:payload, %{})
    |> put_attr_default(:result, %{})
  end

  defp put_new_payload_defaults(_job, attrs), do: attrs

  defp put_attr_default(attrs, field, default) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) or Map.has_key?(attrs, string_field) -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_field, default)
      true -> Map.put(attrs, field, default)
    end
  end

  defp mirror_legacy_payload(changeset, payload_field, legacy_field) do
    case fetch_change(changeset, payload_field) do
      {:ok, payload} ->
        put_change(
          changeset,
          legacy_field,
          if(DurablePayload.legacy_write?(), do: payload, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :payload) or Map.has_key?(changeset.changes, :result),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at &&
         (Map.has_key?(changeset.changes, :payload) or Map.has_key?(changeset.changes, :result)),
       do: put_change(changeset, :payload_purged_at, nil),
       else: changeset
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)

  def statuses, do: @statuses

  defp normalize_string(changeset, field) do
    case get_change(changeset, field) do
      value when is_binary(value) ->
        put_change(changeset, field, String.trim(value))

      _ ->
        changeset
    end
  end
end
