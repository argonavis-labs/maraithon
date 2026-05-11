defmodule Maraithon.LocalMessages.LocalMessage do
  @moduledoc """
  Append-only mirror of a local-context message synced from a companion
  device. `text` and `sender_handle` are stored encrypted at rest via the
  existing Cloak vault (`Maraithon.Encrypted.Binary`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_messages" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string
    field :guid, :string
    field :local_id, :string
    field :is_from_me, :boolean, default: false
    field :sender_handle, Maraithon.Encrypted.Binary
    field :chat_key, :string
    field :chat_display_name, :string
    field :chat_style, :string
    field :text, Maraithon.Encrypted.Binary
    field :sent_at, :utc_datetime_usec
    field :has_attachments, :boolean, default: false
    field :attachments, :map, default: %{}
    field :encrypted_with_device_key, :boolean, default: false
    field :key_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source]
  @optional_fields [
    :guid,
    :local_id,
    :is_from_me,
    :sender_handle,
    :chat_key,
    :chat_display_name,
    :chat_style,
    :text,
    :sent_at,
    :has_attachments,
    :attachments,
    :encrypted_with_device_key,
    :key_id
  ]

  def changeset(message, attrs) do
    message
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_messages_user_device_source_guid_index
    )
  end
end
