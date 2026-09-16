defmodule Maraithon.LocalCalendar.LocalEvent do
  @moduledoc """
  Mirror of a macOS Calendar.app event synced from a companion
  device through EventKit. `title` and `notes` are stored encrypted at
  rest via the existing Cloak vault (`Maraithon.Encrypted.Binary`).

  The macOS Calendar.app aggregates iCloud, Exchange, Google, and any
  CalDAV calendars the user has added locally. Changed-event ingestion alone
  does not prove that the mirror covers a complete window. Each row is one
  occurrence: recurring events are expanded by the EventKit reader so
  date-window queries don't need to evaluate recurrence rules on the
  server.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "local_calendar_events" do
    field :user_id, :string
    field :device_id, Ecto.UUID
    field :source, :string, default: "calendar"
    field :guid, :string
    field :local_id, :string
    field :calendar_name, :string
    field :calendar_color, :string
    field :source_state, :map, default: %{}
    field :title, Maraithon.Encrypted.Binary
    field :notes, Maraithon.Encrypted.Binary
    field :location, :string
    field :start_at, :utc_datetime_usec
    field :end_at, :utc_datetime_usec
    field :is_all_day, :boolean, default: false
    field :is_recurring, :boolean, default: false
    field :organizer_email, :string
    field :attendees_count, :integer, default: 0
    field :attendee_emails, {:array, :string}, default: []
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
    :calendar_name,
    :calendar_color,
    :source_state,
    :title,
    :notes,
    :location,
    :start_at,
    :end_at,
    :is_all_day,
    :is_recurring,
    :organizer_email,
    :attendees_count,
    :attendee_emails,
    :created_at,
    :modified_at,
    :encrypted_with_device_key,
    :key_id
  ]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields ++ [:source_state])
    |> validate_length(:source, max: 64)
    |> validate_length(:calendar_name, max: 255)
    |> validate_length(:calendar_color, max: 32)
    |> validate_length(:location, max: 1024)
    |> validate_length(:organizer_email, max: 255)
    |> validate_change(:source_state, &validate_source_state/2)
    |> unique_constraint([:user_id, :device_id, :source, :guid],
      name: :local_calendar_events_user_device_source_guid_index
    )
  end

  # This is device-reported state, not proof of account ownership or a complete
  # window. Old clients leave it empty; no missing state implies availability.
  @source_states %{
    "event_status" => ~w(unknown confirmed tentative cancelled),
    "availability" => ~w(unknown busy free tentative unavailable),
    "self_response" =>
      ~w(unknown pending accepted declined tentative delegated completed in_process)
  }
  @source_ids ~w(calendar_id source_id source_name external_id)

  defp validate_source_state(_field, state) when state == %{}, do: []

  defp validate_source_state(field, state) do
    valid? =
      state["version"] == 1 and
        Enum.all?(@source_states, fn {key, values} -> state[key] in values end) and
        Enum.all?(state, fn
          {"version", 1} -> true
          {key, value} when key in @source_ids -> is_binary(value) and byte_size(value) <= 2048
          {key, value} -> value in Map.get(@source_states, key, [])
        end)

    if valid?, do: [], else: [{field, "must contain a supported calendar source state"}]
  end
end
