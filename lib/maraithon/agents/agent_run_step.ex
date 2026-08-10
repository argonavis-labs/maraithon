defmodule Maraithon.Agents.AgentRunStep do
  @moduledoc """
  Durable record for a single effect/tool/model step within an agent run.

  Request and response payloads use additive encrypted columns. The legacy
  JSONB columns are read only as a staged-migration fallback when ciphertext is
  absent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Agents.Agent
  alias Maraithon.Agents.AgentRun
  alias Maraithon.DurablePayload

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @max_request_payload_bytes 256_000
  @max_request_binary_bytes 192_000
  @max_response_payload_bytes 640_000
  @max_response_binary_bytes 512_000

  schema "agent_run_steps" do
    field :sequence, :integer
    field :step_type, :string
    field :status, :string
    field :tool_name, :string
    field :effect_type, :string
    field :resolved_model, :string
    field :intelligence, :string
    field :finish_reason, :string
    field :generation_mode, :string

    field :request_payload, Maraithon.Encrypted.Map,
      source: :request_payload_ciphertext,
      redact: true

    field :response_payload, Maraithon.Encrypted.Map,
      source: :response_payload_ciphertext,
      redact: true

    field :legacy_request_payload, :map,
      source: :request_payload,
      default: %{},
      redact: true

    field :legacy_response_payload, :map,
      source: :response_payload,
      default: %{},
      redact: true

    field :payload_purged_at, :utc_datetime_usec
    field :error, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    belongs_to :agent_run, AgentRun
    belongs_to :agent, Agent

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:agent_run_id, :agent_id, :sequence, :step_type, :status, :started_at]
  @optional_fields [
    :tool_name,
    :effect_type,
    :resolved_model,
    :intelligence,
    :finish_reason,
    :generation_mode,
    :request_payload,
    :response_payload,
    :error,
    :completed_at
  ]

  def changeset(step, attrs) do
    attrs = put_new_payload_defaults(step, attrs || %{})

    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, ["requested", "completed", "failed"])
    |> DurablePayload.put_bounded_map(:request_payload, @max_request_payload_bytes,
      max_binary_bytes: @max_request_binary_bytes,
      max_depth: 12,
      max_nodes: 20_000,
      max_map_entries: 2_000,
      max_list_items: 2_000
    )
    |> DurablePayload.put_bounded_map(:response_payload, @max_response_payload_bytes,
      max_binary_bytes: @max_response_binary_bytes,
      max_depth: 12,
      max_nodes: 20_000,
      max_map_entries: 2_000,
      max_list_items: 2_000
    )
    |> foreign_key_constraint(:agent_run_id)
    |> foreign_key_constraint(:agent_id)
    |> unique_constraint([:agent_run_id, :sequence])
  end

  defp put_new_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:request_payload, %{})
    |> put_attr_default(:response_payload, %{})
  end

  defp put_new_payload_defaults(_step, attrs), do: attrs

  defp put_attr_default(attrs, field, default) do
    if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
      do: attrs,
      else: Map.put(attrs, field, default)
  end

  @doc false
  def prepare_response_payload(value) do
    DurablePayload.prepare_map(value, @max_response_payload_bytes,
      max_binary_bytes: @max_response_binary_bytes,
      max_depth: 12,
      max_nodes: 20_000,
      max_map_entries: 2_000,
      max_list_items: 2_000
    )
  end

  @doc false
  def read_payloads!(%__MODULE__{} = step) do
    case {
      step.payload_purged_at,
      step.request_payload,
      step.response_payload,
      step.legacy_request_payload,
      step.legacy_response_payload
    } do
      {%DateTime{}, nil, nil, legacy_request, legacy_response}
      when legacy_request == %{} and legacy_response == %{} ->
        {%{}, %{}}

      {nil, request, response, legacy_request, legacy_response} ->
        {
          read_unpurged_payload!(request, legacy_request),
          read_unpurged_payload!(response, legacy_response)
        }

      _invalid_or_inconsistent ->
        raise ArgumentError, "agent run step payloads are corrupt or inconsistent"
    end
  end

  @doc false
  def hydrate_payloads!(%__MODULE__{} = step) do
    {request, response} = read_payloads!(step)
    %{step | request_payload: request, response_payload: response}
  end

  defp read_unpurged_payload!(payload, _legacy)
       when is_map(payload) and not is_struct(payload),
       do: payload

  defp read_unpurged_payload!(nil, legacy) when is_map(legacy) and not is_struct(legacy),
    do: legacy

  defp read_unpurged_payload!(_payload, _legacy) do
    raise ArgumentError, "agent run step payload is corrupt or inconsistent"
  end
end
