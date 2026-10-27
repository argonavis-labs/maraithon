defmodule Maraithon.Repo.Migrations.AddDirectionAndCounterpartyToTodos do
  use Ecto.Migration

  def change do
    alter table(:todos) do
      add :direction, :string, null: false, default: "owed_by_me"

      add :counterparty_person_id,
          references(:crm_people, type: :binary_id, on_delete: :nilify_all)

      add :counterparty_label, :string
    end

    create index(:todos, [:user_id, :direction, :status])
    create index(:todos, [:counterparty_person_id])
  end
end
