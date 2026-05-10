defmodule Maraithon.Repo.Migrations.EnablePgTrgmForCrmPersons do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create_if_not_exists index(
                           :crm_people,
                           ["display_name gin_trgm_ops"],
                           name: :crm_people_display_name_trgm_index,
                           using: :gin,
                           concurrently: true
                         )

    create_if_not_exists index(
                           :crm_people,
                           [
                             "(coalesce(first_name, '') || ' ' || coalesce(last_name, '')) gin_trgm_ops"
                           ],
                           name: :crm_people_full_name_trgm_index,
                           using: :gin,
                           concurrently: true
                         )
  end

  def down do
    drop_if_exists index(:crm_people, [:display_name], name: :crm_people_display_name_trgm_index)

    drop_if_exists index(:crm_people, [:display_name],
                     name: :crm_people_full_name_trgm_index
                   )

    # Leave pg_trgm extension installed; other queries may depend on it.
  end
end
