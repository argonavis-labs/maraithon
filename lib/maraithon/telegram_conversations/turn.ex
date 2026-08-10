defmodule Maraithon.TelegramConversations.Turn do
  @moduledoc """
  One inbound or outbound Telegram turn attached to a conversation.

  Sensitive content is stored in additive Cloak ciphertext columns. The
  `legacy_*` fields map the original plaintext columns only for staged rollout
  reads and the bounded operator backfill; application callers should use
  `text` and `structured_data`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.BoundedJSON
  alias Maraithon.DurablePayload
  alias Maraithon.TelegramConversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(user assistant system)
  @turn_kinds ~w(user_message assistant_reply assistant_push approval_prompt action_result system_notice)
  # "nudge" (SPEC 01 R4): turns pushed for NudgeSweep follow-up candidates.
  @origin_types ~w(chat insight brief agent_push assistant_digest prepared_action system connector_health dogfood_digest nudge)
  @delivery_states ~w(sending sent delivered failed)

  @max_text_bytes 64_000
  @max_structured_data_bytes 160_000
  @structured_data_bounds [
    max_binary_bytes: 64_000,
    max_depth: 12,
    max_nodes: 8_000,
    max_map_entries: 1_000,
    max_list_items: 2_000
  ]
  @legacy_text_tombstone "[encrypted]"

  schema "telegram_conversation_turns" do
    field :role, :string
    field :telegram_message_id, :string
    field :client_message_id, :string
    field :delivery_state, :string, default: "delivered"
    field :reply_to_message_id, :string

    field :text, Maraithon.Encrypted.Binary, source: :text_ciphertext, redact: true

    field :legacy_text, :string,
      source: :text,
      default: @legacy_text_tombstone,
      redact: true

    field :structured_data, Maraithon.Encrypted.Map,
      source: :structured_data_ciphertext,
      redact: true

    field :legacy_structured_data, :map,
      source: :structured_data,
      default: %{},
      redact: true

    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true

    field :intent, :string
    field :confidence, :float
    field :turn_kind, :string, default: "user_message"
    field :origin_type, :string
    field :origin_id, :string

    # Query-safe, deliberately narrow metadata promoted out of the encrypted
    # structured payload. These columns are derived by `changeset/2`; they are
    # not a second general-purpose payload.
    field :text_bytes, :integer, default: 0
    field :assistant_run_id, :binary_id
    field :message_class, :string
    field :prepared_action_id, :binary_id
    field :linked_todo_id, :binary_id
    field :terminal_response, :boolean, default: true
    field :content_scrubbed_at, :utc_datetime_usec

    belongs_to :conversation, Conversation

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:conversation_id, :role, :text]
  @optional_fields [
    :telegram_message_id,
    :client_message_id,
    :delivery_state,
    :reply_to_message_id,
    :intent,
    :confidence,
    :turn_kind,
    :origin_type,
    :origin_id,
    :structured_data
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "telegram_conversation_turns",
      identity_fields: [:id],
      scope_fields: [:conversation_id],
      fields: [:text, :structured_data],
      purge_field: :content_scrubbed_at
    }
  end

  def max_text_bytes, do: @max_text_bytes
  def max_structured_data_bytes, do: @max_structured_data_bytes
  def structured_data_bounds, do: @structured_data_bounds
  def legacy_text_tombstone, do: @legacy_text_tombstone

  def changeset(turn, attrs) do
    attrs = put_new_structured_data(turn, attrs || %{})

    turn
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> put_default_turn_kind()
    |> put_default_origin_type()
    |> validate_required(@required_fields)
    |> validate_inclusion(:role, @roles)
    |> validate_inclusion(:turn_kind, @turn_kinds)
    |> validate_inclusion(:origin_type, @origin_types)
    |> validate_inclusion(:delivery_state, @delivery_states)
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> validate_sensitive_text()
    |> validate_structured_data()
    |> promote_query_metadata()
    |> mirror_legacy_payload()
    |> put_payload_encryption_version()
    |> reactivate_sensitive_content()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:conversation_id)
    # Postgres truncates identifiers to 63 bytes (NAMEDATALEN), so the
    # actual index names in the DB are NOT the full
    # "..._telegram_message_id_index" / "..._client_message_id_index"
    # strings Ecto's default naming would infer — they get cut to exactly
    # 63 chars, dropping the "_index" suffix (and, for the longer name,
    # part of "id" too). Passing the untruncated inferred name as `:name`
    # here would silently fail to match on conflict (Ecto would raise
    # Ecto.ConstraintError instead of routing the error into the
    # changeset), so both names below are the verified, truncated,
    # as-created-in-the-DB constraint names — see
    # `@telegram_message_id_constraint_name` in `TelegramConversations`,
    # which must stay in sync with the first one.
    |> unique_constraint([:conversation_id, :telegram_message_id],
      name: "telegram_conversation_turns_conversation_id_telegram_message_id",
      error_key: :telegram_message_id
    )
    |> unique_constraint([:conversation_id, :client_message_id],
      name: "telegram_conversation_turns_conversation_id_client_message_id_i",
      error_key: :client_message_id
    )
  end

  @doc """
  Hydrates a Turn through the database-owned payload protocol.

  Legacy mode permits a plaintext fallback only when ciphertext is absent.
  Exact mode requires ciphertext for every unredacted payload. Cloak raises
  while loading malformed ciphertext, so corruption can never fall back.
  """
  def hydrate(turn, mode \\ DurablePayload.mode!())

  def hydrate(%__MODULE__{} = turn, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(turn, payload_binding_spec(), mode)
    {text, structured_data} = read_payloads!(turn, mode)
    promoted = promoted_metadata(structured_data, text)

    %{
      turn
      | text: text,
        structured_data: structured_data,
        text_bytes: turn.text_bytes || promoted.text_bytes,
        assistant_run_id: turn.assistant_run_id || promoted.assistant_run_id,
        message_class: turn.message_class || promoted.message_class,
        prepared_action_id: turn.prepared_action_id || promoted.prepared_action_id,
        linked_todo_id: turn.linked_todo_id || promoted.linked_todo_id,
        terminal_response:
          effective_terminal_response(turn.terminal_response, promoted.terminal_response)
    }
  end

  def hydrate(other, _mode), do: other

  @doc false
  def read_payloads!(%__MODULE__{content_scrubbed_at: %DateTime{}} = turn, _mode) do
    if is_nil(turn.text) and is_nil(turn.structured_data) and
         turn.legacy_text == @legacy_text_tombstone and
         legacy_map(turn.legacy_structured_data) == %{} do
      {nil, %{}}
    else
      raise ArgumentError, "scrubbed Turn payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = turn, :legacy) do
    text = turn.text || legacy_text(turn.legacy_text)
    structured_data = turn.structured_data || legacy_map_or_nil(turn.legacy_structured_data)

    if is_binary(text) and is_map(structured_data) and not is_struct(structured_data) do
      {text, structured_data}
    else
      raise ArgumentError, "Turn payload is corrupt or inconsistent"
    end
  end

  def read_payloads!(%__MODULE__{} = turn, :exact) do
    if turn.payload_encryption_version == 1 and is_binary(turn.text) and
         is_map(turn.structured_data) and not is_struct(turn.structured_data) and
         turn.legacy_text == @legacy_text_tombstone and
         legacy_map(turn.legacy_structured_data) == %{} do
      {turn.text, turn.structured_data}
    else
      raise ArgumentError, "exact Turn payload is not ciphertext-only"
    end
  end

  @doc false
  def legacy_payload?(%__MODULE__{} = turn) do
    (is_nil(turn.text) and present_legacy_text?(turn.legacy_text)) or
      (is_nil(turn.structured_data) and map_size(legacy_map(turn.legacy_structured_data)) > 0)
  end

  def legacy_payload?(_turn), do: false

  @doc false
  def effective_assistant_run_id(%__MODULE__{} = turn) do
    hydrated = hydrate(turn)
    hydrated.assistant_run_id || value(hydrated.structured_data, "run_id")
  end

  @doc false
  def effective_message_class(%__MODULE__{} = turn), do: hydrate(turn).message_class

  @doc false
  def effective_linked_todo_id(%__MODULE__{} = turn), do: hydrate(turn).linked_todo_id

  @doc false
  def effective_terminal_response(%__MODULE__{} = turn), do: hydrate(turn).terminal_response

  defp validate_sensitive_text(changeset) do
    validate_change(changeset, :text, fn :text, value ->
      cond do
        not is_binary(value) -> [text: "must be text"]
        not String.valid?(value) -> [text: "must be valid UTF-8"]
        :binary.match(value, <<0>>) != :nomatch -> [text: "must not contain null bytes"]
        byte_size(value) > @max_text_bytes -> [text: "must be at most #{@max_text_bytes} bytes"]
        true -> []
      end
    end)
  end

  defp validate_structured_data(changeset) do
    validate_change(changeset, :structured_data, fn :structured_data, value ->
      if is_map(value) and
           BoundedJSON.valid?(value, @max_structured_data_bytes, @structured_data_bounds) do
        []
      else
        [structured_data: "must be a bounded JSON object"]
      end
    end)
  end

  defp promote_query_metadata(changeset) do
    text = get_field(changeset, :text)
    structured_data = get_field(changeset, :structured_data) || %{}
    promoted = promoted_metadata(structured_data, text)

    changeset
    |> put_change(:text_bytes, promoted.text_bytes)
    |> put_change(:assistant_run_id, promoted.assistant_run_id)
    |> put_change(:message_class, promoted.message_class)
    |> put_change(:prepared_action_id, promoted.prepared_action_id)
    |> put_change(:linked_todo_id, promoted.linked_todo_id)
    |> put_change(:terminal_response, promoted.terminal_response)
  end

  defp promoted_metadata(structured_data, text) do
    %{
      text_bytes: if(is_binary(text), do: byte_size(text), else: 0),
      assistant_run_id: structured_data |> value("run_id") |> cast_uuid(),
      message_class: structured_data |> value("message_class") |> bounded_string(100),
      prepared_action_id: structured_data |> value("prepared_action_id") |> cast_uuid(),
      linked_todo_id: linked_todo_id(structured_data),
      terminal_response: boolean_value(structured_data, "terminal_response", true)
    }
  end

  defp mirror_legacy_payload(changeset) do
    legacy? = DurablePayload.legacy_write?()

    changeset
    |> mirror_legacy_text(legacy?)
    |> mirror_legacy_structured_data(legacy?)
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :text) or
         Map.has_key?(changeset.changes, :structured_data) do
      put_change(changeset, :payload_encryption_version, 1)
    else
      changeset
    end
  end

  defp reactivate_sensitive_content(changeset) do
    if changeset.data.content_scrubbed_at &&
         (Map.has_key?(changeset.changes, :text) or
            Map.has_key?(changeset.changes, :structured_data)) do
      put_change(changeset, :content_scrubbed_at, nil)
    else
      changeset
    end
  end

  defp mirror_legacy_text(changeset, legacy?) do
    case fetch_change(changeset, :text) do
      {:ok, text} ->
        put_change(
          changeset,
          :legacy_text,
          if(legacy?, do: text, else: @legacy_text_tombstone)
        )

      :error ->
        changeset
    end
  end

  defp mirror_legacy_structured_data(changeset, legacy?) do
    case fetch_change(changeset, :structured_data) do
      {:ok, payload} ->
        put_change(changeset, :legacy_structured_data, if(legacy?, do: payload, else: %{}))

      :error ->
        changeset
    end
  end

  defp put_new_structured_data(%__MODULE__{id: nil}, attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :structured_data) or Map.has_key?(attrs, "structured_data") -> attrs
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, "structured_data", %{})
      true -> Map.put(attrs, :structured_data, %{})
    end
  end

  defp put_new_structured_data(_turn, attrs), do: attrs

  defp put_default_turn_kind(changeset) do
    case get_field(changeset, :turn_kind) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        put_change(changeset, :turn_kind, default_turn_kind(get_field(changeset, :role)))
    end
  end

  defp put_default_origin_type(changeset) do
    case get_field(changeset, :origin_type) do
      value when is_binary(value) and value != "" ->
        changeset

      _ ->
        put_change(changeset, :origin_type, default_origin_type(get_field(changeset, :role)))
    end
  end

  defp linked_todo_id(structured_data) do
    direct = value(structured_data, "linked_todo_id")
    linked_todo = value(structured_data, "linked_todo")
    nested = if is_map(linked_todo), do: value(linked_todo, "id"), else: nil
    cast_uuid(direct || nested)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.reduce_while(map, nil, fn
          {map_key, value}, _acc when is_atom(map_key) ->
            if Atom.to_string(map_key) == key,
              do: {:halt, value},
              else: {:cont, nil}

          _other, _acc ->
            {:cont, nil}
        end)
    end
  end

  defp value(_map, _key), do: nil

  defp boolean_value(map, key, default) do
    case value(map, key) do
      true -> true
      false -> false
      _other -> default
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp cast_uuid(_value), do: nil

  defp bounded_string(value, max_bytes) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed != "" and byte_size(trimmed) <= max_bytes and String.valid?(trimmed) and
         :binary.match(trimmed, <<0>>) == :nomatch,
       do: trimmed,
       else: nil
  end

  defp bounded_string(_value, _max_bytes), do: nil

  defp legacy_text(@legacy_text_tombstone), do: nil
  defp legacy_text(value) when is_binary(value), do: value
  defp legacy_text(_value), do: nil

  defp present_legacy_text?(value), do: is_binary(legacy_text(value))

  defp legacy_map(value) when is_map(value), do: value
  defp legacy_map(_value), do: %{}

  defp legacy_map_or_nil(value) when is_map(value) and not is_struct(value), do: value
  defp legacy_map_or_nil(_value), do: nil

  defp effective_terminal_response(value, _fallback) when is_boolean(value), do: value
  defp effective_terminal_response(_value, fallback), do: fallback

  defp default_turn_kind("assistant"), do: "assistant_reply"
  defp default_turn_kind("system"), do: "system_notice"
  defp default_turn_kind(_role), do: "user_message"

  defp default_origin_type("assistant"), do: "chat"
  defp default_origin_type("system"), do: "system"
  defp default_origin_type(_role), do: "chat"
end
