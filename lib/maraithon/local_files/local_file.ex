defmodule Maraithon.LocalFiles.LocalFile do
  @moduledoc """
  Append-only mirror of a macOS file synced from a companion device.
  Tracks files under `~/Documents`, `~/Desktop`, and `~/Downloads`.

  `filename` and `text_content` are stored encrypted at rest via the
  existing Cloak vault (`Maraithon.Encrypted.Binary`) because both can
  leak project, person, or content context. `path` is stored plain —
  with the home directory redacted to `~/` on the client — so we can
  build substring filters without decrypting every row.

  `text_content` is the extracted plaintext from PDFs, Markdown, .txt,
  .rtf, .rtfd, .docx, and .pages files. Other extensions (images,
  archives, etc.) record metadata only and leave `text_content` nil.
  Extraction is capped at 200 KB after decoding; oversize text sets
  `text_truncated = true` and stores nothing in `text_content`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_files" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "files"
    field :guid, :string
    field :local_id, :string
    field :path, :string
    field :filename, Maraithon.Encrypted.Binary
    field :extension, :string
    field :mime_type, :string
    field :byte_size, :integer
    field :text_content, Maraithon.Encrypted.Binary
    field :text_truncated, :boolean, default: false
    field :created_at, :utc_datetime_usec
    field :modified_at, :utc_datetime_usec
    field :encrypted_with_device_key, :boolean, default: false
    field :key_id, :string

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source]
  @optional_fields [
    :guid,
    :local_id,
    :path,
    :filename,
    :extension,
    :mime_type,
    :byte_size,
    :text_content,
    :text_truncated,
    :created_at,
    :modified_at,
    :encrypted_with_device_key,
    :key_id
  ]

  def changeset(file, attrs) do
    file
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> validate_length(:extension, max: 64)
    |> validate_length(:mime_type, max: 128)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_files_user_device_source_guid_index
    )
  end
end
