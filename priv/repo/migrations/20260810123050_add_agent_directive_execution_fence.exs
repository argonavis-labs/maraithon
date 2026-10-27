defmodule Maraithon.Repo.Migrations.AddAgentDirectiveExecutionFence do
  use Ecto.Migration

  def up do
    alter table(:agent_directives) do
      add :active_run_id, :binary_id
      add :effect_admitted_at, :utc_datetime_usec
      add :effect_count, :integer, null: false, default: 0
      add :ambiguity_code, :string
    end

    create unique_index(:agent_runs, [:id, :agent_id], name: :agent_runs_id_agent_id_unique_index)

    create unique_index(:agent_directives, [:active_run_id],
             where: "active_run_id IS NOT NULL",
             name: :agent_directives_active_run_id_index
           )

    execute """
    ALTER TABLE agent_directives
    ADD CONSTRAINT agent_directives_active_run_owner_fkey
    FOREIGN KEY (active_run_id, agent_id)
    REFERENCES agent_runs(id, agent_id)
    ON DELETE RESTRICT
    """

    create constraint(:agent_directives, :agent_directives_effect_count_check,
             check: "effect_count >= 0"
           )

    create constraint(:agent_directives, :agent_directives_effect_boundary_check,
             check:
               "(effect_count = 0 AND effect_admitted_at IS NULL) OR " <>
                 "(effect_count > 0 AND effect_admitted_at IS NOT NULL AND active_run_id IS NOT NULL)"
           )

    create constraint(:agent_directives, :agent_directives_ambiguity_code_check,
             check:
               "ambiguity_code IS NULL OR " <>
                 "(char_length(ambiguity_code) BETWEEN 1 AND 64 AND " <>
                 "ambiguity_code !~ '[^a-z0-9_]')"
           )
  end

  def down do
    drop constraint(:agent_directives, :agent_directives_ambiguity_code_check)
    drop constraint(:agent_directives, :agent_directives_effect_boundary_check)
    drop constraint(:agent_directives, :agent_directives_effect_count_check)

    execute """
    ALTER TABLE agent_directives
    DROP CONSTRAINT IF EXISTS agent_directives_active_run_owner_fkey
    """

    drop_if_exists index(:agent_directives, [:active_run_id],
                     name: :agent_directives_active_run_id_index
                   )

    drop_if_exists index(:agent_runs, [:id, :agent_id],
                     name: :agent_runs_id_agent_id_unique_index
                   )

    alter table(:agent_directives) do
      remove :ambiguity_code
      remove :effect_count
      remove :effect_admitted_at
      remove :active_run_id
    end
  end
end
