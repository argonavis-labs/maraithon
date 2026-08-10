defmodule Maraithon.TelegramAssistant.Run do
  @moduledoc """
  Persisted Telegram assistant orchestration run.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.DurablePayload
  alias Maraithon.TelegramAssistant.Step
  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @trigger_types ~w(inbound_message reply agent_push brief insight_push follow_up scheduled_digest)
  @statuses ~w(queued running waiting_confirmation completed failed cancelled degraded)
  @surfaces ~w(telegram mobile)
  @max_prompt_snapshot_bytes 640_000
  @max_result_summary_bytes 256_000
  @payload_bounds [
    max_binary_bytes: 128_000,
    max_depth: 16,
    max_nodes: 20_000,
    max_map_entries: 2_000,
    max_list_items: 4_000
  ]

  schema "telegram_assistant_runs" do
    field :chat_id, :string
    field :surface, :string, default: "telegram"
    field :trigger_type, :string
    field :status, :string, default: "running"
    field :model_provider, :string
    field :model_name, :string

    field :prompt_snapshot, Maraithon.Encrypted.Map,
      source: :prompt_snapshot_ciphertext,
      redact: true

    field :legacy_prompt_snapshot, :map,
      source: :prompt_snapshot,
      default: %{},
      redact: true

    field :result_summary, Maraithon.Encrypted.Map,
      source: :result_summary_ciphertext,
      redact: true

    field :legacy_result_summary, :map,
      source: :result_summary,
      default: %{},
      redact: true

    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :delivery_checkpoint_source_message_id, :string
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :error, :string

    belongs_to :user, User, type: :string
    belongs_to :conversation, Conversation
    has_many :steps, Step, foreign_key: :run_id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :chat_id,
    :surface,
    :trigger_type,
    :status,
    :model_provider,
    :model_name,
    :prompt_snapshot,
    :started_at
  ]
  @optional_fields [:conversation_id, :result_summary, :finished_at, :error]

  @doc false
  def payload_binding_spec do
    %{
      table: "telegram_assistant_runs",
      identity_fields: [:id],
      scope_fields: [:user_id, :conversation_id],
      fields: [:prompt_snapshot, :result_summary],
      purge_field: :payload_purged_at
    }
  end

  def max_prompt_snapshot_bytes, do: @max_prompt_snapshot_bytes
  def max_result_summary_bytes, do: @max_result_summary_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(run, attrs) do
    attrs = put_new_payload_defaults(run, attrs || %{})

    run
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_inclusion(:trigger_type, @trigger_types)
    |> validate_inclusion(:status, @statuses)
    |> DurablePayload.put_bounded_map(
      :prompt_snapshot,
      @max_prompt_snapshot_bytes,
      @payload_bounds
    )
    |> DurablePayload.put_bounded_map(:result_summary, @max_result_summary_bytes, @payload_bounds)
    |> promote_result_facts()
    |> mirror_legacy_payload(:prompt_snapshot, :legacy_prompt_snapshot)
    |> mirror_legacy_payload(:result_summary, :legacy_result_summary)
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
  end

  @doc false
  def hydrate_payloads(run, mode \\ DurablePayload.mode!())

  def hydrate_payloads(%__MODULE__{} = run, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(run, payload_binding_spec(), mode)
    {prompt_snapshot, result_summary} = read_payloads!(run, mode)
    %{run | prompt_snapshot: prompt_snapshot, result_summary: result_summary}
  end

  def hydrate_payloads(other, _mode), do: other

  @doc false
  def read_payloads!(%__MODULE__{payload_purged_at: %DateTime{}} = run, _mode) do
    if is_nil(run.prompt_snapshot) and is_nil(run.result_summary) and
         empty_map?(run.legacy_prompt_snapshot) and empty_map?(run.legacy_result_summary) do
      {%{}, %{}}
    else
      raise ArgumentError, "purged assistant Run payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = run, :legacy) do
    prompt = run.prompt_snapshot || legacy_map(run.legacy_prompt_snapshot)
    result = run.result_summary || legacy_map(run.legacy_result_summary)

    if json_map?(prompt) and json_map?(result) do
      {prompt, result}
    else
      raise ArgumentError, "assistant Run payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = run, :exact) do
    if run.payload_encryption_version == 1 and json_map?(run.prompt_snapshot) and
         json_map?(run.result_summary) and empty_map?(run.legacy_prompt_snapshot) and
         empty_map?(run.legacy_result_summary) do
      {run.prompt_snapshot, run.result_summary}
    else
      raise ArgumentError, "exact assistant Run payload is not ciphertext-only"
    end
  end

  defp put_new_payload_defaults(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    attrs
    |> put_attr_default(:prompt_snapshot, %{})
    |> put_attr_default(:result_summary, %{})
  end

  defp put_new_payload_defaults(_run, attrs), do: attrs

  defp put_attr_default(attrs, field, default) do
    string_field = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) or Map.has_key?(attrs, string_field) -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_field, default)
      true -> Map.put(attrs, field, default)
    end
  end

  defp promote_result_facts(changeset) do
    case get_field(changeset, :result_summary) do
      result when is_map(result) ->
        source_message_id =
          result
          |> map_value("delivery_checkpoint", %{})
          |> map_value("source_message_id", nil)
          |> bounded_string(255)

        put_change(changeset, :delivery_checkpoint_source_message_id, source_message_id)

      _invalid ->
        changeset
    end
  end

  defp map_value(map, key, default) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> atom_key_value(map, key, default)
    end
  end

  defp atom_key_value(map, key, default) do
    Enum.find_value(map, default, fn
      {atom, value} when is_atom(atom) -> if Atom.to_string(atom) == key, do: value
      _entry -> nil
    end)
  end

  defp map_value(_map, _key, default), do: default

  defp bounded_string(value, max_bytes) when is_binary(value) do
    value = String.trim(value)

    if value != "" and String.valid?(value) and byte_size(value) <= max_bytes,
      do: value,
      else: nil
  end

  defp bounded_string(_value, _max_bytes), do: nil

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
    if Map.has_key?(changeset.changes, :prompt_snapshot) or
         Map.has_key?(changeset.changes, :result_summary) do
      put_change(changeset, :payload_encryption_version, 1)
    else
      changeset
    end
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at &&
         (Map.has_key?(changeset.changes, :prompt_snapshot) or
            Map.has_key?(changeset.changes, :result_summary)) do
      put_change(changeset, :payload_purged_at, nil)
    else
      changeset
    end
  end

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
  defp empty_map?(value), do: value == %{}
end
