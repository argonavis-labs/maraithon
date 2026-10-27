defmodule Maraithon.Repo.Migrations.AddRelationshipMetricsToCrmPeople do
  use Ecto.Migration

  def change do
    alter table(:crm_people) do
      add :interaction_count, :integer, null: false, default: 0
      add :relationship_strength, :integer, null: false, default: 0
      add :affinity_score, :integer, null: false, default: 0
      add :last_interaction_at, :utc_datetime_usec
    end

    create index(:crm_people, [:user_id, :last_interaction_at])
    create index(:crm_people, [:user_id, :relationship_strength])
    create index(:crm_people, [:user_id, :affinity_score])
  end
end
