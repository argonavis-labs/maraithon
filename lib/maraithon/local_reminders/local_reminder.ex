defmodule Maraithon.LocalReminders.LocalReminder do
  @moduledoc """
  Append-only mirror of a macOS Reminders.app item synced from a
  companion device via EventKit. `title` and `notes` are stored
  encrypted at rest via the existing Cloak vault
  (`Maraithon.Encrypted.Binary`).

  `priority` follows the EventKit convention: `0` is the default "no
  priority", `1` is the highest priority, and `9` is the lowest. The
  column stays integer so we don't have to project string buckets
  ("none" / "low" / "medium" / "high") in the migration — callers that
  need a bucket can derive one from the integer.

  `guid` is the EventKit `calendarItemIdentifier`, stable across the
  reminder's lifetime.

  `list_name` mirrors the parent EventKit calendar's title at sync
  time. We snapshot it on the row so that searches and rollups don't
  need to JOIN against a calendar table; if the user renames a list
  the next sync will rewrite the column.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_reminders" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "reminders"
    field :guid, :string
    field :local_id, :string
    field :list_name, :string
    field :list_color, :string
    field :title, Maraithon.Encrypted.Binary
    field :notes, Maraithon.Encrypted.Binary
    field :priority, :integer, default: 0
    field :due_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :is_completed, :boolean, default: false
    field :has_alarm, :boolean, default: false
    field :url_attachment, :string
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
    :list_name,
    :list_color,
    :title,
    :notes,
    :priority,
    :due_at,
    :completed_at,
    :is_completed,
    :has_alarm,
    :url_attachment,
    :created_at,
    :modified_at,
    :encrypted_with_device_key,
    :key_id
  ]

  def changeset(reminder, attrs) do
    reminder
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:source, max: 64)
    |> validate_length(:list_name, max: 255)
    |> validate_length(:list_color, max: 32)
    |> validate_length(:url_attachment, max: 2048)
    |> validate_number(:priority, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_reminders_user_device_source_guid_index
    )
  end
end
