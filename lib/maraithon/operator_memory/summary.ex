defmodule Maraithon.OperatorMemory.Summary do
  @moduledoc """
  Compact long-term memory summaries derived from Telegram interactions and active rules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Maraithon.DurablePayload

  @legacy_tombstone "[encrypted]"
  @max_content_bytes 5_000

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @summary_types ~w(telegram_behavior content_preferences action_style interrupt_policy)

  schema "operator_memory_summaries" do
    field :user_id, :string
    field :summary_type, :string
    field :content, Maraithon.Encrypted.Binary, source: :content_ciphertext, redact: true

    field :legacy_content, :string,
      source: :content,
      default: @legacy_tombstone,
      redact: true

    field :payload_encryption_version, :integer
    field :payload_binding_version, :integer
    field :payload_binding_key_tag, :string
    field :payload_binding_mac, :binary, redact: true
    field :content_erased_at, :utc_datetime_usec
    field :source_window_start, :utc_datetime_usec
    field :source_window_end, :utc_datetime_usec
    field :confidence, :float, default: 0.0

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :summary_type, :content]
  @optional_fields [:source_window_start, :source_window_end, :confidence]

  def legacy_tombstone, do: @legacy_tombstone
  @doc false
  def payload_binding_spec do
    %{
      table: "operator_memory_summaries",
      identity_fields: [:id],
      scope_fields: [:user_id],
      fields: [:content],
      purge_field: :content_erased_at
    }
  end

  def max_content_bytes, do: @max_content_bytes

  def changeset(summary, attrs) do
    summary
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:summary_type, @summary_types)
    |> validate_length(:content, min: 4, max: 5000)
    |> validate_content_bytes()
    |> mirror_legacy_content()
    |> put_payload_encryption_version()
    |> reactivate_content()
    |> DurablePayload.put_binding(payload_binding_spec())
    |> DurablePayload.require_current_mutation()
    |> validate_number(:confidence, greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:user_id, :summary_type])
  end

  @doc false
  def hydrate_content(summary, mode \\ DurablePayload.mode!())

  def hydrate_content(%__MODULE__{} = summary, mode) when mode in [:legacy, :exact] do
    :ok = DurablePayload.verify_binding!(summary, payload_binding_spec(), mode)
    %{summary | content: read_content!(summary, mode)}
  end

  def hydrate_content(other, _mode), do: other

  @doc false
  def read_content!(%__MODULE__{content_erased_at: %DateTime{}} = summary, _mode) do
    if is_nil(summary.content) and summary.legacy_content == @legacy_tombstone do
      nil
    else
      raise ArgumentError, "erased OperatorMemory content is corrupt or inconsistent"
    end
  end

  def read_content!(%__MODULE__{} = summary, :legacy) do
    case summary.content || legacy_content(summary.legacy_content) do
      content when is_binary(content) -> content
      _invalid -> raise ArgumentError, "OperatorMemory content is corrupt or inconsistent"
    end
  end

  def read_content!(%__MODULE__{} = summary, :exact) do
    if summary.payload_encryption_version == 1 and is_binary(summary.content) and
         summary.legacy_content == @legacy_tombstone do
      summary.content
    else
      raise ArgumentError, "exact OperatorMemory content is not ciphertext-only"
    end
  end

  defp validate_content_bytes(changeset) do
    validate_change(changeset, :content, fn :content, value ->
      if is_binary(value) and String.valid?(value) and byte_size(value) <= @max_content_bytes,
        do: [],
        else: [content: "must be at most #{@max_content_bytes} UTF-8 bytes"]
    end)
  end

  defp mirror_legacy_content(changeset) do
    case fetch_change(changeset, :content) do
      {:ok, content} ->
        put_change(
          changeset,
          :legacy_content,
          if(DurablePayload.legacy_write?(), do: content, else: @legacy_tombstone)
        )

      :error ->
        changeset
    end
  end

  defp put_payload_encryption_version(changeset) do
    if Map.has_key?(changeset.changes, :content),
      do: put_change(changeset, :payload_encryption_version, 1),
      else: changeset
  end

  defp reactivate_content(changeset) do
    if changeset.data.content_erased_at && Map.has_key?(changeset.changes, :content),
      do: put_change(changeset, :content_erased_at, nil),
      else: changeset
  end

  defp legacy_content(@legacy_tombstone), do: nil
  defp legacy_content(value) when is_binary(value), do: value
  defp legacy_content(_value), do: nil
end
