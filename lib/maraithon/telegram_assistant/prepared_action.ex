defmodule Maraithon.TelegramAssistant.PreparedAction do
  @moduledoc """
  Durable Telegram action awaiting confirmation or recording execution.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.DurablePayload
  alias Maraithon.TelegramAssistant.Run
  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(awaiting_confirmation confirmed executed execution_unknown rejected expired failed)
  @surfaces ~w(telegram mobile)
  @max_payload_bytes 512_000
  @max_preview_bytes 4_000
  @payload_bounds [
    max_binary_bytes: 256_000,
    max_depth: 16,
    max_nodes: 20_000,
    max_map_entries: 2_000,
    max_list_items: 5_000
  ]

  schema "telegram_prepared_actions" do
    field :chat_id, :string
    field :surface, :string, default: "telegram"
    field :action_type, :string
    field :target_type, :string
    field :target_id, :string
    field :payload, Maraithon.Encrypted.Map, source: :payload_ciphertext, redact: true
    field :legacy_payload, :map, source: :payload, default: %{}, redact: true

    field :preview_text, Maraithon.Encrypted.Binary,
      source: :preview_text_ciphertext,
      redact: true

    field :legacy_preview_text, :string, source: :preview_text, redact: true
    field :payload_todo_id, :string
    field :payload_surviving_person_id, :string
    field :payload_merged_person_id, :string
    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :payload_purged_at, :utc_datetime_usec
    field :status, :string, default: "awaiting_confirmation"
    field :expires_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :executed_at, :utc_datetime_usec
    field :error, :string

    belongs_to :user, User, type: :string
    belongs_to :conversation, Conversation
    belongs_to :run, Run

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [
    :user_id,
    :chat_id,
    :surface,
    :run_id,
    :action_type,
    :target_type,
    :payload,
    :preview_text,
    :status,
    :expires_at
  ]
  @optional_fields [:conversation_id, :target_id, :confirmed_at, :executed_at, :error]

  @doc false
  def payload_binding_spec do
    %{
      table: "telegram_prepared_actions",
      identity_fields: [:id],
      scope_fields: [:user_id, :conversation_id, :run_id],
      fields: [:payload, :preview_text],
      purge_field: :payload_purged_at
    }
  end

  def max_payload_bytes, do: @max_payload_bytes
  def max_preview_bytes, do: @max_preview_bytes
  def payload_bounds, do: @payload_bounds

  def changeset(prepared_action, attrs) do
    prepared_action
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:action_type, min: 2, max: 100)
    |> validate_length(:target_type, min: 2, max: 100)
    |> validate_inclusion(:status, @statuses)
    |> DurablePayload.put_bounded_map(:payload, @max_payload_bytes, @payload_bounds)
    |> validate_preview()
    |> promote_payload_facts()
    |> mirror_legacy_payload()
    |> mirror_legacy_preview()
    |> put_payload_encryption_version()
    |> reactivate_payload()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:run_id)
    |> unique_constraint(:user_id, name: :telegram_prepared_actions_awaiting_todo_index)
  end

  @doc false
  def hydrate_payload(action, mode \\ DurablePayload.mode!())

  def hydrate_payload(%__MODULE__{} = action, mode) do
    :ok = DurablePayload.verify_binding!(action, payload_binding_spec(), mode)
    {payload, preview} = read_payload!(action, mode)
    %{action | payload: payload, preview_text: preview}
  end

  def hydrate_payload(other, _mode), do: other

  @doc false
  def read_payload!(%__MODULE__{payload_purged_at: %DateTime{}} = action, _mode) do
    if is_nil(action.payload) and is_nil(action.preview_text) and action.legacy_payload == %{} and
         is_nil(action.legacy_preview_text) and terminal?(action.status) do
      {%{}, nil}
    else
      raise ArgumentError, "purged PreparedAction payload is corrupt or inconsistent"
    end
  end

  def read_payload!(%__MODULE__{} = action, :legacy) do
    payload = action.payload || legacy_map(action.legacy_payload)
    preview = action.preview_text || action.legacy_preview_text

    if json_map?(payload) and valid_preview?(preview),
      do: {payload, preview},
      else: raise(ArgumentError, "PreparedAction payload is corrupt or inconsistent")
  end

  def read_payload!(%__MODULE__{} = action, :exact) do
    if action.payload_encryption_version == 1 and json_map?(action.payload) and
         valid_preview?(action.preview_text) and action.legacy_payload == %{} and
         is_nil(action.legacy_preview_text) do
      {action.payload, action.preview_text}
    else
      raise ArgumentError, "exact PreparedAction payload is not ciphertext-only"
    end
  end

  defp validate_preview(changeset) do
    validate_change(changeset, :preview_text, fn :preview_text, preview ->
      if valid_preview?(preview),
        do: [],
        else: [preview_text: "must be valid UTF-8 between 1 and #{@max_preview_bytes} bytes"]
    end)
  end

  defp promote_payload_facts(changeset) do
    case get_field(changeset, :payload) do
      payload when is_map(payload) ->
        changeset
        |> put_change(:payload_todo_id, promoted_id(payload, "todo_id"))
        |> put_change(:payload_surviving_person_id, promoted_id(payload, "surviving_person_id"))
        |> put_change(:payload_merged_person_id, promoted_id(payload, "merged_person_id"))

      _invalid ->
        changeset
    end
  end

  defp promoted_id(payload, key) do
    value = Map.get(payload, key, Map.get(payload, String.to_existing_atom(key)))

    if is_binary(value) and value != "" and String.valid?(value) and byte_size(value) <= 255,
      do: value,
      else: nil
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

  defp mirror_legacy_preview(changeset) do
    case fetch_change(changeset, :preview_text) do
      {:ok, preview} ->
        put_change(
          changeset,
          :legacy_preview_text,
          if(DurablePayload.legacy_write?(), do: preview, else: nil)
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :payload) or Map.has_key?(changeset.changes, :preview_text),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_payload(changeset) do
    if changeset.data.payload_purged_at &&
         (Map.has_key?(changeset.changes, :payload) or
            Map.has_key?(changeset.changes, :preview_text)),
       do: put_change(changeset, :payload_purged_at, nil),
       else: changeset
  end

  defp valid_preview?(value),
    do:
      is_binary(value) and value != "" and String.valid?(value) and
        byte_size(value) <= @max_preview_bytes

  defp legacy_map(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map(_value), do: nil
  defp json_map?(value), do: is_map(value) and not is_struct(value)
  defp terminal?(status), do: status in ["executed", "rejected", "expired", "failed"]
end
