defmodule Maraithon.TelegramAssistant.Step do
  @moduledoc """
  Persisted step within a Telegram assistant run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload
  alias Maraithon.TelegramAssistant.Run

  @max_request_payload_bytes 256_000
  @max_response_payload_bytes 640_000
  @payload_bounds [
    max_binary_bytes: 128_000,
    max_depth: 16,
    max_nodes: 20_000,
    max_map_entries: 2_000,
    max_list_items: 4_000
  ]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @step_types ~w(llm_request llm_response context_fetch tool_call agent_query prepared_action telegram_send telegram_edit push_decision)
  @statuses ~w(running completed failed skipped)

  schema "telegram_assistant_steps" do
    field :sequence, :integer
    field :step_type, :string
    field :status, :string

    field :request_payload, Maraithon.Encrypted.Map,
      source: :request_payload_ciphertext,
      redact: true

    field :legacy_request_payload, :map,
      source: :request_payload,
      default: %{},
      redact: true

    field :response_payload, Maraithon.Encrypted.Map,
      source: :response_payload_ciphertext,
      redact: true

    field :legacy_response_payload, :map,
      source: :response_payload,
      default: %{},
      redact: true

    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:run_id, :sequence, :step_type, :status, :request_payload, :started_at]
  @optional_fields [:response_payload, :error, :finished_at]

  @doc false
  def payload_binding_spec do
    %{
      table: "telegram_assistant_steps",
      identity_fields: [:id],
      scope_fields: [:run_id],
      fields: [:request_payload, :response_payload],
      purge_field: :payload_purged_at
    }
  end

  def max_request_payload_bytes, do: @max_request_payload_bytes
  def max_response_payload_bytes, do: @max_response_payload_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(step, attrs) do
    attrs = put_new_payload_defaults(step, attrs || %{})

    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:sequence, greater_than: 0)
    |> validate_inclusion(:step_type, @step_types)
    |> validate_inclusion(:status, @statuses)
    |> DurablePayload.put_bounded_map(
      :request_payload,
      @max_request_payload_bytes,
      @payload_bounds
    )
    |> DurablePayload.put_bounded_map(
      :response_payload,
      @max_response_payload_bytes,
      @payload_bounds
    )
    |> mirror_legacy_payload(:request_payload, :legacy_request_payload)
    |> mirror_legacy_payload(:response_payload, :legacy_response_payload)
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :sequence])
    |> unique_constraint(:id, name: :telegram_assistant_steps_pkey)
  end

  @doc false
  def hydrate_payloads(step, mode \\ DurablePayload.mode!())

  def hydrate_payloads(%__MODULE__{} = step, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(step, payload_binding_spec(), mode)
    {request, response} = read_payloads!(step, mode)
    %{step | request_payload: request, response_payload: response}
  end

  def hydrate_payloads(other, _mode), do: other

  @doc false
  def read_payloads!(%__MODULE__{payload_purged_at: %DateTime{}} = step, _mode) do
    if is_nil(step.request_payload) and is_nil(step.response_payload) and
         step.legacy_request_payload == %{} and step.legacy_response_payload == %{} do
      {%{}, %{}}
    else
      raise ArgumentError, "purged assistant Step payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = step, :legacy) do
    request = step.request_payload || legacy_map(step.legacy_request_payload)
    response = step.response_payload || legacy_map(step.legacy_response_payload)

    if json_map?(request) and json_map?(response) do
      {request, response}
    else
      raise ArgumentError, "assistant Step payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = step, :exact) do
    if step.payload_encryption_version == 1 and json_map?(step.request_payload) and
         json_map?(step.response_payload) and step.legacy_request_payload == %{} and
         step.legacy_response_payload == %{} do
      {step.request_payload, step.response_payload}
    else
      raise ArgumentError, "exact assistant Step payload is not ciphertext-only"
    end
  end

  defp put_new_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:request_payload, %{})
    |> put_attr_default(:response_payload, %{})
  end

  defp put_new_payload_defaults(_step, attrs), do: attrs

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
    if Map.has_key?(changeset.changes, :request_payload) or
         Map.has_key?(changeset.changes, :response_payload) do
      put_change(changeset, :payload_encryption_version, 1)
    else
      changeset
    end
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at &&
         (Map.has_key?(changeset.changes, :request_payload) or
            Map.has_key?(changeset.changes, :response_payload)) do
      put_change(changeset, :payload_purged_at, nil)
    else
      changeset
    end
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
end
