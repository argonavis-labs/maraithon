defmodule Maraithon.TelegramConversations.Conversation do
  @moduledoc """
  Durable Telegram conversation root for replies, follow-ups, and general DM chat.

  Conversation summaries are sensitive derivatives of turn content. They use
  additive Cloak ciphertext columns; legacy plaintext is read only during the
  staged backfill and is removed from every new write.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.BoundedJSON
  alias Maraithon.DurablePayload
  alias Maraithon.InsightNotifications.Delivery
  alias Maraithon.Insights.Insight
  alias Maraithon.TelegramConversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(open awaiting_confirmation closed)
  @surfaces ~w(telegram mobile)
  @max_summary_bytes 32_000
  @max_metadata_bytes 160_000
  @metadata_bounds [
    max_binary_bytes: 64_000,
    max_depth: 12,
    max_nodes: 8_000,
    max_map_entries: 1_000,
    max_list_items: 2_000
  ]

  schema "telegram_conversations" do
    field :user_id, :string
    field :chat_id, :string
    field :surface, :string, default: "telegram"
    field :root_message_id, :string
    field :status, :string, default: "open"

    field :summary, Maraithon.Encrypted.Binary, source: :summary_ciphertext, redact: true
    field :legacy_summary, :string, source: :summary, redact: true

    field :historical_summary, Maraithon.Encrypted.Binary,
      source: :historical_summary_ciphertext,
      redact: true

    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true

    field :last_intent, :string
    field :last_turn_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :content_scrubbed_at, :utc_datetime_usec

    belongs_to :linked_delivery, Delivery
    belongs_to :linked_insight, Insight
    has_many :turns, Turn

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :chat_id, :status]
  @optional_fields [
    :surface,
    :root_message_id,
    :linked_delivery_id,
    :linked_insight_id,
    :summary,
    :historical_summary,
    :last_intent,
    :last_turn_at,
    :metadata
  ]

  @doc false
  def payload_binding_spec do
    %{
      table: "telegram_conversations",
      identity_fields: [:id],
      scope_fields: [:user_id],
      fields: [:summary, :historical_summary],
      purge_field: :content_scrubbed_at
    }
  end

  def max_summary_bytes, do: @max_summary_bytes
  def max_metadata_bytes, do: @max_metadata_bytes
  def metadata_bounds, do: @metadata_bounds

  def changeset(conversation, attrs) do
    mode = DurablePayload.mode!()
    attrs = extract_historical_summary(attrs, mode)

    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_sensitive_text(:summary)
    |> validate_sensitive_text(:historical_summary)
    |> validate_metadata()
    |> mirror_legacy_summary(mode)
    |> put_payload_encryption_version()
    |> reactivate_sensitive_content()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_delivery_id)
    |> foreign_key_constraint(:linked_insight_id)
    |> unique_constraint([:chat_id, :root_message_id])
  end

  @doc """
  Hydrates summaries through the database-owned payload protocol.

  Exact mode rejects every legacy summary copy. A malformed Cloak value fails
  while Ecto loads the row and therefore cannot fall back to plaintext.
  """
  def hydrate(conversation, mode \\ DurablePayload.mode!())

  def hydrate(%__MODULE__{} = conversation, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(conversation, payload_binding_spec(), mode)
    {summary, historical_summary, metadata} = read_summaries!(conversation, mode)

    %{
      conversation
      | summary: summary,
        historical_summary: historical_summary,
        metadata: metadata,
        turns: hydrate_turns(conversation.turns, mode)
    }
  end

  def hydrate(other, _mode), do: other

  @doc false
  def read_summaries!(%__MODULE__{content_scrubbed_at: %DateTime{}} = conversation, _mode) do
    metadata = drop_historical_summary(conversation.metadata || %{})

    if is_nil(conversation.summary) and is_nil(conversation.historical_summary) and
         is_nil(conversation.legacy_summary) and metadata == (conversation.metadata || %{}) do
      {nil, nil, metadata}
    else
      raise ArgumentError, "scrubbed Conversation summaries are corrupt or inconsistent"
    end
  end

  def read_summaries!(%__MODULE__{} = conversation, :legacy) do
    summary = conversation.summary || conversation.legacy_summary

    historical_summary =
      conversation.historical_summary || metadata_historical_summary(conversation.metadata)

    metadata =
      conversation.metadata
      |> Kernel.||(%{})
      |> drop_historical_summary()
      |> maybe_put_historical_summary(historical_summary)

    if (is_nil(summary) or is_binary(summary)) and
         (is_nil(historical_summary) or is_binary(historical_summary)) do
      {summary, historical_summary, metadata}
    else
      raise ArgumentError, "Conversation summaries are corrupt or inconsistent"
    end
  end

  def read_summaries!(%__MODULE__{} = conversation, :exact) do
    historical_copy = metadata_historical_summary(conversation.metadata)
    encrypted? = is_binary(conversation.summary) or is_binary(conversation.historical_summary)

    if is_nil(conversation.legacy_summary) and is_nil(historical_copy) and
         (not encrypted? or conversation.payload_encryption_version == 1) do
      metadata =
        conversation.metadata
        |> Kernel.||(%{})
        |> maybe_put_historical_summary(conversation.historical_summary)

      {conversation.summary, conversation.historical_summary, metadata}
    else
      raise ArgumentError, "exact Conversation summaries are not ciphertext-only"
    end
  end

  @doc false
  def legacy_summary_payload?(%__MODULE__{} = conversation) do
    (is_nil(conversation.summary) and is_binary(conversation.legacy_summary)) or
      (is_nil(conversation.historical_summary) and
         is_binary(metadata_historical_summary(conversation.metadata)))
  end

  def legacy_summary_payload?(_conversation), do: false

  defp extract_historical_summary(attrs, mode) when is_map(attrs) and mode in [:legacy, :exact] do
    case fetch_attr(attrs, :metadata) do
      {:ok, metadata} when is_map(metadata) ->
        historical =
          case fetch_attr(attrs, :historical_summary) do
            {:ok, value} -> value
            :error -> metadata_historical_summary(metadata)
          end

        stored_metadata =
          if mode == :legacy and is_binary(historical),
            do: maybe_put_historical_summary(metadata, historical),
            else: drop_historical_summary(metadata)

        attrs
        |> put_attr(:metadata, stored_metadata)
        |> maybe_put_attr(:historical_summary, historical)

      _missing_or_invalid ->
        attrs
    end
  end

  defp extract_historical_summary(attrs, _mode), do: attrs

  defp validate_sensitive_text(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) ->
          []

        not is_binary(value) ->
          [{field, "must be text"}]

        not String.valid?(value) ->
          [{field, "must be valid UTF-8"}]

        :binary.match(value, <<0>>) != :nomatch ->
          [{field, "must not contain null bytes"}]

        byte_size(value) > @max_summary_bytes ->
          [{field, "must be at most #{@max_summary_bytes} bytes"}]

        true ->
          []
      end
    end)
  end

  defp validate_metadata(changeset) do
    validate_change(changeset, :metadata, fn :metadata, value ->
      if is_map(value) and BoundedJSON.valid?(value, @max_metadata_bytes, @metadata_bounds) do
        []
      else
        [metadata: "must be a bounded JSON object"]
      end
    end)
  end

  defp mirror_legacy_summary(changeset, mode) do
    case fetch_change(changeset, :summary) do
      {:ok, summary} -> put_change(changeset, :legacy_summary, if(mode == :legacy, do: summary))
      :error -> changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :summary) or
         Map.has_key?(changeset.changes, :historical_summary) do
      put_change(changeset, :payload_encryption_version, 1)
    else
      changeset
    end
  end

  defp reactivate_sensitive_content(changeset) do
    sensitive_content_changed? =
      Enum.any?([:summary, :historical_summary], fn field ->
        is_binary(get_change(changeset, field))
      end)

    if changeset.data.content_scrubbed_at && sensitive_content_changed?,
      do: put_change(changeset, :content_scrubbed_at, nil),
      else: changeset
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp put_attr(attrs, key, value) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, string_key) -> Map.put(attrs, string_key, value)
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Enum.all?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_key, value)
      true -> Map.put(attrs, key, value)
    end
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: put_attr(attrs, key, value)

  defp metadata_historical_summary(metadata) when is_map(metadata) do
    case Map.fetch(metadata, "historical_summary") do
      {:ok, value} -> value
      :error -> Map.get(metadata, :historical_summary)
    end
  end

  defp metadata_historical_summary(_metadata), do: nil

  defp drop_historical_summary(metadata) when is_map(metadata) do
    Map.drop(metadata, ["historical_summary", :historical_summary])
  end

  defp maybe_put_historical_summary(metadata, value) when is_binary(value),
    do: Map.put(metadata, "historical_summary", value)

  defp maybe_put_historical_summary(metadata, _value), do: metadata

  defp hydrate_turns(%Ecto.Association.NotLoaded{} = turns, _mode), do: turns

  defp hydrate_turns(turns, mode) when is_list(turns),
    do: Enum.map(turns, &Turn.hydrate(&1, mode))

  defp hydrate_turns(turns, _mode), do: turns
end
