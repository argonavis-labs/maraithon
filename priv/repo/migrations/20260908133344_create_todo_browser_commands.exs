defmodule Maraithon.Repo.Migrations.CreateTodoBrowserCommands do
  use Ecto.Migration

  def change do
    create table(:todo_browser_hosts, primary_key: false) do
      add :id, references(:companion_devices, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :user_id, :string, null: false
      add :seen_at, :utc_datetime_usec, null: false
    end

    create table(:todo_browser_commands, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false

      add :device_id, references(:companion_devices, type: :uuid, on_delete: :delete_all),
        null: false

      add :todo_id, references(:todos, type: :uuid, on_delete: :delete_all), null: false
      add :operation, :string, null: false
      add :payload, :binary, null: false
      add :result, :binary
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:todo_browser_commands, [:device_id, :status, :expires_at])
    create index(:todo_browser_commands, [:user_id, :todo_id, :inserted_at])

    create constraint(:todo_browser_commands, :todo_browser_command_status,
             check:
               "status IN ('pending', 'running', 'completed', 'failed', 'unknown', 'expired')"
           )

    for table <- ~w(todo_browser_hosts todo_browser_commands) do
      execute(
        """
        DO $$ BEGIN
          IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'maraithon_runtime') THEN
            REVOKE ALL ON TABLE public.#{table} FROM PUBLIC;
            GRANT ALL ON TABLE public.#{table} TO maraithon_migrator;
            GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.#{table} TO maraithon_runtime;
            ALTER TABLE public.#{table} OWNER TO maraithon_object_owner;
          END IF;
        END $$;
        """,
        "SELECT 1"
      )
    end
  end
end
