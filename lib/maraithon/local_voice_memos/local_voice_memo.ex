defmodule Maraithon.LocalVoiceMemos.LocalVoiceMemo do
  @moduledoc """
  Append-only mirror of a macOS Voice Memos recording synced from a
  companion device. `title` and `snippet` are stored encrypted at rest via
  the existing Cloak vault (`Maraithon.Encrypted.Binary`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_voice_memos" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "voice_memos"
    field :guid, :string
    field :local_id, :string
    field :title, Maraithon.Encrypted.Binary
    field :snippet, Maraithon.Encrypted.Binary
    field :duration_seconds, :integer
    field :file_size_bytes, :integer
    field :created_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source]
  @optional_fields [
    :guid,
    :local_id,
    :title,
    :snippet,
    :duration_seconds,
    :file_size_bytes,
    :created_at
  ]

  def changeset(memo, attrs) do
    memo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_voice_memos_user_device_source_guid_index
    )
  end
end
