defmodule Maraithon.Repo.Migrations.CreateCompanionDevices do
  use Ecto.Migration

  def change do
    create table(:companion_devices, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, :string, null: false
      add :device_id, :uuid, null: false
      add :device_name, :string
      add :token_hash, :string, null: false
      add :last_seen_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:companion_devices, [:user_id, :device_id])
    create unique_index(:companion_devices, [:token_hash])
    create index(:companion_devices, [:user_id])
    create index(:companion_devices, [:last_seen_at])
  end
end
