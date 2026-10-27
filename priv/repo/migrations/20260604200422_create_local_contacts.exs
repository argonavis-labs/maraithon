defmodule Maraithon.Repo.Migrations.CreateLocalContacts do
  use Ecto.Migration

  def change do
    create table(:local_contacts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :user_id, references(:users, type: :string, on_delete: :delete_all), null: false
      add :device_id, :uuid, null: false
      add :source, :string, null: false, default: "contacts"
      add :guid, :string, null: false
      add :local_id, :string

      add :display_name, :string
      add :first_name, :string
      add :middle_name, :string
      add :last_name, :string
      add :nickname, :string
      add :organization_name, :string
      add :department_name, :string
      add :job_title, :string

      add :emails, {:array, :string}, null: false, default: []
      add :phones, {:array, :string}, null: false, default: []
      add :urls, {:array, :string}, null: false, default: []
      add :postal_addresses, :map, null: false, default: %{}
      add :payload_hash, :string

      add :crm_person_id, references(:crm_people, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:local_contacts, [:user_id, :device_id, :source, :guid],
             name: :local_contacts_user_device_source_guid_index
           )

    create index(:local_contacts, [:user_id, :display_name])
    create index(:local_contacts, [:user_id, :crm_person_id])
    create index(:local_contacts, [:device_id])

    execute(
      "CREATE INDEX local_contacts_emails_gin_index ON local_contacts USING GIN (emails)",
      "DROP INDEX local_contacts_emails_gin_index"
    )

    execute(
      "CREATE INDEX local_contacts_phones_gin_index ON local_contacts USING GIN (phones)",
      "DROP INDEX local_contacts_phones_gin_index"
    )
  end
end
