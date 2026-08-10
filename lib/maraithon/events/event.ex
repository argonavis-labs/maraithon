defmodule Maraithon.Events.Event do
  @moduledoc """
  Schema for event records.

  New payloads are stored in the additive ciphertext column. The legacy JSONB
  column remains readable during the staged data migration and is never used
  when ciphertext is present.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload
  alias Maraithon.DurablePayloadBinding

  @foreign_key_type :binary_id

  @max_payload_bytes 640_000
  @max_payload_binary_bytes 512_000
  @max_spend_cost 1_000_000_000.0
  @max_spend_cost_integer 1_000_000_000
  @max_token_count 9_223_372_036_854_775_807

  schema "events" do
    field :agent_id, :binary_id
    field :sequence_num, :integer
    field :event_type, :string

    field :payload, Maraithon.Encrypted.Map,
      source: :payload_ciphertext,
      redact: true

    field :legacy_payload, :map, source: :payload, default: %{}, redact: true
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :spend_total_cost, :float
    field :spend_input_tokens, :integer
    field :spend_output_tokens, :integer
    field :spend_llm_calls, :integer
    field :idempotency_key, :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:agent_id, :sequence_num, :event_type]
  @optional_fields [:payload, :idempotency_key]

  def changeset(event, attrs) do
    attrs = put_new_payload_default(event, attrs || %{})

    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> DurablePayload.put_bounded_map(:payload, @max_payload_bytes,
      max_binary_bytes: @max_payload_binary_bytes,
      max_depth: 12,
      max_nodes: 20_000,
      max_map_entries: 2_000,
      max_list_items: 2_000
    )
    |> mirror_legacy_payload()
    |> put_spend_facts()
    |> put_payload_binding()
  end

  @doc false
  def read_payload!(%__MODULE__{} = event) do
    case {event.payload_purged_at, event.payload, event.legacy_payload} do
      {%DateTime{}, nil, legacy} when legacy == %{} ->
        %{}

      {nil, payload, _legacy} when is_map(payload) and not is_struct(payload) ->
        payload

      {nil, nil, legacy} when is_map(legacy) and not is_struct(legacy) ->
        legacy

      _invalid_or_inconsistent ->
        raise ArgumentError, "event payload is corrupt or inconsistent"
    end
  end

  @doc false
  def hydrate_payload!(%__MODULE__{} = event), do: %{event | payload: read_payload!(event)}

  defp mirror_legacy_payload(changeset) do
    case fetch_change(changeset, :payload) do
      {:ok, payload} ->
        changeset = put_change(changeset, :payload_encryption_version, 1)

        if DurablePayload.legacy_write?(),
          do: put_change(changeset, :legacy_payload, payload),
          else: changeset

      :error ->
        changeset
    end
  end

  defp put_new_payload_default(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :payload) or Map.has_key?(attrs, "payload") -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, "payload", %{})
      true -> Map.put(attrs, :payload, %{})
    end
  end

  defp put_new_payload_default(_event, attrs), do: attrs

  defp put_payload_binding(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp put_payload_binding(changeset) do
    agent_id = get_field(changeset, :agent_id)
    sequence_num = get_field(changeset, :sequence_num)
    payload = get_field(changeset, :payload)
    purged_at = get_field(changeset, :payload_purged_at)

    cond do
      not is_nil(purged_at) and is_nil(payload) ->
        changeset
        |> put_change(:payload_binding_version, nil)
        |> put_change(:payload_binding_key_tag, nil)
        |> put_change(:payload_binding_mac, nil)

      is_binary(agent_id) and is_integer(sequence_num) and is_map(payload) ->
        row_identity = agent_id <> ":" <> Integer.to_string(sequence_num)

        binding =
          DurablePayloadBinding.sign(
            "events",
            row_identity,
            agent_id,
            [{"payload", payload}]
          )

        changeset
        |> put_change(:payload_binding_version, binding.version)
        |> put_change(:payload_binding_key_tag, binding.key_tag)
        |> put_change(:payload_binding_mac, binding.mac)

      true ->
        changeset
    end
  end

  defp put_spend_facts(changeset) do
    facts = spend_facts(get_field(changeset, :event_type), get_field(changeset, :payload))

    Enum.reduce(facts, changeset, fn {field, value}, changeset ->
      put_change(changeset, field, value)
    end)
  end

  defp spend_facts("effect_completed", payload) when is_map(payload) do
    case payload |> Map.get("result") |> usage_map() do
      usage when is_map(usage) ->
        %{
          spend_total_cost: bounded_cost(Map.get(usage, "total_cost")),
          spend_input_tokens: bounded_tokens(Map.get(usage, "input_tokens")),
          spend_output_tokens: bounded_tokens(Map.get(usage, "output_tokens")),
          spend_llm_calls: 1
        }

      nil ->
        empty_spend_facts()
    end
  end

  defp spend_facts(_event_type, _payload), do: empty_spend_facts()

  defp empty_spend_facts do
    %{
      spend_total_cost: 0.0,
      spend_input_tokens: 0,
      spend_output_tokens: 0,
      spend_llm_calls: 0
    }
  end

  defp usage_map(result) when is_map(result) do
    case Map.get(result, "usage") do
      usage when is_map(usage) and not is_struct(usage) -> usage
      _invalid -> nil
    end
  end

  defp usage_map(_result), do: nil

  defp bounded_cost(value)
       when is_integer(value) and value >= 0 and value <= @max_spend_cost_integer,
       do: value * 1.0

  defp bounded_cost(value)
       when is_float(value) and value >= 0.0 and value <= @max_spend_cost,
       do: value

  defp bounded_cost(_value), do: 0.0

  defp bounded_tokens(value)
       when is_integer(value) and value >= 0 and value <= @max_token_count,
       do: value

  defp bounded_tokens(_value), do: 0
end
