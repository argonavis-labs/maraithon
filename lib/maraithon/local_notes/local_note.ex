defmodule Maraithon.LocalNotes.LocalNote do
  @moduledoc """
  Append-only mirror of a macOS Notes.app note synced from a companion
  device. `title`, `snippet`, and `body` are stored encrypted at rest
  via the existing Cloak vault (`Maraithon.Encrypted.Binary`).
  `body_format` records the encoding the companion shipped — today
  always `"plain"`, but the column exists so a future RTF / Markdown
  payload doesn't need another migration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_notes" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "notes"
    field :guid, :string
    field :local_id, :string
    field :title, Maraithon.Encrypted.Binary
    field :snippet, Maraithon.Encrypted.Binary
    field :body, Maraithon.Encrypted.Binary
    field :body_format, :string, default: "plain"
    field :folder, :string
    field :is_pinned, :boolean, default: false
    field :created_at, :utc_datetime_usec
    field :modified_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:user_id, :device_id, :source]
  @optional_fields [
    :guid,
    :local_id,
    :title,
    :snippet,
    :body,
    :body_format,
    :folder,
    :is_pinned,
    :created_at,
    :modified_at
  ]

  def changeset(note, attrs) do
    note
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> validate_length(:body_format, max: 32)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_notes_user_device_source_guid_index
    )
  end
end
