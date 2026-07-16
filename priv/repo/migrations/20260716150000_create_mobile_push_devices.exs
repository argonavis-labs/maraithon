defmodule Maraithon.Repo.Migrations.CreateMobilePushDevices do
  use Ecto.Migration

  def change do
    create table(:mobile_push_devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :device_token, :string, null: false
      add :platform, :string, null: false, default: "ios"
      add :app_version, :string
      add :environment, :string
      add :status, :string, null: false, default: "active"
      add :last_seen_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mobile_push_devices, [:device_token])
    create index(:mobile_push_devices, [:user_id, :status])
  end
end
