defmodule Maraithon.Repo.Migrations.CreateControlCalls do
  use Ecto.Migration

  def change do
    create table(:control_calls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string
      add :method, :string, null: false
      add :idempotency_key, :string, null: false
      add :request_hash, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :result, :map, null: false, default: %{}
      add :error, :map, null: false, default: %{}
      add :expires_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:control_calls, [:method, :idempotency_key])
    create index(:control_calls, [:user_id, :inserted_at])
    create index(:control_calls, [:expires_at])
  end
end
