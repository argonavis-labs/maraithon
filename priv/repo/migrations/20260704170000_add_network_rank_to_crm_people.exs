defmodule Maraithon.Repo.Migrations.AddNetworkRankToCrmPeople do
  use Ecto.Migration

  def change do
    alter table(:crm_people) do
      add :network_rank, :integer, null: false, default: 0
    end

    create index(:crm_people, [:user_id, :network_rank])
  end
end
