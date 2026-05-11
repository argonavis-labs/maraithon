defmodule Maraithon.LocalVoiceMemos.LocalVoiceMemo do
  @moduledoc """
  Append-only mirror of a macOS Voice Memos recording synced from a
  companion device. `title`, `snippet`, and `transcript` are stored
  encrypted at rest via the existing Cloak vault
  (`Maraithon.Encrypted.Binary`). `audio_bytes` carries the raw `.m4a`
  bytes for memos that fit under the per-record cap; oversize files are
  passed through with `audio_truncated = true` and a nil `audio_bytes`.
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

    # v1.5: raw `.m4a` bytes + on-device transcript.
    field :audio_bytes, :binary
    field :audio_truncated, :boolean, default: false
    field :audio_mime, :string, default: "audio/m4a"
    field :transcript, Maraithon.Encrypted.Binary
    field :transcript_engine, :string
    field :transcript_lang, :string

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
    :created_at,
    :audio_bytes,
    :audio_truncated,
    :audio_mime,
    :transcript,
    :transcript_engine,
    :transcript_lang
  ]

  def changeset(memo, attrs) do
    memo
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> validate_length(:audio_mime, max: 64)
    |> validate_length(:transcript_engine, max: 64)
    |> validate_length(:transcript_lang, max: 16)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_voice_memos_user_device_source_guid_index
    )
  end
end
