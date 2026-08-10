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

    field :summary, Maraithon.Encrypted.Binary, source: :summary_ciphertext
    field :legacy_summary, :string, source: :summary
    field :historical_summary, Maraithon.Encrypted.Binary, source: :historical_summary_ciphertext

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

  def max_summary_bytes, do: @max_summary_bytes
  def max_metadata_bytes, do: @max_metadata_bytes
  def metadata_bounds, do: @metadata_bounds

  def changeset(conversation, attrs) do
    attrs = extract_historical_summary(attrs)

    conversation
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:surface, @surfaces)
    |> validate_length(:chat_id, min: 1, max: 255)
    |> validate_sensitive_text(:summary)
    |> validate_sensitive_text(:historical_summary)
    |> validate_metadata()
    |> clear_legacy_summary()
    |> reactivate_sensitive_content()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:linked_delivery_id)
    |> foreign_key_constraint(:linked_insight_id)
    |> unique_constraint([:chat_id, :root_message_id])
  end

  @doc """
  Hydrates pre-encryption summary fields for the rollout window.

  Ciphertext always wins. Cloak load failures therefore fail closed rather than
  silently falling back to a potentially stale plaintext copy.
  """
  def hydrate(%__MODULE__{} = conversation) do
    if conversation.content_scrubbed_at do
      %{
        conversation
        | summary: nil,
          historical_summary: nil,
          metadata: drop_historical_summary(conversation.metadata || %{}),
          turns: hydrate_turns(conversation.turns)
      }
    else
      historical_summary =
        conversation.historical_summary || metadata_historical_summary(conversation.metadata)

      metadata =
        conversation.metadata
        |> Kernel.||(%{})
        |> drop_historical_summary()
        |> maybe_put_historical_summary(historical_summary)

      %{
        conversation
        | summary: conversation.summary || conversation.legacy_summary,
          historical_summary: historical_summary,
          metadata: metadata,
          turns: hydrate_turns(conversation.turns)
      }
    end
  end

  def hydrate(other), do: other

  @doc false
  def legacy_summary_payload?(%__MODULE__{} = conversation) do
    (is_nil(conversation.summary) and is_binary(conversation.legacy_summary)) or
      (is_nil(conversation.historical_summary) and
         is_binary(metadata_historical_summary(conversation.metadata)))
  end

  def legacy_summary_payload?(_conversation), do: false

  defp extract_historical_summary(attrs) when is_map(attrs) do
    case fetch_attr(attrs, :metadata) do
      {:ok, metadata} when is_map(metadata) ->
        historical =
          case fetch_attr(attrs, :historical_summary) do
            {:ok, value} -> value
            :error -> metadata_historical_summary(metadata)
          end

        attrs
        |> put_attr(:metadata, drop_historical_summary(metadata))
        |> maybe_put_attr(:historical_summary, historical)

      _missing_or_invalid ->
        attrs
    end
  end

  defp extract_historical_summary(attrs), do: attrs

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

  defp clear_legacy_summary(changeset) do
    if Map.has_key?(changeset.changes, :summary),
      do: put_change(changeset, :legacy_summary, nil),
      else: changeset
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

  defp hydrate_turns(%Ecto.Association.NotLoaded{} = turns), do: turns
  defp hydrate_turns(turns) when is_list(turns), do: Enum.map(turns, &Turn.hydrate/1)
  defp hydrate_turns(turns), do: turns
end
