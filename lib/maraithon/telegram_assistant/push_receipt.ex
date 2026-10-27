defmodule Maraithon.TelegramAssistant.PushReceipt do
  @moduledoc """
  Records proactive Telegram push decisions for dedupe and auditing.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.Accounts.User
  alias Maraithon.TelegramConversations.Turn

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # "nudge" (SPEC 01 R4): NudgeSweep follow-up candidates keep their own
  # origin so receipt telemetry and duplicate suppression stay legible.
  @origin_types ~w(
    insight brief agent_push assistant_digest connector_health dogfood_digest nudge
    staleness_triage todo_completion_confirm
  )
  # `held_rate_limit` covers both interruption-budget and quiet-hours holds.
  # Unlike the other decisions, it must never dedupe-block a future retry —
  # see Maraithon.TelegramAssistant.push_receipt_for/2.
  @decisions ~w(reserved sending delivery_unknown sent_now queued_digest suppressed merged held_rate_limit)

  schema "telegram_push_receipts" do
    field :dedupe_key, :string
    field :origin_type, :string
    field :origin_id, :string
    field :decision, :string
    field :metadata, :map, default: %{}

    belongs_to :user, User, type: :string
    belongs_to :conversation_turn, Turn

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required_fields [:user_id, :dedupe_key, :origin_type, :decision]
  @optional_fields [:origin_id, :conversation_turn_id, :metadata]

  @doc false
  def dedupe_hash(dedupe_key)
      when is_binary(dedupe_key) and byte_size(dedupe_key) in 1..1_024 do
    if String.valid?(dedupe_key) do
      :crypto.hash(:sha256, dedupe_key)
      |> Base.encode16(case: :lower)
    end
  end

  def dedupe_hash(_dedupe_key), do: nil

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:dedupe_key, min: 3, max: 255)
    |> validate_inclusion(:origin_type, @origin_types)
    |> validate_inclusion(:decision, @decisions)
    |> validate_metadata()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:conversation_turn_id)
    |> unique_constraint([:user_id, :dedupe_key])
  end

  defp validate_metadata(changeset) do
    case get_field(changeset, :metadata) do
      metadata when is_map(metadata) and not is_struct(metadata) ->
        if Maraithon.BoundedJSON.valid?(metadata, 8_000,
             max_binary_bytes: 1_000,
             max_depth: 4,
             max_nodes: 150,
             max_map_entries: 20,
             max_list_items: 50
           ) and encoded_metadata_within_limit?(metadata) do
          changeset
        else
          add_error(changeset, :metadata, "is invalid")
        end

      _invalid ->
        add_error(changeset, :metadata, "is invalid")
    end
  end

  defp encoded_metadata_within_limit?(metadata) do
    case Jason.encode(metadata) do
      {:ok, encoded} -> byte_size(encoded) <= 8_000
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end
end
