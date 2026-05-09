defmodule Maraithon.Repo.Migrations.CreateCrmPeople do
  use Ecto.Migration

  def change do
    create table(:crm_people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :first_name, :string
      add :last_name, :string
      add :display_name, :string, null: false
      add :contact_details, :map, null: false, default: %{}
      add :preferred_communication_method, :string
      add :relationship, :string
      add :communication_frequency, :string
      add :notes, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:crm_people, [:user_id])
    create index(:crm_people, [:user_id, :display_name])
    create index(:crm_people, [:user_id, :relationship])
    create index(:crm_people, [:user_id, :preferred_communication_method])
    create index(:crm_people, [:user_id, :communication_frequency])

    execute(
      "CREATE INDEX crm_people_contact_details_gin_index ON crm_people USING GIN (contact_details)",
      "DROP INDEX crm_people_contact_details_gin_index"
    )

    create table(:crm_person_links, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false

      add :person_id,
          references(:crm_people, type: :binary_id, on_delete: :delete_all),
          null: false

      add :resource_type, :string, null: false
      add :resource_id, :string, null: false
      add :resource_source, :string
      add :title, :string
      add :summary, :text
      add :relationship_note, :text
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:crm_person_links, [:user_id, :person_id])
    create index(:crm_person_links, [:user_id, :resource_type, :resource_id])
    create unique_index(:crm_person_links, [:user_id, :person_id, :resource_type, :resource_id])
  end
end
