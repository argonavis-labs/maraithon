defmodule Maraithon.Repo.Migrations.CreateCommitments do
  use Ecto.Migration

  def change do
    create table(:commitments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :source_id, :string
      add :title, :string, null: false
      add :owed_to, :string
      add :project, :string
      add :due_at, :utc_datetime_usec
      add :status, :string, null: false, default: "open"
      add :priority, :integer, null: false, default: 50
      add :evidence, {:array, :string}, null: false, default: []
      add :metadata, :map, null: false, default: %{}
      add :closed_at, :utc_datetime_usec
      add :snoozed_until, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:commitments, [:user_id, :status])
    create index(:commitments, [:user_id, :due_at])
    create index(:commitments, [:source, :source_id])

    create unique_index(:commitments, [:user_id, :source, :source_id],
             where: "source_id IS NOT NULL"
           )
  end
end
