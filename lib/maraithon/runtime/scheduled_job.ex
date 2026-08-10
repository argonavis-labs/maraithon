defmodule Maraithon.Runtime.ScheduledJob do
  @moduledoc """
  Schema for scheduled job records.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload

  @max_payload_bytes 160_000
  @payload_bounds [
    max_binary_bytes: 64_000,
    max_depth: 12,
    max_nodes: 8_000,
    max_map_entries: 1_000,
    max_list_items: 2_000
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "scheduled_jobs" do
    field :agent_id, :binary_id
    field :job_type, :string
    field :fire_at, :utc_datetime_usec
    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext, redact: true
    field :legacy_payload, :map, source: :payload, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :payload_scope_key, :string
    field :payload_scope_value, :string
    field :payload_dedupe_key, :string
    field :payload_empty, :boolean
    field :status, :string, default: "pending"
    field :claimed_by, :string
    field :claimed_at, :utc_datetime_usec
    field :attempts, :integer, default: 0
    field :dispatched_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec
    field :tenant_key, :string
    field :partition_id, :integer
    field :dispatch_token, Ecto.UUID
    field :coordination_activation_epoch, Ecto.UUID
    field :coordination_partition_epoch, :integer
    field :coordination_node_incarnation_id, Ecto.UUID

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:agent_id, :job_type, :fire_at]
  @optional_fields [
    :payload,
    :payload_scope_key,
    :payload_scope_value,
    :status,
    :claimed_by,
    :claimed_at,
    :attempts,
    :dispatched_at,
    :delivered_at
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "scheduled_jobs",
      identity_fields: [:id],
      scope_fields: [:agent_id],
      fields: [:payload],
      purge_field: :payload_purged_at
    }
  end

  def max_payload_bytes, do: @max_payload_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(job, attrs) do
    attrs = put_new_payload_default(job, attrs || %{})

    job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["pending", "dispatched", "delivered", "cancelled", "failed"])
    |> DurablePayload.put_bounded_map(:payload, @max_payload_bytes, @payload_bounds)
    |> validate_length(:payload_scope_key, min: 1, max: 255)
    |> validate_length(:payload_scope_value, min: 1, max: 255)
    |> validate_scope_pair()
    |> promote_payload_facts()
    |> mirror_legacy_payload()
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
  end

  @doc false
  def hydrate_payload(job, mode \\ DurablePayload.mode!())

  def hydrate_payload(%__MODULE__{} = job, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(job, payload_binding_spec(), mode)
    %{job | payload: read_payload!(job, mode)}
  end

  def hydrate_payload(other, _mode), do: other

  @doc false
  def read_payload!(%__MODULE__{payload_purged_at: %DateTime{}} = job, _mode) do
    if is_nil(job.payload) and job.legacy_payload == %{} do
      %{}
    else
      raise ArgumentError, "purged ScheduledJob payload is corrupt or inconsistent"
    end
  end

  def read_payload!(%__MODULE__{} = job, :legacy) do
    case job.payload || legacy_map(job.legacy_payload) do
      payload when is_map(payload) and not is_struct(payload) -> payload
      _invalid -> raise ArgumentError, "ScheduledJob payload is corrupt or inconsistent"
    end
  end

  def read_payload!(%__MODULE__{} = job, :exact) do
    if job.payload_encryption_version == 1 and is_map(job.payload) and
         not is_struct(job.payload) and job.legacy_payload == %{} and
         is_boolean(job.payload_empty) do
      job.payload
    else
      raise ArgumentError, "exact ScheduledJob payload is not ciphertext-only"
    end
  end

  defp put_new_payload_default(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :payload) or Map.has_key?(attrs, "payload") -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, "payload", %{})
      true -> Map.put(attrs, :payload, %{})
    end
  end

  defp put_new_payload_default(_job, attrs), do: attrs

  defp validate_scope_pair(changeset) do
    case {get_field(changeset, :payload_scope_key), get_field(changeset, :payload_scope_value)} do
      {nil, nil} -> changeset
      {key, value} when is_binary(key) and is_binary(value) -> changeset
      _invalid -> add_error(changeset, :payload_scope_key, "must accompany payload_scope_value")
    end
  end

  defp promote_payload_facts(changeset) do
    case fetch_change(changeset, :payload) do
      {:ok, payload} when is_map(payload) ->
        changeset
        |> put_change(:payload_empty, payload == %{})
        |> put_change(:payload_dedupe_key, bounded_string(Map.get(payload, "dedupe_key"), 255))

      _missing ->
        changeset
    end
  end

  defp mirror_legacy_payload(changeset) do
    case fetch_change(changeset, :payload) do
      {:ok, payload} ->
        put_change(
          changeset,
          :legacy_payload,
          if(DurablePayload.legacy_write?(), do: payload, else: %{})
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :payload),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at && Map.has_key?(changeset.changes, :payload),
      do: put_change(changeset, :payload_purged_at, nil),
      else: changeset
  end

  defp bounded_string(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.valid?(value) and byte_size(value) <= max_bytes,
      do: value,
      else: nil
  end

  defp bounded_string(_value, _max_bytes), do: nil
  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
end
