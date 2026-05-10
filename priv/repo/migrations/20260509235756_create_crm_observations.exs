defmodule Maraithon.Repo.Migrations.CreateCrmObservations do
  use Ecto.Migration

  def change do
    create table(:crm_observations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :string, null: false
      add :source, :string, null: false
      add :source_account, :string
      add :source_item_id, :string, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :direction, :string, null: false
      add :participants, {:array, :map}, null: false, default: []
      add :subject, :text
      add :excerpt, :text
      add :metadata, :map, null: false, default: %{}
      add :resolved_person_ids, {:array, :binary_id}, null: false, default: []

      add :window_id,
          references(:crm_ingest_windows, type: :binary_id, on_delete: :nilify_all)

      add :flushed_at, :utc_datetime_usec
      add :learned_at, :utc_datetime_usec
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:crm_observations, [:user_id, :source, :source_item_id],
             name: :crm_observations_user_source_item_index
           )

    create index(:crm_observations, [:user_id, :source, :window_id])
    create index(:crm_observations, [:user_id, :occurred_at])
    create index(:crm_observations, [:window_id])
  end
end
