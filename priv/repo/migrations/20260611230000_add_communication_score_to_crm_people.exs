defmodule Maraithon.Repo.Migrations.AddCommunicationScoreToCrmPeople do
  use Ecto.Migration

  def change do
    alter table(:crm_people) do
      add :communication_score, :integer, null: false, default: 0
    end

    create index(:crm_people, [:user_id, :communication_score])
  end
end
