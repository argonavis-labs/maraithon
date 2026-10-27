defmodule Maraithon.Repo.Migrations.CreateMessageSendCommands do
  use Ecto.Migration

  def change do
    create table(:message_send_hosts, primary_key: false) do
      add :id, references(:companion_devices, type: :uuid, on_delete: :delete_all),
        primary_key: true

      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :seen_at, :utc_datetime_usec, null: false
    end

    create table(:message_send_commands, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :device_id, references(:companion_devices, type: :uuid, on_delete: :delete_all),
        null: false

      add :todo_id, references(:todos, type: :uuid, on_delete: :delete_all), null: false
      add :payload, :binary, null: false
      add :result, :binary
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false
      add :payload_purged_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:message_send_commands, [:device_id, :status, :expires_at])
    create index(:message_send_commands, [:user_id, :todo_id, :inserted_at])

    create constraint(:message_send_commands, :message_send_command_status,
             check:
               "status IN ('pending', 'running', 'completed', 'failed', 'unknown', 'expired')"
           )

    for table <- ~w(message_send_hosts message_send_commands) do
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
