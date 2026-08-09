defmodule Maraithon.Repo.Migrations.AddAgentsOwnerIdentityIndexForRuntime do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_name :agents_id_user_id_unique_index

  def up do
    create_if_not_exists(
      unique_index(:agents, [:id, :user_id],
        name: @index_name,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:agents, [:id, :user_id],
        name: @index_name,
        concurrently: true
      )
    )
  end
end
