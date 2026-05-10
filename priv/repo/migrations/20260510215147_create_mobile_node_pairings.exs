defmodule Maraithon.Repo.Migrations.CreateMobileNodePairings do
  use Ecto.Migration

  def change do
    create table(:mobile_node_pairings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :code_hash, :binary, null: false
      add :code_nonce, :binary, null: false
      add :status, :string, null: false, default: "pending"
      add :allowed_commands, {:array, :string}, null: false, default: []
      add :expires_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :claimed_device_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mobile_node_pairings, [:user_id, :status, :expires_at])
    create index(:mobile_node_pairings, [:claimed_device_id])

    create table(:mobile_node_devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :device_id, :string, null: false
      add :label, :string
      add :platform, :string
      add :status, :string, null: false, default: "active"
      add :public_key_fingerprint, :string
      add :capabilities, :map, null: false, default: %{}
      add :allowed_commands, {:array, :string}, null: false, default: []
      add :last_seen_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mobile_node_devices, [:user_id, :device_id])
    create index(:mobile_node_devices, [:user_id, :status])
  end
end
