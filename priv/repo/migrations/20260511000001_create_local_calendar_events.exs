defmodule Maraithon.Repo.Migrations.CreateLocalCalendarEvents do
  use Ecto.Migration

  def change do
    create table(:local_calendar_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "calendar"
      add :guid, :string
      add :local_id, :string
      add :calendar_name, :string
      add :calendar_color, :string
      add :title, :binary
      add :notes, :binary
      add :location, :string
      add :start_at, :utc_datetime_usec
      add :end_at, :utc_datetime_usec
      add :is_all_day, :boolean, null: false, default: false
      add :is_recurring, :boolean, null: false, default: false
      add :organizer_email, :string
      add :attendees_count, :integer, null: false, default: 0
      add :attendee_emails, {:array, :string}, null: false, default: []
      add :created_at, :utc_datetime_usec
      add :modified_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_calendar_events, [:user_id, :device_id, :source, :guid],
             name: :local_calendar_events_user_device_source_guid_index
           )

    create index(:local_calendar_events, [:user_id, :start_at])
    create index(:local_calendar_events, [:user_id, :calendar_name, :start_at])
    create index(:local_calendar_events, [:device_id])
  end
end
