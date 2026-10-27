defmodule Maraithon.Repo.Migrations.WidenLocalCalendarEventIdentityColumns do
  use Ecto.Migration

  def up do
    alter table(:local_calendar_events) do
      modify :guid, :text
      modify :local_id, :text
      modify :location, :text
    end
  end

  def down do
    alter table(:local_calendar_events) do
      modify :guid, :string
      modify :local_id, :string
      modify :location, :string
    end
  end
end
