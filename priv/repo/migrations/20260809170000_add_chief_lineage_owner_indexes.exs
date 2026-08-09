defmodule Maraithon.Repo.Migrations.AddChiefLineageOwnerIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      unique_index(:connected_accounts, [:id, :user_id, :provider],
        name: :connected_accounts_id_user_provider_unique_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:source_cursors, [:id, :connected_account_id, :user_id, :provider, :kind],
        name: :source_cursors_exact_owner_unique_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:agent_directives, [:id, :agent_id, :user_id],
        name: :agent_directives_id_agent_user_unique_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(
        :agent_directives,
        [:id, :agent_id, :user_id, :terminal_by_generation, :terminal_claim_token],
        name: :agent_directives_terminal_claim_proof_unique_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:agent_runs, [:id, :agent_id, :user_id],
        name: :agent_runs_id_agent_user_unique_index,
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:todos, [:id, :user_id],
        name: :todos_id_user_unique_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      index(:todos, [:id, :user_id],
        name: :todos_id_user_unique_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:agent_runs, [:id, :agent_id, :user_id],
        name: :agent_runs_id_agent_user_unique_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(
        :agent_directives,
        [:id, :agent_id, :user_id, :terminal_by_generation, :terminal_claim_token],
        name: :agent_directives_terminal_claim_proof_unique_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:agent_directives, [:id, :agent_id, :user_id],
        name: :agent_directives_id_agent_user_unique_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:source_cursors, [:id, :connected_account_id, :user_id, :provider, :kind],
        name: :source_cursors_exact_owner_unique_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:connected_accounts, [:id, :user_id, :provider],
        name: :connected_accounts_id_user_provider_unique_index,
        concurrently: true
      )
    )
  end
end
