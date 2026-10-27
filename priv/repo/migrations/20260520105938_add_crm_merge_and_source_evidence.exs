defmodule Maraithon.Repo.Migrations.AddCrmMergeAndSourceEvidence do
  use Ecto.Migration

  def change do
    alter table(:crm_people) do
      add :status, :string, null: false, default: "active"

      add :merged_into_id,
          references(:crm_people, type: :binary_id, on_delete: :nilify_all)

      add :merged_at, :utc_datetime_usec
    end

    create index(:crm_people, [:user_id, :status])
    create index(:crm_people, [:merged_into_id])

    alter table(:crm_person_links) do
      add :role, :string
      add :source_system, :string
      add :source_account, :string
      add :source_ref, :string
      add :evidence_quote, :text
      add :model_rationale, :text
      add :confidence, :float
    end

    create index(:crm_person_links, [:user_id, :source_system, :source_ref])
    create index(:crm_person_links, [:user_id, :role])

    create table(:crm_person_merges, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :surviving_person_id,
          references(:crm_people, type: :binary_id, on_delete: :delete_all),
          null: false

      add :merged_person_id,
          references(:crm_people, type: :binary_id, on_delete: :delete_all),
          null: false

      add :evidence, :text
      add :model_rationale, :text
      add :performed_by, :string
      add :metadata, :map, null: false, default: %{}
      add :performed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:crm_person_merges, [:user_id, :performed_at])
    create index(:crm_person_merges, [:surviving_person_id])
    create index(:crm_person_merges, [:merged_person_id])

    create unique_index(:crm_person_merges, [:user_id, :surviving_person_id, :merged_person_id],
             name: :crm_person_merges_unique_pair
           )
  end
end
